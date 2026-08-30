import AppKit
import SwiftUI

/// Hosting view for content inside a non-activating panel.
///
/// `DeckPanel`, `PillPanel` and `StickyPanel` are `.nonactivatingPanel`s with
/// `becomesKeyOnlyIfNeeded`, so while the user works in another app they are
/// essentially never the key window. AppKit does not deliver a click to a view
/// that refuses first mouse in a non-key window — it spends that click raising
/// the window instead. `NSHostingView` refuses by default, so every SwiftUI
/// button on these surfaces (the editor's close dots, Delete, Mark complete,
/// Close, the pill) silently ate the first click and, because the panel still
/// never became key, every click after it too.
///
/// The note body appeared to work only because `NSTextView` accepts first
/// mouse and reports `needsPanelToBecomeKey`, so clicking the text made the
/// panel key — after which the buttons started working. That asymmetry is the
/// tell.
class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Hosting view for the deck panel. The panel covers a fixed, larger area
/// than the visible content, so hit-testing is delegated: points outside the
/// deck's content rects return nil and clicks/hovers fall through to apps
/// underneath.
final class PassThroughHostingView: FirstMouseHostingView<DeckView> {
    /// Point in AppKit's bottom-left origin — the same basis as the
    /// `DeckMetrics` content rects.
    var shouldAcceptHit: ((CGPoint) -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // `NSHostingView` is flipped, so `local` has a top-left origin while
        // every DeckMetrics rect is built bottom-left. Without this conversion
        // the two non-centred rects (the undo toast, and the card once it has
        // been dragged) are mirrored: the toast is unclickable and an
        // equivalent band at the opposite end swallows clicks meant for the
        // app underneath.
        let unflipped = DeckMetrics.unflippedHitPoint(local, in: bounds, isFlipped: isFlipped)
        if let accept = shouldAcceptHit, !accept(unflipped) {
            return nil
        }
        return super.hitTest(point)
    }
}
