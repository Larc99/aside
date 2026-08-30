import XCTest
import CryptoKit
import GRDB
@testable import Aside

final class NoteCipherTests: XCTestCase {
    func testRoundtrip() throws {
        let key = SymmetricKey(size: .bits256)
        let body = "apple\n4x banana\ndry fruits 🥜"
        let sealed = try NoteCipher.encrypt(body, key: key)
        XCTAssertNotNil(sealed)
        XCTAssertNotEqual(sealed, Data(body.utf8))
        XCTAssertEqual(try NoteCipher.decrypt(sealed, key: key), body)
    }

    func testEmptyBodyEncodesToNil() throws {
        let key = SymmetricKey(size: .bits256)
        XCTAssertNil(try NoteCipher.encrypt("", key: key))
        XCTAssertEqual(try NoteCipher.decrypt(nil, key: key), "")
    }

    func testWrongKeyFails() throws {
        let sealed = try NoteCipher.encrypt("secret", key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try NoteCipher.decrypt(sealed, key: SymmetricKey(size: .bits256)))
    }
}

final class LocalNoteStoreTests: XCTestCase {
    private func makeStore() throws -> LocalNoteStore {
        let database = try AppDatabase.inMemory()
        return LocalNoteStore(database: database, key: SymmetricKey(size: .bits256))
    }

    /// Regression: a body encrypted under a key we no longer have came back as
    /// an empty string with no marker, and `NoteCipher.encrypt("")` returns
    /// nil — so any incidental save (a colour change, a pin, an archive) wrote
    /// `bodyEnc = NULL` and destroyed content the recovery pass could still
    /// have rescued.
    func testAnUnreadableBodyIsNeverOverwrittenByAnIncidentalSave() async throws {
        let database = try AppDatabase.inMemory()
        let originalKey = SymmetricKey(size: .bits256)
        let writer = LocalNoteStore(database: database, key: originalKey)

        let note = Note(title: "Payload", body: "the text that must survive")
        try await writer.upsert(note)

        // Reopen with a different key, exactly as a key change would.
        let strangerKey = SymmetricKey(size: .bits256)
        let stranger = LocalNoteStore(database: database, key: strangerKey)

        let seen = try await stranger.fetch(filter: .all, query: "")
        let damaged = try XCTUnwrap(seen.first)
        XCTAssertTrue(damaged.bodyUnavailable, "An undecryptable body must be flagged, not look empty")
        XCTAssertEqual(damaged.body, "")

        // The incidental edit: recolour the note without ever opening it.
        var recoloured = damaged
        recoloured.colorIndex = NoteColor.mint.rawValue
        try await stranger.upsert(recoloured)

        // The metadata change lands...
        let afterEdit = try await stranger.fetch(filter: .all, query: "")
        XCTAssertEqual(afterEdit.first?.colorIndex, NoteColor.mint.rawValue)

        // ...and the ciphertext is still intact for whoever holds the real key.
        let rightful = LocalNoteStore(database: database, key: originalKey)
        let recovered = try await rightful.fetch(filter: .all, query: "")
        XCTAssertEqual(recovered.first?.body, "the text that must survive")
        XCTAssertFalse(recovered.first?.bodyUnavailable ?? true)
    }

    /// The guard must not freeze a body the user genuinely edits.
    func testTypingIntoADamagedNoteReplacesTheUnreadableBody() async throws {
        let database = try AppDatabase.inMemory()
        let writer = LocalNoteStore(database: database, key: SymmetricKey(size: .bits256))
        try await writer.upsert(Note(title: "Payload", body: "unreadable later"))

        let newKey = SymmetricKey(size: .bits256)
        let store = LocalNoteStore(database: database, key: newKey)
        let damagedRows = try await store.fetch(filter: .all, query: "")
        let damaged = try XCTUnwrap(damagedRows.first)

        try await NoteContentWriter.saveContent(
            {
                var draft = damaged
                draft.body = "typed fresh"
                return draft
            }(),
            to: store
        )

        let after = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(after.first?.body, "typed fresh")
        XCTAssertFalse(after.first?.bodyUnavailable ?? true)
    }

    func testAllKnownIDsIncludesSoftDeletedRows() async throws {
        let store = try makeStore()
        let note = Note(title: "trashed")
        try await store.upsert(note)
        try await store.softDelete(id: note.id)

        let visible = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(visible.isEmpty)
        // Import collision-checking depends on this: without it an import
        // silently overwrote and un-deleted a trashed note.
        let known = try await store.allKnownIDs()
        XCTAssertTrue(known.contains(note.id))
    }

