import AppKit

/// Reachability surface for an LSUIElement app: New Note, All Notes, Archive,
/// Settings, edge and fullscreen toggles, Quit. Window-opening actions are
/// broadcast as notifications so the owning coordinators can respond.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let viewModel: DeckViewModel

    init(viewModel: DeckViewModel) {
        self.viewModel = viewModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "AsideStatusItem"
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Aside menu")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Aside"
            button.setAccessibilityLabel("Aside menu")
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(title: "New Note", symbol: "plus", action: #selector(newNote), keyEquivalent: "n", modifier: [.command, .option])
        menu.addItem(title: "All Notes…", symbol: "note.text", action: #selector(allNotes), keyEquivalent: "a", modifier: [.command, .option])
        menu.addItem(title: "Show Archive…", symbol: "archivebox", action: #selector(archive), keyEquivalent: "l", modifier: [.command, .option])

        menu.addItem(.separator())

        let edgeItem = NSMenuItem(title: "Screen Side", action: nil, keyEquivalent: "")
        edgeItem.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: nil)
        let edgeMenu = NSMenu()
        for edge in AppSettings.Edge.allCases {
            let item = NSMenuItem(
                title: edge == .left ? "Left" : "Right",
                action: #selector(setEdge(_:)),
                keyEquivalent: ""
            )
            item.representedObject = edge.rawValue
            item.state = edge == AppSettings.deckEdge ? .on : .off
            item.image = NSImage(
                systemSymbolName: edge == .left ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled",
                accessibilityDescription: nil
            )
            item.target = self
            edgeMenu.addItem(item)
        }
        edgeItem.submenu = edgeMenu
        menu.addItem(edgeItem)

        let fullscreenItem = NSMenuItem(
            title: "Show Over Full-Screen Apps",
            action: #selector(toggleOverFullScreen),
            keyEquivalent: ""
        )
        fullscreenItem.state = AppSettings.showOverFullScreen ? .on : .off
        fullscreenItem.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        menu.addItem(fullscreenItem)

        menu.addItem(.separator())

        menu.addItem(title: "Settings…", symbol: "gearshape", action: #selector(settings), keyEquivalent: ",", modifier: .command)
        menu.addItem(title: "About Aside", symbol: "info.circle", action: #selector(about), keyEquivalent: "", modifier: [])
        menu.addItem(.separator())
        menu.addItem(title: "Quit Aside", symbol: "power", action: #selector(quit), keyEquivalent: "q", modifier: .command)

        menu.items.forEach { $0.target = self }
    }

    @objc private func newNote() {
        Task { await viewModel.newNote() }
    }

    @objc private func allNotes() {
        NotificationCenter.default.post(name: .openAllNotesRequested, object: nil)
    }

    @objc private func archive() {
        NotificationCenter.default.post(name: .openArchiveRequested, object: nil)
    }

    @objc private func settings() {
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func setEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let edge = AppSettings.Edge(rawValue: raw) else { return }
        AppSettings.deckEdge = edge
    }

    @objc private func toggleOverFullScreen() {
        AppSettings.showOverFullScreen.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension NSMenu {
    func addItem(
        title: String,
        symbol: String,
        action: Selector,
        keyEquivalent: String,
        modifier: NSEvent.ModifierFlags
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifier
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        addItem(item)
    }
}
