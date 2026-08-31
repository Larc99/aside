import AppKit

/// Pure screen placement policy shared by initial presentation, screen
/// changes, and AppKit's live window constraints.
enum StickyPlacement {
    static let screenMargin: CGFloat = 8

    static func clampedFrame(
        _ proposed: CGRect,
        within visibleFrames: [CGRect],
        margin: CGFloat = screenMargin
    ) -> CGRect {
        guard let screen = bestScreen(for: proposed, among: visibleFrames) else { return proposed }

        var result = proposed
        let usable = screen.insetBy(dx: margin, dy: margin)

        if result.width >= usable.width {
            result.origin.x = usable.midX - result.width / 2
        } else {
            result.origin.x = min(max(result.origin.x, usable.minX), usable.maxX - result.width)
        }

        if result.height >= usable.height {
            result.origin.y = usable.midY - result.height / 2
        } else {
            result.origin.y = min(max(result.origin.y, usable.minY), usable.maxY - result.height)
        }

        return result
    }

    private static func bestScreen(for frame: CGRect, among screens: [CGRect]) -> CGRect? {
        screens.max { lhs, rhs in
            let lhsArea = lhs.intersection(frame).nonNullArea
            let rhsArea = rhs.intersection(frame).nonNullArea
            if lhsArea != rhsArea { return lhsArea < rhsArea }

            let lhsDistance = squaredDistance(lhs.center, frame.center)
            let rhsDistance = squaredDistance(rhs.center, frame.center)
            return lhsDistance > rhsDistance
        }
    }

    private static func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

private extension CGRect {
    var nonNullArea: CGFloat { isNull ? 0 : width * height }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// Persists only the card origin; size remains a live-measured invariant.
/// The defaults dependency is accepted so the module can be tested without
/// touching application preferences.
final class StickyPositionStore {
    private let defaults: UserDefaults
    private let key = "pinnedNotePositions.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func origin(for noteID: UUID) -> CGPoint? {
        guard let positions = defaults.dictionary(forKey: key),
              let value = positions[noteID.uuidString] as? [String: Double],
              let x = value["x"], let y = value["y"] else { return nil }
        return CGPoint(x: x, y: y)
    }

    func save(origin: CGPoint, for noteID: UUID) {
        var positions = defaults.dictionary(forKey: key) ?? [:]
        positions[noteID.uuidString] = ["x": Double(origin.x), "y": Double(origin.y)]
        defaults.set(positions, forKey: key)
    }
}
