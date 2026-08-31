import AppKit

@main
struct StickyDeckApp {
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
    let database: AppDatabase

    /// The active store; a `StoreHub` so the backing store (local SQLite ⇄
    /// sync folder) can swap under every observer without rebuilding them.
    var store: any NoteStore { hub }

    init() throws {
        database = try AppDatabase.open()
        localStore = LocalNoteStore(database: database)
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
    private var interactionBlockCount = 0
    private var blockedWindows: [(window: NSWindow, ignoredMouseEvents: Bool)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // The app no longer pins a light appearance. The split is by surface,
        // not app-wide: anything that *is* a sheet of pastel note paper — the
        // deck, the pill, pinned stickies, the onboarding splash — pins itself
        // to Aqua, because black-on-pastel has to stay black in either theme.
        // The windows the user actually lives in (All Notes, Archive,
        // Settings) follow the system, so their chrome is dark on a dark Mac.
        //
        // A visual regression run has to capture both appearances without
        // changing the machine's system setting, so it can force one here.
        // The note-paper panels pin themselves and are unaffected, which is
        // exactly the split being captured.
        if let forced = ProcessInfo.processInfo.environment["STICKYDECK_DEBUG_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: forced == "dark" ? .darkAqua : .aqua)
        }

        do {
            environment = try AppEnvironment()
        } catch {
            // Without activating first, an accessory app's modal alert can be
            // invisible while blocking the whole app in a modal run loop —
            // no Dock icon, no status item yet, no way out but Force Quit.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "StickyDeck could not open its note store"
            // Only real filesystem trouble reaches here now — an unwritable
            // container, a corrupt database. Quitting is the only safe
            // outcome: there is nowhere to put what the user types.
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        guard let environment else { return }

        // Background one-shot: rescue bodies still stored encrypted by 0.2.0
        // and earlier. Isolated visual-QA databases must never touch the
        // user's keychain (their temporary signatures would trigger an ACL
        // permission prompt).
        if ProcessInfo.processInfo.environment["STICKYDECK_DEBUG_DATA_DIR"] == nil {
            let database = environment.database
            Task.detached(priority: .utility) {
                await LegacyEncryptedBodies.migrate(in: database)
            }
        }

        // Resolve the saved backing before any surface loads notes. Otherwise
        // a sync-folder user briefly sees the independent local library, and
        // can even start an edit there, while the asynchronous swap lands.
        // Visual QA deliberately stays on its isolated local database.
        guard ProcessInfo.processInfo.environment["STICKYDECK_DEBUG_DISABLE_SYNC"] != "1" else {
            installUserInterface(using: environment)
            return
        }
        let coordinator = SyncFolderCoordinator(
            hub: environment.hub,
            localStore: environment.localStore,
            flushPendingWork: { @MainActor [weak self] in
                guard let self else { return true }
                let saved = await self.flushAllPendingWork()
                if !saved {
                    self.presentPendingWorkError(
                        message: "StickyDeck kept the current notes location. Check that it is available, then try changing the sync folder again."
                    )
                }
                return saved
            },
            setInteractionBlocked: { @MainActor [weak self] blocked in
                self?.setPersistenceInteractionBlocked(blocked)
            },
            reloadActiveLibrary: { @MainActor [weak self] in
                await self?.reloadActiveLibrary()
            }
        )
        syncFolderCoordinator = coordinator
        Task { [weak self] in
            await coordinator.install()
            self?.installUserInterface(using: environment)
        }
    }

    private func installUserInterface(using environment: AppEnvironment) {
        guard deckController == nil else { return }

        let viewModel = DeckViewModel(store: environment.store)
        let controller = DeckController(viewModel: viewModel)
        controller.install()
        deckController = controller

        statusItemController = StatusItemController(viewModel: viewModel)
        settingsWindowController = SettingsWindowController()
        windowCoordinator = WindowCoordinator(store: environment.store)

        let stickyManager = StickyWindowManager(
            store: environment.store,
            onDeleteWithUndo: { [weak viewModel] note in
                viewModel?.deletePinnedWithUndo(note)
            }
        )
        stickyManager.install()
        stickyWindowManager = stickyManager
        // Pinning hands a card straight to the desktop; the store write that
        // records it follows rather than driving it.
        viewModel.stickyPresenter = stickyManager

        let onboarding = OnboardingController(
            store: environment.store,
            onCreateNewNote: {
                Task { await viewModel.newNote() }
            }
        )
        onboardingController = onboarding
        onboarding.install()

        HotKeyCenter.registerStandard(into: hotKeyCenter) { [weak self] id in
            self?.handleHotKey(id)
        }

        installStandardEditMenu()

        installDebugHooks(viewModel: viewModel)
    }

    /// Screenshot/debug hooks: STICKYDECK_DEBUG_FAN=1 opens the deck on launch,
    /// STICKYDECK_DEBUG_EXPAND=1 also expands the first note, and
    /// STICKYDECK_DEBUG_AUTOSAVE=1 (only alongside STICKYDECK_DEBUG_DATA_DIR)
    /// simulates typing bursts so editor focus can be verified across
    /// autosaves.
    /// Whether the app opened an isolated debug library rather than the
    /// user's own. `AppDatabase.open` diverts only when the variable is
    /// present *and* non-empty, so a `!= nil` gate was satisfied by
    /// `STICKYDECK_DEBUG_DATA_DIR=""` while the harnesses below wrote into the
    /// real library. Every harness that touches notes checks this.
    private static var usesIsolatedDebugLibrary: Bool {
        !(ProcessInfo.processInfo.environment["STICKYDECK_DEBUG_DATA_DIR"] ?? "").isEmpty
    }

    private func installDebugHooks(viewModel: DeckViewModel) {
        let env = ProcessInfo.processInfo.environment
        if env["STICKYDECK_DEBUG_SEED"] == "1", Self.usesIsolatedDebugLibrary {
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
        if env["STICKYDECK_DEBUG_EXPAND"] == "1" || env["STICKYDECK_DEBUG_FAN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                viewModel.debugPinned = true
                viewModel.state = .fan
                if env["STICKYDECK_DEBUG_EXPAND"] == "1",
                   let first = viewModel.deckNotes.first {
                    viewModel.select(first.id)
                }
            }
        }

        // Destructive: it types over the first note's body ten times. Gated
        // on the isolated debug data directory (like the keychain-recovery
        // hook) so it can never run against a real library.
        if env["STICKYDECK_DEBUG_AUTOSAVE"] == "1", Self.usesIsolatedDebugLibrary {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                viewModel.debugPinned = true
                viewModel.state = .fan
                guard let first = viewModel.deckNotes.first else { return }
                viewModel.select(first.id)

                let id = first.id
                let baseBody = first.body
                NSLog("StickyDeck AUTOSAVE harness starting on note \(id)")

                // Give SwiftUI a beat to build the editor, then focus it for
                // real: key the panel and make its text view first responder.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let panel = NSApp.windows.first(where: { $0 is DeckPanel }),
                          let textView = Self.findTextView(in: panel.contentView ?? NSView()) else {
                        NSLog("StickyDeck AUTOSAVE harness: no editor text view found")
                        return
                    }
                    panel.makeKey()
                    panel.makeFirstResponder(textView)
                    NSLog("StickyDeck AUTOSAVE focused %@ key=%d",
                          String(describing: type(of: panel.firstResponder)),
                          panel.isKeyWindow ? 1 : 0)

                    for tick in 0..<10 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9 * Double(tick + 1)) {
                            NSLog("StickyDeck AUTOSAVE tick %d responder=%@ same=%d",
                                  tick,
                                  String(describing: type(of: panel.firstResponder)),
                                  panel.firstResponder === textView ? 1 : 0)
                            viewModel.saveDraft(id: id, title: first.title, body: baseBody + " tick \(tick)")
                        }
                    }
                }
            }
        }

        // STICKYDECK_DEBUG_PIN=1 expands the first note and pins it, so the
        // deck-to-desktop handoff can be captured frame by frame. That
        // transition has regressed three times in ways only a screenshot
        // burst caught, so it gets a harness like the fan and editor do.
        if env["STICKYDECK_DEBUG_PIN"] == "1", Self.usesIsolatedDebugLibrary {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                viewModel.debugPinned = true
                viewModel.state = .fan
                guard let first = viewModel.deckNotes.first else { return }
                viewModel.select(first.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    viewModel.togglePin(of: first.id)
                }
            }
        }

        if env["STICKYDECK_DEBUG_ALL_NOTES"] == "1" {
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
        guard !isFlushingForTermination else { return .terminateLater }
        isFlushingForTermination = true
        setPersistenceInteractionBlocked(true)

        // The notification covers any list model hosted outside the window
        // coordinator (including tests); owned windows are also awaited below.
        NotificationCenter.default.post(name: .appWillTerminate, object: nil)

        Task { @MainActor in
            let saved = await flushAllPendingWork()
            NSApp.reply(toApplicationShouldTerminate: saved)
            guard !saved else { return }
            isFlushingForTermination = false
            setPersistenceInteractionBlocked(false)
            presentPendingWorkError(
                message: "StickyDeck stayed open because one or more recent edits could not be saved. Check that your notes location is available, then quit again."
            )
        }
        return .terminateLater
    }

    /// Drains every UI owner. Evaluate all three independently so a failure in
    /// one editor does not prevent another window from preserving its draft.
    private func flushAllPendingWork() async -> Bool {
        while true {
            // Sticky actions can hand Delete into the deck, so let them finish
            // before the deck takes its final mutation snapshot.
            await onboardingController?.flushPendingWork()
            let stickySaved = await stickyWindowManager?.flushPendingWork() ?? true
            let deckSaved = await deckController?.viewModel.flushPendingWork() ?? true
            let windowsSaved = await windowCoordinator?.flushPendingWork() ?? true
            guard stickySaved && deckSaved && windowsSaved else { return false }

            // Any owner can receive another edit while a later owner suspends.
            // Recheck all of them synchronously on MainActor before declaring
            // the app quiescent.
            guard onboardingController?.hasPendingWork != true,
                  stickyWindowManager?.hasPendingWork != true,
                  deckController?.viewModel.hasPendingWork != true,
                  windowCoordinator?.hasPendingWork != true else { continue }
            return true
        }
    }

    private func presentPendingWorkError(message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Changes Couldn’t Be Saved"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func reloadActiveLibrary() async {
        await onboardingController?.refreshActiveLibrary()
        await deckController?.viewModel.reload()
        await stickyWindowManager?.reloadFromStore()
        await windowCoordinator?.reloadFromStore()
    }

    /// Resigning the active text editor commits its binding before the drain;
    /// ignoring mouse input and disabling the status item prevents a fresh UI
    /// action in the interval between the final flush and StoreHub's swap.
    private func setPersistenceInteractionBlocked(_ blocked: Bool) {
        if blocked {
            interactionBlockCount += 1
            guard interactionBlockCount == 1 else { return }
            blockedWindows = NSApp.windows.map { window in
                _ = window.makeFirstResponder(nil)
                let previous = window.ignoresMouseEvents
                window.ignoresMouseEvents = true
                return (window, previous)
            }
            statusItemController?.setInteractionEnabled(false)
            return
        }

        interactionBlockCount = max(interactionBlockCount - 1, 0)
        guard interactionBlockCount == 0 else { return }
        for entry in blockedWindows {
            entry.window.ignoresMouseEvents = entry.ignoredMouseEvents
        }
        blockedWindows.removeAll()
        statusItemController?.setInteractionEnabled(true)
    }

    private func handleHotKey(_ id: UInt32) {
        guard interactionBlockCount == 0 else { return }
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
        let appMenu = NSMenu(title: "StickyDeck")
        appMenu.addItem(
            withTitle: "About StickyDeck",
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
            title: "Quit StickyDeck",
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
