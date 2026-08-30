import Foundation

/// User-facing settings. Mutations post `.appSettingsChanged` so live surfaces
/// (deck panels, editor, settings window) can react without restarts.
enum AppSettings {
    enum Edge: String, CaseIterable, Sendable {
        case left
        case right
    }

    enum AnimationSpeed: String, CaseIterable, Sendable {
        case brisk
        case normal
        case gentle

        var staggerFactor: Double {
            switch self {
            case .brisk: return 0.7
            case .normal: return 1.0
            case .gentle: return 1.6
            }
        }
    }

    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let deckEdge = "deckEdge"
        static let showOverFullScreen = "showOverFullScreen"
        static let animationSpeed = "animationSpeed"
        static let noteFontName = "noteFontName"
        static let noteFontSize = "noteFontSize"
        static let noteCardOffsetY = "noteCardOffsetY"
        static let syncFolderBookmark = "syncFolderBookmark"
        static let syncFolderName = "syncFolderName"
    }

    static var deckEdge: Edge {
        get { Edge(rawValue: defaults.string(forKey: Keys.deckEdge) ?? "") ?? .right }
        set { set(newValue.rawValue, forKey: Keys.deckEdge) }
    }

    static var showOverFullScreen: Bool {
        get { defaults.bool(forKey: Keys.showOverFullScreen) }
        set { set(newValue, forKey: Keys.showOverFullScreen) }
    }

    static var animationSpeed: AnimationSpeed {
        get { AnimationSpeed(rawValue: defaults.string(forKey: Keys.animationSpeed) ?? "") ?? .normal }
        set { set(newValue.rawValue, forKey: Keys.animationSpeed) }
    }

    /// Empty string means "use the system rounded face".
    static var noteFontName: String {
        get { defaults.string(forKey: Keys.noteFontName) ?? "Caveat" }
        set { set(newValue, forKey: Keys.noteFontName) }
    }

    static var noteFontSize: Double {
        get { defaults.double(forKey: Keys.noteFontSize) == 0 ? 19 : defaults.double(forKey: Keys.noteFontSize) }
        set { set(newValue, forKey: Keys.noteFontSize) }
    }

    /// Last vertical position of the expanded card relative to the centered
    /// deck slot. This preserves where the user left the note between opens.
    static var noteCardOffsetY: Double {
        get { defaults.double(forKey: Keys.noteCardOffsetY) }
        set { set(newValue, forKey: Keys.noteCardOffsetY) }
    }

    /// Security-scoped bookmark for the sync folder (D22). `nil` means
    /// "this Mac only": notes live in the encrypted local SQLite store.
    /// Resolution and store swapping are `SyncFolderCoordinator`'s job.
    static var syncFolderBookmark: Data? {
        get { defaults.data(forKey: Keys.syncFolderBookmark) }
        set { set(newValue, forKey: Keys.syncFolderBookmark) }
    }

    /// Human-readable label for the sync folder (mirrors the bookmark for
    /// display in Settings without resolving it).
    static var syncFolderName: String {
        get { defaults.string(forKey: Keys.syncFolderName) ?? "" }
        set { set(newValue, forKey: Keys.syncFolderName) }
    }

    private static func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .appSettingsChanged, object: nil)
    }
}
