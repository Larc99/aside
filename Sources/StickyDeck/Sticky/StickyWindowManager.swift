import AppKit
import SwiftUI
import Combine

/// Pinned notes detach from the deck into their own floating windows that
/// join every Space. Unpinning closes the window and returns the note to the
/// deck. Observes the store so external edits stay in sync.
@MainActor
final class StickyWindowManager {
    private let store: any NoteStore
    private let positionStore = StickyPositionStore()
    private var windows: [UUID: StickyWindowController] = [:]
    private var observer: AnyCancellable?

    init(store: any NoteStore) {
        self.store = store

        observer = NotificationCenter.default
            .publisher(for: .noteStoreChanged)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }

        NotificationCenter.default
            .publisher(for: .appSettingsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyFullscreenBehavior() }
            .store(in: &observers)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.clampWindowsToScreens() }
            .store(in: &observers)
    }

    private var observers: Set<AnyCancellable> = []

    func install() {
        sync()
    }

    func togglePin(_ note: Note) {
        Task {
            await applyStateChange(from: note) { $0.pinned.toggle() }
            sync()
        }
    }

    /// Applies a state change onto the note as the store currently holds it,
    /// carrying across whatever the sticky's editor was showing.
    ///
    /// Unpin and archive are still whole-row writes — they have to be, since
    /// they own state fields — but writing the editor's *snapshot* would
    /// resurrect a note that was archived or deleted elsewhere while the
    /// sticky sat open, exactly as the debounced content save used to.
    private func applyStateChange(from draft: Note, _ change: (inout Note) -> Void) async {
        guard let live = try? await store.fetch(filter: .all, query: ""),
              var note = live.first(where: { $0.id == draft.id }) else { return }

        note.title = draft.title
        if !note.bodyUnavailable || !draft.body.isEmpty {
            note.body = draft.body
            note.bodyUnavailable = false
        }
        note.colorIndex = draft.colorIndex
        note.tag = draft.tag
        change(&note)
        note.updatedAt = Date()
        do {
            try await store.upsert(note)
        } catch {
            NSLog("StickyDeck could not update the pinned note: %@", error.localizedDescription)
        }
    }

    private func sync() {
        Task {
            guard let all = try? await store.fetch(filter: .active, query: "") else { return }
            let pinned = all.filter(\.pinned)
            let pinnedIDs = Set(pinned.map(\.id))

            for (id, controller) in windows where !pinnedIDs.contains(id) {
                controller.dismissWindow()
                windows.removeValue(forKey: id)
            }
            for note in pinned where windows[note.id] == nil {
                let controller = StickyWindowController(
                    note: note,
                    onSave: { [weak self] updated in
                        Task {
                            guard let store = self?.store else { return }
                            // Content only. The editor's 250 ms debounce can
                            // outlive an archive or delete made elsewhere, and
                            // a whole-row upsert of that snapshot would carry
                            // `archivedAt: nil, pinned: true` back in and
                            // resurrect the note as a sticky.
                            _ = try? await NoteContentWriter.saveContent(updated, to: store)
                        }
                    },
                    onUnpin: { [weak self] current in
                        // Uses the note as the view currently holds it, not a
                        // snapshot from window creation — otherwise edits made
                        // in the sticky would be rolled back on unpin.
                        self?.togglePin(current)
                    },
                    onArchive: { [weak self] current in
                        Task {
                            await self?.applyStateChange(from: current) {
                                $0.pinned = false
                                $0.archivedAt = Date()
                            }
                        }
                    },
                    onDelete: { [weak self] current in
                        Task { try? await self?.store.softDelete(id: current.id) }
                    },
                    positionStore: positionStore
                )
                controller.present()
                windows[note.id] = controller
            }
            for note in pinned {
                windows[note.id]?.update(note)
            }
        }
    }

    /// Commits every sticky's debounced draft and window position. The quit
    /// path has no later opportunity: `onDisappear` does not run at terminate.
    func flushPendingWork() async {
        for controller in windows.values {
            controller.flushPendingWork()
        }
        // Let the writes the controllers just issued reach the store.
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func applyFullscreenBehavior() {
        windows.values.forEach { $0.applyFullscreenBehavior() }
    }

    private func clampWindowsToScreens() {
        windows.values.forEach { $0.clampToVisibleScreens() }
    }
}

