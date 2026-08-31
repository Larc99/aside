import XCTest
@testable import StickyDeck

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

    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool {
        guard var note = stored[id], note.deletedAt == nil else { return false }
        let original = note
        change(&note)
        note.id = original.id
        note.createdAt = original.createdAt
        note.deletedAt = original.deletedAt
        note.updatedAt = original.updatedAt
        guard note != original else { return false }
        note.updatedAt = max(Date(), original.updatedAt.addingTimeInterval(0.001))
        stored[id] = note
        writes.append(note)
        return true
    }

    func softDelete(id: UUID) async throws -> DeletionToken? {
        guard var note = stored[id], note.deletedAt == nil else { return nil }
        // The stamp that makes a later upsert of the pre-delete snapshot look
        // stale to the sync store.
        let deletedAt = Date()
        note.deletedAt = deletedAt
        note.updatedAt = Date()
        stored[id] = note
        return DeletionToken(noteID: id, deletedAt: deletedAt)
    }

    func restore(_ deletion: DeletionToken) async throws -> Bool {
        guard var note = stored[deletion.noteID],
              note.deletedAt == deletion.deletedAt else { return false }
        restores.append(deletion.noteID)
        note.deletedAt = nil
        note.updatedAt = Date()
        stored[deletion.noteID] = note
        return true
    }

    func purge(_ deletion: DeletionToken) async throws -> Bool {
        guard stored[deletion.noteID]?.deletedAt == deletion.deletedAt else { return false }
        stored[deletion.noteID] = nil
        return true
    }

    func allKnownIDs() async throws -> Set<UUID> { Set(stored.keys) }

    func recordedWrites() -> [Note] { writes }
    func restoredIDs() -> [UUID] { restores }
    func note(_ id: UUID) -> Note? { stored[id] }
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
    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool { false }
    func softDelete(id: UUID) async throws -> DeletionToken? { nil }
    func restore(_ deletion: DeletionToken) async throws -> Bool { false }
    func purge(_ deletion: DeletionToken) async throws -> Bool { false }
}

private actor FailingNoteStore: NoteStore {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The test store is unavailable." }
    }

    private var upserts = 0
    private var writesFail = true
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
    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool {
        upserts += 1
        guard !writesFail else { throw Failure() }
        guard let index = readable.firstIndex(where: { $0.id == id }) else { return false }
        let original = readable[index]
        var note = original
        change(&note)
        guard note != original else { return false }
        readable[index] = note
        return true
    }
    func softDelete(id: UUID) async throws -> DeletionToken? { throw Failure() }
    func restore(_ deletion: DeletionToken) async throws -> Bool { throw Failure() }
    func purge(_ deletion: DeletionToken) async throws -> Bool { throw Failure() }

    func upsertAttempts() -> Int { upserts }
    func allowWrites() { writesFail = false }
    func note(_ id: UUID) -> Note? { readable.first { $0.id == id } }
}

/// Mirrors GRDB: a read whose task is cancelled surfaces the cancellation as
/// a thrown error out of the suspended call rather than returning quietly.
private actor CancellingNoteStore: NoteStore {
    func fetch(filter: NoteFilter, query: String) async throws -> [Note] { throw CancellationError() }
    func allKnownIDs() async throws -> Set<UUID> { throw CancellationError() }
    func upsert(_ note: Note) async throws {}
    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool { false }
    func softDelete(id: UUID) async throws -> DeletionToken? { nil }
    func restore(_ deletion: DeletionToken) async throws -> Bool { false }
    func purge(_ deletion: DeletionToken) async throws -> Bool { false }
}

/// Fails the purge of one nominated note and records every attempt, so a test
/// can prove the rest of a batch is still tried.
private actor SelectivePurgeFailureStore: NoteStore {
    struct Failure: LocalizedError {
        var errorDescription: String? { "That note could not be removed." }
    }

    private var notes: [Note]
    private let unpurgeable: UUID
    private(set) var purgeAttempts: [UUID] = []

    init(notes: [Note], unpurgeable: UUID) {
        self.notes = notes
        self.unpurgeable = unpurgeable
    }

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] {
        notes.filter { $0.deletedAt == nil }
    }
    func allKnownIDs() async throws -> Set<UUID> { Set(notes.map(\.id)) }
    func upsert(_ note: Note) async throws {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.append(note)
        }
    }
    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].deletedAt == nil else { return false }
        var note = notes[index]
        change(&note)
        notes[index] = note
        return true
    }
    func softDelete(id: UUID) async throws -> DeletionToken? {
        guard let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].deletedAt == nil else { return nil }
        let deletedAt = Date()
        notes[index].deletedAt = deletedAt
        return DeletionToken(noteID: id, deletedAt: deletedAt)
    }
    func restore(_ deletion: DeletionToken) async throws -> Bool { false }
    func purge(_ deletion: DeletionToken) async throws -> Bool {
        purgeAttempts.append(deletion.noteID)
        if deletion.noteID == unpurgeable { throw Failure() }
        notes.removeAll { $0.id == deletion.noteID }
        return true
    }

    func attempts() -> [UUID] { purgeAttempts }
}

