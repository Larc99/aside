import AppKit
import SwiftUI
import Combine
import Observation

/// Pinned notes detach from the deck into their own floating windows that
/// join every Space. Unpinning closes the window and returns the note to the
/// deck. Observes the store so external edits stay in sync.
@MainActor
final class StickyWindowManager: StickyPresenting {
    private let store: any NoteStore
    private let onDeleteWithUndo: (Note) -> Void
    private let positionStore = StickyPositionStore()
    private var windows: [UUID: StickyWindowController] = [:]
    /// Desktop presence the store has not confirmed yet.
    ///
    /// Windows go up and come down on the click, before the write recording it
    /// has landed. Until the store agrees, these entries — not the fetched
    /// rows — decide what is on screen, so a reconcile that races a write can
    /// never tear down a window the user just asked for. Each entry clears
    /// itself the moment the store does agree.
    private var unconfirmed: [UUID: Bool] = [:]
    private var observer: AnyCancellable?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    private var syncGeneration = 0

    init(store: any NoteStore, onDeleteWithUndo: @escaping (Note) -> Void) {
        self.store = store
        self.onDeleteWithUndo = onDeleteWithUndo

        // Debounced, and that is fine now: reconciliation is how the store
        // catches up with the desktop, not how the desktop is driven. Pins and
        // unpins are applied by `present`/`dismiss` in the turn they happen.
        observer = NotificationCenter.default
            .publisher(for: .noteStoreChanged)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }

        NotificationCenter.default
            .publisher(for: .appSettingsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &observers)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.clampWindowsToScreens() }
            .store(in: &observers)
    }

    private var observers: Set<AnyCancellable> = []

    var hasPendingWork: Bool {
        syncTask != nil || windows.values.contains { $0.hasPendingWork }
    }

    deinit {
        syncTask?.cancel()
    }

    func install() {
        reconcile()
    }

    func reloadFromStore() async {
        reconcile()
        while let syncTask {
            await syncTask.value
        }
    }

    // MARK: - Commands

    /// The deck is handing this note to the desktop. Synchronous by design:
    /// the window is on screen in the same turn the deck retires its card, so
    /// the two are never both visible and never both absent.
    func present(_ note: Note, takingPlaceOf frame: CGRect?) {
        unconfirmed[note.id] = true
        if let existing = windows[note.id] {
            existing.update(note)
            return
        }
        let controller = makeController(for: note)
        controller.present(at: frame)
        windows[note.id] = controller
    }

    func dismiss(_ noteID: UUID) {
        unconfirmed[noteID] = false
        guard let controller = windows.removeValue(forKey: noteID) else { return }
        controller.dismissWindow()
    }

    /// Unpin from the sticky's own header: the window goes now, the write
    /// follows. `note` is the copy the sticky's editor holds, so text typed
    /// into it is carried across rather than rolled back.
    func unpin(_ note: Note) async {
        dismiss(note.id)
        await applyStateChange(from: note) { $0.pinned = false }
    }

    // MARK: - Reconciliation

    /// Brings the desktop in line with the store, for everything the commands
    /// above did not cause: launch, a sync-folder change, an edit from All
    /// Notes, an undone delete.
    private func reconcile() {
        syncGeneration &+= 1
        let generation = syncGeneration
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.syncGeneration {
                    self.syncTask = nil
                }
            }
            guard let all = try? await self.store.fetch(filter: .active, query: "") else { return }
            guard !Task.isCancelled, generation == self.syncGeneration else { return }

            let notesByID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            let storePinned = Set(all.filter(\.pinned).map(\.id))

            // Unconfirmed intent outranks the store, and retires as soon as the
            // store catches up with it.
            var desired = storePinned
            for (id, wanted) in unconfirmed {
                if storePinned.contains(id) == wanted {
                    unconfirmed[id] = nil
                } else if wanted {
                    desired.insert(id)
                } else {
                    desired.remove(id)
                }
            }

            for (id, controller) in windows where !desired.contains(id) {
                controller.dismissWindow()
                windows.removeValue(forKey: id)
            }
            for id in desired where windows[id] == nil {
                guard let note = notesByID[id] else { continue }
                let controller = makeController(for: note)
                controller.present(at: nil)
                windows[id] = controller
            }
            for id in desired {
                if let note = notesByID[id] { windows[id]?.update(note) }
            }
        }
    }

    /// Applies a state change onto the note as the store currently holds it,
    /// carrying across whatever the sticky's editor was showing.
    ///
    /// Unpin and archive are whole-row writes — they have to be, since they own
    /// state fields — but writing the editor's *snapshot* would resurrect a
    /// note archived or deleted elsewhere while the sticky sat open.
    private func applyStateChange(
        from draft: Note,
        _ change: @Sendable (inout Note) -> Void
    ) async {
        do {
            try await NoteContentWriter.applyStateChange(
                to: draft.id,
                from: draft,
                in: store,
                change
            )
        } catch {
            NSLog("StickyDeck could not update the pinned note: %@", error.localizedDescription)
        }
    }

    private func makeController(for note: Note) -> StickyWindowController {
        StickyWindowController(
            note: note,
            onSave: { [store] updated in
                // Content only. The editor's 250 ms debounce can outlive an
                // archive or delete made elsewhere, and a whole-row upsert of
                // that snapshot would carry `archivedAt: nil, pinned: true`
                // back in and resurrect the note as a sticky.
                try await NoteContentWriter.saveContent(updated, to: store)
            },
            onUnpin: { [weak self] current in
                await self?.unpin(current)
            },
            onArchive: { [weak self] current in
                self?.dismiss(current.id)
                await self?.applyStateChange(from: current) {
                    $0.pinned = false
                    $0.archivedAt = Date()
                }
            },
            onDelete: { [weak self] current in
                self?.dismiss(current.id)
                self?.onDeleteWithUndo(current)
            },
            positionStore: positionStore
        )
    }

    /// Commits every sticky's debounced draft and window position. The quit
    /// path has no later opportunity: `onDisappear` does not run at terminate.
    @discardableResult
    func flushPendingWork() async -> Bool {
        if let syncTask { await syncTask.value }
        var succeeded = true
        for controller in windows.values {
            if !(await controller.flushPendingWork()) {
                succeeded = false
            }
        }
        return succeeded
    }

    private func applyFullscreenBehavior() {
        windows.values.forEach { $0.applyFullscreenBehavior() }
    }

    private func applySettings() {
        applyFullscreenBehavior()
    }

    private func clampWindowsToScreens() {
        windows.values.forEach { $0.clampToVisibleScreens() }
    }
}

