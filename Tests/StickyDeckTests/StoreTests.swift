import XCTest
import CryptoKit
import GRDB
@testable import StickyDeck

private final class CleanupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

final class LocalNoteStoreTests: XCTestCase {
    private func makeStore() throws -> LocalNoteStore {
        let database = try AppDatabase.inMemory()
        return LocalNoteStore(database: database)
    }

    func testAllKnownIDsIncludesSoftDeletedRows() async throws {
        let store = try makeStore()
        let note = Note(title: "trashed")
        try await store.upsert(note)
        _ = try await store.softDelete(id: note.id)

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

    func testBodiesRoundTripThroughTheDatabase() async throws {
        let database = try AppDatabase.inMemory()
        let store = LocalNoteStore(database: database)

        try await store.upsert(Note(title: "Visible", body: "line one\nline two 🥜"))

        let reopened = LocalNoteStore(database: database)
        let notes = try await reopened.fetch(filter: .all, query: "")
        XCTAssertEqual(notes.first?.body, "line one\nline two 🥜")
    }

    func testSoftDeleteRestoreAndPurge() async throws {
        let store = try makeStore()
        let note = Note(title: "Bye")
        try await store.upsert(note)

        let firstDeletionResult = try await store.softDelete(id: note.id)
        let firstDeletion = try XCTUnwrap(firstDeletionResult)
        let afterDelete = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(afterDelete.isEmpty)

        let didRestore = try await store.restore(firstDeletion)
        XCTAssertTrue(didRestore)
        let restored = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(restored.count, 1)

        let secondDeletionResult = try await store.softDelete(id: note.id)
        let secondDeletion = try XCTUnwrap(secondDeletionResult)
        let didPurge = try await store.purge(secondDeletion)
        XCTAssertTrue(didPurge)
        let remaining = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDeletionTokenCannotAffectARestoredOrNewerDeletion() async throws {
        let store = try makeStore()
        let note = Note(title: "Keep the newer state")
        try await store.upsert(note)

        let firstResult = try await store.softDelete(id: note.id)
        let first = try XCTUnwrap(firstResult)
        let duplicate = try await store.softDelete(id: note.id)
        XCTAssertNil(duplicate, "an existing tombstone has one owner")
        let didRestoreFirst = try await store.restore(first)
        XCTAssertTrue(didRestoreFirst)
        let didRestoreConsumed = try await store.restore(first)
        XCTAssertFalse(didRestoreConsumed, "a consumed Undo token is stale")
        let didPurgeRestored = try await store.purge(first)
        XCTAssertFalse(didPurgeRestored, "expiry must not purge a restored note")
        let afterRestore = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(afterRestore.map(\.id), [note.id])

        let secondResult = try await store.softDelete(id: note.id)
        let second = try XCTUnwrap(secondResult)
        XCTAssertNotEqual(first, second)
        let didRestoreNewerWithOldToken = try await store.restore(first)
        XCTAssertFalse(didRestoreNewerWithOldToken, "old Undo must not revive a newer deletion")
        let didPurgeNewerWithOldToken = try await store.purge(first)
        XCTAssertFalse(didPurgeNewerWithOldToken, "old expiry must not remove a newer deletion")
        let didRestoreSecond = try await store.restore(second)
        XCTAssertTrue(didRestoreSecond)
        let afterSecondRestore = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(afterSecondRestore.map(\.id), [note.id])
    }

    func testAtomicMutationUsesTheCurrentCopyAndPreservesStoreOwnedFields() async throws {
        let store = try makeStore()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let note = Note(title: "Original", body: "current body", createdAt: created)
        try await store.upsert(note)

        let changed = try await store.mutate(id: note.id) { current in
            current.title = "Renamed"
            current.id = UUID()
            current.createdAt = .distantFuture
            current.deletedAt = Date()
        }

        XCTAssertTrue(changed)
        let fetched = try await store.fetch(filter: .all, query: "")
        let stored = try XCTUnwrap(fetched.first)
        XCTAssertEqual(stored.id, note.id)
        XCTAssertEqual(stored.title, "Renamed")
        XCTAssertEqual(stored.body, "current body")
        XCTAssertEqual(stored.createdAt, created)
        XCTAssertNil(stored.deletedAt)
        XCTAssertGreaterThan(stored.updatedAt, note.updatedAt)
    }

    func testAtomicMutationCannotResurrectASoftDeletedNote() async throws {
        let store = try makeStore()
        let note = Note(body: "keep me deleted")
        try await store.upsert(note)
        _ = try await store.softDelete(id: note.id)

        let changed = try await store.mutate(id: note.id) { $0.body = "resurrected" }

        XCTAssertFalse(changed)
        let visible = try await store.fetch(filter: .all, query: "")
        let known = try await store.allKnownIDs()
        XCTAssertTrue(visible.isEmpty)
        XCTAssertTrue(known.contains(note.id))
    }

    func testInvalidStoredIdentifierFailsStablyInsteadOfInventingAnIdentity() async throws {
        let database = try AppDatabase.inMemory()
        let now = Date()
        try await database.writer.write { db in
            var record = NoteRecord(
                id: "not-a-uuid",
                title: "Damaged row",
                body: "leave these bytes alone",
                bodyEnc: nil,
                colorIndex: 0,
                tag: "",
                pinned: false,
                sortIndex: 0,
                createdAt: now,
                updatedAt: now,
                archivedAt: nil,
                deletedAt: nil
            )
            try record.insert(db)
        }
        let store = LocalNoteStore(database: database)

        do {
            _ = try await store.fetch(filter: .all, query: "")
            XCTFail("A corrupt primary key must be reported, not replaced by a random UUID")
        } catch NoteRecordError.invalidIdentifier(let value) {
            XCTAssertEqual(value, "not-a-uuid")
        }

        let storedID: String? = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM note")
        }
        XCTAssertEqual(storedID, "not-a-uuid", "reading a damaged row must not mutate it")
    }
}

final class LegacyEncryptedBodiesTests: XCTestCase {
    private func stageLegacyBody(
        _ plaintext: String,
        key: SymmetricKey,
        in database: AppDatabase
    ) async throws -> Note {
        let note = Note(title: "Legacy")
        try await LocalNoteStore(database: database).upsert(note)
        let sealed = try XCTUnwrap(try AES.GCM.seal(Data(plaintext.utf8), using: key).combined)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE note SET body = '', bodyEnc = ? WHERE id = ?",
                arguments: [sealed, note.id.uuidString]
            )
        }
        return note
    }

    func testMigrationUsesTheLegacyFileKey() async throws {
        let database = try AppDatabase.inMemory()
        let key = SymmetricKey(size: .bits256)
        let note = try await stageLegacyBody("from the source build", key: key, in: database)
        let keyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try key.withUnsafeBytes { try Data($0).write(to: keyURL) }
        defer { try? FileManager.default.removeItem(at: keyURL) }

        await LegacyEncryptedBodies.migrate(
            in: database,
            fileKeyURL: keyURL,
            keychainKeyProvider: { nil },
            cleanup: {}
        )

        let migrated = try await LocalNoteStore(database: database).fetch(filter: .all, query: "")
        XCTAssertEqual(migrated.first(where: { $0.id == note.id })?.body, "from the source build")
    }

    func testMigrationDoesNotOverwriteAnEditMadeWhileWaitingForTheKey() async throws {
        let database = try AppDatabase.inMemory()
        let key = SymmetricKey(size: .bits256)
        let note = try await stageLegacyBody("old body", key: key, in: database)

        await LegacyEncryptedBodies.migrate(
            in: database,
            fileKeyURL: nil,
            keychainKeyProvider: {
                var edited = note
                edited.body = "typed while the prompt was open"
                try? await LocalNoteStore(database: database).upsert(edited)
                return key
            },
            cleanup: {}
        )

        let migrated = try await LocalNoteStore(database: database).fetch(filter: .all, query: "")
        XCTAssertEqual(migrated.first?.body, "typed while the prompt was open")
    }

    func testDraftLoadedBeforeMigrationCannotEraseTheRecoveredBody() async throws {
        let database = try AppDatabase.inMemory()
        let store = LocalNoteStore(database: database)
        let key = SymmetricKey(size: .bits256)
        _ = try await stageLegacyBody("recovered text", key: key, in: database)
        let beforeMigration = try await store.fetch(filter: .all, query: "")
        var staleDraft = try XCTUnwrap(beforeMigration.first)

        await LegacyEncryptedBodies.migrate(
            in: database,
            fileKeyURL: nil,
            keychainKeyProvider: { key },
            cleanup: {}
        )
        staleDraft.title = "Renamed while recovery finished"
        try await NoteContentWriter.saveContent(staleDraft, to: store)

        let afterStaleSave = try await store.fetch(filter: .all, query: "")
        let saved = try XCTUnwrap(afterStaleSave.first)
        XCTAssertEqual(saved.title, "Renamed while recovery finished")
        XCTAssertEqual(saved.body, "recovered text")
    }

    func testMigrationKeepsTheKeyWhenAWriteFails() async throws {
        let database = try AppDatabase.inMemory()
        let key = SymmetricKey(size: .bits256)
        _ = try await stageLegacyBody("must remain recoverable", key: key, in: database)
        try await database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER rejectLegacyMigration
                BEFORE UPDATE OF body ON note
                WHEN OLD.bodyEnc IS NOT NULL
                BEGIN
                    SELECT RAISE(ABORT, 'forced migration failure');
                END
                """)
        }
        let cleanup = CleanupRecorder()

        await LegacyEncryptedBodies.migrate(
            in: database,
            fileKeyURL: nil,
            keychainKeyProvider: { key },
            cleanup: { cleanup.record() }
        )

        XCTAssertFalse(cleanup.wasCalled, "The only recovery key must survive a failed database write")
        let ciphertext: Data? = try await database.writer.read { db in
            try Data.fetchOne(db, sql: "SELECT bodyEnc FROM note")
        }
        XCTAssertNotNil(ciphertext)
    }

    func testMigrationTriesFileAndKeychainKeysBeforeCleaningUp() async throws {
        let database = try AppDatabase.inMemory()
        let fileKey = SymmetricKey(size: .bits256)
        let keychainKey = SymmetricKey(size: .bits256)
        let fileNote = try await stageLegacyBody("file-key body", key: fileKey, in: database)
        let keychainNote = try await stageLegacyBody("keychain body", key: keychainKey, in: database)
        let keyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try fileKey.withUnsafeBytes { try Data($0).write(to: keyURL) }
        defer { try? FileManager.default.removeItem(at: keyURL) }
        let cleanup = CleanupRecorder()

        await LegacyEncryptedBodies.migrate(
            in: database,
            fileKeyURL: keyURL,
            keychainKeyProvider: { keychainKey },
            cleanup: { cleanup.record() }
        )

        let migrated = try await LocalNoteStore(database: database).fetch(filter: .all, query: "")
        XCTAssertEqual(migrated.first(where: { $0.id == fileNote.id })?.body, "file-key body")
        XCTAssertEqual(migrated.first(where: { $0.id == keychainNote.id })?.body, "keychain body")
        XCTAssertTrue(cleanup.wasCalled)
    }

    func testMigrationRetainsKeysWhileAnyCiphertextIsUnresolved() async throws {
        let database = try AppDatabase.inMemory()
        let key = SymmetricKey(size: .bits256)
        _ = try await stageLegacyBody("recoverable", key: key, in: database)
        let corrupt = try await stageLegacyBody("will be corrupted", key: key, in: database)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE note SET bodyEnc = ? WHERE id = ?",
                arguments: [Data("not an AES-GCM box".utf8), corrupt.id.uuidString]
            )
        }
        let cleanup = CleanupRecorder()

        await LegacyEncryptedBodies.migrate(
            in: database,
            fileKeyURL: nil,
            keychainKeyProvider: { key },
            cleanup: { cleanup.record() }
        )

        XCTAssertFalse(cleanup.wasCalled)
        let unresolved: Int = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note WHERE bodyEnc IS NOT NULL") ?? 0
        }
        XCTAssertEqual(unresolved, 1)
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
        let store = LocalNoteStore(database: database)

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

final class TransferRegressionTests: XCTestCase {
    func testArchiveImportMakesDuplicateIncomingIDsUnique() {
        let id = UUID()
        let prepared = TransferService.prepareIncoming(
            [Note(id: id, title: "One"), Note(id: id, title: "Two")],
            existingIDs: [],
            preservesArchiveState: true
        )

        XCTAssertEqual(prepared.count, 2)
        XCTAssertEqual(Set(prepared.map(\.id)).count, 2, "both entries must survive subsequent upserts")
    }

    /// Regression: the archive path preserved every state field verbatim,
    /// including `deletedAt`. Both stores' `fetch` hides a tombstoned note, so
    /// a crafted archive imported straight into the library invisibly — the
    /// user could not tell it apart from an import that failed, and each retry
    /// appended another hidden copy.
    func testArchiveImportNeverBringsInATombstone() {
        let tombstoned = Note(
            title: "Hidden",
            pinned: true,
            archivedAt: Date(timeIntervalSince1970: 1_000),
            deletedAt: Date(timeIntervalSince1970: 2_000)
        )

        let prepared = TransferService.prepareIncoming(
            [tombstoned],
            existingIDs: [],
            preservesArchiveState: true
        )

        XCTAssertEqual(prepared.count, 1)
        XCTAssertNil(prepared.first?.deletedAt, "an imported note must be visible")
        XCTAssertNotNil(
            prepared.first?.archivedAt,
            "archived state is still part of the lossless archive contract"
        )
        XCTAssertEqual(prepared.first?.pinned, true)
    }

    func testMarkdownImportDoesNotTreatAPreprocessorDirectiveAsAHeading() {
        let text = "#include <stdio.h>\nint main(void) {}\n"
        let note = TransferService.markdownNote(from: Data(text.utf8))

        XCTAssertEqual(note?.title, "")
        XCTAssertEqual(note?.body, "#include <stdio.h>\nint main(void) {}")
    }

    func testReadableNoteImportsNormalizeWindowsLineEndings() {
        let markdown = TransferService.markdownNote(
            from: Data("# Title\r\n\r\nMarkdown body\r\n".utf8)
        )
        XCTAssertEqual(markdown?.title, "Title")
        XCTAssertEqual(markdown?.body, "Markdown body")

        let plain = TransferService.plainTextNote(
            from: Data("Plain title\r\n\r\nPlain body\r\n".utf8)
        )
        XCTAssertEqual(plain?.title, "Plain title")
        XCTAssertEqual(plain?.body, "Plain body")
    }
}
