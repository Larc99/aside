import AppKit
import Foundation

/// How the deck hands a note to the desktop, and takes it back.
///
/// Pinning is a *view* transition: the same 400x450 note surface stops being
/// drawn by the deck panel and becomes its own window at the same screen frame.
/// It only ever looked like a transition, though — it was routed through the
/// store, so the window could not exist until a write had landed and a fetch
/// had returned it. Everything the user complained about followed from that:
/// the card had to be held open, or retired early and re-shown, around a
/// database round trip nobody could see the point of.
///
/// These two calls take effect in the turn they are made. The write that
/// records the change still happens, but it no longer gates anything on screen.
@MainActor
protocol StickyPresenting: AnyObject {
    /// Puts `note` on the desktop now.
    ///
    /// - Parameter frame: the deck card's screen rectangle when there is a live
    ///   card being replaced, so the window opens exactly over it. `nil` falls
    ///   back to the note's remembered desktop position.
    func present(_ note: Note, takingPlaceOf frame: CGRect?)

    /// Takes `noteID` off the desktop now.
    func dismiss(_ noteID: UUID)
}