/// Controller-owned sticky editor state. SwiftUI view-local `@State` cannot be
/// reached from the application termination path, so the old quit handler
/// saved only window positions and silently abandoned text still inside the
/// 250 ms debounce.
@MainActor
@Observable
final class StickyNoteDraft {
    private(set) var note: Note

    private struct PendingSave {
        let generation: UUID
        let note: Note
    }

    private let onSave: (Note) async throws -> Void
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    private var pendingSave: PendingSave?
    @ObservationIgnored private var writeTask: Task<Bool, Never>?
    private var writeGeneration: UUID?
    @ObservationIgnored private var actionTask: Task<Bool, Never>?
    private var actionGeneration: UUID?

    init(note: Note, onSave: @escaping (Note) async throws -> Void) {
        self.note = note
        self.onSave = onSave
    }

    deinit {
        debounceTask?.cancel()
    }

    var hasPendingWork: Bool {
        pendingSave != nil || debounceTask != nil || writeTask != nil || actionTask != nil
    }

    func updateTitle(_ title: String) {
        note.title = title
        scheduleSave()
    }

    func updateBody(_ body: String) {
        note.body = body
        // An actual edit owns the body from this point on, including when the
        // user intentionally deletes it back to empty.
        note.bodyNeedsMigration = false
        scheduleSave()
    }

    func updateColor(_ colorIndex: Int) {
        note.colorIndex = colorIndex
        scheduleSave()
    }

    func adopt(_ note: Note) {
        self.note = note
    }

