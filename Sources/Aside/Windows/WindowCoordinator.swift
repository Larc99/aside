import AppKit
import SwiftUI
import Combine

/// Lazily creates and fronts the All Notes and Archive windows. Opening any
/// window activates the app so controls and text fields are interactive even
/// though the app is accessory (LSUIElement).
@MainActor
final class WindowCoordinator {
    private let store: any NoteStore
    private var allNotesController: NoteListWindowController?
    private var archiveController: NoteListWindowController?

    init(store: any NoteStore) {
        self.store = store

        NotificationCenter.default
            .publisher(for: .openAllNotesRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showAllNotes() }
            .store(in: &observers)

        NotificationCenter.default
            .publisher(for: .openArchiveRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showArchive() }
            .store(in: &observers)
    }

    private var observers: Set<AnyCancellable> = []

    func showAllNotes() {
        let controller = allNotesController ?? NoteListWindowController(
            store: store,
            mode: .all,
            title: "All Notes"
        )
        allNotesController = controller
        controller.showAndActivate()
    }

    func showArchive() {
        let controller = archiveController ?? NoteListWindowController(
            store: store,
            mode: .archive,
            title: "Archive"
        )
        archiveController = controller
        controller.showAndActivate()
    }
}
