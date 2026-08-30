import AppKit
import Foundation
import SwiftUI

@MainActor
final class DeckViewModel: ObservableObject {
    enum State: Equatable {
        case pill
        case fan
        case expanded(UUID)
    }

    enum NotePresentationPhase: Equatable {
        case idle
        case moving
        case editing
    }

    struct PendingDelete: Identifiable, Equatable {
        let id = UUID()
        let note: Note
        let expiresAt: Date
    }

    @Published private(set) var deckNotes: [Note] = []
    @Published var state: State = .pill
    @Published private(set) var notePresentationPhase: NotePresentationPhase = .idle
    @Published private(set) var presentedNoteID: UUID?
    @Published var pendingDelete: PendingDelete?
    @Published var peekedNoteID: UUID?

    /// Mirrors `AppSettings.deckEdge` as observable state. The views used to
    /// read the static directly, so switching edge with the deck open moved
    /// the panel without ever invalidating the SwiftUI body — leaving the fan
    /// drawn against the old edge while the hit rects had already moved.
    @Published private(set) var edge: AppSettings.Edge = AppSettings.deckEdge

    /// How many tabs the fan is currently rendering. On the last page of an
    /// overflowing deck this is smaller than the layout's page size, and the
    /// hit rect has to follow it or it swallows clicks in the blank strip.
    @Published var drawnTabCount: Int = 0

    /// Height of the fixed-size deck panel on the current screen. The fan
    /// fits its layout inside it (D26) — fewer/tighter tabs on short
    /// displays. DeckController keeps it in sync with the panel frame.
    @Published private(set) var panelHeight: CGFloat = (NSScreen.main?.visibleFrame.height ?? 900) * 0.8
    @Published var cardOffsetY: CGFloat = CGFloat(AppSettings.noteCardOffsetY)

    /// Debug/screenshot mode: hover-collapse is suspended.
    var debugPinned = false

    /// Whether the open/close morph is skipped. Defaults to the system
    /// setting, but stays injectable because it is read at the moment of
    /// selection: CI runners report Reduce Motion as *on*, which sent the
    /// deck tests down the no-animation path and failed them for a reason
    /// that had nothing to do with the code under test.
    var reduceMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Installed by DeckController: returns false when the pointer is still
    /// inside the deck, so a stale mouse-exited never collapses it.
    var shouldCollapseCheck: (() -> Bool)?

    /// Closing is rendered by moving the containing NSPanel. Keeping this
    /// callback outside published state means a close request cannot perturb
    /// SwiftUI's otherwise-idle hover tree.
    var collapseRequest: (() -> Void)?
    var collapseCancellationRequest: (() -> Void)?

    let store: any NoteStore

    private var saveTasks: [UUID: Task<Void, Never>] = [:]
    private var collapseTask: Task<Void, Never>?
    private var notePresentationTask: Task<Void, Never>?
    private var peekDismissTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var settingsObservationTask: Task<Void, Never>?
    private var lastOwnSaveAt = Date.distantPast
    private var suppressNextStoreEcho = false
    private var cardDragOrigin: CGFloat?
    private var pausedDeleteRemaining: TimeInterval?
    /// The most recent debounced draft, kept so the quit path can write it
    /// even though its timer will never fire.
    private var pendingEditorDraft: (id: UUID, title: String, body: String, tag: String?)?
    private var hoveredNoteIDs: [UUID] = []

    /// Installed by DeckController so pinning can hand the exact live editor
    /// frame to the sticky-window module without exposing panel geometry to
    /// the view model.
    var pinTransitionFrameProvider: (() -> CGRect?)?

