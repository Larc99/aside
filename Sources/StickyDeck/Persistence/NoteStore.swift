import Foundation
import GRDB

/// Identifies one specific tombstone generation. Undo and expiry must carry
/// this value back to the store: an older UI owner must never restore or purge
/// a note that was subsequently restored and deleted again elsewhere.
struct DeletionToken: Sendable, Equatable {
    let noteID: UUID
    let deletedAt: Date
}

/// Persistence abstraction. Both stores keep bodies as plain text — the local
/// one in SQLite inside the app's sandbox container, the optional sync-folder
/// one as Markdown files in a folder the user chose.
protocol NoteStore: Sendable {
    func fetch(filter: NoteFilter, query: String) async throws -> [Note]
    /// Every id the store knows about, *including* soft-deleted rows that
    /// `fetch` hides. Import uses this so a collision with a trashed note
    /// appends a copy instead of silently overwriting and un-deleting it.
    func allKnownIDs() async throws -> Set<UUID>
    func upsert(_ note: Note) async throws
    /// Atomically changes the current live copy of one note. Returns false
    /// when the note was deleted, purged, or the closure made no change.
    ///
    /// Editors use this instead of a fetch followed by an upsert: another
    /// task can delete a note (or swap StoreHub's backing library) at either
    /// suspension point in that two-call sequence.
    @discardableResult
    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool
    /// Tombstones a live note and returns the exact generation written. Returns
    /// nil when the note is missing or already tombstoned, so two surfaces
    /// cannot both claim ownership of the same deletion.
    @discardableResult
    func softDelete(id: UUID) async throws -> DeletionToken?
    /// Restores only the tombstone represented by `token`.
    @discardableResult
    func restore(_ token: DeletionToken) async throws -> Bool
    /// Permanently removes only the tombstone represented by `token`.
    @discardableResult
    func purge(_ token: DeletionToken) async throws -> Bool
}

enum NoteStoreError: Error, LocalizedError {
    case notFound
    /// The store declined the write because its stored copy is newer. The
    /// caller must reload rather than treat the write as applied.
    case staleWrite

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "That note is no longer in your library."
        case .staleWrite:
            return "A newer version of this note arrived from another Mac, so this change was not saved."
        }
    }
}

/// Writes only user-authored content onto the note as the store currently
/// holds it.
///
/// Every editor in the app saves on a 250 ms debounce over a *snapshot*. A
/// plain `upsert` of that snapshot re-writes the whole row, so a note that was
/// archived, unpinned or deleted while the timer ran comes back from the dead.
/// Routing debounced saves through here keeps state fields owned by the store
/// and lets a purged note simply drop the write.
enum NoteContentWriter {
    /// Returns true when a write actually reached the store. Callers that arm
    /// an echo-suppression flag need this: a dropped write posts no change
    /// notification, so arming unconditionally swallowed the next genuine one.
    @discardableResult
    static func saveContent(_ draft: Note, to store: any NoteStore) async throws -> Bool {
        try await store.mutate(id: draft.id) { note in
            note.title = draft.title
            if !draft.bodyNeedsMigration || !draft.body.isEmpty {
                note.body = draft.body
                note.bodyNeedsMigration = false
            }
            note.colorIndex = draft.colorIndex
            note.tag = draft.tag
        }
    }

    /// The All Notes preview edits only the body. Giving that surface the
    /// broader content writer let its stale row snapshot roll back a newer
    /// title, colour or tag chosen in the deck/sticky while the debounce sat.
    @discardableResult
    static func saveBody(_ draft: Note, to store: any NoteStore) async throws -> Bool {
        try await store.mutate(id: draft.id) { note in
            if !draft.bodyNeedsMigration || !draft.body.isEmpty {
                note.body = draft.body
                note.bodyNeedsMigration = false
            }
        }
    }

    /// Applies a state change (pin, archive, colour) onto the note as the store
    /// currently holds it, carrying across the caller's content.
    ///
    /// A whole-row upsert of a UI snapshot always carries `deletedAt: nil`,
    /// because both stores' `fetch` hides tombstones — so pinning or
    /// recolouring a note that was deleted elsewhere brought it back.
    @discardableResult
    static func applyStateChange(
        to id: UUID,
        from draft: Note?,
        in store: any NoteStore,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool {
        try await store.mutate(id: id) { note in
            if let draft {
                note.title = draft.title
                if !draft.bodyNeedsMigration || !draft.body.isEmpty {
                    note.body = draft.body
                    note.bodyNeedsMigration = false
                }
                note.tag = draft.tag
            }
            change(&note)
        }
    }
}

struct LocalNoteStore: NoteStore {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] {
        var clauses = ["deletedAt IS NULL"]
        if filter == .active { clauses.append("archivedAt IS NULL") }
        if filter == .archived { clauses.append("archivedAt IS NOT NULL") }
        let sql = "SELECT * FROM note WHERE " + clauses.joined(separator: " AND ")
            + " ORDER BY sortIndex ASC, createdAt DESC"

