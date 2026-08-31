import XCTest
@testable import StickyDeck
import SwiftUI

private actor HoverNoteStore: NoteStore {
    let notes: [Note]

    init(notes: [Note] = []) {
        self.notes = notes
    }

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] { notes }
    func allKnownIDs() async throws -> Set<UUID> { Set(notes.map(\.id)) }

    func upsert(_ note: Note) async throws {}
    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool { false }
    func softDelete(id: UUID) async throws -> DeletionToken? { nil }
    func restore(_ deletion: DeletionToken) async throws -> Bool { false }
    func purge(_ deletion: DeletionToken) async throws -> Bool { false }
}

/// Captures what the deck actually hands to the desktop, so a test can prove
/// the sticky opens on the text the user can see rather than the last saved copy.
@MainActor
private final class RecordingStickyPresenter: StickyPresenting {
    private(set) var presented: [Note] = []
    func present(_ note: Note, takingPlaceOf frame: CGRect?) { presented.append(note) }
    func dismiss(_ noteID: UUID) {}
}

/// Records purges so a test can prove a replaced pending delete is not leaked.
private actor PurgeRecordingNoteStore: NoteStore {
    private var notes: [Note]
    private(set) var purged: [UUID] = []

    init(notes: [Note] = []) {
        self.notes = notes
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
        let original = notes[index]
        var note = original
        change(&note)
        note.id = original.id
        note.createdAt = original.createdAt
        note.deletedAt = original.deletedAt
        note.updatedAt = original.updatedAt
        guard note != original else { return false }
        note.updatedAt = max(Date(), original.updatedAt.addingTimeInterval(0.001))
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
    func restore(_ deletion: DeletionToken) async throws -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == deletion.noteID }),
              notes[index].deletedAt == deletion.deletedAt else { return false }
        notes[index].deletedAt = nil
        return true
    }
    func purge(_ deletion: DeletionToken) async throws -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == deletion.noteID }),
              notes[index].deletedAt == deletion.deletedAt else { return false }
        purged.append(deletion.noteID)
        notes.remove(at: index)
        return true
    }

    func note(_ id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    func snapshot() -> [Note] { notes }
}

private actor RecoveringDeckStore: NoteStore {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The test store is unavailable." }
    }

    private var note: Note
    private var writesFail = true
    private var purges = 0

    init(note: Note) {
        self.note = note
    }

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] { [note] }
    func allKnownIDs() async throws -> Set<UUID> { [note.id] }
    func upsert(_ note: Note) async throws { self.note = note }
    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool {
        guard id == note.id else { return false }
        guard !writesFail else { throw Failure() }
        let original = note
        change(&note)
        return note != original
    }
    func softDelete(id: UUID) async throws -> DeletionToken? { nil }
    func restore(_ deletion: DeletionToken) async throws -> Bool { false }
    func purge(_ deletion: DeletionToken) async throws -> Bool {
        purges += 1
        return true
    }

    func allowWrites() { writesFail = false }
    func storedNote() -> Note { note }
    func purgeCount() -> Int { purges }
}

private actor GatedDeckMutationStore: NoteStore {
    private var note: Note
    private var mutationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseMutation: CheckedContinuation<Void, Never>?

    init(note: Note) { self.note = note }

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] { [note] }
    func allKnownIDs() async throws -> Set<UUID> { [note.id] }
    func upsert(_ note: Note) async throws { self.note = note }
    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool {
        mutationStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseMutation = $0 }
        guard id == note.id else { return false }
        let original = note
        change(&note)
        return note != original
    }
    func softDelete(id: UUID) async throws -> DeletionToken? { nil }
    func restore(_ deletion: DeletionToken) async throws -> Bool { false }
    func purge(_ deletion: DeletionToken) async throws -> Bool { false }

    func waitUntilMutationStarts() async {
        guard !mutationStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseMutation?.resume()
        releaseMutation = nil
    }

    func storedNote() -> Note { note }
}

private actor CompletionFlag {
    private var value = false
    func mark() { value = true }
    func isSet() -> Bool { value }
}

@MainActor
final class DeckHoverTests: XCTestCase {
    /// `select` reads the system Reduce Motion setting to decide whether to
    /// morph or jump straight to editing. CI runners report it as *on*, so
    /// building the model directly makes these tests depend on the machine
    /// they run on. Pin it instead.
    private func makeModel(_ store: any NoteStore) -> DeckViewModel {
        let model = DeckViewModel(store: store)
        model.reduceMotion = { false }
        return model
    }

