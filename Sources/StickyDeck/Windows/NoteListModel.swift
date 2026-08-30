import Foundation
import SwiftUI

@MainActor
final class NoteListModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var query: String = "" { didSet { scheduleReload() } }
    @Published var filter: NoteFilter = .all { didSet { scheduleReload() } }
    /// Moving the preview focus flushes like a selection change does: the
    /// debounced draft belongs to the note we are leaving, and replacing it
    /// 250 ms later would drop that edit on the floor.
    @Published var focusedID: UUID? { didSet { flushAutosave() } }
    /// Checkbox selection is independent from the row focused in the preview.
    /// The reference opens with a focused first row and no checked boxes.
    @Published var selection = Set<UUID>() { didSet { flushAutosave() } }
    @Published var pendingDelete: NoteListModel.Delete?
    @Published private(set) var isLoading = false
    @Published var presentedError: PresentedError?

    struct PresentedError: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    struct Delete: Identifiable, Equatable {
        let id: UUID
        let notes: [Note]
        let expiresAt: Date

        init(id: UUID = UUID(), notes: [Note], expiresAt: Date) {
            self.id = id
            self.notes = notes
            self.expiresAt = expiresAt
        }
    }

    let mode: NoteListView.Mode
    let store: any NoteStore
    private var reloadTask: Task<Void, Never>?
    private var purgeTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var autosaveDraft: Note?
    /// The in-flight write started by `flushAutosave`, so a state write that
    /// follows can wait for it instead of racing it.
    private var flushTask: Task<Void, Never>?
    private var pausedDeleteRemaining: TimeInterval?
    /// Bumped on every `reload`; `publishedGeneration` records the newest one
    /// whose rows actually reached the list, so a fetch that lost the race can
    /// tell it has been overtaken.
    private var reloadGeneration = 0
    private var publishedGeneration = 0

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
    }

    deinit {
        observationTask?.cancel()
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
        let note = Note()
        do {
            try await store.upsert(note)
        } catch {
            presentError(title: "Note Couldn’t Be Created", message: error.localizedDescription)
            return
        }
        focusedID = note.id
        selection = []
        await reload()
    }

    /// Archive / restore is a whole-row write — it owns a state field — so it
    /// applies the change onto the note as the store currently holds it rather
    /// than onto this list's cached row. The cached row can be a few hundred
    /// milliseconds stale (the deck and sticky windows save on their own
    /// debounce), and writing it back rolled those edits out. Same shape as
    /// `StickyWindowManager.applyStateChange`.
    func setArchived(_ ids: Set<UUID>, archived: Bool) async {
        flushAutosave()
        // Our own pending draft is a store write too: reading before it lands
        // would archive the pre-edit body, and the flush would then land after
        // the archive and undo it.
        await awaitPendingFlush()

        // Filtered through `notes` first, so a bulk action still only touches
        // what is actually on screen even when checks survive on hidden rows.
        let targets = notes.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }

        let live: [Note]
        do {
            live = try await store.fetch(filter: .all, query: "")
        } catch {
            presentError(
                title: archived ? "Note Couldn’t Be Archived" : "Note Couldn’t Be Restored",
                message: error.localizedDescription
            )
            return
        }

        for target in targets {
            // Missing from the store means purged while the pane was open.
            // Dropping the write is deliberate: it must not resurrect.
            guard var note = live.first(where: { $0.id == target.id }) else { continue }
            note.archivedAt = archived ? Date() : nil
            note.updatedAt = Date()
            do {
                try await store.upsert(note)
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
        flushAutosave()
        let victims = notes.filter { ids.contains($0.id) && $0.deletedAt == nil }
        guard !victims.isEmpty else { return }
        var deleted: [Note] = []
        for victim in victims {
            do {
                try await store.softDelete(id: victim.id)
                deleted.append(victim)
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
        pendingDelete = Delete(notes: deleted, expiresAt: Date().addingTimeInterval(10))
        pausedDeleteRemaining = nil
        selection.subtract(Set(deleted.map(\.id)))
        await reload()
        if let pendingDelete { schedulePurge(pendingDelete) }
    }

    func undoDelete() async {
        flushAutosave()
        guard let pending = pendingDelete else { return }
        purgeTask?.cancel()
        pausedDeleteRemaining = nil
        pendingDelete = nil
        for victim in pending.notes {
            do {
                // Restore, not upsert: `softDelete` stamped a newer updatedAt
                // on the stored copy, so re-writing the pre-delete snapshot is
                // discarded by the sync store's last-writer-wins guard and the
                // note stays deleted.
                try await store.restore(id: victim.id)
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
            expiresAt: Date().addingTimeInterval(remaining)
        )
        pendingDelete = resumed
        schedulePurge(resumed)
    }

    /// Debounced preview-card save: one store write per typing pause, not
    /// per keystroke (per-keystroke writes would echo through the store while
    /// typing, and in sync-folder mode write a file per keystroke).
    func autosave(_ note: Note) {
        autosaveDraft = note
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, var note = self.autosaveDraft else { return }
            // Taken, not left in place: a second flush landing while this
            // write is in flight would write the same note twice — and after
            // a delete, resurrect it.
            self.autosaveDraft = nil
            note.updatedAt = Date()
            do {
                // Content only: this debounce can outlive an archive or delete
                // made elsewhere, and a whole-row write of the draft would
                // carry the note's old state back in and resurrect it.
                try await NoteContentWriter.saveContent(note, to: self.store)
            } catch {
                // The draft goes back so the text is not lost with the write:
                // clearing it outright destroyed the edit, and the alert's
                // Try Again then reloaded the stored copy over it. A newer
                // draft that arrived meanwhile wins.
                if self.autosaveDraft == nil { self.autosaveDraft = note }
                self.presentError(title: "Changes Couldn’t Be Saved", message: error.localizedDescription)
            }
        }
    }

    /// Writes a pending preview-card draft immediately (selection change,
    /// bulk actions, window close).
    func flushAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard var note = autosaveDraft else { return }
        autosaveDraft = nil
        note.updatedAt = Date()
        flushTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await NoteContentWriter.saveContent(note, to: self.store)
            } catch {
                // Same rule as the debounced path: a failed write hands the
                // draft back instead of destroying the user's text.
                if self.autosaveDraft == nil { self.autosaveDraft = note }
                self.presentError(title: "Changes Couldn’t Be Saved", message: error.localizedDescription)
            }
        }
    }

    /// Waits for the last `flushAutosave` write to reach the store.
    private func awaitPendingFlush() async {
        let pending = flushTask
        await pending?.value
        // Only cleared if no newer flush was started while we waited.
        if flushTask == pending { flushTask = nil }
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
        for victim in pending.notes {
            do {
                try await store.purge(id: victim.id)
            } catch {
                presentError(title: "Deleted Note Couldn’t Be Removed", message: error.localizedDescription)
                break
            }
        }
    }

}
