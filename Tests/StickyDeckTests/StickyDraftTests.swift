import XCTest
@testable import StickyDeck

private actor StickyDraftRecorder {
    private var writes: [Note] = []

    func record(_ note: Note) {
        writes.append(note)
    }

    func recordedWrites() -> [Note] {
        writes
    }
}

private actor StickyActionGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseAction: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseAction = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseAction?.resume()
        releaseAction = nil
    }
}

private actor StickyCompletionFlag {
    private var value = false
    func mark() { value = true }
    func isSet() -> Bool { value }
}

@MainActor
final class StickyDraftTests: XCTestCase {
    func testFlushCommitsTextWithoutWaitingForTheDebounce() async {
        let recorder = StickyDraftRecorder()
        let draft = StickyNoteDraft(note: Note(body: "before")) { note in
            await recorder.record(note)
        }

        draft.updateBody("typed immediately before quit")
        let saved = await draft.flushPendingSave()

        XCTAssertTrue(saved)
        let writes = await recorder.recordedWrites()
        XCTAssertEqual(writes.map(\.body), ["typed immediately before quit"])
    }

    func testARealBodyEditClearsTheLegacyPlaceholderMarker() async {
        let recorder = StickyDraftRecorder()
        let note = Note(body: "", bodyNeedsMigration: true)
        let draft = StickyNoteDraft(note: note) { saved in
            await recorder.record(saved)
        }

        // Typing and then deleting back to empty is an intentional edit. It
        // must not be mistaken for the untouched migration placeholder.
        draft.updateBody("temporary")
        draft.updateBody("")
        let saved = await draft.flushPendingSave()

        XCTAssertTrue(saved)
        let writes = await recorder.recordedWrites()
        XCTAssertEqual(writes.count, 1)
        XCTAssertFalse(writes[0].bodyNeedsMigration)
        XCTAssertEqual(writes[0].body, "")
    }

    func testFailedFlushRetainsTheDraftForAQuitRetry() async {
        struct ExpectedFailure: Error {}

        let recorder = StickyDraftRecorder()
        var failNextSave = true
        let draft = StickyNoteDraft(note: Note(body: "before")) { note in
            if failNextSave {
                failNextSave = false
                throw ExpectedFailure()
            }
            await recorder.record(note)
        }

        draft.updateBody("must survive")
        let firstSaved = await draft.flushPendingSave()
        let writesAfterFailure = await recorder.recordedWrites()

        XCTAssertFalse(firstSaved)
        XCTAssertTrue(draft.hasPendingWork)
        XCTAssertTrue(writesAfterFailure.isEmpty)

        let retrySaved = await draft.flushPendingSave()

        XCTAssertTrue(retrySaved)
        XCTAssertFalse(draft.hasPendingWork)
        let writes = await recorder.recordedWrites()
        XCTAssertEqual(writes.map(\.body), ["must survive"])
    }

    func testLifecycleFlushWaitsForTheStateActionAfterSaving() async throws {
        let recorder = StickyDraftRecorder()
        let actionGate = StickyActionGate()
        let completed = StickyCompletionFlag()
        let draft = StickyNoteDraft(note: Note(body: "before")) { note in
            await recorder.record(note)
        }
        draft.updateBody("saved before unpin")
        draft.performAfterFlush { _ in
            await actionGate.enterAndWait()
        }

        let drain = Task {
            let saved = await draft.flushPendingWork()
            await completed.mark()
            return saved
        }
        await actionGate.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(40))

        let finishedBeforeRelease = await completed.isSet()
        XCTAssertFalse(finishedBeforeRelease, "the lifecycle barrier must include the state action")
        let writes = await recorder.recordedWrites()
        XCTAssertEqual(writes.map(\.body), ["saved before unpin"])

        await actionGate.release()
        let saved = await drain.value
        XCTAssertTrue(saved)
    }
}
