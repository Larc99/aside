import AppKit
import CryptoKit

@main
struct AsideApp {
    static func main() {
        FontLoader.registerBundledFonts()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // `NSApplication.delegate` is weak, so nothing but this local holds
        // the delegate. An optimised build may release it after its last
        // use, leaving the app with no status item, deck or hotkeys.
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppEnvironment {
    let hub: StoreHub
    let localStore: LocalNoteStore
    let key: SymmetricKey

    /// The active store; a `StoreHub` so the backing store (local SQLite ⇄
    /// sync folder) can swap under every observer without rebuilding them.
    var store: any NoteStore { hub }

    init() throws {
        key = try KeyStore.noteBodyKey()
        localStore = LocalNoteStore(database: try AppDatabase.open(), key: key)
        hub = StoreHub(backing: localStore)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var deckController: DeckController?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var windowCoordinator: WindowCoordinator?
    private var stickyWindowManager: StickyWindowManager?
    private var onboardingController: OnboardingController?
    private var syncFolderCoordinator: SyncFolderCoordinator?
    private let hotKeyCenter = HotKeyCenter()
    private var isFlushingForTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Every surface in this app is drawn on the light paper ground
        // (#F5F4ED) with black-on-light text, and the note colours are fixed
        // pastels. Letting the chrome follow a dark system appearance put a
        // dark sidebar behind that palette and made All Notes unreadable.
        // Pinning the appearance keeps the app self-consistent; a real dark
        // theme would mean redesigning the palette.
        NSApp.appearance = NSAppearance(named: .aqua)

        do {
            environment = try AppEnvironment()
        } catch {
            // Without activating first, an accessory app's modal alert can be
            // invisible while blocking the whole app in a modal run loop —
            // no Dock icon, no status item yet, no way out but Force Quit.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Aside could not open its note store"
            // The store errors that reach here are actionable (a locked
            // keychain, above all), so show the localized text rather than
            // the raw case. Quitting is the only safe outcome: continuing
            // would mean running without the key that reads note bodies.
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        guard let environment else { return }

        let viewModel = DeckViewModel(store: environment.store)
        let controller = DeckController(viewModel: viewModel)
        controller.install()
        deckController = controller

        statusItemController = StatusItemController(viewModel: viewModel)
        settingsWindowController = SettingsWindowController()
        windowCoordinator = WindowCoordinator(store: environment.store)

        let stickyManager = StickyWindowManager(store: environment.store)
        stickyManager.install()
        stickyWindowManager = stickyManager

        let onboarding = OnboardingController(
            store: environment.store,
            onCreateNewNote: {
                Task { await viewModel.newNote() }
            }
        )
        onboarding.install()
        onboardingController = onboarding

        // Visual QA uses a disposable local database and must not inherit a
        // real sync-folder bookmark from UserDefaults.
        if ProcessInfo.processInfo.environment["ASIDE_DEBUG_DISABLE_SYNC"] != "1" {
            let coordinator = SyncFolderCoordinator(hub: environment.hub, localStore: environment.localStore)
            coordinator.install()
            syncFolderCoordinator = coordinator
        }

        HotKeyCenter.registerStandard(into: hotKeyCenter) { [weak self] id in
            self?.handleHotKey(id)
        }

        installStandardEditMenu()

        // Background one-shot: re-encrypt any rows written under a legacy
        // production key. Isolated visual-QA databases must never touch the
        // user's Keychain (their temporary signatures would trigger an ACL
        // permission prompt).
        if ProcessInfo.processInfo.environment["ASIDE_DEBUG_DATA_DIR"] == nil {
            Task.detached(priority: .utility) {
                await environment.localStore.recoverUndecryptableRows()
            }
        }

        installDebugHooks(viewModel: viewModel)
    }

    /// Screenshot/debug hooks: ASIDE_DEBUG_FAN=1 opens the deck on launch,
    /// ASIDE_DEBUG_EXPAND=1 also expands the first note, and
    /// ASIDE_DEBUG_AUTOSAVE=1 (only alongside ASIDE_DEBUG_DATA_DIR)
    /// simulates typing bursts so editor focus can be verified across
    /// autosaves.
    private func installDebugHooks(viewModel: DeckViewModel) {
        let env = ProcessInfo.processInfo.environment
        if env["ASIDE_DEBUG_SEED"] == "1" {
            Task {
                let existing = (try? await viewModel.store.fetch(filter: .all, query: "")) ?? []
                if existing.isEmpty {
                    let samples = [
                        ("Office", "Understand the API surface\nCreate tickets for the next release"),
                        ("Groceries", "- apple\n- bananas\n- dry fruits\n- peanuts"),
                        ("Hold", "Follow up on the release checklist"),
                        ("Side projects", "Sketch the next small Mac utility"),
                        ("Reading", "Designing Data-Intensive Applications"),
                        ("Weekend", "Long walk\nCoffee\nCall home"),
                        ("Ideas", "A calm place for unfinished thoughts"),
                        ("Packing", "Charger\nNotebook\nHeadphones"),
                        ("Later", "This note exercises deck overflow"),
                    ]
                    for (index, sample) in samples.enumerated() {
                        let note = Note(
                            title: sample.0,
                            body: sample.1,
                            colorIndex: index % NoteColor.allCases.count,
                            sortIndex: index
                        )
                        try? await viewModel.store.upsert(note)
                    }
                    await viewModel.reload()
                }
            }
        }
        if env["ASIDE_DEBUG_EXPAND"] == "1" || env["ASIDE_DEBUG_FAN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                viewModel.debugPinned = true
                viewModel.state = .fan
                if env["ASIDE_DEBUG_EXPAND"] == "1",
                   let first = viewModel.deckNotes.first {
                    viewModel.select(first.id)
                }
            }
        }

        // Destructive: it types over the first note's body ten times. Gated
        // on the isolated debug data directory (like the keychain-recovery
        // hook) so it can never run against a real library.
        if env["ASIDE_DEBUG_AUTOSAVE"] == "1", env["ASIDE_DEBUG_DATA_DIR"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                viewModel.debugPinned = true
                viewModel.state = .fan
                guard let first = viewModel.deckNotes.first else { return }
                viewModel.select(first.id)

                let id = first.id
                let baseBody = first.body
                NSLog("Aside AUTOSAVE harness starting on note \(id)")

                // Give SwiftUI a beat to build the editor, then focus it for
                // real: key the panel and make its text view first responder.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let panel = NSApp.windows.first(where: { $0 is DeckPanel }),
                          let textView = Self.findTextView(in: panel.contentView ?? NSView()) else {
                        NSLog("Aside AUTOSAVE harness: no editor text view found")
                        return
                    }
                    panel.makeKey()
                    panel.makeFirstResponder(textView)
                    NSLog("Aside AUTOSAVE focused %@ key=%d",
                          String(describing: type(of: panel.firstResponder)),
                          panel.isKeyWindow ? 1 : 0)

                    for tick in 0..<10 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9 * Double(tick + 1)) {
                            NSLog("Aside AUTOSAVE tick %d responder=%@ same=%d",
                                  tick,
                                  String(describing: type(of: panel.firstResponder)),
                                  panel.firstResponder === textView ? 1 : 0)
                            viewModel.saveDraft(id: id, title: first.title, body: baseBody + " tick \(tick)")
                        }
                    }
                }
            }
        }

        if env["ASIDE_DEBUG_ALL_NOTES"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NotificationCenter.default.post(name: .openAllNotesRequested, object: nil)
            }
        }
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        for subview in view.subviews {
            if let found = findTextView(in: subview) {
                return found
            }
        }
        return nil
    }

    /// Nothing in this app writes synchronously: the editors debounce 250 ms,
    /// sticky positions 150 ms, and a pending delete holds a ten-second purge.
    /// Quitting used to drop all of it — type a word, press Cmd-Q, lose the
    /// word — and leave soft-deleted rows that nothing would ever reclaim.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFlushingForTermination else { return .terminateNow }
        isFlushingForTermination = true

        // List windows own their models privately, so they flush themselves.
        NotificationCenter.default.post(name: .appWillTerminate, object: nil)

        Task { @MainActor in
            await deckController?.viewModel.flushPendingWork()
            await stickyWindowManager?.flushPendingWork()
            // A short grace for the notification-driven flushes above to land.
            try? await Task.sleep(for: .milliseconds(250))
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func handleHotKey(_ id: UInt32) {
        switch id {
        case HotKeyID.newNote:
            Task {
                guard let viewModel = deckController?.viewModel else { return }
                await viewModel.newNote()
            }
        case HotKeyID.allNotes:
            NotificationCenter.default.post(name: .openAllNotesRequested, object: nil)
        case HotKeyID.archive:
            NotificationCenter.default.post(name: .openArchiveRequested, object: nil)
        default:
            break
        }
    }

    /// Accessory apps get no default menu bar; text editing in panels and
    /// windows still needs the standard Edit commands (copy/paste/undo).
    private func installStandardEditMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Aside")
        appMenu.addItem(
            withTitle: "About Aside",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Aside",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // undo:/redo: live in the informal NSStandardKeyBindingMethods
        // protocol, so they have no Swift-visible #selector source.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSTextView.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSTextView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSTextView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSTextView.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = NSMenuItem(
            title: "Find…",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "f"
        )
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        editMenu.addItem(find)
        let findNext = NSMenuItem(
            title: "Find Next",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "g"
        )
        findNext.tag = Int(NSFindPanelAction.next.rawValue)
        editMenu.addItem(findNext)
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettingsFromMenu() {
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
    }
}
