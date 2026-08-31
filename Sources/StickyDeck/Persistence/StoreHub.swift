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

    /// Drains work that still belongs to the outgoing library, then replaces
    /// the backing store and notifies observers. The backing remains unchanged
    /// while `flushPendingWork` awaits, so a debounced editor save forced by
    /// that hook is routed to the library whose note the user was editing.
    /// There is deliberately no suspension between the hook returning and the
    /// assignment, which closes the final redirect window inside this actor.
    ///
    /// Every successful swap posts: the contract's stores are value or actor
    /// types without reliable identity, so callers (e.g.
    /// `SyncFolderCoordinator`) dedupe on the setting instead of the instance.
    @discardableResult
    func swap(
        to newBacking: any NoteStore,
        afterFlushing flushPendingWork: @Sendable () async -> Bool = { true }
    ) async -> Bool {
        guard await flushPendingWork() else { return false }
        backing = newBacking
        NotificationCenter.default.post(name: .noteStoreChanged, object: nil)
        NotificationCenter.default.post(name: .noteStoreBackingChanged, object: nil)
        return true
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

    func mutate(
        id: UUID,
        _ change: @Sendable (inout Note) -> Void
    ) async throws -> Bool {
        // Capture once. A backing swap may enter this actor while the store
        // operation is suspended; the entire compound mutation must stay in
        // the library where it began.
        let target = backing
        return try await target.mutate(id: id, change)
    }

    func softDelete(id: UUID) async throws -> DeletionToken? {
        let target = backing
        return try await target.softDelete(id: id)
    }

    func restore(_ token: DeletionToken) async throws -> Bool {
        let target = backing
        return try await target.restore(token)
    }

    func purge(_ token: DeletionToken) async throws -> Bool {
        let target = backing
        return try await target.purge(token)
    }
}