    init(store: any NoteStore) {
        self.store = store
        observationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .noteStoreChanged).map({ _ in () }) {
                guard let self else { continue }
                // Our own saves echo back through this notification; persist()
                // already updated deckNotes in place, and a full reload here
                // would churn the editor (and its focus) after every pause.
                //
                // The suppression is one-shot (not a time window): a time
                // window would swallow genuinely external changes that land
                // within the window (e.g. a delete from another window stays
                // on the deck until the 10 s purge), and a short window
                // misses the echo when store I/O is slow. The 2 s deadline
                // bounds the damage if an echo never arrives.
                if self.suppressNextStoreEcho,
                   Date().timeIntervalSince(self.lastOwnSaveAt) < 2.0 {
                    self.suppressNextStoreEcho = false
                    continue
                }
                await self.reload()
            }
        }
        settingsObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .appSettingsChanged).map({ _ in () }) {
                guard let self else { continue }
                if self.edge != AppSettings.deckEdge {
                    self.edge = AppSettings.deckEdge
                }
            }
        }
        Task { [weak self] in
            await self?.reload()
        }
    }

    deinit {
        observationTask?.cancel()
        settingsObservationTask?.cancel()
        collapseTask?.cancel()
        notePresentationTask?.cancel()
        peekDismissTask?.cancel()
        deleteTask?.cancel()
        saveTasks.values.forEach { $0.cancel() }
    }

    // MARK: - Data

    func reload() async {
        guard let all = try? await store.fetch(filter: .active, query: "") else { return }
        deckNotes = all.filter { !$0.pinned }.sorted { $0.sortIndex < $1.sortIndex }
        if presentedNoteID == nil
            || !deckNotes.contains(where: { $0.id == presentedNoteID }) {
            // Keep one real editor subtree mounted in the hidden deck panel.
            // Its first visible open therefore requires only a layer move.
            presentedNoteID = deckNotes.first?.id
        }
        if let peekedNoteID, !deckNotes.contains(where: { $0.id == peekedNoteID }) {
            self.peekedNoteID = nil
        }
        // A store swap or external delete can remove the open note; keeping
        // the orphaned expanded state would render a dead card and an
        // over-wide hit rect.
        if case .expanded(let id) = state, !deckNotes.contains(where: { $0.id == id }) {
            notePresentationTask?.cancel()
            notePresentationPhase = .idle
            state = .fan
        }
    }

    // MARK: - Hover / state transitions

    func deckHoverChanged(_ hovering: Bool) {
        if hovering {
            collapseTask?.cancel()
            collapseTask = nil
            collapseCancellationRequest?()
        } else if state == .fan && !debugPinned {
            collapseTask?.cancel()
            collapseTask = Task { [weak self] in
                try? await Task.sleep(
                    for: .milliseconds(DeckInteraction.collapseGraceMilliseconds)
                )
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let check = self.shouldCollapseCheck, !check() { return }
                if let collapseRequest = self.collapseRequest {
                    collapseRequest()
                } else {
                    // Tests and standalone model clients do not install a
                    // panel controller; retain the model's safe fallback.
                    self.clearPeek()
                    self.state = .pill
                }
            }
        }
    }

    func completePanelRetraction() {
        guard state == .fan else { return }
        clearPeek()
        state = .pill
    }

    func select(_ id: UUID) {
        guard deckNotes.contains(where: { $0.id == id }) else { return }
        clearPeek()
        notePresentationTask?.cancel()
        presentedNoteID = id
        if reduceMotion() {
            notePresentationPhase = .editing
            state = .expanded(id)
            return
        }
        notePresentationPhase = .moving
        state = .expanded(id)
        notePresentationTask = Task { [weak self] in
            try? await Task.sleep(
                for: .milliseconds(DeckInteraction.noteMorphMilliseconds)
            )
            guard !Task.isCancelled,
                  let self,
                  self.state == .expanded(id) else { return }
            self.notePresentationPhase = .editing
        }
    }

    func setPeek(_ id: UUID, hovering: Bool) {
        guard state == .fan else {
            clearPeek()
            return
        }
        if hovering {
            hoveredNoteIDs.removeAll { $0 == id }
            hoveredNoteIDs.append(id)
            peekDismissTask?.cancel()
            peekDismissTask = nil
            peekedNoteID = id
        } else {
            hoveredNoteIDs.removeAll { $0 == id }
            guard peekedNoteID == id else { return }

            // The expanded preview can briefly invalidate its own tracking
            // area while SwiftUI reconciles overlapping shingles. A short
            // ownership-aware grace period absorbs that native tracking gap.
            peekDismissTask?.cancel()
            peekDismissTask = Task { [weak self] in
                try? await Task.sleep(
                    for: .milliseconds(DeckInteraction.peekExitGraceMilliseconds)
                )
                guard !Task.isCancelled, let self, self.state == .fan else { return }
                self.peekedNoteID = self.hoveredNoteIDs.last
            }
        }
    }

    func clearPeek() {
        peekDismissTask?.cancel()
        peekDismissTask = nil
        hoveredNoteIDs.removeAll()
        peekedNoteID = nil
    }

    func closeNote() {
        guard case .expanded = state else { return }
        notePresentationTask?.cancel()
        notePresentationPhase = .idle
        state = .fan
        // Hover exits that arrive while expanded are dropped (that path is
        // guarded on `.fan`), and AppKit will not send another one without a
        // fresh enter. Without this re-check the fan sits on the screen edge
        // forever whenever the note was closed from the keyboard or a button
        // with the pointer somewhere else.
        // A pending delete puts its Undo toast inside this panel; collapsing
        // now would take the user's only undo affordance with it.
        if pendingDelete == nil, let check = shouldCollapseCheck, check() {
            deckHoverChanged(false)
        }
    }

    func updatePanelHeight(_ height: CGFloat) {
        panelHeight = height
        cardOffsetY = DeckMetrics.clampedCardOffset(cardOffsetY, panelHeight: height)
    }

    func dragCard(translationY: CGFloat) {
        if cardDragOrigin == nil { cardDragOrigin = cardOffsetY }
        cardOffsetY = DeckMetrics.clampedCardOffset(
            (cardDragOrigin ?? 0) + translationY,
            panelHeight: panelHeight
        )
    }

    func finishDraggingCard() {
        cardDragOrigin = nil
        AppSettings.noteCardOffsetY = Double(cardOffsetY)
    }

    /// Writes out everything still in flight and commits any pending delete.
    /// Called on the quit path, where no debounce will ever fire again.
    func flushPendingWork() async {
        for (_, task) in saveTasks { task.cancel() }
        saveTasks.removeAll()
        if let draft = pendingEditorDraft {
            await persist(id: draft.id, title: draft.title, body: draft.body, tag: draft.tag)
        }
        pendingEditorDraft = nil
        deleteTask?.cancel()
        deleteTask = nil
        if let pending = pendingDelete {
            pendingDelete = nil
            pausedDeleteRemaining = nil
            try? await store.purge(id: pending.note.id)
        }
    }

    // MARK: - Note actions

    func newNote() async {
        let minSort = deckNotes.map(\.sortIndex).min() ?? 1
        let note = Note(sortIndex: minSort - 1)
        try? await store.upsert(note)
        await reload()
        clearPeek()
        select(note.id)
    }

    func duplicate(_ id: UUID) {
        guard let source = deckNotes.first(where: { $0.id == id }) else { return }
        var copy = source
        copy.id = UUID()
        copy.pinned = false
        copy.sortIndex = source.sortIndex + 1
        copy.createdAt = Date()
        copy.updatedAt = copy.createdAt
        copy.archivedAt = nil
        copy.deletedAt = nil
        Task {
            try? await store.upsert(copy)
            await reload()
        }
    }

    func saveDraft(id: UUID, title: String, body: String, tag: String? = nil) {
        pendingEditorDraft = (id: id, title: title, body: body, tag: tag)
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.persist(id: id, title: title, body: body, tag: tag)
            self.pendingEditorDraft = nil
        }
    }

    /// Writes any pending draft for `id` immediately. Pin, archive and delete
    /// call this first: they upsert the note as `deckNotes` holds it and then
    /// reload it out of that array, so the debounced save that lands afterwards
    /// finds nothing and silently drops the last few hundred milliseconds of
    /// typing.
    func flushDraft(id: UUID, title: String, body: String, tag: String? = nil) async {
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        await persist(id: id, title: title, body: body, tag: tag)
    }

    private func persist(id: UUID, title: String, body: String, tag: String? = nil) async {
        guard let current = deckNotes.first(where: { $0.id == id }) else { return }
        var draft = current
        draft.title = title
        draft.body = body
        if let tag {
            draft.tag = tag
        }
        guard draft.title != current.title
                || draft.body != current.body
                || draft.tag != current.tag else { return }

        lastOwnSaveAt = Date()
        suppressNextStoreEcho = true
        do {
            // Content-only write: state fields stay owned by the store, so a
            // note archived or deleted while this debounce ran cannot be
            // resurrected by the save landing afterwards.
            let wrote = try await NoteContentWriter.saveContent(draft, to: store)
            if !wrote {
                // No write means no echo. Leaving the flag armed swallowed the
                // next genuine change — e.g. this note being deleted from All
                // Notes — and the deck kept rendering a note that was gone.
                suppressNextStoreEcho = false
                await reload()
                return
            }
        } catch {
            // No write, no echo — don't suppress the next real event.
            suppressNextStoreEcho = false
            if case NoteStoreError.staleWrite = error {
                // Another Mac holds a newer copy. Show it rather than leaving
                // the editor claiming this text was saved.
                await reload()
            }
            return
        }
        // Surgical in-place update: replacing the whole array (full reload)
        // re-rendered the open editor after every autosave pause and could
        // drop its first responder mid-typing.
        if let idx = deckNotes.firstIndex(where: { $0.id == id }) {
            draft.updatedAt = Date()
            deckNotes[idx] = draft
        }
    }

    func cycleColor(of id: UUID) {
        guard let note = deckNotes.first(where: { $0.id == id }) else { return }
        let next = NoteColor.at(note.colorIndex).next.rawValue
        applyStateChange(to: id) { $0.colorIndex = next }
    }

    func setColor(_ colorIndex: Int, of id: UUID) {
        guard let note = deckNotes.first(where: { $0.id == id }), note.colorIndex != colorIndex else { return }
        applyStateChange(to: id) { $0.colorIndex = colorIndex }
    }

    /// Every state change goes through the store's live copy. Upserting the
    /// deck's snapshot always carried `deletedAt: nil` (fetch hides
    /// tombstones), so recolouring or pinning a note that had just been
    /// deleted elsewhere brought it back from the dead.
    private func applyStateChange(to id: UUID, _ change: @escaping (inout Note) -> Void) {
        let draft = deckNotes.first(where: { $0.id == id })
        Task {
            do {
                try await NoteContentWriter.applyStateChange(
                    to: id, from: draft, in: store, change
                )
            } catch {
                NSLog("StickyDeck could not update the note: %@", error.localizedDescription)
            }
            await reload()
        }
    }

    func togglePin(of id: UUID) {
        guard let note = deckNotes.first(where: { $0.id == id }) else { return }
        if !note.pinned,
           case .expanded(let expandedID) = state,
           expandedID == id,
           let frame = pinTransitionFrameProvider?() {
            PinnedNotePlacementHints.record(frame, for: id)
        }
        applyStateChange(to: id) { $0.pinned.toggle() }
        if case .expanded(let expandedID) = state, expandedID == id {
            closeNote()
        }
    }

    /// Archive from the deck's right-click menu: the note leaves the
    /// fan but stays restorable from the Archive window.
    func archiveNote(_ id: UUID) {
        guard deckNotes.contains(where: { $0.id == id }) else { return }
        applyStateChange(to: id) { $0.archivedAt = Date() }
        if case .expanded(let expandedID) = state, expandedID == id {
            closeNote()
        }
    }

    func deleteWithUndo(_ id: UUID) {
        guard let note = deckNotes.first(where: { $0.id == id }) else { return }
        // A newer delete replaces a pending one (D9), but the outgoing note
        // still has to be purged — cancelling its timer and dropping it left
        // an invisible soft-deleted row behind forever.
        deleteExpired()
        let pending = PendingDelete(note: note, expiresAt: Date().addingTimeInterval(10))
        Task {
            try? await store.softDelete(id: id)
            await reload()
        }
        pendingDelete = pending
        if case .expanded(let expandedID) = state, expandedID == id {
            closeNote()
        }
        scheduleExpiry(for: pending)
        announce(
            pending.note.title.isEmpty
                ? "Deleted a note. Undo is available."
                : "Deleted \(pending.note.title). Undo is available."
        )
    }

    private func scheduleExpiry(for pending: PendingDelete) {
        deleteTask?.cancel()
        deleteTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(max(pending.expiresAt.timeIntervalSinceNow, 0.1))
            )
            guard !Task.isCancelled, let self, self.pendingDelete?.id == pending.id else { return }
            self.deleteExpired()
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    func undoDelete() {
        guard let pending = pendingDelete else { return }
        deleteTask?.cancel()
        pausedDeleteRemaining = nil
        pendingDelete = nil
        Task {
            do {
                // `restore` clears the tombstone in place. Re-upserting the
                // pre-delete snapshot carries its older `updatedAt`, which
                // loses the sync store's last-writer-wins comparison against
                // the tombstone — so undo silently did nothing there.
                try await store.restore(id: pending.note.id)
            } catch {
                NSLog("StickyDeck could not undo the delete: %@", error.localizedDescription)
            }
            await reload()
        }
    }

    /// Pauses the ten-second window while the toast is hovered or
    /// accessibility-focused, mirroring the All Notes toast.
    func pausePendingDeleteExpiry() {
        guard pausedDeleteRemaining == nil, let pendingDelete else { return }
        pausedDeleteRemaining = max(pendingDelete.expiresAt.timeIntervalSinceNow, 0.1)
        deleteTask?.cancel()
        deleteTask = nil
    }

    func resumePendingDeleteExpiry() {
        guard let pending = pendingDelete, let remaining = pausedDeleteRemaining else { return }
        pausedDeleteRemaining = nil
        let resumed = PendingDelete(note: pending.note, expiresAt: Date().addingTimeInterval(remaining))
        pendingDelete = resumed
        scheduleExpiry(for: resumed)
    }

    func deleteExpired() {
        guard let pending = pendingDelete else { return }
        pausedDeleteRemaining = nil
        pendingDelete = nil
        Task {
            try? await store.purge(id: pending.note.id)
        }
    }
}