    /// Debounced like the deck editor — one store write per typing pause.
    private func scheduleSave() {
        debounceTask?.cancel()
        var updated = note
        updated.updatedAt = Date()
        pendingSave = PendingSave(generation: UUID(), note: updated)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.enqueuePendingSave()
        }
    }

    /// Serializes writes. A cancelled debounce may already have crossed into
    /// store I/O; chaining keeps an older snapshot from landing after a newer
    /// one and rolling the editor back.
    private func enqueuePendingSave() {
        guard let pending = pendingSave else { return }
        pendingSave = nil
        let prior = writeTask
        let generation = pending.generation
        writeGeneration = generation
        writeTask = Task { [weak self] in
            _ = await prior?.value
            guard let self else { return true }
            do {
                try await self.onSave(pending.note)
                if self.writeGeneration == generation {
                    self.writeTask = nil
                    self.writeGeneration = nil
                }
                return true
            } catch {
                NSLog("StickyDeck could not save the pinned note: %@", error.localizedDescription)
                // Keep the newest failed snapshot available for another state
                // action or quit attempt. An older failure must not replace a
                // later draft that is already queued behind it.
                if self.writeGeneration == generation {
                    if self.pendingSave == nil {
                        self.pendingSave = pending
                    }
                    self.writeTask = nil
                    self.writeGeneration = nil
                }
                return false
            }
        }
    }

    /// Commits every draft that exists or arrives while store I/O is awaited.
    /// State actions and application termination call this before proceeding.
    @discardableResult
    func flushPendingSave() async -> Bool {
        while true {
            debounceTask?.cancel()
            debounceTask = nil
            if pendingSave != nil { enqueuePendingSave() }

            guard let pendingWrite = writeTask,
                  let generation = writeGeneration else {
                return pendingSave == nil
            }
            let succeeded = await pendingWrite.value
            if writeGeneration == generation {
                writeTask = nil
                writeGeneration = nil
            }
            guard succeeded else { return false }
            guard pendingSave != nil || writeTask != nil else { return true }
        }
    }

    /// Owns the complete save-then-state-action chain. Keeping this Task on the
    /// controller model lets quit and a sync-library switch wait for an Unpin,
    /// Archive or Delete click that is still suspended in store I/O.
    func performAfterFlush(
        _ action: @escaping @MainActor (Note) async -> Void
    ) {
        let prior = actionTask
        let generation = UUID()
        actionGeneration = generation
        actionTask = Task { [weak self] in
            _ = await prior?.value
            guard let self else { return true }
            guard await self.flushPendingSave() else {
                if self.actionGeneration == generation {
                    self.actionTask = nil
                    self.actionGeneration = nil
                }
                return false
            }
            var current = self.note
            current.updatedAt = Date()
            await action(current)
            if self.actionGeneration == generation {
                self.actionTask = nil
                self.actionGeneration = nil
            }
            return true
        }
    }

    @discardableResult
    func flushPendingWork() async -> Bool {
        while let pendingAction = actionTask,
              let generation = actionGeneration {
            let succeeded = await pendingAction.value
            if actionGeneration == generation {
                actionTask = nil
                actionGeneration = nil
            }
            guard succeeded else { return false }
        }
        return await flushPendingSave()
    }
}

@MainActor
final class StickyWindowController: NSWindowController {
    private let onUnpin: @MainActor (Note) async -> Void
    private let onArchive: @MainActor (Note) async -> Void
    private let onDelete: @MainActor (Note) async -> Void
    private let panel: StickyPanel
    private let positionStore: StickyPositionStore
    private let noteID: UUID
    private let draftModel: StickyNoteDraft
    private var currentNote: Note?
    private var needsViewRefresh = false
    private var moveObserver: AnyCancellable?
    private var resignKeyObserver: AnyCancellable?
    @ObservationIgnored private var positionSaveTask: Task<Void, Never>?

    var hasPendingWork: Bool {
        positionSaveTask != nil || draftModel.hasPendingWork
    }

