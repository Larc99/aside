import Foundation
import AppKit

/// Single source of truth for deck geometry. Both DeckController (which sizes
/// the NSPanels) and the SwiftUI views read from here, so the panels and their
/// content can never disagree.
enum DeckMetrics {
    static var edge: AppSettings.Edge { AppSettings.deckEdge }

    // Pill (rest state): the original's 12 pt stripe with a slim dash per
    // note. The window overdraw is outside this visible width.
    static let edgeMargin: CGFloat = 0
    /// Panels overdraw past the screen edge so no anti-aliased seam is
    /// visible on the flush side.
    static let edgeOverdraw: CGFloat = 2
    static let pillWidth: CGFloat = 12
    static let pillDashWidth: CGFloat = 6
    static let pillDashHeight: CGFloat = 16
    static let pillChipGap: CGFloat = 5
    static let pillPadding: CGFloat = 7
    static let pillMinHeight: CGFloat = 36
    static let pillMaxChips = 12

    // Fan (hover state): pastel shingles flush with the screen edge.
    /// Resting fan tabs expose only their narrow stitched label strip. A
    /// hovered tab expands leftward into a readable preview without opening.
    static let tabWidth: CGFloat = 40
    static let peekWidth: CGFloat = 192
    static let tabHeight: CGFloat = 158
    /// Vertical reveal between shingles. The reference artwork exposes enough
    /// of each card for its full vertical label rather than a narrow sliver.
    static let tabStep: CGFloat = 84
    /// Floor for the tightened stagger on short displays; below this the
    /// visible tab count drops instead of tabs stacking any tighter.
    static let minTabStep: CGFloat = 30
    static let tabRadius: CGFloat = 16
    static let maxVisibleTabs = 8
    static let tileGap: CGFloat = 4
    static let plusSize: CGFloat = 30
    static let fanPadding: CGFloat = 0

    static func tabInteractionWidth(isPeeking: Bool) -> CGFloat {
        isPeeking ? peekWidth : tabWidth
    }

