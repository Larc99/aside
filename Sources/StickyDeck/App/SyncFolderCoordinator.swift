import AppKit
import Foundation
import Combine

/// Bridges the sync-folder setting to the active store. Resolves the
/// security-scoped bookmark (D22), holds folder access for the lifetime of
/// the selection, and swaps the backing store in the `StoreHub` — local
/// plaintext SQLite when no folder is chosen, `SyncNoteStore` when one is.
/// Swaps post `.noteStoreChanged` via the hub so every observer re-pulls.
@MainActor
final class SyncFolderCoordinator {
    private let hub: StoreHub
    private let localStore: any NoteStore
    private let flushPendingWork: @Sendable () async -> Bool
    private let setInteractionBlocked: @MainActor @Sendable (Bool) -> Void
    private let reloadActiveLibrary: @MainActor @Sendable () async -> Void
    private var cancellables: Set<AnyCancellable> = []
    private var lastAppliedBookmark: Data?
    private var lastAppliedFolderName: String
    private var accessingURL: URL?
    private var applyTask: Task<Void, Never>?
    private var applyGeneration = 0

    init(
        hub: StoreHub,
        localStore: any NoteStore,
        flushPendingWork: @escaping @Sendable () async -> Bool = { true },
        setInteractionBlocked: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
        reloadActiveLibrary: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.hub = hub
        self.localStore = localStore
        self.flushPendingWork = flushPendingWork
        self.setInteractionBlocked = setInteractionBlocked
        self.reloadActiveLibrary = reloadActiveLibrary
        lastAppliedBookmark = AppSettings.syncFolderBookmark
        lastAppliedFolderName = AppSettings.syncFolderName

        NotificationCenter.default.publisher(for: .appSettingsChanged)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.queueCurrentSetting()
            }
            .store(in: &cancellables)
    }

    /// Applies the current setting at launch (before this call the hub is
    /// backed by the local store; a valid bookmark swaps to the sync folder).
    func install() async {
        await apply(bookmark: AppSettings.syncFolderBookmark)
    }

    deinit {
        applyTask?.cancel()
    }

    private func queueCurrentSetting() {
        let bookmark = AppSettings.syncFolderBookmark
        guard bookmark != lastAppliedBookmark else { return }
        let folderName = AppSettings.syncFolderName
        applyGeneration &+= 1
        let generation = applyGeneration
        let prior = applyTask
        applyTask = Task { [weak self] in
            // A security scope and its backing must move as one ordered state
            // machine. Serializing requests prevents a slower earlier choice
            // from resuming after Stop Syncing/a later choice and overwriting it.
            await prior?.value
            guard !Task.isCancelled,
                  let self,
                  generation == self.applyGeneration,
                  bookmark != self.lastAppliedBookmark else { return }
            // An older failed request may have restored Settings while this
            // newer choice waited in the serial queue. Put the captured latest
            // intent back before applying it so UI and backing converge.
            if AppSettings.syncFolderBookmark != bookmark {
                AppSettings.syncFolderBookmark = bookmark
            }
            if AppSettings.syncFolderName != folderName {
                AppSettings.syncFolderName = folderName
            }
            await self.apply(bookmark: bookmark, requestedFolderName: folderName)
            if generation == self.applyGeneration {
                self.applyTask = nil
            }
        }
    }

    private func apply(
        bookmark: Data?,
        requestedFolderName: String? = nil
    ) async {
        let previousBookmark = lastAppliedBookmark
        let previousFolderName = lastAppliedFolderName
        let requestedFolderName = requestedFolderName ?? AppSettings.syncFolderName
        lastAppliedBookmark = bookmark
        // The outgoing folder's scope is handed to the swap instead of being
        // dropped here: the swap is asynchronous, so until it lands the hub
        // still routes writes to the old store and revoking access first
        // fails any autosave already in flight.
        let outgoing = accessingURL
        accessingURL = nil

        guard let bookmark else {
            guard await swapBacking(to: localStore, releasing: outgoing) else {
                accessingURL = outgoing
                restoreSetting(bookmark: previousBookmark, folderName: previousFolderName)
                return
            }
            lastAppliedBookmark = nil
            lastAppliedFolderName = ""
            return
        }

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                // We own the access lifetime explicitly below. Without this
                // option, resolution starts an implicit access that our one
                // matching `stopAccessingSecurityScopedResource` cannot end.
                options: [.withSecurityScope, .withoutImplicitStartAccessing],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            // If access cannot be granted (scope lost), treat the folder as
            // unavailable rather than failing every write later.
            guard url.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            accessingURL = url

            var effectiveBookmark = bookmark
            if stale {
                // A stale bookmark may resolve for this launch but fail after
                // the next one. Prepare its replacement while the security
                // scope is live, but do not publish it unless the backing swap
                // succeeds.
                effectiveBookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }

            let syncStore = try SyncNoteStore(folder: url)
            guard await swapBacking(to: syncStore, releasing: outgoing) else {
                // The new scope was opened only for the rejected switch. Keep
                // the outgoing scope alive and put Settings back in agreement
                // with the backing that remains active.
                releaseAccess()
                accessingURL = outgoing
                restoreSetting(bookmark: previousBookmark, folderName: previousFolderName)
                return
            }
            lastAppliedBookmark = effectiveBookmark
            lastAppliedFolderName = requestedFolderName
            if effectiveBookmark != bookmark {
                // Mark it applied first so our own settings notification does
                // not tear down and recreate the same store 200 ms later.
                AppSettings.syncFolderBookmark = effectiveBookmark
            }
        } catch {
            // The bookmark could not be resolved (folder moved/deleted, or
            // scope lost): stay on local storage and let the user re-pick.
            // Nothing was ever swapped onto the new folder, so any scope we
            // took for it can go right away.
            releaseAccess()
            presentUnavailabilityError(error)
            guard await swapBacking(to: localStore, releasing: outgoing) else {
                accessingURL = outgoing
                restoreSetting(bookmark: previousBookmark, folderName: previousFolderName)
                return
            }
            lastAppliedBookmark = nil
            lastAppliedFolderName = ""
            AppSettings.syncFolderBookmark = nil
            AppSettings.syncFolderName = ""
        }
    }

    private func swapBacking(to store: any NoteStore, releasing previous: URL?) async -> Bool {
        setInteractionBlocked(true)
        defer { setInteractionBlocked(false) }
        guard await hub.swap(to: store, afterFlushing: flushPendingWork) else { return false }
        // Only now is the old store unreachable through the hub.
        previous?.stopAccessingSecurityScopedResource()
        // Keep editors blocked until they display the incoming library. An old
        // card must never accept a keystroke that would then target the new one.
        await reloadActiveLibrary()
        return true
    }

    private func restoreSetting(bookmark: Data?, folderName: String) {
        lastAppliedBookmark = bookmark
        lastAppliedFolderName = folderName
        AppSettings.syncFolderBookmark = bookmark
        AppSettings.syncFolderName = folderName
    }

    private func releaseAccess() {
        if let accessingURL {
            accessingURL.stopAccessingSecurityScopedResource()
        }
        accessingURL = nil
    }

    private func presentUnavailabilityError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sync folder unavailable"
        alert.informativeText = """
        StickyDeck could not open the sync folder (\(error.localizedDescription)). \
        Notes stay on this Mac until you choose a folder again in Settings.
        """
        // `runModal` orders the alert front *within* the app but does not
        // activate an accessory (LSUIElement) app, so at launch this alert can
        // sit invisibly behind the frontmost app while its modal run loop
        // blocks StickyDeck — unreachable and unquittable. Activate first.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