@MainActor
final class StickyWindowController: NSWindowController {
    private let onSave: (Note) -> Void
    private let onUnpin: (Note) -> Void
    private let onArchive: (Note) -> Void
    private let onDelete: (Note) -> Void
    private let panel: StickyPanel
    private let positionStore: StickyPositionStore
    private let noteID: UUID
    private var currentNote: Note?
    private var needsViewRefresh = false
    private var moveObserver: AnyCancellable?
    private var resignKeyObserver: AnyCancellable?
    private var positionSaveTask: Task<Void, Never>?

    init(
        note: Note,
        onSave: @escaping (Note) -> Void,
        onUnpin: @escaping (Note) -> Void,
        onArchive: @escaping (Note) -> Void,
        onDelete: @escaping (Note) -> Void,
        positionStore: StickyPositionStore = StickyPositionStore()
    ) {
        self.onSave = onSave
        self.onUnpin = onUnpin
        self.onArchive = onArchive
        self.onDelete = onDelete
        self.positionStore = positionStore
        noteID = note.id
        panel = StickyPanel()
        currentNote = note

        let root = StickyNoteView(
            note: note,
            onSave: onSave,
            onUnpin: onUnpin,
            onArchive: onArchive,
            onDelete: onDelete
        )
        panel.contentView = FirstMouseHostingView(rootView: root)

        super.init(window: panel)

        moveObserver = NotificationCenter.default
            .publisher(for: NSWindow.didMoveNotification, object: panel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedulePositionSave() }

        resignKeyObserver = NotificationCenter.default
            .publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildIfPending() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        positionSaveTask?.cancel()
    }

    func present() {
        // Pinning the live editor keeps the same surface in the same place
        // while the deck folds away. On relaunch, its last desktop position
        // wins; a brand-new sticky falls back to the active screen's deck.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let hint = PinnedNotePlacementHints.take(for: noteID) {
            window?.setFrame(hint, display: false)
        } else if let origin = positionStore.origin(for: noteID) {
            window?.setFrameOrigin(origin)
        } else if let screen {
            let deckFrame = DeckMetrics.deckPanelFrame(screen: screen)
            let cardRect = DeckMetrics.cardContentRect(
                panelWidth: deckFrame.width,
                panelHeight: deckFrame.height,
                noteCount: 1,
                verticalOffset: CGFloat(AppSettings.noteCardOffsetY)
            )
            window?.setFrameOrigin(CGPoint(
                x: deckFrame.minX + cardRect.minX,
                y: deckFrame.minY + cardRect.minY
            ))
        } else {
            window?.center()
        }
        clampToVisibleScreens()
        window?.orderFrontRegardless()
    }

    func dismissWindow() {
        savePosition()
        window?.orderOut(nil)
    }

    func clampToVisibleScreens() {
        guard let window else { return }
        let clamped = StickyPlacement.clampedFrame(
            window.frame,
            within: NSScreen.screens.map(\.visibleFrame)
        )
        if clamped.origin != window.frame.origin {
            window.setFrame(clamped, display: true, animate: false)
        }
    }

    func update(_ note: Note) {
        let unchanged = currentNote.map {
            $0.title == note.title
                && $0.body == note.body
                && $0.colorIndex == note.colorIndex
                && $0.tag == note.tag
        } ?? false

        // Always adopt the store's copy, key window or not. Returning before
        // this assignment staleness-locked the window: while the panel stayed
        // key it never learned the store had changed, so it kept showing (and
        // saving) a copy that an edit in All Notes — or one arriving from
        // another Mac — had already superseded.
        currentNote = note
        guard !unchanged else { return }

        // Only the hosting-view rebuild waits — swapping the view out from
        // under the user's cursor is what the key-window guard protects.
        // Deferring it to resign-key keeps the window from staying stale.
        guard !panel.isKeyWindow else {
            needsViewRefresh = true
            return
        }
        rebuildContentView(with: note)
    }

    private func rebuildIfPending() {
        guard needsViewRefresh, let currentNote else { return }
        needsViewRefresh = false
        rebuildContentView(with: currentNote)
    }

    private func rebuildContentView(with note: Note) {
        needsViewRefresh = false
        panel.contentView = FirstMouseHostingView(
            rootView: StickyNoteView(
                note: note,
                onSave: onSave,
                onUnpin: onUnpin,
                onArchive: onArchive,
                onDelete: onDelete
            )
        )
    }

    func applyFullscreenBehavior() {
        panel.applyFullscreenBehavior()
    }

    func flushPendingWork() {
        positionSaveTask?.cancel()
        positionSaveTask = nil
        savePosition()
    }

    private func schedulePositionSave() {
        positionSaveTask?.cancel()
        positionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.savePosition()
        }
    }

    private func savePosition() {
        guard let origin = window?.frame.origin else { return }
        positionStore.save(origin: origin, for: noteID)
    }
}

