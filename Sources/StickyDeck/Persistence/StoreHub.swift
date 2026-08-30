import Foundation

/// A `NoteStore` that forwards to a swappable backing store. Controllers and
/// views capture `any NoteStore` at init; the hub lets the backing store
/// change underneath them (local SQLite ⇄ sync folder) without rebuilding
/// anything. Swaps post `.noteStoreChanged` so every observer re-pulls.
actor StoreHub: NoteStore {
    private(set) var backing: any NoteStore

    init(backing: any NoteStore) {
        self.backing = backing
    }

    /// Replaces the backing store and notifies observers. Always posts: the
    /// contract's stores are value or actor types without reliable identity,
    /// so callers (e.g. `SyncFolderCoordinator`) dedupe on the *setting*
    /// instead of the instance.
    func swap(to newBacking: any NoteStore) {
        backing = newBacking
        NotificationCenter.default.post(name: .noteStoreChanged, object: nil)
    }

    // MARK: - NoteStore (forwarded)
    //
    // Each forward reads `backing` and then suspends, so a `swap` landing
    // during that suspension leaves the operation completing against the store
    // the user has just switched away from. That is accepted rather than
    // fixed: per D24 the local library and a sync folder are independent
    // libraries with no migration between them, so an edit made moments before
    // the switch belongs to the library it was typed into. Nothing is lost —
    // the swap posts `.noteStoreChanged`, and every observer re-pulls from the
    // new backing store.

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] {
        try await backing.fetch(filter: filter, query: query)
    }

    func allKnownIDs() async throws -> Set<UUID> {
        try await backing.allKnownIDs()
    }

    func upsert(_ note: Note) async throws {
        try await backing.upsert(note)
    }

    func softDelete(id: UUID) async throws {
        try await backing.softDelete(id: id)
    }

    func restore(id: UUID) async throws {
        try await backing.restore(id: id)
    }

    func purge(id: UUID) async throws {
        try await backing.purge(id: id)
    }
}