    init(
        note: Note,
        onSave: @escaping (Note) async throws -> Void,
        onUnpin: @escaping @MainActor (Note) async -> Void,
        onArchive: @escaping @MainActor (Note) async -> Void,
        onDelete: @escaping @MainActor (Note) async -> Void,
        positionStore: StickyPositionStore = StickyPositionStore()
    ) {
        self.onUnpin = onUnpin
        self.onArchive = onArchive
        self.onDelete = onDelete
        self.positionStore = positionStore
        noteID = note.id
        panel = StickyPanel()
        draftModel = StickyNoteDraft(note: note, onSave: onSave)
        currentNote = note

        let root = StickyNoteView(
            draft: draftModel,
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

    func present(at handoffFrame: CGRect?) {
        // Pinning the live editor keeps the same surface in the same place
        // while the deck folds away. On relaunch, its last desktop position
        // wins; a brand-new sticky falls back to the active screen's deck.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let handoffFrame {
            window?.setFrame(handoffFrame, display: false)
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
        // NSHostingView's first render is not documented to happen before its
        // window is ordered in (docs/PIN_HANDOFF_RESEARCH.md §5), and one frame
        // of empty window would undo the whole point of handing the card over.
        // Lay out and draw the content while the window is still off screen.
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
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

        // Only adopting the store copy waits. Updating bindings under the
        // user's cursor could replace local selection or in-progress typing;
        // deferring to resign-key keeps the window stable while it is edited.
        guard !panel.isKeyWindow else {
            needsViewRefresh = true
            return
        }
        // A local draft wins until its serial save reaches the store. Its own
        // store-change notification will deliver the authoritative copy next.
        guard !draftModel.hasPendingWork else {
            needsViewRefresh = true
            return
        }
        rebuildContentView(with: note)
    }

    private func rebuildIfPending() {
        guard needsViewRefresh, let currentNote else { return }
        needsViewRefresh = false
        guard !draftModel.hasPendingWork else { return }
        rebuildContentView(with: currentNote)
    }

    private func rebuildContentView(with note: Note) {
        needsViewRefresh = false
        draftModel.adopt(note)
    }

    func applyFullscreenBehavior() {
        panel.applyFullscreenBehavior()
    }

    @discardableResult
    func flushPendingWork() async -> Bool {
        positionSaveTask?.cancel()
        positionSaveTask = nil
        savePosition()
        return await draftModel.flushPendingWork()
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
        // `.none`, not `.utilityWindow`: this window is not appearing, it is
        // taking over from a card that is already on screen at its exact frame,
        // and the same in reverse when it is dismissed. Measured `alphaValue`
        // showed `.utilityWindow` was not fading it in practice, but `.none` is
        // the documented way to say so rather than relying on that.
        animationBehavior = .none
        // This panel is a sheet of pastel note paper: its fill is a fixed
        // light colour and its text is black, so it stays in the light
        // appearance whatever the system is set to.
        appearance = NSAppearance(named: .aqua)
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
    let draft: StickyNoteDraft
    let onUnpin: @MainActor (Note) async -> Void
    let onArchive: @MainActor (Note) async -> Void
    let onDelete: @MainActor (Note) async -> Void

    var body: some View {
        NoteEditorCard(
            title: Binding(
                get: { draft.note.title },
                set: { draft.updateTitle($0) }
            ),
            noteBody: Binding(
                get: { draft.note.body },
                set: { draft.updateBody($0) }
            ),
            colorIndex: draft.note.colorIndex,
            updatedAt: draft.note.updatedAt,
            isPinned: true,
            onClose: unpin,
            onTogglePin: unpin,
            onSetColor: draft.updateColor,
            onDelete: { performAfterFlush(onDelete) },
            onArchive: { performAfterFlush(onArchive) },
            autoFocus: false,
            closesOnEscape: false
        )
        .onDisappear {
            Task { _ = await draft.flushPendingWork() }
        }
    }

    private func performAfterFlush(
        _ action: @escaping @MainActor (Note) async -> Void
    ) {
        draft.performAfterFlush(action)
    }

    private func unpin() {
        performAfterFlush(onUnpin)
    }
}
