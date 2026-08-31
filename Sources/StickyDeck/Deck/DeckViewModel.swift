import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class DeckViewModel {
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
        let deletion: DeletionToken
        let expiresAt: Date
    }

    private(set) var deckNotes: [Note] = []
    var state: State = .pill
    private(set) var notePresentationPhase: NotePresentationPhase = .idle
    private(set) var presentedNoteID: UUID?
    var pendingDelete: PendingDelete?
    var peekedNoteID: UUID?

    /// Mirrors `AppSettings.deckEdge` as observable state. The views used to
    /// read the static directly, so switching edge with the deck open moved
    /// the panel without ever invalidating the SwiftUI body — leaving the fan
    /// drawn against the old edge while the hit rects had already moved.
    private(set) var edge: AppSettings.Edge = AppSettings.deckEdge

    /// How many tabs the fan is currently rendering. On the last page of an
    /// overflowing deck this is smaller than the layout's page size, and the
    /// hit rect has to follow it or it swallows clicks in the blank strip.
    var drawnTabCount: Int = 0

    /// Height of the fixed-size deck panel on the current screen. The fan
    /// fits its layout inside it (D26) — fewer/tighter tabs on short
    /// displays. DeckController keeps it in sync with the panel frame.
    private(set) var panelHeight: CGFloat = (NSScreen.main?.visibleFrame.height ?? 900) * 0.8
    var cardOffsetY: CGFloat = CGFloat(AppSettings.noteCardOffsetY)

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

    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    /// Pin, archive, delete, duplicate and undo are launched from synchronous
    /// AppKit/SwiftUI actions. Keep their tasks reachable so quit and a sync
    /// backing change cannot overtake a store mutation already requested by
    /// the user.
    @ObservationIgnored private var mutationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var mutationTail: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var notePresentationTask: Task<Void, Never>?
    @ObservationIgnored private var peekDismissTask: Task<Void, Never>?
    @ObservationIgnored private var deleteTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var settingsObservationTask: Task<Void, Never>?
    private var lastOwnSaveAt = Date.distantPast
    private var suppressNextStoreEcho = false
    private var cardDragOrigin: CGFloat?
    private var pausedDeleteRemaining: TimeInterval?
    /// Every note owns its own quit fallback, just as it owns its own debounce
    /// task. A single global draft lets an older note's task clear a newer
    /// note's fallback when the user switches cards quickly.
    private struct EditorDraft {
        let generation: UUID
        let id: UUID
        let title: String
        let body: String
        let tag: String?
        let bodyWasEdited: Bool
    }
    private var pendingEditorDrafts: [UUID: EditorDraft] = [:]
    private var hoveredNoteIDs: [UUID] = []

    /// Installed by DeckController so pinning can hand the exact live editor
    /// frame to the sticky-window module without exposing panel geometry to
    /// the view model.
    var pinTransitionFrameProvider: (() -> CGRect?)?

    /// Installed by AppDelegate. The deck does not own desktop windows, but it
    /// is the surface a pin is initiated from, and the handoff has to be
    /// visually atomic — so it asks directly rather than by store round trip.
    weak var stickyPresenter: (any StickyPresenting)?

    var hasPendingWork: Bool {
        !saveTasks.isEmpty
            || !pendingEditorDrafts.isEmpty
            || !mutationTasks.isEmpty
            || pendingDelete != nil
    }

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
        mutationTasks.values.forEach { $0.cancel() }
        mutationTail?.cancel()
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
        } else if state == .fan && !debugPinned && pendingDelete == nil {
            // A pending delete puts its Undo toast inside this panel. Collapsing
            // now orders the panel out and takes the toast, its Undo button and
            // its ⌘Z shortcut with it, while the ten-second purge keeps running
            // — so the delete becomes unundoable. `closeNote` has always been
            // guarded this way; the hover path has to be too, and whatever
            // clears the pending delete re-checks collapse afterwards.
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
        collapseIfPointerOutside()
    }

    /// Collapses the deck when the pointer is no longer over any of its
    /// content, provided nothing on the panel still needs to be reachable.
    ///
    /// Called both when the note closes and when a pending delete resolves:
    /// the hover exit that would normally collapse the deck is suppressed
    /// while the Undo toast is up, and AppKit sends no fresh exit for a
    /// pointer that never moved — so without this the fan would sit open on
    /// the screen edge until the user waved at it.
    private func collapseIfPointerOutside() {
        guard pendingDelete == nil, let check = shouldCollapseCheck, check() else { return }
        deckHoverChanged(false)
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
    @discardableResult
    func flushPendingWork() async -> Bool {
        // Main-actor reentrancy allows another action to start at any await.
        // Repeat until both queues are empty; once the final condition is read
        // there is no suspension before returning.
        while true {
            await awaitMutationTasks()
            guard await flushEditorDrafts() else { return false }
            guard saveTasks.isEmpty,
                  pendingEditorDrafts.isEmpty,
                  mutationTasks.isEmpty else { continue }
            break
        }

        deleteTask?.cancel()
        deleteTask = nil
        if let pending = pendingDelete {
            pendingDelete = nil
            pausedDeleteRemaining = nil
            _ = try? await store.purge(pending.deletion)
        }
        return true
    }

    private func flushEditorDrafts() async -> Bool {
        let ids = Set(saveTasks.keys).union(pendingEditorDrafts.keys)
        for id in ids {
            guard await flushEditorDraft(id: id) else { return false }
        }
        return true
    }

    private func flushEditorDraft(id: UUID) async -> Bool {
        while true {
            let task = saveTasks.removeValue(forKey: id)
            task?.cancel()
            // Cancellation can arrive after a task entered store I/O. Let that
            // snapshot settle before the newest pending generation wins.
            await task?.value

            guard let draft = pendingEditorDrafts[id] else { return true }
            let saved = await persist(
                id: draft.id,
                title: draft.title,
                body: draft.body,
                tag: draft.tag,
                bodyWasEdited: draft.bodyWasEdited
            )
            guard saved else { return false }
            if pendingEditorDrafts[id]?.generation == draft.generation {
                pendingEditorDrafts[id] = nil
            }
            guard saveTasks[id] != nil || pendingEditorDrafts[id] != nil else { return true }
        }
    }

    @discardableResult
    private func launchMutation(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let prior = mutationTail
        let task = Task { [weak self] in
            await prior?.value
            await operation()
            self?.mutationTasks[id] = nil
        }
        mutationTasks[id] = task
        mutationTail = task
        return task
    }

    private func awaitMutationTasks() async {
        while !mutationTasks.isEmpty {
            let tasks = mutationTasks
            for (id, task) in tasks {
                await task.value
                mutationTasks[id] = nil
            }
        }
    }

    // MARK: - Note actions

    func newNote() async {
        let task = launchMutation { [weak self] in
            guard let self else { return }
            let minSort = self.deckNotes.map(\.sortIndex).min() ?? 1
            // Sync files and .stickies archives are user-editable. Saturate an
            // extreme imported value instead of trapping on integer overflow.
            let sortIndex = minSort == .min ? Int.min : minSort - 1
            let note = Note(sortIndex: sortIndex)
            do {
                try await self.store.upsert(note)
            } catch {
                // A silent no-op left the "+" looking broken. The deck has no
                // alert surface of its own, so this matches every other write
                // failure here and leaves a trail.
                NSLog("StickyDeck could not create the note: %@", error.localizedDescription)
                return
            }
            await self.reload()
            self.clearPeek()
            self.select(note.id)
        }
        await task.value
    }

    func duplicate(_ id: UUID) {
        guard deckNotes.contains(where: { $0.id == id }) else { return }
        launchMutation { [weak self] in
            guard let self,
                  await self.flushEditorDraft(id: id),
                  let source = self.deckNotes.first(where: { $0.id == id }) else { return }
            var copy = source
            copy.id = UUID()
            copy.pinned = false
            copy.sortIndex = source.sortIndex == .max ? Int.max : source.sortIndex + 1
            copy.createdAt = Date()
            copy.updatedAt = copy.createdAt
            copy.archivedAt = nil
            copy.deletedAt = nil
            do {
                try await self.store.upsert(copy)
            } catch {
                NSLog("StickyDeck could not duplicate the note: %@", error.localizedDescription)
                return
            }
            await self.reload()
        }
    }

    func saveDraft(
        id: UUID,
        title: String,
        body: String,
        tag: String? = nil,
        bodyWasEdited: Bool = false
    ) {
        // Title and body changes can arrive as separate SwiftUI callbacks in
        // the same update. Once the body changed, keep that fact on the
        // coalesced draft even if a later title callback replaces its timer.
        let effectiveBodyWasEdited = bodyWasEdited
            || pendingEditorDrafts[id]?.bodyWasEdited == true
        let draft = EditorDraft(
            generation: UUID(),
            id: id,
            title: title,
            body: body,
            tag: tag,
            bodyWasEdited: effectiveBodyWasEdited
        )
        pendingEditorDrafts[id] = draft
        let prior = saveTasks[id]
        prior?.cancel()
        saveTasks[id] = Task { [weak self] in
            // A cancelled task may already be inside store I/O. Keep it in the
            // chain so quit or a state action can wait for the older snapshot
            // before making this newest draft authoritative.
            await prior?.value
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let saved = await self.persist(
                id: id,
                title: title,
                body: body,
                tag: tag,
                bodyWasEdited: effectiveBodyWasEdited
            )
            // A cancelled task may already be inside store I/O. It must never
            // clear a draft that superseded it while that await was in flight.
            guard self.pendingEditorDrafts[id]?.generation == draft.generation else { return }
            self.saveTasks[id] = nil
            if saved {
                self.pendingEditorDrafts[id] = nil
            }
        }
    }

    /// Writes any pending draft for `id` immediately. Pin, archive and delete
    /// call this first: they upsert the note as `deckNotes` holds it and then
    /// reload it out of that array, so the debounced save that lands afterwards
    /// finds nothing and silently drops the last few hundred milliseconds of
    /// typing.
    func flushDraft(id: UUID, title: String, body: String, tag: String? = nil) async -> Bool {
        let bodyWasEdited = pendingEditorDrafts[id]?.bodyWasEdited == true
        saveDraft(
            id: id,
            title: title,
            body: body,
            tag: tag,
            bodyWasEdited: bodyWasEdited
        )
        return await flushEditorDraft(id: id)
    }

    private func persist(
        id: UUID,
        title: String,
        body: String,
        tag: String? = nil,
        bodyWasEdited: Bool = false
    ) async -> Bool {
        guard let current = deckNotes.first(where: { $0.id == id }) else { return true }
        var draft = current
        draft.title = title
        draft.body = body
        if bodyWasEdited {
            // The migration marker describes an untouched placeholder, not an
            // empty value. Real input owns the body even when the user types
            // and then clears it back to empty.
            draft.bodyNeedsMigration = false
        }
        if let tag {
            draft.tag = tag
        }
        let replacesMigrationPlaceholder = bodyWasEdited && current.bodyNeedsMigration
        guard replacesMigrationPlaceholder
                || draft.title != current.title
                || draft.body != current.body
                || draft.tag != current.tag else { return true }

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
                return true
            }
        } catch {
            // No write, no echo — don't suppress the next real event.
            suppressNextStoreEcho = false
            if case NoteStoreError.staleWrite = error {
                // Another Mac holds a newer copy. Show it rather than leaving
                // the editor claiming this text was saved.
                await reload()
                return true
            }
            NSLog("StickyDeck could not save the note: %@", error.localizedDescription)
            return false
        }
        // Surgical in-place update: replacing the whole array (full reload)
        // re-rendered the open editor after every autosave pause and could
        // drop its first responder mid-typing.
        if let idx = deckNotes.firstIndex(where: { $0.id == id }) {
            draft.updatedAt = Date()
            deckNotes[idx] = draft
        }
        return true
    }

    func cycleColor(of id: UUID) {
        guard deckNotes.contains(where: { $0.id == id }) else { return }
        // Derive from the store's live copy inside the atomic mutation. Two
        // rapid keyboard commands should advance twice instead of both
        // writing the same next colour computed from a stale UI snapshot.
        applyStateChange(to: id) {
            $0.colorIndex = NoteColor.at($0.colorIndex).next.rawValue
        }
    }

    func setColor(_ colorIndex: Int, of id: UUID) {
        guard let note = deckNotes.first(where: { $0.id == id }), note.colorIndex != colorIndex else { return }
        applyStateChange(to: id) { $0.colorIndex = colorIndex }
    }

    /// Every state change goes through the store's live copy. Upserting the
    /// deck's snapshot always carried `deletedAt: nil` (fetch hides
    /// tombstones), so recolouring or pinning a note that had just been
    /// deleted elsewhere brought it back from the dead.
    private func applyStateChange(
        to id: UUID,
        _ change: @escaping @Sendable (inout Note) -> Void
    ) {
        launchMutation { [weak self] in
            guard let self, await self.flushEditorDraft(id: id) else { return }
            let draft = self.deckNotes.first(where: { $0.id == id })
            do {
                try await NoteContentWriter.applyStateChange(
                    to: id, from: draft, in: self.store, change
                )
            } catch {
                NSLog("StickyDeck could not update the note: %@", error.localizedDescription)
            }
            await self.reload()
        }
    }

    /// Moves a note from the deck to the desktop.
    ///
    /// Both halves happen in this turn: the window goes up over the card's own
    /// frame, and the card is retired underneath it. Only the write that
    /// records the pin is asynchronous, and nothing on screen waits for it.
    func togglePin(of id: UUID) {
        guard let note = deckNotes.first(where: { $0.id == id }) else { return }
        // `deckNotes` never contains a pinned note, so this is always a pin.
        // Unpinning is the sticky window's own affordance.
        var pinned = note
        // A debounced editor draft for this note has not reached the store
        // yet, and the pin paths that go through the tab (context menu,
        // accessibility action) cannot flush it first — the flush helper on
        // the expanded card only ever flushes the card's own note. Hand the
        // sticky the draft the user is looking at: otherwise the window opens
        // on stale text and its own save writes that text back over the
        // newer copy `applyStateChange` is about to flush.
        if let draft = pendingEditorDrafts[id] {
            pinned.title = draft.title
            if !note.bodyNeedsMigration || !draft.body.isEmpty {
                pinned.body = draft.body
                if draft.bodyWasEdited { pinned.bodyNeedsMigration = false }
            }
            if let tag = draft.tag { pinned.tag = tag }
        }
        pinned.pinned = true
        stickyPresenter?.present(pinned, takingPlaceOf: pinTransitionFrameProvider?())
        retireCard(id: id)
        applyStateChange(to: id) { $0.pinned = true }
    }

    /// Retires the expanded card under the window that has just taken its place.
    ///
    /// The card is not animated away, it stops existing: the editor layer
    /// renders `presentedNote`, which is looked up in `deckNotes`, so dropping
    /// the note there removes the card outright. Letting it animate instead
    /// slid a now-stale card out from behind the new window — and suppressing
    /// that with a `disablesAnimations` transaction went too far the other
    /// way, freezing the *fan* as well so its tabs snapped into their new
    /// positions in a single frame. The fan closing its gap is the one part of
    /// this the user should see, so it is left to animate normally.
    private func retireCard(id: UUID) {
        guard case .expanded(let expandedID) = state, expandedID == id else { return }
        notePresentationTask?.cancel()
        notePresentationPhase = .idle
        deckNotes.removeAll { $0.id == id }
        state = .fan
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
        beginDeleteWithUndo(note)
    }

    /// Pinned notes are intentionally absent from `deckNotes`, but their
    /// editor still uses the same ten-second delete contract. Revealing the
    /// fan makes the shared Undo toast reachable after the sticky disappears.
    func deletePinnedWithUndo(_ note: Note) {
        clearPeek()
        state = .fan
        beginDeleteWithUndo(note)
    }

    private func beginDeleteWithUndo(_ note: Note) {
        launchMutation { [weak self] in
            guard let self, await self.flushEditorDraft(id: note.id) else { return }
            let deletion: DeletionToken
            do {
                guard let token = try await self.store.softDelete(id: note.id) else {
                    // A stale surface can still present a note that another
                    // window has already deleted. It owns no Undo generation.
                    await self.reload()
                    return
                }
                deletion = token
            } catch {
                NSLog("StickyDeck could not delete the note: %@", error.localizedDescription)
                return
            }

            // Publish an Undo token only after the tombstone exists. Otherwise
            // its timer (or a second delete) could purge a still-active note if
            // the preceding content save/soft-delete failed.
            if let outgoing = self.pendingDelete {
                self.deleteTask?.cancel()
                self.deleteTask = nil
                self.pendingDelete = nil
                self.pausedDeleteRemaining = nil
                do {
                    try await self.store.purge(outgoing.deletion)
                } catch {
                    NSLog("StickyDeck could not remove the prior deleted note: %@", error.localizedDescription)
                }
            }

            let pending = PendingDelete(
                note: note,
                deletion: deletion,
                expiresAt: Date().addingTimeInterval(10)
            )
            self.pendingDelete = pending
            self.pausedDeleteRemaining = nil
            await self.reload()
            if case .expanded(let expandedID) = self.state, expandedID == note.id {
                self.closeNote()
            }
            self.scheduleExpiry(for: pending)
            self.announce(
                note.title.isEmpty
                    ? "Deleted a note. Undo is available."
                    : "Deleted \(note.title). Undo is available."
            )
        }
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
        launchMutation { [weak self] in
            guard let self else { return }
            do {
                // `restore` clears the tombstone in place. Re-upserting the
                // pre-delete snapshot carries its older `updatedAt`, which
                // loses the sync store's last-writer-wins comparison against
                // the tombstone — so undo silently did nothing there.
                try await self.store.restore(pending.deletion)
            } catch {
                NSLog("StickyDeck could not undo the delete: %@", error.localizedDescription)
            }
            await self.reload()
        }
        collapseIfPointerOutside()
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
        let resumed = PendingDelete(
            note: pending.note,
            deletion: pending.deletion,
            expiresAt: Date().addingTimeInterval(remaining)
        )
        pendingDelete = resumed
        scheduleExpiry(for: resumed)
    }

    func deleteExpired() {
        guard let pending = pendingDelete else { return }
        pausedDeleteRemaining = nil
        pendingDelete = nil
        launchMutation { [weak self] in
            do {
                _ = try await self?.store.purge(pending.deletion)
            } catch {
                // The tombstone stays behind — invisible in every surface but
                // still owning its row/file, with nothing that ever sweeps it
                // up. Silence made that indistinguishable from a clean purge.
                NSLog("StickyDeck could not remove the deleted note: %@", error.localizedDescription)
            }
        }
        // The toast is gone, so the hover exit that was suppressed while it
        // was up can finally take effect.
        collapseIfPointerOutside()
    }
}
