import XCTest
@testable import StickyDeck

/// Counts what the welcome-note seed actually writes, and can be emptied the
/// way a user empties their library: tombstones are purged ten seconds after
/// the last delete, so nothing is left behind to prove the library was used.
private actor SeedRecordingNoteStore: NoteStore {
    private var notes: [Note] = []
    private(set) var upserts = 0

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] { notes }
    func allKnownIDs() async throws -> Set<UUID> { Set(notes.map(\.id)) }
    func upsert(_ note: Note) async throws {
        upserts += 1
        notes.append(note)
    }
    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool { false }
    func softDelete(id: UUID) async throws -> DeletionToken? { nil }
    func restore(_ deletion: DeletionToken) async throws -> Bool { false }
    func purge(_ deletion: DeletionToken) async throws -> Bool { false }

    /// Adds a note without counting it as a seed write.
    func preload(_ note: Note) { notes.append(note) }
    func emptyTheLibraryCompletely() { notes.removeAll() }
    func seedCount() -> Int { upserts }
}

@MainActor
final class OnboardingSeedTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // A private suite: these assertions are about persisted state, and
        // `UserDefaults.standard` would carry it between runs and machines.
        suiteName = "OnboardingSeedTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeController(_ store: any NoteStore) -> OnboardingController {
        OnboardingController(store: store, onCreateNewNote: {}, defaults: defaults)
    }

    func testANeverUsedLibraryIsSeededOnce() async {
        let store = SeedRecordingNoteStore()
        let controller = makeController(store)

        await controller.refreshActiveLibrary()
        await controller.refreshActiveLibrary()

        let count = await store.seedCount()
        XCTAssertEqual(count, 1, "the welcome note is seeded once, not on every check")
    }

    /// Regression: emptiness was the only test, and it rested on tombstones
    /// that are purged ten seconds after the last delete (or on quit). A user
    /// who cleared the deck and relaunched was handed the welcome note back —
    /// exactly what the seed is documented never to do.
    func testAnEmptiedLibraryIsNotSeededAgain() async {
        let store = SeedRecordingNoteStore()
        let controller = makeController(store)
        await controller.refreshActiveLibrary()

        await store.emptyTheLibraryCompletely()
        await controller.refreshActiveLibrary()

        let count = await store.seedCount()
        XCTAssertEqual(count, 1, "a library the user deliberately cleared stays cleared")
    }

    /// The user-facing shape of the same bug: someone who has been using
    /// StickyDeck deletes every note. Ten seconds later the tombstones are
    /// purged, the library is genuinely empty, and the next launch used to
    /// greet them with "Getting started" again.
    func testALibraryThatAlreadyHeldNotesIsNeverSeededAfterBeingEmptied() async {
        let store = SeedRecordingNoteStore()
        await store.preload(Note(title: "Existing work"))
        let controller = makeController(store)

        await controller.refreshActiveLibrary()
        await store.emptyTheLibraryCompletely()
        await controller.refreshActiveLibrary()

        let count = await store.seedCount()
        XCTAssertEqual(count, 0, "a library the user has used is never seeded, however empty it gets")
    }
}
