import Foundation

extension Notification.Name {
    static let noteStoreChanged = Notification.Name("StickyDeck.noteStoreChanged")
    /// Posted only when StoreHub changes which independent library is active.
    /// Ordinary note saves use `noteStoreChanged` alone.
    static let noteStoreBackingChanged = Notification.Name("StickyDeck.noteStoreBackingChanged")
    static let appSettingsChanged = Notification.Name("StickyDeck.appSettingsChanged")
    static let openAllNotesRequested = Notification.Name("StickyDeck.openAllNotesRequested")
    static let openArchiveRequested = Notification.Name("StickyDeck.openArchiveRequested")
    static let openSettingsRequested = Notification.Name("StickyDeck.openSettingsRequested")
    /// Posted once before the app terminates so surfaces that own their own
    /// debounced drafts can write them out.
    static let appWillTerminate = Notification.Name("StickyDeck.appWillTerminate")
}