    func testCreateFetchAndFilter() async throws {
        let store = try makeStore()

        let active = Note(title: "Groceries", body: "apples", tag: "home")
        let archived = Note(title: "Old plan", body: "history", archivedAt: Date())
        try await store.upsert(active)
        try await store.upsert(archived)

        let all = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(all.count, 2)

        let activeOnly = try await store.fetch(filter: .active, query: "")
        XCTAssertEqual(activeOnly.map(\.id), [active.id])

        let archivedOnly = try await store.fetch(filter: .archived, query: "")
        XCTAssertEqual(archivedOnly.map(\.id), [archived.id])

        let byBody = try await store.fetch(filter: .all, query: "apples")
        XCTAssertEqual(byBody.map(\.id), [active.id])

        let byTag = try await store.fetch(filter: .all, query: "home")
        XCTAssertEqual(byBody.map(\.id), [active.id])
        XCTAssertEqual(byTag.map(\.id), [active.id])
    }

    func testBodiesAreEncryptedAtRest() async throws {
        let database = try AppDatabase.inMemory()
        let key = SymmetricKey(size: .bits256)
        let store = LocalNoteStore(database: database, key: key)

        try await store.upsert(Note(title: "Visible", body: "plaintext-secret"))

        let raw: Data? = try await database.writer.read { db in
            try Data.fetchOne(db, sql: "SELECT bodyEnc FROM note WHERE title = ?", arguments: ["Visible"])
        }
        XCTAssertNotNil(raw)
        XCTAssertNotEqual(raw, Data("plaintext-secret".utf8))
        XCTAssertNil(String(data: raw!, encoding: .utf8)?.range(of: "plaintext-secret"))
    }

    func testSoftDeleteRestoreAndPurge() async throws {
        let store = try makeStore()
        let note = Note(title: "Bye")
        try await store.upsert(note)

        try await store.softDelete(id: note.id)
        let afterDelete = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(afterDelete.isEmpty)

        try await store.restore(id: note.id)
        let restored = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(restored.count, 1)

        try await store.purge(id: note.id)
        let remaining = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(remaining.isEmpty)
    }
}

final class StickyArchiveTests: XCTestCase {
    func testRoundtripKeepsStatesColorsAndDates() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let note = Note(
            title: "Groceries",
            body: "apples",
            colorIndex: 3,
            tag: "home",
            sortIndex: -5,
            createdAt: created,
            updatedAt: created.addingTimeInterval(60),
            archivedAt: created.addingTimeInterval(30)
        )

        let archive = StickyArchive(notes: [StickiedNote(note: note)])
        let data = try archive.encoded()
        let decoded = try StickyArchive.decoded(from: data)

        XCTAssertEqual(decoded.notes.count, 1)
        let restored = decoded.notes[0].note
        XCTAssertEqual(restored.id, note.id)
        XCTAssertEqual(restored.title, note.title)
        XCTAssertEqual(restored.body, note.body)
        XCTAssertEqual(restored.colorIndex, 3)
        XCTAssertEqual(restored.tag, "home")
        XCTAssertEqual(restored.sortIndex, -5)
        XCTAssertEqual(restored.createdAt, created)
        XCTAssertEqual(restored.archivedAt, note.archivedAt)
    }

    func testImportArrivesActive() async throws {
        let database = try AppDatabase.inMemory()
        let store = LocalNoteStore(database: database, key: SymmetricKey(size: .bits256))

        let archived = Note(title: "Old", body: "history", archivedAt: Date())
        let archive = StickyArchive(notes: [StickiedNote(note: archived)])
        let data = try archive.encoded()

        let decoded = try StickyArchive.decoded(from: data)
        for stickied in decoded.notes {
            var note = stickied.note
            note.archivedAt = nil
            note.deletedAt = nil
            try await store.upsert(note)
        }

        let fetched = try await store.fetch(filter: .active, query: "")
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].title, "Old")
    }

    func testStickyImportPreservesArchiveStateAndDates() {
        let archivedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let original = Note(
            title: "Archived",
            pinned: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_050),
            archivedAt: archivedAt
        )

        let prepared = TransferService.prepareIncoming(
            [original],
            existingIDs: [],
            preservesArchiveState: true
        )

        XCTAssertEqual(prepared.first, original)
        XCTAssertEqual(prepared.first?.archivedAt, archivedAt)
        XCTAssertTrue(prepared.first?.pinned == true)
    }

    func testPlainFileImportArrivesActiveAndUnpinned() {
        let original = Note(title: "Imported", pinned: true, archivedAt: Date(), deletedAt: Date())
        let prepared = TransferService.prepareIncoming(
            [original],
            existingIDs: [],
            preservesArchiveState: false
        )

        XCTAssertNil(prepared.first?.archivedAt)
        XCTAssertNil(prepared.first?.deletedAt)
        XCTAssertFalse(prepared.first?.pinned == true)
    }
}
