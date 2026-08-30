import Foundation
import CryptoKit
import GRDB

/// Persistence abstraction. The local store keeps bodies AES-GCM-encrypted at
/// rest; the optional sync-folder store writes plain files instead.
protocol NoteStore: Sendable {
    func fetch(filter: NoteFilter, query: String) async throws -> [Note]
    /// Every id the store knows about, *including* soft-deleted rows that
    /// `fetch` hides. Import uses this so a collision with a trashed note
    /// appends a copy instead of silently overwriting and un-deleting it.
    func allKnownIDs() async throws -> Set<UUID>
    func upsert(_ note: Note) async throws
    func softDelete(id: UUID) async throws
    func restore(id: UUID) async throws
    func purge(id: UUID) async throws
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
        let live = try await store.fetch(filter: .all, query: "")
        // A note missing here was purged or soft-deleted while we were typing.
        // Dropping the write is deliberate: it must not resurrect.
        guard var note = live.first(where: { $0.id == draft.id }) else { return false }

        // A body we could not decrypt stays untouched unless the user actually
        // typed something, so an incidental save cannot erase the ciphertext.
        if note.bodyUnavailable && draft.body.isEmpty {
            guard note.title != draft.title
                    || note.colorIndex != draft.colorIndex
                    || note.tag != draft.tag else { return false }
        } else {
            guard note.title != draft.title
                    || note.body != draft.body
                    || note.colorIndex != draft.colorIndex
                    || note.tag != draft.tag else { return false }
            note.body = draft.body
            note.bodyUnavailable = false
        }

        note.title = draft.title
        note.colorIndex = draft.colorIndex
        note.tag = draft.tag
        note.updatedAt = Date()
        try await store.upsert(note)
        return true
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
        _ change: (inout Note) -> Void
    ) async throws -> Bool {
        let live = try await store.fetch(filter: .all, query: "")
        guard var note = live.first(where: { $0.id == id }) else { return false }
        if let draft {
            note.title = draft.title
            if !note.bodyUnavailable || !draft.body.isEmpty {
                note.body = draft.body
                note.bodyUnavailable = false
            }
            note.tag = draft.tag
        }
        change(&note)
        note.updatedAt = Date()
        try await store.upsert(note)
        return true
    }
}

struct LocalNoteStore: NoteStore {
    private let database: AppDatabase
    private let key: SymmetricKey

    init(database: AppDatabase, key: SymmetricKey) {
        self.database = database
        self.key = key
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

        var notes: [Note] = []
        for record in records {
            do {
                notes.append(try NoteMapper.note(from: record, key: key))
            } catch {
                // Body encrypted under an older key. Keep the row's metadata
                // with an empty body — recovery runs as a background pass
                // (recoverUndecryptableRows), and a damaged row must never
                // blank the whole list. The `bodyUnavailable` marker keeps a
                // later save from writing the placeholder back over the
                // ciphertext.
                notes.append(NoteMapper.noteSkippingBody(from: record))
            }
        }

        if !query.isEmpty {
            notes = notes.filter { $0.matches(query: query) }
        }
        return notes
    }

    /// One-shot per launch: re-reads rows whose body cannot be decrypted with
    /// the current key and tries the legacy keychain key. Runs entirely off
    /// the main thread — the consent prompt (if any) can take its time. On
    /// success rows are re-encrypted under the current key and the change is
    /// broadcast so the UI refreshes.
    func recoverUndecryptableRows() async {
        let records = (try? await database.writer.read { db in
            // Unfiltered: a soft-deleted note can still be restored, so its
            // body has to be recovered too.
            try NoteRecord.fetchAll(db, sql: "SELECT * FROM note")
        }) ?? []

        var damaged: [NoteRecord] = []
        for record in records {
            if (try? NoteMapper.note(from: record, key: key)) == nil {
                damaged.append(record)
            }
        }
        guard !damaged.isEmpty else { return }

        guard let legacy = KeyStore.legacyKeychainKey() else { return }

        for record in damaged {
            guard let recovered = try? NoteMapper.note(from: record, key: legacy) else { continue }
            try? await database.writer.write { db in
                // Built inside the write closure: record mutation stays
                // confined to the database write (Swift 6 sendability).
                if let reencrypted = try? NoteMapper.record(from: recovered, key: key) {
                    try reencrypted.update(db)
                }
            }
        }
        NotificationCenter.default.post(name: .noteStoreChanged, object: nil)
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
            var record = try NoteMapper.record(from: note, key: key)
            if note.bodyUnavailable {
                // We could not read this body, so we are not entitled to
                // replace it. Encrypting the placeholder would write NULL and
                // destroy content the recovery pass can still rescue.
                record.bodyEnc = try NoteRecord
                    .filter(key: note.id.uuidString)
                    .fetchOne(db)?
                    .bodyEnc
            }
            try record.save(db)
        }
        postChanged()
    }

    func softDelete(id: UUID) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE note SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [Date(), Date(), id.uuidString]
            )
        }
        postChanged()
    }

    func restore(id: UUID) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE note SET deletedAt = NULL, updatedAt = ? WHERE id = ?",
                arguments: [Date(), id.uuidString]
            )
        }
        postChanged()
    }

    func purge(id: UUID) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM note WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
        postChanged()
    }

    private func postChanged() {
        NotificationCenter.default.post(name: .noteStoreChanged, object: nil)
    }
}