    /// Waits for something to *become* true instead of sleeping a fixed
    /// margin past a grace period. The deck's timers are tens of
    /// milliseconds, and a loaded CI runner overshoots a 40 ms cushion
    /// routinely — which reads as a deck bug rather than a slow machine.
    /// Only use this for assertions of presence; proving something did *not*
    /// happen still needs a real elapsed wait.
    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    func testNewNoteSaturatesAnImportedMinimumSortIndex() async {
        let original = Note(title: "Extreme", sortIndex: .min)
        let store = PurgeRecordingNoteStore(notes: [original])
        let model = makeModel(store)
        await model.reload()

        await model.newNote()

        let stored = await store.snapshot()
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.map(\.sortIndex).min(), Int.min)
    }

    func testDuplicateSaturatesAnImportedMaximumSortIndex() async {
        let original = Note(title: "Extreme", sortIndex: .max)
        let store = PurgeRecordingNoteStore(notes: [original])
        let model = makeModel(store)
        await model.reload()

        model.duplicate(original.id)
        let duplicated = await eventually { await store.snapshot().count == 2 }

        XCTAssertTrue(duplicated)
        let stored = await store.snapshot()
        XCTAssertEqual(stored.map(\.sortIndex), [Int.max, Int.max])
    }

    func testPinnedDeleteUsesTheSharedUndoFlowAndRevealsItsToast() async {
        let note = Note(title: "Pinned", pinned: true)
        let store = PurgeRecordingNoteStore(notes: [note])
        let model = makeModel(store)
        await model.reload()
        XCTAssertTrue(model.deckNotes.isEmpty, "pinned notes do not live in the deck array")

        model.deletePinnedWithUndo(note)

        XCTAssertEqual(model.state, .fan)
        let undoArmed = await eventually { model.pendingDelete?.note.id == note.id }
        XCTAssertTrue(undoArmed)
        let softDeleted = await eventually { await store.note(note.id)?.deletedAt != nil }
        XCTAssertTrue(softDeleted)

        model.undoDelete()
        let restored = await eventually { await store.note(note.id)?.deletedAt == nil }
        XCTAssertTrue(restored)
        XCTAssertNil(model.pendingDelete)
    }

    func testRapidColorCyclesAdvanceFromTheLiveStoredColor() async {
        let note = Note(colorIndex: NoteColor.amber.rawValue)
        let store = PurgeRecordingNoteStore(notes: [note])
        let model = makeModel(store)
        await model.reload()
        let once = NoteColor.at(note.colorIndex).next.rawValue
        let twice = NoteColor.at(once).next.rawValue

        model.cycleColor(of: note.id)
        model.cycleColor(of: note.id)

        let advancedTwice = await eventually {
            await store.note(note.id)?.colorIndex == twice
        }
        XCTAssertTrue(advancedTwice)
    }

    /// Regression: closing a note from the keyboard or a button while the
    /// pointer sits elsewhere used to leave the fan on the screen edge
    /// forever, because hover exits are dropped while expanded and AppKit
    /// never sends another one without a fresh enter.
    func testClosingWithThePointerAwayReEvaluatesCollapse() async {
        let note = Note()
        let model = makeModel(HoverNoteStore(notes: [note]))
        await model.reload()
        model.state = .fan
        model.select(note.id)
        XCTAssertEqual(model.state, .expanded(note.id))

        var requestedRetraction = false
        model.collapseRequest = { requestedRetraction = true }
        model.shouldCollapseCheck = { true }   // pointer is nowhere near the deck

        model.closeNote()
        let collapsed = await eventually { requestedRetraction }
        XCTAssertTrue(
            collapsed,
            "Closing with the pointer away must collapse rather than strand the fan open"
        )
    }

    /// The pointer resting on the deck must still hold it open after a close.
    func testClosingWithThePointerInsideKeepsTheFanOpen() async {
        let note = Note()
        let model = makeModel(HoverNoteStore(notes: [note]))
        await model.reload()
        model.state = .fan
        model.select(note.id)

        var requestedRetraction = false
        model.collapseRequest = { requestedRetraction = true }
        model.shouldCollapseCheck = { false }  // pointer still over the deck

        model.closeNote()
        try? await Task.sleep(
            for: .milliseconds(DeckInteraction.collapseGraceMilliseconds + 40)
        )
        XCTAssertFalse(requestedRetraction)
        XCTAssertEqual(model.state, .fan)
    }

    /// Regression: deleting from the expanded card closed the note, and the
    /// new collapse re-check then retracted the whole panel ~60 ms later —
    /// taking the undo toast, which lives inside that panel, with it.
    func testClosingWithAPendingDeleteKeepsTheDeckOpenForTheToast() async {
        let note = Note()
        let store = PurgeRecordingNoteStore(notes: [note])
        let model = makeModel(store)
        await model.reload()
        model.state = .fan
        model.select(note.id)

        var requestedRetraction = false
        model.collapseRequest = { requestedRetraction = true }
        model.shouldCollapseCheck = { true }   // pointer is away from the deck

        model.deleteWithUndo(note.id)          // closes the note and arms the toast
        try? await Task.sleep(
            for: .milliseconds(DeckInteraction.collapseGraceMilliseconds + 60)
        )

        XCTAssertNotNil(model.pendingDelete)
        XCTAssertFalse(
            requestedRetraction,
            "The deck must stay open while its undo toast is the only way back"
        )
    }

    /// Regression: `closeNote` refused to collapse while a delete was pending,
    /// but the editor layer's own hover exit — which fires as the card stops
    /// hit-testing — went through the unguarded path and retracted the panel
    /// ~60 ms later anyway, taking the toast, its Undo button and its ⌘Z with
    /// it while the ten-second purge kept running.
    func testHoverExitWithAPendingDeleteKeepsTheDeckOpenForTheToast() async {
        let note = Note()
        let store = PurgeRecordingNoteStore(notes: [note])
        let model = makeModel(store)
        await model.reload()
        model.state = .fan

        var requestedRetraction = false
        model.collapseRequest = { requestedRetraction = true }
        model.shouldCollapseCheck = { true }   // pointer is away from the deck

        model.deleteWithUndo(note.id)
        let armed = await eventually { model.pendingDelete != nil }
        XCTAssertTrue(armed)

        model.deckHoverChanged(false)          // the exit the editor layer sends
        try? await Task.sleep(
            for: .milliseconds(DeckInteraction.collapseGraceMilliseconds + 60)
        )

        XCTAssertNotNil(model.pendingDelete)
        XCTAssertFalse(
            requestedRetraction,
            "A hover exit must not retract the panel the undo toast lives in"
        )
    }

    /// The other half of that guard: suppressing the collapse must not strand
    /// the fan open once the toast is gone. AppKit sends no fresh exit for a
    /// pointer that never moved, so the deck has to re-check for itself.
    func testTheDeckCollapsesOnceThePendingDeleteResolves() async {
        let note = Note()
        let store = PurgeRecordingNoteStore(notes: [note])
        let model = makeModel(store)
        await model.reload()
        model.state = .fan

        var requestedRetraction = false
        model.collapseRequest = { requestedRetraction = true }
        model.shouldCollapseCheck = { true }

        model.deleteWithUndo(note.id)
        let armed = await eventually { model.pendingDelete != nil }
        XCTAssertTrue(armed)
        model.deckHoverChanged(false)
        try? await Task.sleep(
            for: .milliseconds(DeckInteraction.collapseGraceMilliseconds + 60)
        )
        XCTAssertFalse(requestedRetraction, "the exit is suppressed while the toast is up")

        model.deleteExpired()

        let collapsed = await eventually { requestedRetraction }
        XCTAssertTrue(
            collapsed,
            "Once the toast expires the suppressed collapse must finally run"
        )
    }

    /// Regression: pinning from a fan tab handed the sticky the pre-debounce
    /// `deckNotes` copy. The expanded card's paths flush first, but that
    /// helper only ever flushes the card's *own* note — so pinning note A
    /// from its tab while A still had a pending draft opened the window on
    /// stale text, and the sticky's own save wrote that text back over the
    /// newer copy.
    func testPinningFromATabHandsOverTheDraftTheUserCanSee() async {
        let note = Note(title: "Before", body: "Saved body")
        let store = PurgeRecordingNoteStore(notes: [note])
        let model = makeModel(store)
        await model.reload()
        model.state = .fan

        let presenter = RecordingStickyPresenter()
        model.stickyPresenter = presenter

        // Typed, still inside the 250 ms debounce — nothing has reached the store.
        model.saveDraft(id: note.id, title: "After", body: "Typed body", bodyWasEdited: true)
        model.togglePin(of: note.id)

        XCTAssertEqual(presenter.presented.count, 1)
        XCTAssertEqual(presenter.presented.first?.title, "After")
        XCTAssertEqual(
            presenter.presented.first?.body,
            "Typed body",
            "The sticky must open on the pending draft, not the last saved copy"
        )
        XCTAssertEqual(presenter.presented.first?.pinned, true)
    }

    /// Regression: a newer delete replaces a pending one (D9), but the
    /// outgoing note used to be abandoned — its purge timer cancelled and its
    /// row left soft-deleted forever, invisible and never cleaned up.
    func testReplacingAPendingDeletePurgesTheOutgoingNote() async {
        let first = Note(title: "first", sortIndex: 0)
        let second = Note(title: "second", sortIndex: 1)
        let store = PurgeRecordingNoteStore(notes: [first, second])
        let model = makeModel(store)
        await model.reload()

        model.deleteWithUndo(first.id)
        try? await Task.sleep(for: .milliseconds(60))
        model.deleteWithUndo(second.id)
        _ = await eventually { await store.purged == [first.id] }

        let purged = await store.purged
        XCTAssertEqual(
            purged,
            [first.id],
            "The replaced delete must be committed, not silently abandoned"
        )
        XCTAssertEqual(model.pendingDelete?.note.id, second.id)
    }
    func testHoveredTabInteractionWidthCoversItsVisiblePreview() {
        XCTAssertEqual(
            DeckMetrics.tabInteractionWidth(isPeeking: true),
            DeckMetrics.peekWidth,
            "The visible preview must remain inside the tab's hoverable frame"
        )
    }

    func testLateExitFromPreviousTabDoesNotClearCurrentPreview() {
        let model = makeModel(HoverNoteStore())
        let first = UUID()
        let second = UUID()
        model.state = .fan

        model.setPeek(first, hovering: true)
        model.setPeek(second, hovering: true)
        model.setPeek(first, hovering: false)

        XCTAssertEqual(
            model.peekedNoteID,
            second,
            "A late exit from an overlapped tab must not collapse the preview that just gained hover"
        )
    }

    func testNewNoteButtonClearsTheHoveredPreview() async {
        let model = makeModel(HoverNoteStore())
        let hovered = UUID()
        model.state = .fan
        model.setPeek(hovered, hovering: true)

        await model.newNote()

        XCTAssertNil(
            model.peekedNoteID,
            "Opening a note from the plus button must not retain the fan's wide hover hit region"
        )
    }

    func testPreviewExitUsesShortTrackingAreaGrace() async {
        let note = Note()
        let model = makeModel(HoverNoteStore(notes: [note]))
        await model.reload()
        let hovered = note.id
        model.state = .fan
        model.setPeek(hovered, hovering: true)
        model.setPeek(hovered, hovering: false)

        XCTAssertEqual(model.peekedNoteID, hovered)
        let cleared = await eventually { model.peekedNoteID == nil }
        XCTAssertTrue(cleared, "The preview should release after the exit grace")
    }

    func testReturningDuringGraceKeepsPreviewOwned() async {
        let note = Note()
        let model = makeModel(HoverNoteStore(notes: [note]))
        await model.reload()
        let hovered = note.id
        model.state = .fan
        model.setPeek(hovered, hovering: true)
        model.setPeek(hovered, hovering: false)
        model.setPeek(hovered, hovering: true)

        try? await Task.sleep(
            for: .milliseconds(DeckInteraction.peekExitGraceMilliseconds + 40)
        )
        XCTAssertEqual(model.peekedNoteID, hovered)
    }

    func testEditorRemainsMountedAcrossNoteOpenAndClose() async {
        let note = Note()
        let model = makeModel(HoverNoteStore(notes: [note]))
        await model.reload()
        model.state = .fan

        XCTAssertEqual(
            model.presentedNoteID,
            note.id,
            "The editor should be prewarmed before its first visible transition"
        )

        model.select(note.id)
        XCTAssertEqual(model.state, .expanded(note.id))
        XCTAssertEqual(
            model.notePresentationPhase,
            .moving,
            "Opening should only translate the already-mounted editor"
        )

        let settled = await eventually { model.notePresentationPhase == .editing }
        XCTAssertTrue(settled, "The morph should hand off to the editor")

        model.closeNote()
        XCTAssertEqual(model.state, .fan)
        XCTAssertEqual(model.notePresentationPhase, .idle)
        XCTAssertEqual(
            model.presentedNoteID,
            note.id,
            "Closing should retain the same editor instance behind the edge"
        )
    }

    /// Regression: each note has its own debounce task, but the quit fallback
    /// used to retain only one global draft. When note A's older task finished,
    /// it cleared note B's newer fallback; quitting before B's timer then lost
    /// the text the user had just typed.
    func testQuitFlushesANewerDraftAfterAnotherNotesDebounceCompletes() async throws {
        let first = Note(title: "First", body: "before A", sortIndex: 0)
        let second = Note(title: "Second", body: "before B", sortIndex: 1)
        let store = PurgeRecordingNoteStore(notes: [first, second])
        let model = makeModel(store)
        await model.reload()

        model.saveDraft(id: first.id, title: first.title, body: "edited A")
        try await Task.sleep(for: .milliseconds(200))
        model.saveDraft(id: second.id, title: second.title, body: "edited B")

        let firstSaved = await eventually {
            await store.note(first.id)?.body == "edited A"
        }
        XCTAssertTrue(firstSaved, "the older debounce must complete before the quit flush")

        await model.flushPendingWork()

        let savedSecond = await store.note(second.id)
        XCTAssertEqual(savedSecond?.body, "edited B")
    }

    func testFailedQuitFlushKeepsTheDraftForARetry() async {
        let note = Note(title: "Draft", body: "before")
        let store = RecoveringDeckStore(note: note)
        let model = makeModel(store)
        await model.reload()
        model.saveDraft(id: note.id, title: note.title, body: "must survive")

        let firstSaved = await model.flushPendingWork()

        XCTAssertFalse(firstSaved)
        let noteAfterFailure = await store.storedNote()
        XCTAssertEqual(noteAfterFailure.body, "before")

        await store.allowWrites()
        let retrySaved = await model.flushPendingWork()

        XCTAssertTrue(retrySaved)
        let noteAfterRetry = await store.storedNote()
        XCTAssertEqual(noteAfterRetry.body, "must survive")
    }

    func testFanArchiveWaitsForThePendingEditorDraft() async {
        let note = Note(title: "Draft", body: "before")
        let store = PurgeRecordingNoteStore(notes: [note])
        let model = makeModel(store)
        await model.reload()
        model.saveDraft(id: note.id, title: note.title, body: "latest text")

        model.archiveNote(note.id)

        let archived = await eventually {
            await store.note(note.id)?.archivedAt != nil
        }
        XCTAssertTrue(archived)
        let stored = await store.note(note.id)
        XCTAssertEqual(stored?.body, "latest text")
    }

    func testFailedDraftSaveNeverPublishesOrPurgesADelete() async {
        let note = Note(title: "Keep", body: "before")
        let store = RecoveringDeckStore(note: note)
        let model = makeModel(store)
        await model.reload()
        model.saveDraft(id: note.id, title: note.title, body: "unsaved")

        model.deleteWithUndo(note.id)
        let drained = await model.flushPendingWork()

        XCTAssertFalse(drained)
        XCTAssertNil(model.pendingDelete)
        let purgeCount = await store.purgeCount()
        let stored = await store.storedNote()
        XCTAssertEqual(purgeCount, 0)
        XCTAssertEqual(stored.body, "before")
    }

    func testFlushWaitsForARequestedStateMutation() async throws {
        let note = Note(colorIndex: 0)
        let store = GatedDeckMutationStore(note: note)
        let model = makeModel(store)
        await model.reload()
        let completed = CompletionFlag()

        model.cycleColor(of: note.id)
        let drain = Task {
            let saved = await model.flushPendingWork()
            await completed.mark()
            return saved
        }
        await store.waitUntilMutationStarts()
        try await Task.sleep(for: .milliseconds(40))

        let finishedBeforeRelease = await completed.isSet()
        XCTAssertFalse(finishedBeforeRelease, "the lifecycle barrier must still be awaiting the mutation")

        await store.release()
        let saved = await drain.value
        XCTAssertTrue(saved)
        let stored = await store.storedNote()
        XCTAssertEqual(stored.colorIndex, NoteColor.amber.next.rawValue)
    }

    func testClearingAnEditedLegacyPlaceholderReplacesTheRecoveredBody() async throws {
        let placeholder = Note(
            title: "Legacy",
            body: "",
            bodyNeedsMigration: true
        )
        let store = PurgeRecordingNoteStore(notes: [placeholder])
        let model = makeModel(store)
        await model.reload()

        // Recovery finishes after the editor loaded its empty placeholder.
        var recovered = placeholder
        recovered.body = "recovered plaintext"
        recovered.bodyNeedsMigration = false
        try await store.upsert(recovered)

        // The user typed, then intentionally cleared the body back to empty.
        model.saveDraft(
            id: placeholder.id,
            title: placeholder.title,
            body: "",
            bodyWasEdited: true
        )
        await model.flushPendingWork()

        let stored = await store.note(placeholder.id)
        XCTAssertEqual(stored?.body, "")
        XCTAssertFalse(stored?.bodyNeedsMigration ?? true)
    }

    /// With Reduce Motion on there is no morph to wait for: opening must land
    /// in `.editing` immediately rather than leaving the editor mid-flight.
    /// This path is what CI runners actually take, and it went uncovered
    /// while the setting was read straight off NSWorkspace.
    func testReduceMotionOpensStraightIntoEditing() async {
        let note = Note()
        let model = makeModel(HoverNoteStore(notes: [note]))
        model.reduceMotion = { true }
        await model.reload()
        model.state = .fan

        model.select(note.id)

        XCTAssertEqual(model.state, .expanded(note.id))
        XCTAssertEqual(
            model.notePresentationPhase,
            .editing,
            "Reduce Motion should skip the morph, not stall in .moving"
        )
    }

    func testFocusLossRequestsNativeRetractionWithoutMutatingTheFan() async {
        let note = Note()
        let model = makeModel(HoverNoteStore(notes: [note]))
        await model.reload()
        model.state = .fan
        model.setPeek(note.id, hovering: true)
        var requestedRetraction = false
        model.collapseRequest = { requestedRetraction = true }

        XCTAssertLessThanOrEqual(
            DeckInteraction.collapseGraceMilliseconds,
            100,
            "Focus loss should have only a brief anti-flicker grace period"
        )

        model.deckHoverChanged(false)
        let retracted = await eventually { requestedRetraction }
        XCTAssertTrue(retracted)
        XCTAssertEqual(model.state, .fan, "SwiftUI must keep rendering the untouched fan")
        XCTAssertEqual(
            model.peekedNoteID,
            note.id,
            "The preview must remain rigid while AppKit moves its containing panel"
        )
    }

    /// Regression: the deck, pill and sticky panels are non-activating and
    /// `becomesKeyOnlyIfNeeded`, so they are essentially never the key window.
    /// A view that refuses first mouse gets no click there at all — which made
    /// every SwiftUI button on those surfaces (close dots, Delete, Mark
    /// complete, Close, the pill) dead until the panel was made key by
    /// clicking the note body, whose NSTextView does accept first mouse.
    func testPanelHostingViewsAcceptTheFirstMouseClick() {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )

        let model = makeModel(HoverNoteStore())
        let deck = PassThroughHostingView(rootView: DeckView(viewModel: model))
        XCTAssertTrue(
            deck.acceptsFirstMouse(for: event),
            "The deck editor's buttons are unreachable if its host refuses first mouse"
        )

        let sticky = FirstMouseHostingView(rootView: Text("sticky"))
        XCTAssertTrue(sticky.acceptsFirstMouse(for: event))

        // The plain hosting view is what the bug was: kept here so the
        // difference stays visible if someone swaps the subclass back out.
        let plain = NSHostingView(rootView: Text("plain"))
        XCTAssertFalse(plain.acceptsFirstMouse(for: event))
    }

    func testNativeRetractionMovesTheWholePanelWithoutResizingIt() {
        let resting = CGRect(x: 100, y: 200, width: 452, height: 720)
        let right = DeckInteraction.retractedPanelFrame(
            restingFrame: resting,
            exposedWidth: DeckMetrics.peekWidth,
            isRightEdge: true
        )
        let left = DeckInteraction.retractedPanelFrame(
            restingFrame: resting,
            exposedWidth: DeckMetrics.tabWidth,
            isRightEdge: false
        )

        XCTAssertEqual(right.size, resting.size)
        XCTAssertEqual(left.size, resting.size)
        XCTAssertEqual(right.minY, resting.minY)
        XCTAssertEqual(left.minY, resting.minY)
        XCTAssertGreaterThan(right.minX - resting.minX, DeckMetrics.peekWidth)
        XCTAssertLessThan(left.minX - resting.minX, -DeckMetrics.tabWidth)
        XCTAssertTrue(
            140 ... 190 ~= DeckInteraction.panelRetractionMilliseconds,
            "Native panel travel should be brief but continuously rendered"
        )
    }
}