/// Non-activating floating panel for a pinned note.
class StickyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: DeckMetrics.noteWidth,
                height: DeckMetrics.expandedCardHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Movement is owned by NativeWindowDragHandle in the editor header.
        // Keeping the whole paper draggable interferes with text selection
        // and scrolling, which makes the panel feel unlike a native editor.
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        hasShadow = false
        acceptsMouseMovedEvents = true
        animationBehavior = .utilityWindow
        applyFullscreenBehavior()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        StickyPlacement.clampedFrame(
            frameRect,
            within: (screen.map { [$0.visibleFrame] } ?? NSScreen.screens.map(\.visibleFrame))
        )
    }

    func applyFullscreenBehavior() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        if AppSettings.showOverFullScreen {
            collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }
}

/// The content of a pinned sticky window: color-tinted editor with a pin and
/// archive affordance in the title-bar area.
struct StickyNoteView: View {
    @State var note: Note
    let onSave: (Note) -> Void
    let onUnpin: (Note) -> Void
    let onArchive: (Note) -> Void
    let onDelete: (Note) -> Void

    @State private var saveTask: Task<Void, Never>?
    @State private var pendingSave: Note?

    var body: some View {
        NoteEditorCard(
            title: Binding(
                get: { note.title },
                set: { note.title = $0; save() }
            ),
            noteBody: Binding(
                get: { note.body },
                set: { note.body = $0; save() }
            ),
            colorIndex: note.colorIndex,
            updatedAt: note.updatedAt,
            isPinned: true,
            onClose: unpin,
            onTogglePin: unpin,
            onSetColor: { colorIndex in
                note.colorIndex = colorIndex
                save()
            },
            onDelete: {
                cancelPendingSave()
                onDelete(note)
            },
            onArchive: {
                cancelPendingSave()
                onArchive(note)
            },
            autoFocus: false,
            closesOnEscape: false
        )
        .onDisappear(perform: flushSave)
    }

    /// Debounced like the deck editor — one store write per pause, not per
    /// keystroke (each write would otherwise bounce the editor via sync()).
    private func save() {
        saveTask?.cancel()
        var updated = note
        updated.updatedAt = Date()
        pendingSave = updated
        let onSave = onSave
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            onSave(updated)
            pendingSave = nil
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        guard let pendingSave else { return }
        self.pendingSave = nil
        onSave(pendingSave)
    }

    private func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        pendingSave = nil
    }

    private func unpin() {
        // Unpin persists the current in-memory value itself. Clear the
        // pending pinned save so disappearance cannot race and pin it again.
        saveTask?.cancel()
        saveTask = nil
        pendingSave = nil
        var current = note
        current.updatedAt = Date()
        onUnpin(current)
    }
}
