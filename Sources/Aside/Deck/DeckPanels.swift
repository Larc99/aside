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
