import Foundation

extension Notification.Name {
    static let noteStoreChanged = Notification.Name("Aside.noteStoreChanged")
    static let appSettingsChanged = Notification.Name("Aside.appSettingsChanged")
    static let openAllNotesRequested = Notification.Name("Aside.openAllNotesRequested")
    static let openArchiveRequested = Notification.Name("Aside.openArchiveRequested")
    static let openSettingsRequested = Notification.Name("Aside.openSettingsRequested")
    /// Posted once before the app terminates so surfaces that own their own
    /// debounced drafts can write them out.
    static let appWillTerminate = Notification.Name("Aside.appWillTerminate")
}
