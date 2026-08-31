import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class NoteListModel {
    var notes: [Note] = []
    var query: String = "" { didSet { scheduleReload() } }
    var filter: NoteFilter = .all { didSet { scheduleReload() } }
    /// Moving the preview focus flushes like a selection change does: the
    /// debounced draft belongs to the note we are leaving, and replacing it
    /// 250 ms later would drop that edit on the floor.
    var focusedID: UUID? { didSet { flushAutosave() } }
    /// Checkbox selection is independent from the row focused in the preview.
    /// The reference opens with a focused first row and no checked boxes.
    var selection = Set<UUID>() { didSet { flushAutosave() } }
    var pendingDelete: NoteListModel.Delete?
    private(set) var isLoading = false
    var presentedError: PresentedError?

    struct PresentedError: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    struct Delete: Identifiable, Equatable {
        let id: UUID
        let notes: [Note]
        let deletions: [UUID: DeletionToken]
        let expiresAt: Date

        init(
            id: UUID = UUID(),
            notes: [Note],
            deletions: [UUID: DeletionToken],
            expiresAt: Date
        ) {
            self.id = id
            self.notes = notes
            self.deletions = deletions
            self.expiresAt = expiresAt
        }
    }

    let mode: NoteListView.Mode
    let store: any NoteStore
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var purgeTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObservationTask: Task<Void, Never>?
    @ObservationIgnored private var terminationTask: Task<Bool, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    private struct AutosaveDraft {
        let generation: Int
        var note: Note
    }
    /// Preview focus can move while an older write is suspended. Retain one
    /// newest draft per note so a failure for row A cannot be erased merely
    /// because the user has already begun editing row B.
    private var autosaveDrafts: [UUID: AutosaveDraft] = [:]
    private var autosaveGeneration = 0
    private var latestAutosaveGeneration: [UUID: Int] = [:]
    /// The in-flight write started by `flushAutosave`, so a state write that
    /// follows can wait for it instead of racing it.
    @ObservationIgnored private var flushTask: Task<Set<UUID>, Never>?
    private var flushGeneration: UUID?
    /// Async list commands are launched from SwiftUI Tasks. Termination and a
    /// backing-store switch wait for them so an archive/delete/create request
    /// cannot still be suspended in the outgoing library when the app moves on.
    private var activeActionCount = 0
    private var actionWaiters: [CheckedContinuation<Void, Never>] = []
    private var pausedDeleteRemaining: TimeInterval?
    /// Bumped on every `reload`; `publishedGeneration` records the newest one
    /// whose rows actually reached the list, so a fetch that lost the race can
    /// tell it has been overtaken.
    private var reloadGeneration = 0
    private var publishedGeneration = 0

    var hasPendingWork: Bool {
        autosaveTask != nil
            || !autosaveDrafts.isEmpty
            || flushTask != nil
            || activeActionCount > 0
            || pendingDelete != nil
    }

    init(store: any NoteStore, mode: NoteListView.Mode) {
        self.store = store
        self.mode = mode
        filter = mode == .archive ? .archived : .all

        reloadTask = Task { [weak self] in await self?.reload() }
        observationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .noteStoreChanged).map({ _ in () }) {
                guard let self else { return }
                // Debounced: per-keystroke saves elsewhere (deck editor, sticky
                // windows) would otherwise re-sort this list mid-typing.
                self.scheduleReload()
            }
        }
        terminationObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .appWillTerminate) {
                guard let self else { return }
                self.beginTerminationFlush()
            }
        }
    }

    deinit {
        observationTask?.cancel()
        terminationObservationTask?.cancel()
        terminationTask?.cancel()
        reloadTask?.cancel()
        purgeTask?.cancel()
        autosaveTask?.cancel()
    }

    func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = notes.isEmpty
        defer { isLoading = false }

        let all: [Note]
        do {
            all = try await store.fetch(filter: filter, query: query)
        } catch {
            // Every keystroke, filter switch and store-change notification
            // cancels the reload already in flight, and GRDB reports that
            // cancellation as a thrown error out of the suspended read
            // (`SerializedDatabase.execute` checks for it before running the
            // block). Only the success path below was guarded, so ordinary
            // fast typing in the search field could raise a real "your notes
            // are unavailable" alert for work this model cancelled itself.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            presentError(
                title: "Notes Couldn’t Be Loaded",
                message: "Check that your notes folder is available, then try again.\n\n\(error.localizedDescription)"
            )
            return
        }
        // Filter switches, typing and store-change notifications leave several
        // fetches in flight. One that comes back after a newer reload already
        // published is stale and must not overwrite those rows.
        guard !Task.isCancelled, generation > publishedGeneration else { return }
        publishedGeneration = generation
        // Taken before `notes` is replaced: repairing the focus below needs to
        // know where the focused row used to sit.
        let previousIndex = focusedID.flatMap { id in notes.firstIndex { $0.id == id } }
        // Both stores return notes already ordered (sortIndex, then newest
        // first) — re-sorting here by updatedAt made rows jump to the top
        // after every autosave.
        notes = all
        // Checked rows deliberately survive a reload: glancing at another
        // filter or typing in the search field must not silently uncheck
        // them. `selectedNotes` intersects with `notes`, so bulk actions still
        // only ever touch what is on screen.
        let visibleIDs = Set(all.map(\.id))
        if focusedID == nil || !visibleIDs.contains(focusedID!) {
            // The focused note is gone — deleted, archived, or filtered out.
            // Focus lands on the row that took its place, not back at the top:
            // jumping home after deleting row 40 of 60 threw the list, the
            // preview and the scroll position away with it.
            if let previousIndex, !all.isEmpty {
                focusedID = all[min(previousIndex, all.count - 1)].id
            } else {
                focusedID = all.first?.id
            }
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    var selectedNotes: [Note] {
        notes.filter { selection.contains($0.id) }
    }

    /// All Notes can be filtered to archived rows. A checked group of only
    /// archived notes should offer Restore; any active note makes Archive the
    /// useful common action.
    var bulkActionArchives: Bool {
        selectedNotes.contains { !$0.isArchived }
    }

    var focusedNote: Note? {
        guard let focusedID else { return nil }
        return notes.first { $0.id == focusedID }
    }

    var actionNotes: [Note] {
        if !selectedNotes.isEmpty { return selectedNotes }
        return focusedNote.map { [$0] } ?? []
    }

    /// Rows a Page Up / Page Down moves through. The list pane is roughly
    /// 500 pt tall at the window's default height and rows are 58 pt, so eight
    /// rows is about a screenful with one row of overlap for context.
    static let pageLength = 8

    /// Moves the independent preview focus without changing bulk selection.
    /// This mirrors native source-list navigation: arrows browse; Space checks.
    func moveFocus(by offset: Int) {
        guard !notes.isEmpty else { return }
        let currentIndex = focusedID.flatMap { id in notes.firstIndex { $0.id == id } }
        let fallback = offset >= 0 ? -1 : notes.count
        let nextIndex = min(max((currentIndex ?? fallback) + offset, 0), notes.count - 1)
        focusedID = notes[nextIndex].id
    }

    /// Home / End. Expressed as a full-length move so the clamping and the
    /// empty-list guard in `moveFocus` cover these too.
    func moveFocusToFirst() { moveFocus(by: -notes.count) }

    func moveFocusToLast() { moveFocus(by: notes.count) }

    /// Returns false when there was nothing to toggle (archive mode has no
    /// checkboxes) so the key handler can let Space fall through to the
    /// list's page-scroll instead of swallowing it.
    @discardableResult
    func toggleFocusedSelection() -> Bool {
        guard mode == .all, let focusedID else { return false }
        if selection.contains(focusedID) {
            selection.remove(focusedID)
        } else {
            selection.insert(focusedID)
        }
        return true
    }

    func clearSelection() {
        selection.removeAll()
    }

    func createNote() async {
        beginAction()
        defer { endAction() }
        flushAutosave()
        guard await awaitPendingFlush() else { return }
        let note = Note()
        do {
            try await store.upsert(note)
        } catch {
            presentError(title: "Note Couldn’t Be Created", message: error.localizedDescription)
            return
        }
        // A new active note would be invisible under a search or Archived
        // filter. Return to the complete library before focusing it.
        query = ""
        filter = .all
        focusedID = note.id
        selection = []
        await reload()
    }

    /// Import performs a read followed by one or more writes. Treat the whole
    /// operation as one list action so a backing switch cannot split an archive
    /// across two independent libraries.
    func importNotes() async {
        beginAction()
        defer { endAction() }
        await TransferService.importNotes(into: store)
        await reload()
    }

    /// Archive / restore applies only its state field to the store's current
    /// live copy. The cached row can be a few hundred milliseconds stale (the
    /// deck and sticky windows save on their own debounce), and writing it
    /// back rolled those edits out.
    func setArchived(_ ids: Set<UUID>, archived: Bool) async {
        beginAction()
        defer { endAction() }
        flushAutosave()
        // Our own pending draft is a store write too: reading before it lands
        // would archive the pre-edit body, and the flush would then land after
        // the archive and undo it.
        guard await awaitPendingFlush() else { return }

        // Filtered through `notes` first, so a bulk action still only touches
        // what is actually on screen even when checks survive on hidden rows.
        let targets = notes.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }

        for target in targets {
            do {
                // Atomic with respect to delete/purge. A note that vanished
                // after the rows were rendered is deliberately left gone.
                try await store.mutate(id: target.id) { note in
                    note.archivedAt = archived ? Date() : nil
                }
            } catch {
                presentError(
                    title: archived ? "Note Couldn’t Be Archived" : "Note Couldn’t Be Restored",
                    message: error.localizedDescription
                )
                // Earlier notes in the batch already changed in the store,
                // so the rows on screen are stale until we re-read them.
                await reload()
                return
            }
        }
        await reload()
    }

    func deleteSelection(_ ids: Set<UUID>) async {
        beginAction()
        defer { endAction() }
        flushAutosave()
        // `softDelete` preserves the store's current content, and Undo restores
        // that copy. Wait for the visible draft so Undo cannot bring back the
        // text from before the user's last typing pause.
        guard await awaitPendingFlush() else { return }
        let victims = notes.filter { ids.contains($0.id) && $0.deletedAt == nil }
        guard !victims.isEmpty else { return }
        var deleted: [Note] = []
        var deletions: [UUID: DeletionToken] = [:]
        for victim in victims {
            do {
                guard let deletion = try await store.softDelete(id: victim.id) else {
                    continue
                }
                deleted.append(victim)
                deletions[victim.id] = deletion
            } catch {
                presentError(title: "Note Couldn’t Be Deleted", message: error.localizedDescription)
                break
            }
        }
        guard !deleted.isEmpty else { return }
        // A newer delete replaces a pending one, but the batch it displaces
        // must not be left soft-deleted with its toast gone: it would be
        // invisible in the list and never cleaned up. Purge it now.
        if let outgoing = pendingDelete {
            purgeTask?.cancel()
            purgeTask = nil
            pausedDeleteRemaining = nil
            pendingDelete = nil
            await purgeNow(outgoing)
        }
        pendingDelete = Delete(
            notes: deleted,
            deletions: deletions,
            expiresAt: Date().addingTimeInterval(10)
        )
        pausedDeleteRemaining = nil
        selection.subtract(Set(deleted.map(\.id)))
        await reload()
        if let pendingDelete { schedulePurge(pendingDelete) }
    }

    func undoDelete() async {
        beginAction()
        defer { endAction() }
        flushAutosave()
        guard await awaitPendingFlush() else { return }
        guard let pending = pendingDelete else { return }
        purgeTask?.cancel()
        pausedDeleteRemaining = nil
        pendingDelete = nil
        for victim in pending.notes {
            guard let deletion = pending.deletions[victim.id] else { continue }
            do {
                // Restore, not upsert: `softDelete` stamped a newer updatedAt
                // on the stored copy, so re-writing the pre-delete snapshot is
                // discarded by the sync store's last-writer-wins guard and the
                // note stays deleted.
                try await store.restore(deletion)
            } catch {
                presentError(title: "Note Couldn’t Be Restored", message: error.localizedDescription)
                // Earlier notes in the batch are already back, so the list has
                // to be re-read before we give up.
                await reload()
                return
            }
        }
        await reload()
    }

    /// Pauses the otherwise ten-second Undo window while the feedback is
    /// hovered or accessibility-focused.
    func pausePendingDeleteExpiry() {
        guard pausedDeleteRemaining == nil, let pendingDelete else { return }
        pausedDeleteRemaining = max(pendingDelete.expiresAt.timeIntervalSinceNow, 0.1)
        purgeTask?.cancel()
        purgeTask = nil
    }

    func resumePendingDeleteExpiry() {
        guard let pending = pendingDelete, let remaining = pausedDeleteRemaining else { return }
        pausedDeleteRemaining = nil
        let resumed = Delete(
            id: pending.id,
            notes: pending.notes,
            deletions: pending.deletions,
            expiresAt: Date().addingTimeInterval(remaining)
        )
        pendingDelete = resumed
        schedulePurge(resumed)
    }

    /// Debounced preview-card save: one store write per typing pause, not
    /// per keystroke (per-keystroke writes would echo through the store while
    /// typing, and in sync-folder mode write a file per keystroke).
    func autosave(_ note: Note) {
        autosaveGeneration &+= 1
        autosaveDrafts[note.id] = AutosaveDraft(generation: autosaveGeneration, note: note)
        latestAutosaveGeneration[note.id] = autosaveGeneration
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            // Store writes are queued by `flushAutosave`; the timer itself
            // never enters I/O. That leaves every in-flight write reachable so
            // delete, export and termination can await them deterministically.
            self.flushAutosave()
        }
    }

    /// Creates a content draft from actual preview-editor input. Clearing the
    /// migration marker here distinguishes an intentional empty body from the
    /// untouched empty placeholder shown while a legacy body is recovered.
    func autosaveBody(_ body: String, for note: Note) {
        var draft = note
        draft.body = body
        draft.bodyNeedsMigration = false
        autosave(draft)
    }

    /// Writes a pending preview-card draft immediately (selection change,
    /// bulk actions, window close).
    func flushAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        let drafts = autosaveDrafts.values.sorted { $0.generation < $1.generation }
        for draft in drafts {
            if autosaveDrafts[draft.note.id]?.generation == draft.generation {
                autosaveDrafts[draft.note.id] = nil
            }
            enqueueFlush(draft)
        }
    }

    private func enqueueFlush(_ original: AutosaveDraft) {
        var draft = original
        draft.note.updatedAt = Date()
        let prior = flushTask
        let generation = UUID()
        flushGeneration = generation
        flushTask = Task { [weak self] in
            // Preserve edit order even if a prior store operation is slow.
            // The newest visible draft always lands last.
            var failedIDs = await prior?.value ?? []
            guard let self else { return failedIDs }
            do {
                try await NoteContentWriter.saveBody(draft.note, to: self.store)
                // A later successful snapshot of this same note supersedes an
                // earlier failed one in the serialized chain.
                failedIDs.remove(draft.note.id)
                if let pending = self.autosaveDrafts[draft.note.id],
                   pending.generation <= draft.generation {
                    self.autosaveDrafts[draft.note.id] = nil
                }
            } catch {
                // Hand this snapshot back unless a newer edit of the same row
                // is already pending. A draft for another note is independent.
                if self.latestAutosaveGeneration[draft.note.id] == draft.generation {
                    self.autosaveDrafts[draft.note.id] = draft
                }
                failedIDs.insert(draft.note.id)
                self.presentError(title: "Changes Couldn’t Be Saved", message: error.localizedDescription)
            }
            return failedIDs
        }
    }

    /// Waits for every preview write that was queued while waiting. Main-actor
    /// reentrancy permits a new draft to flush at an `await`, so this is a loop
    /// rather than one snapshot.
    private func awaitPendingFlush() async -> Bool {
        while let pending = flushTask, let generation = flushGeneration {
            let failedIDs = await pending.value
            guard flushGeneration == generation else { continue }
            flushTask = nil
            flushGeneration = nil
            guard failedIDs.isEmpty else { return false }
            // A newer edit can arrive while the write is suspended. Commit it
            // in the same drain rather than reporting success with a live timer.
            if !autosaveDrafts.isEmpty { flushAutosave() }
        }
        return autosaveDrafts.isEmpty
    }

    /// Returns fresh store copies for export after committing the editable
    /// preview. Passing the view's row snapshots directly exported the body as
    /// it looked before the last 250 ms typing pause.
    func notesForExport(_ candidates: [Note]) async -> [Note]? {
        guard !candidates.isEmpty else { return [] }
        flushAutosave()
        guard await awaitPendingFlush() else { return nil }
        do {
            let live = try await store.fetch(filter: .all, query: "")
            let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
            return candidates.compactMap { byID[$0.id] }
        } catch {
            presentError(title: "Notes Couldn’t Be Exported", message: error.localizedDescription)
            return nil
        }
    }

    /// Called both by the application coordinator and by the termination
    /// notification. Keeping one task makes the two paths idempotent.
    @discardableResult
    func flushPendingWork() async -> Bool {
        beginTerminationFlush()
        guard let task = terminationTask else { return true }
        return await task.value
    }

    private func beginTerminationFlush() {
        guard terminationTask == nil else { return }
        terminationTask = Task { [weak self] in
            guard let self else { return true }

            while true {
                await self.awaitActions()
                self.flushAutosave()
                guard await self.awaitPendingFlush() else {
                    self.terminationTask = nil
                    return false
                }
                await self.awaitActions()
                guard self.activeActionCount == 0,
                      self.autosaveDrafts.isEmpty,
                      self.flushTask == nil else { continue }
                break
            }

            self.purgeTask?.cancel()
            self.purgeTask = nil
            self.pausedDeleteRemaining = nil
            if let pending = self.pendingDelete {
                self.pendingDelete = nil
                await self.purgeNow(pending)
            }
            self.terminationTask = nil
            return true
        }
    }

    private func beginAction() {
        activeActionCount += 1
    }

    private func endAction() {
        activeActionCount -= 1
        guard activeActionCount == 0 else { return }
        let waiters = actionWaiters
        actionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func awaitActions() async {
        guard activeActionCount > 0 else { return }
        await withCheckedContinuation { continuation in
            actionWaiters.append(continuation)
        }
    }

    private func presentError(title: String, message: String) {
        presentedError = PresentedError(title: title, message: message)
    }

    private func schedulePurge(_ pending: Delete) {
        purgeTask?.cancel()
        purgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(pending.expiresAt.timeIntervalSinceNow, 0.1)))
            guard !Task.isCancelled, let self else { return }
            await self.purgeNow(pending)
            // Cleared even when a purge failed. Leaving it set kept the Undo
            // toast up forever, and undoing a half-purged batch would have
            // resurrected only the notes that happened to survive.
            if self.pendingDelete?.id == pending.id {
                self.pendingDelete = nil
                self.pausedDeleteRemaining = nil
            }
        }
    }

    /// Purges a batch immediately: either its Undo window ran out, or a newer
    /// delete took the toast away from it.
    private func purgeNow(_ pending: Delete) async {
        // `schedulePurge` clears `pendingDelete` whether or not this succeeds,
        // so anything skipped here is stranded as a tombstone that is
        // invisible in every surface and swept up by nothing. Stopping at the
        // first failure stranded every later note in the batch as well, so
        // each victim now gets its own attempt and one alert reports the lot.
        var firstFailure: Error?
        for victim in pending.notes {
            guard let deletion = pending.deletions[victim.id] else { continue }
            do {
                try await store.purge(deletion)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure {
            presentError(
                title: "Deleted Note Couldn’t Be Removed",
                message: firstFailure.localizedDescription
            )
        }
    }

}
