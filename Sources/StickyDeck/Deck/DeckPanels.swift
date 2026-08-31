import AppKit

/// Borderless non-activating panel that can take key focus (needed for text
/// editing inside the expanded note without activating the whole app).
class DeckPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        animationBehavior = .utilityWindow
        // This panel is a sheet of pastel note paper: its fill is a fixed
        // light colour and its text is black, so it stays in the light
        // appearance whatever the system is set to.
        appearance = NSAppearance(named: .aqua)
        applyFullscreenBehavior()
    }

    func applyFullscreenBehavior() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        if AppSettings.showOverFullScreen {
            collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }
}

/// The dormant per-display pill. Small borderless non-activating panel.
class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        // This panel is a sheet of pastel note paper: its fill is a fixed
        // light colour and its text is black, so it stays in the light
        // appearance whatever the system is set to.
        appearance = NSAppearance(named: .aqua)
        applyFullscreenBehavior()
    }

    func applyFullscreenBehavior() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        if AppSettings.showOverFullScreen {
            collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }
}
