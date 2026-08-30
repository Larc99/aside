import XCTest
@testable import Aside

private actor RecordingNoteStore: NoteStore {
    private var stored: [UUID: Note] = [:]
    private var writes: [Note] = []
    private var restores: [UUID] = []

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] {
        // Like both real stores: soft-deleted rows are kept but hidden.
        stored.values.filter { $0.deletedAt == nil }
    }

    func upsert(_ note: Note) async throws {
        stored[note.id] = note
        writes.append(note)
    }

    func softDelete(id: UUID) async throws {
        guard var note = stored[id] else { return }
        // The stamp that makes a later upsert of the pre-delete snapshot look
        // stale to the sync store.
        note.deletedAt = Date()
        note.updatedAt = Date()
        stored[id] = note
    }

    func restore(id: UUID) async throws {
        restores.append(id)
        guard var note = stored[id] else { return }
        note.deletedAt = nil
        note.updatedAt = Date()
        stored[id] = note
    }

    func purge(id: UUID) async throws { stored[id] = nil }

    func allKnownIDs() async throws -> Set<UUID> { Set(stored.keys) }

    func recordedWrites() -> [Note] { writes }
    func restoredIDs() -> [UUID] { restores }
}

/// Answers successive fetches from a script so a slow reload can be raced
/// against a newer, faster one.
private actor ScriptedNoteStore: NoteStore {
    private let script: [(delay: Duration, notes: [Note])]
    private var callCount = 0

    init(script: [(delay: Duration, notes: [Note])]) {
        self.script = script
    }

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] {
        // The index is claimed before the sleep, so calls are scripted in
        // arrival order rather than completion order.
        let step = script[min(callCount, script.count - 1)]
        callCount += 1
        try? await Task.sleep(for: step.delay)
        return step.notes
    }

    func allKnownIDs() async throws -> Set<UUID> { [] }
    func upsert(_ note: Note) async throws {}
    func softDelete(id: UUID) async throws {}
    func restore(id: UUID) async throws {}
    func purge(id: UUID) async throws {}
}

private actor FailingNoteStore: NoteStore {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The test store is unavailable." }
    }

    private var upserts = 0
    /// Seeded so `NoteContentWriter` can resolve the note it is merging onto;
    /// only the write is meant to fail. Empty means reads fail too.
    var readable: [Note] = []

    func seed(_ notes: [Note]) { readable = notes }

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] {
        guard !readable.isEmpty else { throw Failure() }
        return readable
    }
    func allKnownIDs() async throws -> Set<UUID> { throw Failure() }
    func upsert(_ note: Note) async throws {
        upserts += 1
        throw Failure()
    }
    func softDelete(id: UUID) async throws { throw Failure() }
    func restore(id: UUID) async throws { throw Failure() }
    func purge(id: UUID) async throws { throw Failure() }

    func upsertAttempts() -> Int { upserts }
}

/// Like `RecordingNoteStore` but with a stable row order, so a test can say
/// which row sat where. `RecordingNoteStore` answers from a dictionary, whose
/// order is not defined between fetches.
private actor OrderedNoteStore: NoteStore {
    private var stored: [Note] = []

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] {
        stored.filter { $0.deletedAt == nil }
    }

    func upsert(_ note: Note) async throws {
        if let index = stored.firstIndex(where: { $0.id == note.id }) {
            stored[index] = note
        } else {
            stored.append(note)
        }
    }

    func softDelete(id: UUID) async throws {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
        stored[index].deletedAt = Date()
        stored[index].updatedAt = Date()
    }

    func restore(id: UUID) async throws {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
        stored[index].deletedAt = nil
        stored[index].updatedAt = Date()
    }

    func purge(id: UUID) async throws { stored.removeAll { $0.id == id } }

    func allKnownIDs() async throws -> Set<UUID> { Set(stored.map(\.id)) }

    func note(_ id: UUID) -> Note? { stored.first { $0.id == id } }
}

