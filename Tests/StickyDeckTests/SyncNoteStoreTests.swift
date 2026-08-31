import XCTest
@testable import StickyDeck

/// Reference box so a notification observer can tally posts without mutating
/// a captured local.
private final class PostCounter: @unchecked Sendable {
    var count = 0
}

final class SyncNoteStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StickyDeckSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeStore() throws -> SyncNoteStore {
        try SyncNoteStore(folder: folder)
    }

    func testRoundtripFiltersAndSearch() async throws {
        let store = try makeStore()

        let active = Note(title: "Groceries", body: "apples", tag: "home", sortIndex: 2)
        let archived = Note(title: "Old plan", body: "history", sortIndex: 1, archivedAt: Date())
        try await store.upsert(active)
        try await store.upsert(archived)

        let all = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(all.map(\.id).count, 2)

        let activeOnly = try await store.fetch(filter: .active, query: "")
        XCTAssertEqual(activeOnly.map(\.id), [active.id])

        let archivedOnly = try await store.fetch(filter: .archived, query: "")
        XCTAssertEqual(archivedOnly.map(\.id), [archived.id])

        let byBody = try await store.fetch(filter: .all, query: "apples")
        XCTAssertEqual(byBody.map(\.id), [active.id])

        let byTag = try await store.fetch(filter: .all, query: "home")
        XCTAssertEqual(byTag.map(\.id), [active.id])

        let sorted = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(sorted.first?.id, archived.id, "lower sortIndex first")
    }

    func testRoundtripKeepsAllFields() async throws {
        let store = try makeStore()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let note = Note(
            title: "Multi\nline \"title\" with \\ backslash",
            body: "line one\n\tline two 🥜\n\n--- not a fence ---",
            colorIndex: 5,
            tag: "work/urgent",
            pinned: true,
            sortIndex: -3,
            createdAt: created,
            updatedAt: created.addingTimeInterval(45),
            archivedAt: created.addingTimeInterval(30)
        )

        try await store.upsert(note)
        let fetched = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0], note)
    }

    func testFileLayoutIsVersionedFrontmatterMarkdown() async throws {
        let store = try makeStore()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let note = Note(
            title: "Layout",
            body: "body text",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try await store.upsert(note)

        let url = folder.appendingPathComponent("\(note.id.uuidString).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nstickyDeck: 1\n"))
        XCTAssertTrue(text.contains("createdAt: \"2023-11-14T22:13:20.000Z\""))
        XCTAssertTrue(text.contains("updatedAt: \"2023-11-14T22:13:20.000Z\""))
        XCTAssertTrue(text.contains("---\nbody text"))
        XCTAssertEqual(text.components(separatedBy: "---").count >= 3, true)
    }

    /// The app has been renamed twice: EdgeNotes, then Aside, now StickyDeck.
    /// Sync-folder files live in the user's own folder, not the app container,
    /// so they outlive every rename and each old key must still load.
    func testFilesWrittenUnderTheOldNameStillLoad() async throws {
        let id = UUID()
        let legacy = """
        ---
        edgeNotes: 1
        id: "\(id.uuidString)"
        title: "Written by EdgeNotes"
        colorIndex: 2
        tag: ""
        pinned: false
        sortIndex: 0
        createdAt: "2026-08-29T10:00:00.000Z"
        updatedAt: "2026-08-29T10:00:00.000Z"
        archivedAt: null
        deletedAt: null
        ---
        body from before the rename
        """
        try Data(legacy.utf8).write(
            to: folder.appendingPathComponent("\(id.uuidString).md"),
            options: .atomic
        )

        let store = try makeStore()
        let notes = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.title, "Written by EdgeNotes")
        XCTAssertEqual(notes.first?.body, "body from before the rename")
    }

    /// The rename before this one wrote `aside: 1`. Those files are just as
    /// real as the EdgeNotes ones and must load too.
    func testFilesWrittenUnderThePreviousNameStillLoad() async throws {
        let id = UUID()
        let legacy = """
        ---
        aside: 1
        id: "\(id.uuidString)"
        title: "Written by Aside"
        colorIndex: 1
        tag: ""
        pinned: false
        sortIndex: 0
        createdAt: "2026-08-30T10:00:00.000Z"
        updatedAt: "2026-08-30T10:00:00.000Z"
        archivedAt: null
        deletedAt: null
        ---
        body from the Aside era
        """
        try Data(legacy.utf8).write(
            to: folder.appendingPathComponent("\(id.uuidString).md"),
            options: .atomic
        )

        let store = try makeStore()
        let notes = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.title, "Written by Aside")
        XCTAssertEqual(notes.first?.body, "body from the Aside era")
    }

    func testLastWriterWinsRemoteNewerSurvivesStaleLocalWrite() async throws {
        let store = try makeStore()
        let stale = Note(
            title: "Conflict",
            body: "stale local copy",
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        try await store.upsert(stale)

        let remote = Note(
            id: stale.id,
            title: "Conflict",
            body: "remote newer edit",
            updatedAt: Date(timeIntervalSince1970: 2_000_000)
        )
        try SyncNoteStore.serialize(remote).write(
            to: folder.appendingPathComponent("\(remote.id.uuidString).md"),
            options: .atomic
        )

        do {
            try await store.upsert(stale)
            XCTFail("A write older than the stored copy must be reported, not silently dropped")
        } catch NoteStoreError.staleWrite {
            // Expected: the caller has to know its edit did not land.
        }

        let fetched = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].body, "remote newer edit")
    }

    func testMutateEditsTheCurrentCopyAndPreservesStoreOwnedFields() async throws {
        let store = try makeStore()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let original = Note(
            title: "Original",
            body: "old body",
            createdAt: created,
            updatedAt: created
        )
        try await store.upsert(original)

        // Model a copy that arrived after the caller's UI snapshot. Mutation
        // must start from these bytes, so changing the title does not roll
        // back the body or pin state that arrived with them.
        let current = Note(
            id: original.id,
            title: "Remote title",
            body: "current body",
            pinned: true,
            createdAt: created,
            updatedAt: created.addingTimeInterval(10)
        )
        try SyncNoteStore.serialize(current).write(
            to: folder.appendingPathComponent("\(current.id.uuidString).md"),
            options: .atomic
        )

        let wrongID = UUID()
        let didChange = try await store.mutate(id: original.id) { note in
            note.title = "Local title"
            note.id = wrongID
            note.createdAt = .distantFuture
            note.updatedAt = .distantPast
            note.deletedAt = Date()
        }

        XCTAssertTrue(didChange)
        let fetched = try await store.fetch(filter: .all, query: "")
        let saved = try XCTUnwrap(fetched.first)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.createdAt, created)
        XCTAssertNil(saved.deletedAt)
        XCTAssertEqual(saved.title, "Local title")
        XCTAssertEqual(saved.body, "current body")
        XCTAssertTrue(saved.pinned)
        XCTAssertGreaterThan(saved.updatedAt, current.updatedAt)
    }

    func testMutateNoOpReturnsFalseAndLeavesTheFileUntouched() async throws {
        let store = try makeStore()
        let note = Note(title: "Unchanged", body: "same")
        try await store.upsert(note)
        let url = folder.appendingPathComponent("\(note.id.uuidString).md")
        let before = try Data(contentsOf: url)

        let didChange = try await store.mutate(id: note.id) { _ in }

        XCTAssertFalse(didChange)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testMutateCannotChangeATombstoneOrResurrectIt() async throws {
        let store = try makeStore()
        let note = Note(title: "Deleted", body: "keep in tombstone")
        try await store.upsert(note)
        _ = try await store.softDelete(id: note.id)
        let url = folder.appendingPathComponent("\(note.id.uuidString).md")
        let before = try Data(contentsOf: url)

        let didChange = try await store.mutate(id: note.id) { stored in
            stored.title = "Resurrected"
            stored.deletedAt = nil
        }

        XCTAssertFalse(didChange)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let fetched = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(fetched.isEmpty)
    }

    /// Regression: undo-after-delete used to re-`upsert` the pre-delete
    /// snapshot, whose `updatedAt` is older than the tombstone the delete just
    /// wrote — so last-writer-wins discarded it and the note was gone for good.
    func testRestoreRevivesATombstoneThatAStaleUpsertCannotReach() async throws {
        let store = try makeStore()
        let note = Note(title: "Undo me", body: "still here")
        try await store.upsert(note)

        let deletionResult = try await store.softDelete(id: note.id)
        let deletion = try XCTUnwrap(deletionResult)
        let afterDelete = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(afterDelete.isEmpty)

        // The old undo path: refused, because the tombstone is newer.
        do {
            try await store.upsert(note)
            XCTFail("Re-upserting the pre-delete snapshot must not appear to succeed")
        } catch NoteStoreError.staleWrite {
            // Expected.
        }
        let afterStaleUpsert = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(afterStaleUpsert.isEmpty, "The stale write must not have revived the note")

        // The correct path.
        let didRestore = try await store.restore(deletion)
        XCTAssertTrue(didRestore)
        let restored = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(restored.count, 1)
        let restoredNote = try XCTUnwrap(restored.first)
        XCTAssertEqual(restoredNote.body, "still here")
    }

    func testSoftDeleteWritesTombstoneRestoreRevivesPurgeRemovesFile() async throws {
        let store = try makeStore()
        let note = Note(title: "Bye")
        try await store.upsert(note)
        let fileURL = folder.appendingPathComponent("\(note.id.uuidString).md")

        let firstDeletionResult = try await store.softDelete(id: note.id)
        let firstDeletion = try XCTUnwrap(firstDeletionResult)
        let afterDelete = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(afterDelete.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "tombstone stays so deletion syncs")

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
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDeletionTokenIsCanonicalAndCannotAffectANewerGeneration() async throws {
        let store = try makeStore()
        let note = Note(title: "Keep the newer state")
        try await store.upsert(note)
        let fileURL = folder.appendingPathComponent("\(note.id.uuidString).md")

        let firstResult = try await store.softDelete(id: note.id)
        let first = try XCTUnwrap(firstResult)
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let roundTripped = try format.parse(first.deletedAt.formatted(format))
        XCTAssertEqual(
            first.deletedAt.formatted(format),
            roundTripped.formatted(format),
            "the token must match the millisecond-precision file"
        )
        let duplicate = try await store.softDelete(id: note.id)
        XCTAssertNil(duplicate, "an existing tombstone has one owner")

        let didRestoreFirst = try await store.restore(first)
        XCTAssertTrue(didRestoreFirst, "a token returned before the file round-trip must still match")
        let didPurgeRestored = try await store.purge(first)
        XCTAssertFalse(didPurgeRestored, "expiry must not purge a restored note")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let secondResult = try await store.softDelete(id: note.id)
        let second = try XCTUnwrap(secondResult)
        XCTAssertNotEqual(first, second)
        let didRestoreNewerWithOldToken = try await store.restore(first)
        XCTAssertFalse(didRestoreNewerWithOldToken, "old Undo must not revive a newer deletion")
        let didPurgeNewerWithOldToken = try await store.purge(first)
        XCTAssertFalse(didPurgeNewerWithOldToken, "old expiry must not remove a newer deletion")
        let didPurgeSecond = try await store.purge(second)
        XCTAssertTrue(didPurgeSecond)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAdoptsForeignUuidNamedNoteFile() async throws {
        let foreignID = UUID()
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let foreign = Note(
            id: foreignID,
            title: "From the other Mac",
            body: "synced in",
            colorIndex: 2,
            tag: "sync",
            sortIndex: 7,
            createdAt: created,
            updatedAt: created
        )
        try SyncNoteStore.serialize(foreign).write(
            to: folder.appendingPathComponent("\(foreignID.uuidString).md"),
            options: .atomic
        )
        try Data("# Just a human note\n".utf8).write(
            to: folder.appendingPathComponent("human-note.md"),
            options: .atomic
        )

        let store = try makeStore()
        let fetched = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(fetched.map(\.id), [foreignID])
        XCTAssertEqual(fetched[0].body, "synced in")
    }

    /// Regression: an unmounted volume or an evicted iCloud folder used to
    /// read as an empty library — `fetch` returned `[]`, callers could not
    /// find the note they were editing, and every write was dropped while the
    /// UI reported success.
    func testVanishedFolderIsAnErrorNotAnEmptyLibrary() async throws {
        let store = try makeStore()
        let note = Note(title: "Still mine", body: "on the volume")
        try await store.upsert(note)

        try FileManager.default.removeItem(at: folder)

        do {
            _ = try await store.fetch(filter: .all, query: "")
            XCTFail("An unreadable folder must not look like a library with no notes")
        } catch {
            // Expected: the underlying FileManager error, so the message the
            // user sees names the folder.
        }
        do {
            _ = try await store.allKnownIDs()
            XCTFail("allKnownIDs must not report an empty set for an unreadable folder")
        } catch {}
        do {
            _ = try await store.softDelete(id: note.id)
            XCTFail("softDelete must not silently no-op on an unreadable folder")
        } catch {}
        let deletion = DeletionToken(noteID: note.id, deletedAt: Date())
        do {
            _ = try await store.restore(deletion)
            XCTFail("restore must not silently no-op on an unreadable folder")
        } catch {}
        do {
            _ = try await store.purge(deletion)
            XCTFail("purge must not silently no-op on an unreadable folder")
        } catch {}
    }

    /// Regression: a file synced from a Mac with a fast clock is stamped in
    /// our future, so every edit — stamped `Date()` — lost last-writer-wins
    /// and the note became permanently uneditable.
    func testFutureTimestampFromASkewedClockDoesNotFreezeTheNote() async throws {
        let store = try makeStore()
        // `.004` lands immediately below a binary floating-point millisecond
        // boundary on current Foundation. A one-millisecond bump serialized
        // back to the same wire timestamp and made this regression flaky.
        let futureSecond = Date().addingTimeInterval(600).timeIntervalSince1970.rounded(.down)
        let future = Date(timeIntervalSince1970: futureSecond + 0.004)
        let skewed = Note(title: "Fast clock", body: "original", updatedAt: future)
        try SyncNoteStore.serialize(skewed).write(
            to: folder.appendingPathComponent("\(skewed.id.uuidString).md"),
            options: .atomic
        )

        var edit = skewed
        edit.body = "typed just now"
        edit.updatedAt = Date()
        try await store.upsert(edit)

        let fetched = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].body, "typed just now")
        XCTAssertGreaterThan(
            fetched[0].updatedAt, future,
            "The overriding write must stamp past the future file, or the same file wins again on every Mac"
        )
    }

    /// The skew allowance is narrow: a stored copy that is only plausibly
    /// newer still wins, so genuine sync conflicts are unaffected.
    func testAPlausiblyNewerStoredCopyStillWins() async throws {
        let store = try makeStore()
        let soon = Date().addingTimeInterval(5)
        let remote = Note(title: "Remote", body: "newer", updatedAt: soon)
        try SyncNoteStore.serialize(remote).write(
            to: folder.appendingPathComponent("\(remote.id.uuidString).md"),
            options: .atomic
        )

        var mine = remote
        mine.body = "mine"
        mine.updatedAt = Date()
        do {
            try await store.upsert(mine)
            XCTFail("A stored copy inside the plausible clock range must still win")
        } catch NoteStoreError.staleWrite {
            // Expected.
        }
        let fetched = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(fetched[0].body, "newer")
    }

    /// `softDelete`/`restore` used to skip the timestamp policy entirely, so
    /// tombstoning a future-stamped note wrote an *older* `updatedAt` and the
    /// delete lost on every other Mac.
    func testSoftDeleteStampsPastAFutureTimestamp() async throws {
        let store = try makeStore()
        let future = Date().addingTimeInterval(600)
        let skewed = Note(title: "Fast clock", body: "text", updatedAt: future)
        try SyncNoteStore.serialize(skewed).write(
            to: folder.appendingPathComponent("\(skewed.id.uuidString).md"),
            options: .atomic
        )

        let deletionResult = try await store.softDelete(id: skewed.id)
        let deletion = try XCTUnwrap(deletionResult)
        let afterDelete = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(afterDelete.isEmpty)

        let didRestore = try await store.restore(deletion)
        XCTAssertTrue(didRestore)
        let restored = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(restored.count, 1)
        let restoredNote = try XCTUnwrap(restored.first)
        XCTAssertGreaterThan(restoredNote.updatedAt, future, "the tombstone must out-rank the file it replaced")
    }

    func testParsesCRLFLineEndings() async throws {
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let note = Note(
            id: UUID(),
            title: "Windows editor",
            body: "line one\nline two",
            createdAt: created,
            updatedAt: created
        )
        let crlf = String(decoding: SyncNoteStore.serialize(note), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "\r\n")
        try Data(crlf.utf8).write(
            to: folder.appendingPathComponent("\(note.id.uuidString).md"),
            options: .atomic
        )

        let store = try makeStore()
        let fetched = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(fetched.map(\.id), [note.id], "a CRLF file is still one of our notes")
        XCTAssertEqual(fetched[0].body, "line one\nline two")
    }

    /// Regression: an unparseable file made the note vanish from `fetch`
    /// while its id stayed "known", and because `readNote` returned nil the
    /// last-writer-wins check was skipped and the next write clobbered it.
    func testUnparseableFileIsAConflictNotAnAbsentNote() async throws {
        let id = UUID()
        let url = folder.appendingPathComponent("\(id.uuidString).md")
        let garbage = Data("---\nnot our frontmatter at all\n".utf8)
        try garbage.write(to: url, options: .atomic)

        let store = try makeStore()
        let fetched = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(fetched.isEmpty, "an unparseable file is not a note we can show")
        let known = try await store.allKnownIDs()
        XCTAssertEqual(known, [id], "the id is still taken")

        do {
            try await store.upsert(Note(id: id, title: "Clobber", body: "mine"))
            XCTFail("A file we cannot parse must not be overwritten unconditionally")
        } catch NoteStoreError.staleWrite {
            // Expected: exists-but-unreadable is a conflict, not an absence.
        }
        XCTAssertEqual(try Data(contentsOf: url), garbage, "the original content survives")

        do {
            _ = try await store.softDelete(id: id)
            XCTFail("softDelete must not rewrite a file it could not read")
        } catch NoteStoreError.staleWrite {}
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }

    func testZeroByteFileIsNotTreatedAsAbsent() async throws {
        let id = UUID()
        let url = folder.appendingPathComponent("\(id.uuidString).md")
        try Data().write(to: url, options: .atomic)

        let store = try makeStore()
        do {
            try await store.upsert(Note(id: id, title: "Half-synced", body: "mine"))
            XCTFail("A file still being downloaded must not be overwritten")
        } catch NoteStoreError.staleWrite {}
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
    }

    /// Regression: `removeItem` deletes recursively, so purging an id that
    /// happened to be a directory removed the whole tree under it.
    func testPurgeRefusesADirectoryAndUpsertDoesNotReplaceIt() async throws {
        let id = UUID()
        let url = folder.appendingPathComponent("\(id.uuidString).md")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let inside = url.appendingPathComponent("keepme.txt")
        try Data("precious".utf8).write(to: inside, options: .atomic)

        let store = try makeStore()
        do {
            _ = try await store.purge(DeletionToken(noteID: id, deletedAt: Date()))
            XCTFail("purge must not delete a directory tree")
        } catch SyncStoreError.unexpectedFileShape {}
        do {
            try await store.upsert(Note(id: id, title: "Nope"))
            XCTFail("upsert must not replace a directory")
        } catch SyncStoreError.unexpectedFileShape {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
    }

    /// Regression: an atomic write replaced the symlink with a regular file
    /// and orphaned whatever it pointed at.
    func testUpsertDoesNotReplaceASymlink() async throws {
        let id = UUID()
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("StickyDeckTarget-\(UUID().uuidString).md")
        let original = Note(id: id, title: "Linked", body: "target content")
        try SyncNoteStore.serialize(original).write(to: target, options: .atomic)
        defer { try? FileManager.default.removeItem(at: target) }

        let link = folder.appendingPathComponent("\(id.uuidString).md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let store = try makeStore()
        do {
            try await store.upsert(Note(id: id, title: "Replacement", body: "mine"))
            XCTFail("upsert must not turn a symlink into a regular file")
        } catch SyncStoreError.unexpectedFileShape {}

        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink)
        let survived = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(survived.contains("target content"))
    }

    /// Regression: `purge` announced a change even when there was nothing to
    /// remove, so every observer re-read the folder for nothing.
    func testPurgeOfAMissingNoteAnnouncesNothing() async throws {
        let store = try makeStore()
        let posts = PostCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .noteStoreChanged, object: nil, queue: nil
        ) { _ in posts.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try await store.purge(DeletionToken(noteID: UUID(), deletedAt: Date()))
        XCTAssertEqual(posts.count, 0)
    }

    func testNewerDeleteWinsOverOlderUpsert() async throws {
        let store = try makeStore()
        let note = Note(title: "Delete me", updatedAt: Date(timeIntervalSince1970: 1_000_000))
        try await store.upsert(note)

        let remote = Note(
            id: note.id,
            title: "Delete me",
            body: "",
            updatedAt: Date(timeIntervalSince1970: 2_000_000),
            deletedAt: Date(timeIntervalSince1970: 2_000_000)
        )
        try SyncNoteStore.serialize(remote).write(
            to: folder.appendingPathComponent("\(note.id.uuidString).md"),
            options: .atomic
        )

        do {
            try await store.upsert(note)
            XCTFail("The refused write must be reported so the caller can reload")
        } catch NoteStoreError.staleWrite {
            // Expected: the tombstone still wins, but silently returning
            // success here is what made undo-after-delete lose notes.
        }
        let fetched = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(fetched.isEmpty, "remote tombstone (newer) survives the stale local upsert")
    }

    func testMismatchedFileNameAndFrontmatterIDIsIgnoredAndProtected() async throws {
        let pathID = UUID()
        let embedded = Note(id: UUID(), title: "Wrong identity", body: "must survive")
        let original = SyncNoteStore.serialize(embedded)
        let url = folder.appendingPathComponent("\(pathID.uuidString).md")
        try original.write(to: url, options: .atomic)

        let store = try makeStore()
        let fetched = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(fetched.isEmpty, "a sync file has one identity, shared by its name and frontmatter")
        let knownIDs = try await store.allKnownIDs()
        XCTAssertEqual(knownIDs, [pathID], "the occupied path still reserves its id")

        do {
            try await store.upsert(Note(id: pathID, title: "Replacement"))
            XCTFail("a mismatched file must be treated as unreadable, not overwritten")
        } catch NoteStoreError.staleWrite {}
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testMalformedUpdatedAtUsesTheStableCreatedDateFallback() async throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let original = Note(
            title: "Externally edited",
            body: "before",
            createdAt: created,
            updatedAt: created.addingTimeInterval(60)
        )
        var text = String(decoding: SyncNoteStore.serialize(original), as: UTF8.self)
        text = text.components(separatedBy: "\n").map {
            $0.hasPrefix("updatedAt:") ? "updatedAt: \"not-a-date\"" : $0
        }.joined(separator: "\n")
        try Data(text.utf8).write(
            to: folder.appendingPathComponent("\(original.id.uuidString).md"),
            options: .atomic
        )

        let store = try makeStore()
        let initiallyFetched = try await store.fetch(filter: .all, query: "")
        var draft = try XCTUnwrap(initiallyFetched.first)
        XCTAssertEqual(draft.updatedAt, created, "a damaged timestamp must not change on every parse")

        let editTimestamp = Date()
        try await Task.sleep(for: .milliseconds(20))
        draft.body = "after"
        draft.updatedAt = editTimestamp
        try await store.upsert(draft)

        let saved = try await store.fetch(filter: .all, query: "")
        XCTAssertEqual(saved.first?.body, "after", "the stable fallback lets the next valid edit heal the file")
    }
}

// MARK: - Live updates
//
// These two exercise the directory watcher, so they wait on real filesystem
// events. Both fail outright on the old watcher rather than flaking: it went
// deaf for good after a rename, and its debounce never fired under a
// continuous stream.
extension SyncNoteStoreTests {
    private func stage(_ note: Note) throws {
        try SyncNoteStore.serialize(note).write(
            to: folder.appendingPathComponent("\(note.id.uuidString).md"),
            options: .atomic
        )
    }

    /// Regression: on a `.rename`/`.delete` the watcher re-opened the *old*
    /// path, `makeWatcher` returned nil, and nothing was left to ever re-arm
    /// it — the store never saw another change.
    func testWatcherRecoversAfterTheFolderIsReplaced() async throws {
        let store = try makeStore()
        try await Task.sleep(for: .milliseconds(300))  // let priming arm the watcher

        let moved = folder.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: folder, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(800))  // let the re-arm retries land

        let announced = XCTNSNotificationExpectation(name: .noteStoreChanged)
        try stage(Note(title: "after the folder was replaced"))
        await fulfillment(of: [announced], timeout: 5)
        _ = try await store.fetch(filter: .all, query: "")
    }

    /// Regression: every event cancelled the pending debounce, so a stream
    /// arriving faster than 250 ms — an initial iCloud download — never fired
    /// at all and nothing appeared until it finished.
    func testAContinuousStreamOfEventsStillAnnouncesMidStream() async throws {
        let store = try makeStore()
        try await Task.sleep(for: .milliseconds(300))

        let announced = XCTNSNotificationExpectation(name: .noteStoreChanged)
        let trickleFolder = try XCTUnwrap(folder)
        let trickle = Task {
            for index in 0..<12 {
                try? await Task.sleep(for: .milliseconds(200))
                let note = Note(title: "downloading \(index)")
                try? SyncNoteStore.serialize(note).write(
                    to: trickleFolder.appendingPathComponent("\(note.id.uuidString).md"),
                    options: .atomic
                )
            }
        }
        await fulfillment(of: [announced], timeout: 2.4)
        trickle.cancel()
        _ = try await store.fetch(filter: .all, query: "")
    }
}