private actor GatedFirstFailureStore: NoteStore {
    struct Failure: Error {}

    private var notes: [UUID: Note]
    private var mutationCount = 0
    private var firstStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseFirst: CheckedContinuation<Void, Never>?

    init(notes: [Note]) {
        self.notes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
    }

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] {
        Array(notes.values)
    }
    func allKnownIDs() async throws -> Set<UUID> { Set(notes.keys) }
    func upsert(_ note: Note) async throws { notes[note.id] = note }
    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool {
        mutationCount += 1
        if mutationCount == 1 {
            firstStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { releaseFirst = $0 }
            throw Failure()
        }
        guard var note = notes[id] else { return false }
        let original = note
        change(&note)
        guard note != original else { return false }
        notes[id] = note
        return true
    }
    func softDelete(id: UUID) async throws -> DeletionToken? { nil }
    func restore(_ deletion: DeletionToken) async throws -> Bool { false }
    func purge(_ deletion: DeletionToken) async throws -> Bool { false }

    func waitUntilFirstMutationStarts() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstMutation() {
        releaseFirst?.resume()
        releaseFirst = nil
    }

    func note(_ id: UUID) -> Note? { notes[id] }
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

    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool {
        guard let index = stored.firstIndex(where: { $0.id == id }),
              stored[index].deletedAt == nil else { return false }
        let original = stored[index]
        var note = original
        change(&note)
        note.id = original.id
        note.createdAt = original.createdAt
        note.deletedAt = original.deletedAt
        note.updatedAt = original.updatedAt
        guard note != original else { return false }
        note.updatedAt = max(Date(), original.updatedAt.addingTimeInterval(0.001))
        stored[index] = note
        return true
    }

    func softDelete(id: UUID) async throws -> DeletionToken? {
        guard let index = stored.firstIndex(where: { $0.id == id }),
              stored[index].deletedAt == nil else { return nil }
        let deletedAt = Date()
        stored[index].deletedAt = deletedAt
        stored[index].updatedAt = Date()
        return DeletionToken(noteID: id, deletedAt: deletedAt)
    }

    func restore(_ deletion: DeletionToken) async throws -> Bool {
        guard let index = stored.firstIndex(where: { $0.id == deletion.noteID }),
              stored[index].deletedAt == deletion.deletedAt else { return false }
        stored[index].deletedAt = nil
        stored[index].updatedAt = Date()
        return true
    }

    func purge(_ deletion: DeletionToken) async throws -> Bool {
        guard let index = stored.firstIndex(where: { $0.id == deletion.noteID }),
              stored[index].deletedAt == deletion.deletedAt else { return false }
        stored.remove(at: index)
        return true
    }

    func allKnownIDs() async throws -> Set<UUID> { Set(stored.map(\.id)) }

    func note(_ id: UUID) -> Note? { stored.first { $0.id == id } }
    func remove(_ id: UUID) { stored.removeAll { $0.id == id } }
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

    /// The app posts this notification before replying to AppKit's terminate
    /// request. List windows must consume it; their private models otherwise
    /// leave a 250 ms draft racing the process exit.
    func testTerminationNotificationFlushesThePreviewDraft() async throws {
        let store = RecordingNoteStore()
        var note = Note(title: "Quit", body: "before")
        try await store.upsert(note)
        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        note.body = "typed immediately before quit"
        model.autosave(note)
        NotificationCenter.default.post(name: .appWillTerminate, object: nil)
        try await Task.sleep(for: .milliseconds(80))

        let stored = await store.note(note.id)
        XCTAssertEqual(stored?.body, "typed immediately before quit")
    }

    func testTerminationNotificationCommitsAPendingDelete() async throws {
        let store = RecordingNoteStore()
        let note = Note(title: "Delete then quit")
        try await store.upsert(note)
        let model = NoteListModel(store: store, mode: .all)
        await model.reload()
        await model.deleteSelection([note.id])
        let idsBeforeTermination = try await store.allKnownIDs()
        XCTAssertTrue(idsBeforeTermination.contains(note.id))

        NotificationCenter.default.post(name: .appWillTerminate, object: nil)
        try await Task.sleep(for: .milliseconds(80))

        let idsAfterTermination = try await store.allKnownIDs()
        XCTAssertFalse(idsAfterTermination.contains(note.id))
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
        XCTAssertFalse(model.bulkActionArchives, "an archived-only selection must offer Restore")

        await model.setArchived(model.selection, archived: false)
        let restoredWrites = await store.recordedWrites()
        XCTAssertNil(restoredWrites.last?.archivedAt)
        XCTAssertTrue(model.bulkActionArchives)
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

    func testOldUndoExpiryCannotPurgeANewerDeletionGeneration() async throws {
        let store = RecordingNoteStore()
        let note = Note(title: "Deleted twice")
        try await store.upsert(note)

        let model = NoteListModel(store: store, mode: .all)
        await model.reload()
        await model.deleteSelection([note.id])

        let first = try XCTUnwrap(model.pendingDelete?.deletions[note.id])
        let restored = try await store.restore(first)
        XCTAssertTrue(restored)
        let secondValue = try await store.softDelete(id: note.id)
        let second = try XCTUnwrap(secondValue)
        XCTAssertNotEqual(first, second)

        // Termination commits the model's original pending delete. That old
        // timer must not remove the distinct tombstone created afterwards by
        // another window (or another Mac sharing the folder).
        let flushed = await model.flushPendingWork()
        XCTAssertTrue(flushed)
        let stored = await store.note(note.id)
        XCTAssertEqual(stored?.deletedAt, second.deletedAt)
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

        _ = try await store.softDelete(id: hidden.id)
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

    func testFailedTerminationFlushReportsFailureAndRetriesTheDraft() async {
        let store = FailingNoteStore()
        var note = Note(title: "Quit", body: "before")
        await store.seed([note])
        let model = NoteListModel(store: store, mode: .all)
        note.body = "must survive"
        model.autosave(note)

        let firstSaved = await model.flushPendingWork()

        XCTAssertFalse(firstSaved)
        let noteAfterFailure = await store.note(note.id)
        XCTAssertEqual(noteAfterFailure?.body, "before")

        await store.allowWrites()
        let retrySaved = await model.flushPendingWork()

        XCTAssertTrue(retrySaved)
        let noteAfterRetry = await store.note(note.id)
        XCTAssertEqual(noteAfterRetry?.body, "must survive")
    }

    func testFailureForOnePreviewSurvivesASuccessfulSaveOfAnother() async {
        var first = Note(title: "First", body: "before A")
        var second = Note(title: "Second", body: "before B")
        let store = GatedFirstFailureStore(notes: [first, second])
        let model = NoteListModel(store: store, mode: .all)

        first.body = "unsaved A"
        model.autosave(first)
        model.flushAutosave()
        await store.waitUntilFirstMutationStarts()

        second.body = "saved B"
        model.autosave(second)
        model.flushAutosave()
        await store.releaseFirstMutation()

        let firstDrain = await model.flushPendingWork()

        XCTAssertFalse(firstDrain, "A's failure must propagate through B's later successful write")
        let firstAfterFailure = await store.note(first.id)
        let secondAfterSuccess = await store.note(second.id)
        XCTAssertEqual(firstAfterFailure?.body, "before A")
        XCTAssertEqual(secondAfterSuccess?.body, "saved B")

        let retry = await model.flushPendingWork()

        XCTAssertTrue(retry)
        let firstAfterRetry = await store.note(first.id)
        XCTAssertEqual(firstAfterRetry?.body, "unsaved A")
    }

    func testNewerSnapshotOfSamePreviewSupersedesAnOlderFailure() async {
        var note = Note(title: "Draft", body: "before")
        let store = GatedFirstFailureStore(notes: [note])
        let model = NoteListModel(store: store, mode: .all)

        note.body = "older edit"
        model.autosave(note)
        model.flushAutosave()
        await store.waitUntilFirstMutationStarts()

        note.body = "newest edit"
        model.autosave(note)
        model.flushAutosave()
        await store.releaseFirstMutation()

        let saved = await model.flushPendingWork()

        XCTAssertTrue(saved)
        let stored = await store.note(note.id)
        XCTAssertEqual(stored?.body, "newest edit")
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

    func testDeleteWaitsForTheVisibleDraftSoUndoRestoresLatestText() async throws {
        let store = RecordingNoteStore()
        var note = Note(title: "Undo latest edit", body: "before")
        try await store.upsert(note)
        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        note.body = "visible draft"
        model.autosave(note)
        await model.deleteSelection([note.id])
        await model.undoDelete()

        let restored = await store.note(note.id)
        XCTAssertEqual(restored?.body, "visible draft")
    }

    func testExportReadsTheDraftThatIsStillVisibleInThePreview() async throws {
        let store = RecordingNoteStore()
        var note = Note(title: "Export", body: "stored body")
        try await store.upsert(note)
        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        note.body = "body typed immediately before export"
        model.autosave(note)
        let prepared = await model.notesForExport([note])
        let export = try XCTUnwrap(prepared)

        XCTAssertEqual(export.first?.body, "body typed immediately before export")
    }

    func testClearingAnEditedLegacyPlaceholderReplacesTheRecoveredBody() async throws {
        let store = RecordingNoteStore()
        let placeholder = Note(
            title: "Legacy preview",
            body: "",
            bodyNeedsMigration: true
        )
        try await store.upsert(placeholder)
        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        // Migration recovered the body after All Notes rendered its stale,
        // empty placeholder.
        var recovered = placeholder
        recovered.body = "recovered plaintext"
        recovered.bodyNeedsMigration = false
        try await store.upsert(recovered)

        model.autosaveBody("", for: placeholder)
        let prepared = await model.notesForExport([placeholder])

        XCTAssertEqual(prepared?.first?.body, "")
        XCTAssertFalse(prepared?.first?.bodyNeedsMigration ?? true)
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

    func testPreviewBodySavePreservesNewerMetadataFromAnotherSurface() async throws {
        var note = Note(title: "Original", body: "before", colorIndex: 0, tag: "old")
        let store = RecordingNoteStore()
        try await store.upsert(note)
        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        note.body = "body from preview"
        model.autosave(note)

        _ = try await store.mutate(id: note.id) { live in
            live.title = "Changed in deck"
            live.colorIndex = 4
            live.tag = "new"
        }
        model.flushAutosave()
        _ = await model.flushPendingWork()

        let stored = await store.note(note.id)
        XCTAssertEqual(stored?.body, "body from preview")
        XCTAssertEqual(stored?.title, "Changed in deck")
        XCTAssertEqual(stored?.colorIndex, 4)
        XCTAssertEqual(stored?.tag, "new")
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

        await store.remove(note.id)
        await model.setArchived([note.id], archived: true)

        let ids = try await store.allKnownIDs()
        XCTAssertFalse(ids.contains(note.id), "a whole-row archive write must not bring a purged note back")
    }

    /// Regression: every keystroke, filter switch and store notification
    /// cancels the reload already in flight, and GRDB reports that as a thrown
    /// error out of the suspended read. Only the success path was guarded, so
    /// fast typing in the search field could raise a real "your notes are
    /// unavailable" alert for work the model cancelled itself.
    func testACancelledReloadIsNotReportedAsALoadFailure() async {
        let model = NoteListModel(store: CancellingNoteStore(), mode: .all)

        await model.reload()

        XCTAssertNil(
            model.presentedError,
            "A cancelled reload is the model's own bookkeeping, not a load failure"
        )
        XCTAssertFalse(model.isLoading)
    }

    /// Regression: a batch purge stopped at the first failure, so every later
    /// note in it stayed soft-deleted — invisible in the list, with its toast
    /// gone and nothing that ever sweeps a tombstone up.
    func testAFailedPurgeStillAttemptsTheRestOfTheBatch() async {
        let first = Note(title: "Unpurgeable")
        let second = Note(title: "Collateral")
        let trigger = Note(title: "Newer delete")
        let store = SelectivePurgeFailureStore(
            notes: [first, second, trigger],
            unpurgeable: first.id
        )
        let model = NoteListModel(store: store, mode: .all)
        await model.reload()

        await model.deleteSelection([first.id, second.id])
        // A newer delete takes the toast away from that batch and purges it now.
        await model.deleteSelection([trigger.id])

        let attempted = await store.attempts()
        XCTAssertTrue(attempted.contains(first.id))
        XCTAssertTrue(
            attempted.contains(second.id),
            "One unpurgeable note must not strand the rest of the batch as tombstones"
        )
        XCTAssertEqual(model.presentedError?.title, "Deleted Note Couldn’t Be Removed")
    }

    func testLoadFailureLeavesARecoverableUserFacingError() async {
        let model = NoteListModel(store: FailingNoteStore(), mode: .all)

        await model.reload()

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.presentedError?.title, "Notes Couldn’t Be Loaded")
        XCTAssertTrue(model.presentedError?.message.contains("test store is unavailable") == true)
    }
}
