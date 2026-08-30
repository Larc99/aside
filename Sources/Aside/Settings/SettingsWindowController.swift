import AppKit
import SwiftUI

/// Owns the Settings window. Lazily creates the window on the first
/// `.openSettingsRequested` (posted by the status item and the deck menus),
/// brings it to the front, and activates the app so its controls are
/// immediately interactive despite the accessory activation policy.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .openSettingsRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showSettings()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func showSettings() {
        let window = self.window ?? makeWindow()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Aside Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier("AsideSettingsWindow")
        window.contentView = NSHostingView(rootView: SettingsView())
        let autosaveName = "AsideSettingsWindow"
        let hasSavedFrame = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        if !hasSavedFrame { window.center() }
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        return window
    }
}