        let records = try await database.writer.read { db in
            try NoteRecord.fetchAll(db, sql: sql)
        }

        var notes = try records.map(NoteMapper.note(from:))

        if !query.isEmpty {
            notes = notes.filter { $0.matches(query: query) }
        }
        return notes
    }

    func allKnownIDs() async throws -> Set<UUID> {
        // Deliberately unfiltered: soft-deleted rows still own their id.
        let ids = try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM note")
        }
        return Set(ids.compactMap(UUID.init(uuidString:)))
    }

    func upsert(_ note: Note) async throws {
        try await database.writer.write { db in
            var record = NoteMapper.record(from: note)
            if note.bodyNeedsMigration,
               let existing = try NoteRecord
                .filter(key: note.id.uuidString)
                .fetchOne(db) {
                // A pre-migration UI snapshot owns no body text. Preserve
                // whichever representation the database has now: ciphertext
                // if recovery is still pending, or plaintext if it completed
                // while this draft was open.
                record.body = existing.body
                record.bodyEnc = existing.bodyEnc
            }
            try record.save(db)
        }
        postChanged()
    }

    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool {
        let didChange = try await database.writer.write { db in
            guard let existing = try NoteRecord
                .filter(Column("id") == id.uuidString && Column("deletedAt") == nil)
                .fetchOne(db) else { return false }

            var note = try NoteMapper.note(from: existing)
            let original = note
            change(&note)

            // Identity, creation time and deletion state belong to the store;
            // callers of this live-note API cannot move or resurrect a row.
            note.id = original.id
            note.createdAt = original.createdAt
            note.deletedAt = original.deletedAt
            note.updatedAt = original.updatedAt
            guard note != original else { return false }
            note.updatedAt = max(Date(), original.updatedAt.addingTimeInterval(0.001))

            var record = NoteMapper.record(from: note)
            if note.bodyNeedsMigration {
                // A compatibility placeholder still owns no body. Preserve
                // both representations until migration either recovers it or
                // a real user edit intentionally replaces it.
                record.body = existing.body
                record.bodyEnc = existing.bodyEnc
            }
            try record.save(db)
            return true
        }
        if didChange { postChanged() }
        return didChange
    }

    func softDelete(id: UUID) async throws -> DeletionToken? {
        let token = try await database.writer.write { db -> DeletionToken? in
            guard var record = try NoteRecord
                .filter(Column("id") == id.uuidString && Column("deletedAt") == nil)
                .fetchOne(db) else { return nil }

            // Use the same monotonic stamp for both fields. Besides ordering the
            // tombstone after the live copy, this makes rapid restore/re-delete
            // cycles produce distinct deletion generations.
            let deletedAt = max(Date(), record.updatedAt.addingTimeInterval(0.001))
            record.deletedAt = deletedAt
            record.updatedAt = deletedAt
            try record.update(db)
            return DeletionToken(noteID: id, deletedAt: deletedAt)
        }
        if token != nil { postChanged() }
        return token
    }

    func restore(_ token: DeletionToken) async throws -> Bool {
        let didRestore = try await database.writer.write { db in
            guard var record = try NoteRecord
                .filter(
                    Column("id") == token.noteID.uuidString
                        && Column("deletedAt") == token.deletedAt
                )
                .fetchOne(db) else { return false }

            record.deletedAt = nil
            record.updatedAt = max(Date(), record.updatedAt.addingTimeInterval(0.001))
            try record.update(db)
            return true
        }
        if didRestore { postChanged() }
        return didRestore
    }

    func purge(_ token: DeletionToken) async throws -> Bool {
        let didPurge = try await database.writer.write { db in
            try NoteRecord
                .filter(
                    Column("id") == token.noteID.uuidString
                        && Column("deletedAt") == token.deletedAt
                )
                .deleteAll(db) > 0
        }
        if didPurge { postChanged() }
        return didPurge
    }

    private func postChanged() {
        NotificationCenter.default.post(name: .noteStoreChanged, object: nil)
    }
}
