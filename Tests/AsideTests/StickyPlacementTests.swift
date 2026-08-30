import XCTest
@testable import Aside

final class StickyPlacementTests: XCTestCase {
    func testClampsEveryEdgeInsideVisibleScreenMargin() {
        let screen = CGRect(x: 0, y: 24, width: 1_000, height: 700)
        let proposed = CGRect(x: 900, y: -200, width: 400, height: 450)

        let result = StickyPlacement.clampedFrame(proposed, within: [screen])

        XCTAssertEqual(result.maxX, screen.maxX - StickyPlacement.screenMargin)
        XCTAssertEqual(result.minY, screen.minY + StickyPlacement.screenMargin)
        XCTAssertEqual(result.size, proposed.size)
    }

    func testChoosesScreenWithLargestIntersection() {
        let left = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let right = CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        let proposed = CGRect(x: 940, y: 200, width: 400, height: 450)

        let result = StickyPlacement.clampedFrame(proposed, within: [left, right])

        XCTAssertGreaterThanOrEqual(result.minX, right.minX + StickyPlacement.screenMargin)
    }

    func testOffscreenFrameMovesToNearestDisplay() {
        let left = CGRect(x: 0, y: 0, width: 800, height: 600)
        let right = CGRect(x: 800, y: 0, width: 800, height: 600)
        let proposed = CGRect(x: 1_900, y: 900, width: 400, height: 450)

        let result = StickyPlacement.clampedFrame(proposed, within: [left, right])

        XCTAssertLessThanOrEqual(result.maxX, right.maxX - StickyPlacement.screenMargin)
        XCTAssertLessThanOrEqual(result.maxY, right.maxY - StickyPlacement.screenMargin)
    }

    func testPositionStoreRoundTripsPerNoteOrigin() throws {
        let suite = "StickyPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StickyPositionStore(defaults: defaults)
        let first = UUID()
        let second = UUID()

        store.save(origin: CGPoint(x: 123.5, y: -42), for: first)
        store.save(origin: CGPoint(x: 700, y: 88), for: second)

        XCTAssertEqual(store.origin(for: first), CGPoint(x: 123.5, y: -42))
        XCTAssertEqual(store.origin(for: second), CGPoint(x: 700, y: 88))
    }
}
