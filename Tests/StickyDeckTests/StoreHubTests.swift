import XCTest
@testable import StickyDeck

private actor GatedMutationStore: NoteStore {
    private var notes: [UUID: Note]
    private var mutationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseMutation: CheckedContinuation<Void, Never>?

    init(note: Note) {
        notes = [note.id: note]
    }

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] {
        notes.values.filter { $0.deletedAt == nil }
    }

    func allKnownIDs() async throws -> Set<UUID> { Set(notes.keys) }

    func upsert(_ note: Note) async throws { notes[note.id] = note }

    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool {
        mutationStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseMutation = $0 }

        guard var note = notes[id], note.deletedAt == nil else { return false }
        let original = note
        change(&note)
        guard note != original else { return false }
        note.updatedAt = max(Date(), original.updatedAt.addingTimeInterval(0.001))
        notes[id] = note
        return true
    }

    func softDelete(id: UUID) async throws -> DeletionToken? {
        guard var note = notes[id], note.deletedAt == nil else { return nil }
        let deletedAt = max(Date(), note.updatedAt.addingTimeInterval(0.001))
        note.deletedAt = deletedAt
        note.updatedAt = deletedAt
        notes[id] = note
        return DeletionToken(noteID: id, deletedAt: deletedAt)
    }

    func restore(_ token: DeletionToken) async throws -> Bool {
        guard var note = notes[token.noteID], note.deletedAt == token.deletedAt else { return false }
        note.deletedAt = nil
        notes[token.noteID] = note
        return true
    }

    func purge(_ token: DeletionToken) async throws -> Bool {
        guard notes[token.noteID]?.deletedAt == token.deletedAt else { return false }
        notes[token.noteID] = nil
        return true
    }

    func waitUntilMutationStarts() async {
        guard !mutationStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishMutation() {
        releaseMutation?.resume()
        releaseMutation = nil
    }

    func note(_ id: UUID) -> Note? { notes[id] }
}

final class StoreHubTests: XCTestCase {
    private func makeLocalStore() throws -> LocalNoteStore {
        LocalNoteStore(database: try AppDatabase.inMemory())
    }

    func testForwardsToBackingStore() async throws {
        let hub = StoreHub(backing: try makeLocalStore())

        let note = Note(title: "Through the hub", body: "content", tag: "hub")
        try await hub.upsert(note)

        let fetched = try await hub.fetch(filter: .all, query: "")
        XCTAssertEqual(fetched.map(\.id), [note.id])

        let firstDeletionResult = try await hub.softDelete(id: note.id)
        let firstDeletion = try XCTUnwrap(firstDeletionResult)
        let afterDelete = try await hub.fetch(filter: .all, query: "")
        XCTAssertTrue(afterDelete.isEmpty)

        let didRestore = try await hub.restore(firstDeletion)
        XCTAssertTrue(didRestore)
        let restored = try await hub.fetch(filter: .all, query: "")
        XCTAssertEqual(restored.map(\.id), [note.id])

        let secondDeletionResult = try await hub.softDelete(id: note.id)
        let secondDeletion = try XCTUnwrap(secondDeletionResult)
        let didPurge = try await hub.purge(secondDeletion)
        XCTAssertTrue(didPurge)
        let purged = try await hub.fetch(filter: .all, query: "")
        XCTAssertTrue(purged.isEmpty)
    }

    func testSwapReplacesBackingAndNotifies() async throws {
        let storeA = try makeLocalStore()
        let storeB = try makeLocalStore()
        let hub = StoreHub(backing: storeA)

        let note = Note(title: "Lives in A")
        try await storeA.upsert(note)

        let expectation = expectation(forNotification: .noteStoreChanged, object: nil)
        await hub.swap(to: storeB)
        await fulfillment(of: [expectation], timeout: 1)

        let afterSwap = try await hub.fetch(filter: .all, query: "")
        XCTAssertTrue(afterSwap.isEmpty, "hub now reads from B, which is empty")

        let mirrorNote = Note(title: "Lives in B")
        try await hub.upsert(mirrorNote)
        let inB = try await storeB.fetch(filter: .all, query: "")
        XCTAssertEqual(inB.map(\.id), [mirrorNote.id])
        let inA = try await storeA.fetch(filter: .all, query: "")
        XCTAssertEqual(inA.map(\.id), [note.id], "A keeps its contents after the swap")
    }

    func testCompoundMutationStaysInTheLibraryWhereItStarted() async throws {
        let id = UUID()
        let storeA = GatedMutationStore(note: Note(id: id, body: "library A"))
        let storeB = GatedMutationStore(note: Note(id: id, body: "library B"))
        let hub = StoreHub(backing: storeA)
        var draft = Note(id: id, body: "library A")
        draft.body = "edited while switching"

        let save = Task {
            try await NoteContentWriter.saveContent(draft, to: hub)
        }
        await storeA.waitUntilMutationStarts()
        await hub.swap(to: storeB)
        await storeA.finishMutation()
        let didSave = try await save.value
        XCTAssertTrue(didSave)

        let noteA = await storeA.note(id)
        let noteB = await storeB.note(id)
        XCTAssertEqual(noteA?.body, "edited while switching")
        XCTAssertEqual(noteB?.body, "library B", "a store swap must not redirect the second half of a save")
    }

    func testSwapFlushesAPendingSaveBeforeChangingLibraries() async throws {
        let id = UUID()
        let storeA = try makeLocalStore()
        let storeB = try makeLocalStore()
        try await storeA.upsert(Note(id: id, body: "library A"))
        try await storeB.upsert(Note(id: id, body: "library B"))
        let hub = StoreHub(backing: storeA)
        let releaseSave = OneShotGate()

        var draft = Note(id: id, body: "library A")
        draft.body = "typed before switching"
        let pendingSave = Task {
            await releaseSave.wait()
            return try await NoteContentWriter.saveContent(draft, to: hub)
        }

        let didSwap = await hub.swap(to: storeB, afterFlushing: {
            await releaseSave.open()
            _ = try? await pendingSave.value
            return true
        })

        XCTAssertTrue(didSwap)
        let noteA = try await storeA.fetch(filter: .all, query: "").first
        let noteB = try await storeB.fetch(filter: .all, query: "").first
        XCTAssertEqual(noteA?.body, "typed before switching")
        XCTAssertEqual(noteB?.body, "library B", "the outgoing draft must never land in the new library")
    }

    func testSwapAbortsWithoutNotificationWhenPendingWorkCannotBeSaved() async throws {
        let storeA = try makeLocalStore()
        let storeB = try makeLocalStore()
        let noteA = Note(title: "Library A")
        let noteB = Note(title: "Library B")
        try await storeA.upsert(noteA)
        try await storeB.upsert(noteB)
        let hub = StoreHub(backing: storeA)
        let posts = LockedPostCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .noteStoreChanged,
            object: nil,
            queue: nil
        ) { _ in posts.record() }
        defer { NotificationCenter.default.removeObserver(token) }

        let didSwap = await hub.swap(to: storeB, afterFlushing: { false })

        XCTAssertFalse(didSwap)
        XCTAssertEqual(posts.count, 0)
        let active = try await hub.fetch(filter: .all, query: "")
        XCTAssertEqual(active.map(\.id), [noteA.id])
    }
}

private actor OneShotGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private final class LockedPostCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
