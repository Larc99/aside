import SwiftUI

/// One small interface for deck timing and motion. Closing is deliberately an
/// AppKit panel operation so it cannot alter the SwiftUI fan's hover rendering.
enum DeckInteraction {
    static let peekExitGraceMilliseconds = 110
    static let collapseGraceMilliseconds = 60
    static let panelRetractionMilliseconds = 165
    static let noteMorphMilliseconds = 200

    static func cardAnimation(reduceMotion: Bool) -> Animation? {
        if reduceMotion { return nil }
        return .spring(response: 0.32, dampingFraction: 0.86)
    }

    static func noteMorphAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .smooth(duration: Double(noteMorphMilliseconds) / 1_000)
    }

    static func hoverAnimation(reduceMotion: Bool) -> Animation? {
        if reduceMotion { return nil }
        return .spring(response: 0.24, dampingFraction: 0.88)
    }

    static func retractedPanelFrame(
        restingFrame: CGRect,
        exposedWidth: CGFloat,
        isRightEdge: Bool
    ) -> CGRect {
        let travel = max(exposedWidth, 0) + DeckMetrics.edgeOverdraw + 4
        return restingFrame.offsetBy(dx: isRightEdge ? travel : -travel, dy: 0)
    }

    static func controlAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.16)
    }

    static func tabInsertionAnimation(index: Int, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.34, dampingFraction: 0.82)
            .delay(Double(index) * DeckMetrics.stagger())
    }
}
