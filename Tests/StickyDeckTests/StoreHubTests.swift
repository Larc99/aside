import XCTest
import CryptoKit
@testable import StickyDeck

final class StoreHubTests: XCTestCase {
    private func makeLocalStore() throws -> LocalNoteStore {
        LocalNoteStore(database: try AppDatabase.inMemory(), key: SymmetricKey(size: .bits256))
    }

    func testForwardsToBackingStore() async throws {
        let hub = StoreHub(backing: try makeLocalStore())

        let note = Note(title: "Through the hub", body: "content", tag: "hub")
        try await hub.upsert(note)

        let fetched = try await hub.fetch(filter: .all, query: "")
        XCTAssertEqual(fetched.map(\.id), [note.id])

        try await hub.softDelete(id: note.id)
        let afterDelete = try await hub.fetch(filter: .all, query: "")
        XCTAssertTrue(afterDelete.isEmpty)

        try await hub.restore(id: note.id)
        let restored = try await hub.fetch(filter: .all, query: "")
        XCTAssertEqual(restored.map(\.id), [note.id])

        try await hub.purge(id: note.id)
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
}
