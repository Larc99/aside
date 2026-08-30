import XCTest
@testable import Aside
import SwiftUI

private actor HoverNoteStore: NoteStore {
    let notes: [Note]

    init(notes: [Note] = []) {
        self.notes = notes
    }

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] { notes }
    func allKnownIDs() async throws -> Set<UUID> { Set(notes.map(\.id)) }

    func upsert(_ note: Note) async throws {}
    func softDelete(id: UUID) async throws {}
    func restore(id: UUID) async throws {}
    func purge(id: UUID) async throws {}
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
    func softDelete(id: UUID) async throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].deletedAt = Date()
    }
    func restore(id: UUID) async throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].deletedAt = nil
    }
    func purge(id: UUID) async throws {
        purged.append(id)
        notes.removeAll { $0.id == id }
    }
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
