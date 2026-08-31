import AppKit
import SwiftUI

/// Hosts a searchable, multi-selectable note list window (All Notes or Archive).
@MainActor
final class NoteListWindowController: NSWindowController {
    let model: NoteListModel

    init(store: any NoteStore, mode: NoteListView.Mode, title: String) {
        model = NoteListModel(store: store, mode: mode)
        let size = mode == .archive
            ? NSSize(width: 786, height: 490)
            : NSSize(width: 786, height: 634)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let autosaveName = mode == .archive ? "StickyDeckArchiveWindow" : "StickyDeckAllNotesWindow"
        let hasSavedFrame = window.setFrameUsingName(autosaveName)
        window.identifier = NSUserInterfaceItemIdentifier(autosaveName)
        window.minSize = mode == .archive
            ? NSSize(width: 680, height: 420)
            : NSSize(width: 720, height: 540)

        let root = NoteListView(model: model)
        window.contentView = NSHostingView(rootView: root)
        window.setFrameAutosaveName(autosaveName)
        if !hasSavedFrame { window.center() }

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showAndActivate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func flushPendingWork() async -> Bool {
        await model.flushPendingWork()
    }

    var hasPendingWork: Bool { model.hasPendingWork }

    func reload() async {
        await model.reload()
    }
}