    /// Converts a hit-test point into the bottom-left basis every content rect
    /// here is written in. Hosting views are flipped; plain AppKit views are
    /// not, so the caller passes its own `isFlipped` rather than assuming.
    static func unflippedHitPoint(_ point: CGPoint, in bounds: CGRect, isFlipped: Bool) -> CGPoint {
        guard isFlipped else { return point }
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    // Expanded note
    static let noteWidth: CGFloat = 400
    static let noteGap: CGFloat = 10

    static func stagger() -> TimeInterval {
        0.045 * AppSettings.animationSpeed.staggerFactor
    }

    static func pillHeight(noteCount: Int, screen: NSScreen) -> CGFloat {
        pillHeight(noteCount: noteCount, maximumHeight: screen.visibleFrame.height * 0.4)
    }

    static func pillHeight(noteCount: Int, maximumHeight: CGFloat) -> CGFloat {
        let chips = min(max(noteCount, 1), pillMaxChips)
        let content = pillPadding * 2 + CGFloat(chips) * pillDashHeight + CGFloat(max(chips - 1, 0)) * pillChipGap
        return min(max(content, pillMinHeight), maximumHeight)
    }

    /// Fan layout fitted to the panel height (D26): 8 tabs at the full
    /// stagger need ~635 pt, which clips on short displays. The stagger
    /// tightens first (down to `minTabStep`), then the visible tab count
    /// drops. SwiftUI and the hit rects both read this, so they cannot drift.
    static func fanLayout(noteCount: Int, panelHeight: CGFloat) -> (visibleCount: Int, tabStep: CGFloat) {
        guard noteCount > 0 else { return (0, tabStep) }
        var visibleCount = min(noteCount, maxVisibleTabs)
        var step = tabStep
        while visibleCount > 1 {
            let available = max(
                panelHeight - accessoryHeight(noteCount: noteCount, visibleCount: visibleCount),
                tabHeight
            )
            guard tabsExtent(visibleCount: visibleCount, step: step) > available else { break }
            let fitted = (available - tabHeight) / CGFloat(visibleCount - 1)
            if fitted >= minTabStep {
                step = fitted
            } else {
                visibleCount -= 1
                step = tabStep
            }
        }
        return (visibleCount, min(step, tabStep))
    }

    static func tabsExtent(visibleCount: Int, step: CGFloat) -> CGFloat {
        guard visibleCount > 0 else { return 0 }
        return tabHeight + CGFloat(visibleCount - 1) * step
    }

    /// `drawnTabCount` is how many tabs the fan is actually rendering right
    /// now. On the last page of an overflowing deck that is fewer than the
    /// layout's page size, and using the page size here made the hit rect far
    /// taller than the visible column — swallowing clicks in the blank strip
    /// and keeping the collapse check reporting "pointer still inside".
    static func fanColumnHeight(
        noteCount: Int,
        panelHeight: CGFloat,
        drawnTabCount: Int? = nil
    ) -> CGFloat {
        let layout = fanLayout(noteCount: noteCount, panelHeight: panelHeight)
        let drawn = min(drawnTabCount ?? layout.visibleCount, layout.visibleCount)
        return tabsExtent(visibleCount: drawn, step: layout.tabStep)
            + accessoryHeight(noteCount: noteCount, visibleCount: layout.visibleCount)
    }

    /// Height below the shingled tabs. There is always a new-note button;
    /// empty and overflow states add a second tile. Keeping this exact is
    /// important because the same value drives pass-through hit testing.
    static func accessoryHeight(noteCount: Int, visibleCount: Int) -> CGFloat {
        let hasSecondTile = noteCount == 0 || noteCount > visibleCount
        let tileCount = hasSecondTile ? 2 : 1
        return CGFloat(tileCount) * plusSize + CGFloat(tileCount) * tileGap
    }

    static func fanPanelWidth() -> CGFloat {
        fanPadding + tabWidth
    }

    static func expandedPanelWidth() -> CGFloat {
        noteWidth + noteGap + fanPanelWidth()
    }

    /// The deck panel is FIXED at its maximum extents — all state changes
    /// animate inside SwiftUI. Content rects (bottom-left origin, panel-local)
    /// drive the pass-through hit testing.
    static func deckPanelFrame(screen: NSScreen) -> CGRect {
        let width = expandedPanelWidth() + edgeOverdraw
        let height = screen.visibleFrame.height * 0.8
        let x = edge == .right
            ? screen.frame.maxX - width
            : screen.frame.minX - edgeOverdraw
        return CGRect(x: x, y: screen.frame.midY - height / 2, width: width, height: height)
    }

    static func fanContentRect(
        panelWidth: CGFloat,
        panelHeight: CGFloat,
        noteCount: Int,
        isPeeking: Bool = false,
        drawnTabCount: Int? = nil
    ) -> CGRect {
        let width = fanPadding + (isPeeking ? peekWidth : tabWidth)
        let height = fanColumnHeight(
            noteCount: noteCount,
            panelHeight: panelHeight,
            drawnTabCount: drawnTabCount
        )
        let x: CGFloat = edge == .right ? panelWidth - width : 0
        return CGRect(x: x, y: (panelHeight - height) / 2, width: width, height: height)
    }

    static func cardContentRect(
        panelWidth: CGFloat,
        panelHeight: CGFloat,
        noteCount: Int,
        verticalOffset: CGFloat = 0,
        drawnTabCount: Int? = nil
    ) -> CGRect {
        let fan = fanContentRect(
            panelWidth: panelWidth,
            panelHeight: panelHeight,
            noteCount: noteCount,
            drawnTabCount: drawnTabCount
        )
        let height = expandedCardHeight
        let x: CGFloat = edge == .right
            ? panelWidth - fan.width - noteGap - noteWidth
            : fan.width + noteGap
        // SwiftUI positive y offsets move down; AppKit's rect origin moves up.
        return CGRect(x: x, y: (panelHeight - height) / 2 - verticalOffset, width: noteWidth, height: height)
    }

    static let expandedCardHeight: CGFloat = 450

    /// The complete interface for vertical card placement. Callers never
    /// need to duplicate the card/screen arithmetic, which keeps dragging and
    /// screen-change clamping identical.
    static func cardOffsetLimit(panelHeight: CGFloat, margin: CGFloat = 12) -> CGFloat {
        max((panelHeight - expandedCardHeight - margin) / 2, 0)
    }

    static func clampedCardOffset(_ proposed: CGFloat, panelHeight: CGFloat) -> CGFloat {
        let limit = cardOffsetLimit(panelHeight: panelHeight)
        return min(max(proposed, -limit), limit)
    }

    /// Bottom strip where the undo toast is anchored. Must accept hits or the
    /// Undo button is click-through (it lives outside the fan/card rects).
    ///
    /// Sized to the toast, not to the whole panel: the toast is edge-aligned
    /// and only about this wide, so claiming the full expanded width left a
    /// ~200pt invisible dead zone swallowing clicks meant for the app
    /// underneath, for ten seconds after every delete.
    static let toastWidth: CGFloat = 260

    static func toastContentRect(panelWidth: CGFloat, panelHeight: CGFloat) -> CGRect {
        let width = min(toastWidth, expandedPanelWidth())
        let x = edge == .right ? panelWidth - width : 0
        return CGRect(x: x, y: 0, width: width, height: 70)
    }

    // MARK: - Panel frames
    //
    // All frames overdraw past the flush screen edge (edgeOverdraw) so the
    // window's anti-aliased boundary is off-screen.

    static func pillFrame(noteCount: Int, screen: NSScreen) -> CGRect {
        let height = pillHeight(noteCount: noteCount, screen: screen)
        let width = pillWidth + edgeOverdraw
        let x = edge == .right
            ? screen.frame.maxX - width
            : screen.frame.minX - edgeOverdraw
        return CGRect(x: x, y: screen.frame.midY - height / 2, width: width, height: height)
    }
}
