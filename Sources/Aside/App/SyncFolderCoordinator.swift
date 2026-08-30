import AppKit
import Foundation
import Combine

/// Bridges the sync-folder setting to the active store. Resolves the
/// security-scoped bookmark (D22), holds folder access for the lifetime of
/// the selection, and swaps the backing store in the `StoreHub` — local
/// encrypted SQLite when no folder is chosen, `SyncNoteStore` when one is.
/// Swaps post `.noteStoreChanged` via the hub so every observer re-pulls.
@MainActor
final class SyncFolderCoordinator {
    private let hub: StoreHub
    private let localStore: any NoteStore
    private var cancellables: Set<AnyCancellable> = []
    private var lastAppliedBookmark: Data?
    private var accessingURL: URL?

    init(hub: StoreHub, localStore: any NoteStore) {
        self.hub = hub
        self.localStore = localStore
        lastAppliedBookmark = AppSettings.syncFolderBookmark

        NotificationCenter.default.publisher(for: .appSettingsChanged)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyCurrentSetting() }
            .store(in: &cancellables)
    }

    /// Applies the current setting at launch (before this call the hub is
    /// backed by the local store; a valid bookmark swaps to the sync folder).
    func install() {
        apply(bookmark: AppSettings.syncFolderBookmark)
    }

    private func applyCurrentSetting() {
        let bookmark = AppSettings.syncFolderBookmark
        guard bookmark != lastAppliedBookmark else { return }
        apply(bookmark: bookmark)
    }

    private func apply(bookmark: Data?) {
        lastAppliedBookmark = bookmark
        // The outgoing folder's scope is handed to the swap instead of being
        // dropped here: the swap is asynchronous, so until it lands the hub
        // still routes writes to the old store and revoking access first
        // fails any autosave already in flight.
        let outgoing = accessingURL
        accessingURL = nil

        guard let bookmark else {
            swapBacking(to: localStore, releasing: outgoing)
            return
        }

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            // If access cannot be granted (scope lost), treat the folder as
            // unavailable rather than failing every write later.
            guard url.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            accessingURL = url

            let syncStore = try SyncNoteStore(folder: url)
            swapBacking(to: syncStore, releasing: outgoing)
        } catch {
            // The bookmark could not be resolved (folder moved/deleted, or
            // scope lost): stay on local storage and let the user re-pick.
            // Nothing was ever swapped onto the new folder, so any scope we
            // took for it can go right away.
            releaseAccess()
            presentUnavailabilityError(error)
            AppSettings.syncFolderBookmark = nil
            AppSettings.syncFolderName = ""
            swapBacking(to: localStore, releasing: outgoing)
        }
    }

    private func swapBacking(to store: any NoteStore, releasing previous: URL?) {
        Task {
            await hub.swap(to: store)
            // Only now is the old store unreachable through the hub.
            previous?.stopAccessingSecurityScopedResource()
        }
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
        Aside could not open the sync folder (\(error.localizedDescription)). \
        Notes stay on this Mac until you choose a folder again in Settings.
        """
        // `runModal` orders the alert front *within* the app but does not
        // activate an accessory (LSUIElement) app, so at launch this alert can
        // sit invisibly behind the frontmost app while its modal run loop
        // blocks Aside — unreachable and unquittable. Activate first.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
