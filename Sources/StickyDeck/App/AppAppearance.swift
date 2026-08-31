import Observation
import SwiftUI

/// Observable mirror of the appearance-affecting values in `AppSettings`.
///
/// `AppSettings` stores everything in `UserDefaults` behind static accessors,
/// which SwiftUI cannot track. Every surface that reads one therefore had to be
/// invalidated by hand: the deck view model, the note list model, each sticky
/// draft and the settings window each subscribed to `.appSettingsChanged` and
/// broadcast a manual `objectWillChange`, which redrew whole windows to pick up
/// a font change. Mirroring the values here lets Observation invalidate exactly
/// the views that read them, and there is still a single source of truth: this
/// object never writes, it only follows `AppSettings`.
@MainActor
@Observable
final class AppAppearance {
    static let shared = AppAppearance()

    private(set) var deckEdge: AppSettings.Edge = AppSettings.deckEdge
    private(set) var showOverFullScreen: Bool = AppSettings.showOverFullScreen
    private(set) var animationSpeed: AppSettings.AnimationSpeed = AppSettings.animationSpeed
    private(set) var noteFontName: String = AppSettings.noteFontName
    private(set) var noteFontSize: Double = AppSettings.noteFontSize
    private(set) var syncFolderName: String = AppSettings.syncFolderName
    private(set) var hasSyncFolder: Bool = AppSettings.syncFolderBookmark != nil

    @ObservationIgnored private var observationTask: Task<Void, Never>?

    private init() {
        observationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .appSettingsChanged).map({ _ in () }) {
                self?.refresh()
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    /// The note body face. An empty family means "the system rounded face",
    /// and a family the system cannot resolve falls back to it too, so a font
    /// uninstalled since it was chosen degrades instead of rendering blank.
    var bodyFont: Font {
        Self.font(named: noteFontName, size: noteFontSize)
    }

    /// The body face at a fixed size, for list rows that must keep their
    /// established row height regardless of the chosen note size.
    func bodyFont(size: Double) -> Font {
        Self.font(named: noteFontName, size: size)
    }

    private static func font(named name: String, size: Double) -> Font {
        guard !name.isEmpty, NSFont(name: name, size: size) != nil else {
            return .system(size: size, weight: .regular, design: .rounded)
        }
        return .custom(name, size: size)
    }

    /// Assigning only on a real change keeps Observation from invalidating
    /// views for settings they do not read.
    private func refresh() {
        if deckEdge != AppSettings.deckEdge { deckEdge = AppSettings.deckEdge }
        if showOverFullScreen != AppSettings.showOverFullScreen { showOverFullScreen = AppSettings.showOverFullScreen }
        if animationSpeed != AppSettings.animationSpeed { animationSpeed = AppSettings.animationSpeed }
        if noteFontName != AppSettings.noteFontName { noteFontName = AppSettings.noteFontName }
        if noteFontSize != AppSettings.noteFontSize { noteFontSize = AppSettings.noteFontSize }
        if syncFolderName != AppSettings.syncFolderName { syncFolderName = AppSettings.syncFolderName }
        let hasFolder = AppSettings.syncFolderBookmark != nil
        if hasSyncFolder != hasFolder { hasSyncFolder = hasFolder }
    }
}