@MainActor
final class NoteListModelTests: XCTestCase {
    func testReloadFocusesFirstRowWithoutCheckingIt() async throws {
        let store = RecordingNoteStore()
        let note = Note(title: "First preview")
        try await store.upsert(note)

        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        XCTAssertEqual(model.focusedID, note.id)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.focusedNote?.id, note.id)
        XCTAssertEqual(model.actionNotes.map(\.id), [note.id])
    }

    func testPreviewAutosaveCoalescesTypingBurst() async throws {
        let store = RecordingNoteStore()
        let note = Note(title: "Draft")
        // The preview card only ever edits a note the store already holds; a
        // content-only save deliberately drops a write for anything else.
        try await store.upsert(note)
        let model = NoteListModel(store: store, mode: .all)

        var first = note
        first.body = "a"
        model.autosave(first)

        var final = note
        final.body = "abc"
        model.autosave(final)

        try await Task.sleep(for: .milliseconds(350))
        let writes = await store.recordedWrites()
        XCTAssertEqual(writes.count, 2, "one seeding write, then one coalesced save")
        XCTAssertEqual(writes.last?.body, "abc")
    }

    func testPreviewAutosaveFlushesImmediately() async throws {
        let store = RecordingNoteStore()
        var note = Note(title: "Draft")
        try await store.upsert(note)
        let model = NoteListModel(store: store, mode: .all)
        note.body = "pending"

        model.autosave(note)
        model.flushAutosave()

        try await Task.sleep(for: .milliseconds(80))
        let writes = await store.recordedWrites()
        XCTAssertEqual(writes.count, 2, "one seeding write, then the flushed save")
        XCTAssertEqual(writes.last?.body, "pending")
    }

    func testBulkArchiveActionCanAlsoRestoreArchivedSelection() async throws {
        let store = RecordingNoteStore()
        let note = Note(title: "Ship it")
        try await store.upsert(note)

        let model = NoteListModel(store: store, mode: .all)
        await model.reload()
        model.selection = [note.id]

        await model.setArchived(model.selection, archived: true)
        let archivedWrites = await store.recordedWrites()
        XCTAssertNotNil(archivedWrites.last?.archivedAt)

        await model.setArchived(model.selection, archived: false)
        let restoredWrites = await store.recordedWrites()
        XCTAssertNil(restoredWrites.last?.archivedAt)
    }

    func testArrowNavigationChangesPreviewFocusWithoutChangingCheckboxes() async throws {
        let store = RecordingNoteStore()
        try await store.upsert(Note(title: "One"))
        try await store.upsert(Note(title: "Two"))
        try await store.upsert(Note(title: "Three"))

        let model = NoteListModel(store: store, mode: .all)
        await model.reload()
        let first = try XCTUnwrap(model.focusedID)

        model.moveFocus(by: 1)
        XCTAssertNotEqual(model.focusedID, first)
        XCTAssertTrue(model.selection.isEmpty)

        model.moveFocus(by: 100)
        XCTAssertEqual(model.focusedID, model.notes.last?.id)
        model.moveFocus(by: -100)
        XCTAssertEqual(model.focusedID, model.notes.first?.id)
    }

    func testSpaceSelectionTogglesFocusedNoteOnlyInAllNotes() async throws {
        let store = RecordingNoteStore()
        let note = Note(title: "Keyboard selection")
        try await store.upsert(note)

        let allNotes = NoteListModel(store: store, mode: .all)
        await allNotes.reload()
        XCTAssertTrue(allNotes.toggleFocusedSelection())
        XCTAssertEqual(allNotes.selection, [note.id])
        XCTAssertTrue(allNotes.toggleFocusedSelection())
        XCTAssertTrue(allNotes.selection.isEmpty)

        let archive = NoteListModel(store: store, mode: .archive)
        await archive.reload()
        // Reported as not applied so the view can leave Space to the list's
        // page-scroll instead of swallowing it.
        XCTAssertFalse(archive.toggleFocusedSelection())
        XCTAssertTrue(archive.selection.isEmpty)
    }

    func testUndoDeleteRestoresTheStoredCopyInsteadOfRewritingIt() async throws {
        let store = RecordingNoteStore()
        let note = Note(title: "Undo me")
        try await store.upsert(note)

        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        await model.deleteSelection([note.id])
        XCTAssertTrue(model.notes.isEmpty)
        XCTAssertNotNil(model.pendingDelete)

        await model.undoDelete()

        XCTAssertNil(model.pendingDelete)
        XCTAssertEqual(model.notes.map(\.id), [note.id])
        let restored = await store.restoredIDs()
        XCTAssertEqual(restored, [note.id])
        // Only the seed write: re-upserting the pre-delete snapshot would
        // carry a stale updatedAt and the sync store would drop it.
        let writes = await store.recordedWrites()
        XCTAssertEqual(writes.count, 1)
    }

    func testSecondDeleteInsideTheUndoWindowPurgesTheDisplacedBatch() async throws {
        let store = RecordingNoteStore()
        let first = Note(title: "First victim")
        let second = Note(title: "Second victim")
        try await store.upsert(first)
        try await store.upsert(second)

        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        await model.deleteSelection([first.id])
        await model.deleteSelection([second.id])

        XCTAssertEqual(model.pendingDelete?.notes.map(\.id), [second.id])
        // The displaced batch is gone for good rather than left soft-deleted
        // with no toast to reach it.
        let known = try await store.allKnownIDs()
        XCTAssertFalse(known.contains(first.id))
        XCTAssertTrue(known.contains(second.id))
    }

    func testCheckedRowsHiddenByAReloadStayCheckedButOutOfBulkActions() async throws {
        let store = RecordingNoteStore()
        let visible = Note(title: "Still here")
        let hidden = Note(title: "Filtered out")
        try await store.upsert(visible)
        try await store.upsert(hidden)

        let model = NoteListModel(store: store, mode: .all)
        await model.reload()
        model.selection = [visible.id, hidden.id]

        try await store.softDelete(id: hidden.id)
        await model.reload()

        XCTAssertEqual(model.selection, [visible.id, hidden.id])
        XCTAssertEqual(model.selectedNotes.map(\.id), [visible.id])
    }

    func testSlowReloadDoesNotOverwriteTheRowsANewerOnePublished() async throws {
        let slow = Note(title: "Slow fetch")
        let fresh = Note(title: "Fresh fetch")
        let store = ScriptedNoteStore(script: [
            (.zero, []),
            (.milliseconds(400), [slow]),
            (.zero, [fresh]),
        ])

        let model = NoteListModel(store: store, mode: .all)
        // Let the initializer's own reload take the first scripted fetch.
        try await Task.sleep(for: .milliseconds(60))

        async let stale: Void = model.reload()
        try await Task.sleep(for: .milliseconds(40))
        async let current: Void = model.reload()
        _ = await (stale, current)

        XCTAssertEqual(model.notes.map(\.id), [fresh.id])
    }

    func testFailedAutosaveKeepsTheDraftForTheNextFlush() async throws {
        let store = FailingNoteStore()
        var note = Note(title: "Draft")
        await store.seed([note])
        let model = NoteListModel(store: store, mode: .all)
        note.body = "unsaved"

        model.autosave(note)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.presentedError?.title, "Changes Couldn’t Be Saved")
        let firstAttempt = await store.upsertAttempts()
        XCTAssertEqual(firstAttempt, 1)

        // The text outlived the failed write, so closing the window still has
        // something to save instead of having dropped it.
        model.flushAutosave()
        try await Task.sleep(for: .milliseconds(60))
        let secondAttempt = await store.upsertAttempts()
        XCTAssertEqual(secondAttempt, 2)
    }

    /// The preview card is editable now, so its debounced save can outlive a
    /// delete made in the same window. A content-only write drops rather than
    /// bringing the note back.
    func testPreviewAutosaveCannotResurrectADeletedNote() async throws {
        let store = RecordingNoteStore()
        var note = Note(title: "Doomed")
        try await store.upsert(note)
        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        note.body = "typed just before deleting"
        model.autosave(note)
        await model.deleteSelection([note.id])

        try await Task.sleep(for: .milliseconds(350))
        let visible = try await store.fetch(filter: .all, query: "")
        XCTAssertTrue(visible.isEmpty, "The in-flight preview save must not undo the delete")
    }

    func testRemovedFocusMovesToTheClosestSurvivingRowNotTheTop() async throws {
        let store = OrderedNoteStore()
        for title in ["One", "Two", "Three", "Four", "Five"] {
            try await store.upsert(Note(title: title))
        }
        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        let third = model.notes[2]
        model.focusedID = third.id
        await model.deleteSelection([third.id])

        XCTAssertEqual(model.notes.count, 4)
        XCTAssertEqual(
            model.focusedID, model.notes[2].id,
            "focus follows the row that took the deleted one's place, not the top of the list"
        )
        XCTAssertNotEqual(model.focusedID, model.notes.first?.id)
    }

    func testRemovedFocusOnTheLastRowClampsToTheNewLastRow() async throws {
        let store = OrderedNoteStore()
        for title in ["One", "Two", "Three"] { try await store.upsert(Note(title: title)) }
        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        let last = try XCTUnwrap(model.notes.last)
        model.focusedID = last.id
        await model.deleteSelection([last.id])

        XCTAssertEqual(model.focusedID, model.notes.last?.id)
        XCTAssertEqual(model.notes.count, 2)
    }

    func testHomeEndAndPageNavigationLandOnTheEdgesOfTheList() async throws {
        let store = OrderedNoteStore()
        for index in 0..<20 { try await store.upsert(Note(title: "Note \(index)")) }
        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        model.moveFocusToLast()
        XCTAssertEqual(model.focusedID, model.notes.last?.id)
        model.moveFocusToFirst()
        XCTAssertEqual(model.focusedID, model.notes.first?.id)

        model.moveFocus(by: NoteListModel.pageLength)
        XCTAssertEqual(model.focusedID, model.notes[NoteListModel.pageLength].id)
        model.moveFocus(by: -NoteListModel.pageLength)
        XCTAssertEqual(model.focusedID, model.notes.first?.id, "a page up from row 8 clamps to the top")
        // Navigation is focus only — it must never tick a checkbox.
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testArchiveKeepsAnEditMadeElsewhereWhileTheListRowWasStale() async throws {
        let store = OrderedNoteStore()
        var note = Note(title: "Shared", body: "before")
        try await store.upsert(note)

        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        // The deck or a sticky window saves a newer body straight to the store.
        // The list still holds the row as it was when it last reloaded.
        note.body = "typed in the deck"
        note.updatedAt = Date()
        try await store.upsert(note)

        await model.setArchived([note.id], archived: true)

        let latest = await store.note(note.id)
        let stored = try XCTUnwrap(latest)
        XCTAssertNotNil(stored.archivedAt, "the state change still has to be applied")
        XCTAssertEqual(stored.body, "typed in the deck", "archiving must not write the stale cached row back")
    }

    func testArchiveWaitsForItsOwnPendingDraftInsteadOfRacingIt() async throws {
        let store = OrderedNoteStore()
        var note = Note(title: "Draft", body: "before")
        try await store.upsert(note)

        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        note.body = "typed in the preview"
        model.autosave(note)
        // No pause: the flush and the archive write are deliberately started
        // back to back, which is exactly when they used to overwrite each other.
        await model.setArchived([note.id], archived: true)

        let latest = await store.note(note.id)
        let stored = try XCTUnwrap(latest)
        XCTAssertEqual(stored.body, "typed in the preview")
        XCTAssertNotNil(stored.archivedAt, "the flush must not land after the archive and undo it")
    }

    func testArchiveCannotResurrectANotePurgedElsewhere() async throws {
        let store = OrderedNoteStore()
        let note = Note(title: "Gone")
        try await store.upsert(note)

        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        try await store.purge(id: note.id)
        await model.setArchived([note.id], archived: true)

        let ids = try await store.allKnownIDs()
        XCTAssertFalse(ids.contains(note.id), "a whole-row archive write must not bring a purged note back")
    }

    func testLoadFailureLeavesARecoverableUserFacingError() async {
        let model = NoteListModel(store: FailingNoteStore(), mode: .all)

        await model.reload()

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.presentedError?.title, "Notes Couldn’t Be Loaded")
        XCTAssertTrue(model.presentedError?.message.contains("test store is unavailable") == true)
    }
}
