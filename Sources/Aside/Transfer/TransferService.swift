import AppKit
import Foundation
import UniformTypeIdentifiers

/// Export/import of notes. Export shapes: one .md per note, one .txt per
/// note, a single combined file, and a .stickies archive that keeps colors,
/// states and dates. Import reads .stickies archives and readable note files
/// (.md/.txt — first heading/line becomes the title per D7); imported notes
/// arrive active.
enum ExportShape: Equatable {
    case markdownPerNote
    case textPerNote
    case singleFile
    case stickyArchive
}

@MainActor
enum TransferService {
    static func export(notes: [Note], shape: ExportShape) async {
        switch shape {
        case .markdownPerNote:
            guard let folder = await chooseFolder() else { return }
            presentExportFailures(writePerNote(notes, folder: folder, ext: "md", content: { markdown($0) }))
        case .textPerNote:
            guard let folder = await chooseFolder() else { return }
            presentExportFailures(writePerNote(notes, folder: folder, ext: "txt", content: { plain($0) }))
        case .singleFile:
            guard let url = await savePanel(
                name: "Notes",
                ext: "md",
                prompt: "Export \(notes.count) notes to one document"
            ) else { return }
            let text = notes.map(markdown).joined(separator: "\n\n---\n\n")
            presentExportFailures(attempt(url.lastPathComponent) {
                try text.write(to: url, atomically: true, encoding: .utf8)
            })
        case .stickyArchive:
            guard let url = await savePanel(
                name: "Notes",
                ext: "stickies",
                prompt: "Export a sticky archive (colors, states and dates kept)"
            ) else { return }
            let archive = StickyArchive(notes: notes.map(StickiedNote.init))
            presentExportFailures(attempt(url.lastPathComponent) {
                try archive.encoded().write(to: url, options: .atomic)
            })
        }
    }

    static func importNotes(into store: any NoteStore) async {
        guard let url = await openPanel() else { return }
        do {
            let data = try Data(contentsOf: url)

            let incoming: [Note]
            let preservesArchiveState: Bool
            switch importKind(of: url) {
            case .markdown:
                guard let note = markdownNote(from: data) else {
                    presentImportError(readFailure(for: data, name: url.lastPathComponent))
                    return
                }
                incoming = [note]
                preservesArchiveState = false
            case .plainText:
                guard let note = plainTextNote(from: data) else {
                    presentImportError(readFailure(for: data, name: url.lastPathComponent))
                    return
                }
                incoming = [note]
                preservesArchiveState = false
            case .archive:
                let archive = try StickyArchive.decoded(from: data)
                guard archive.format == "edge-notes-stickies", archive.version <= 1 else {
                    presentImportError(
                        StickyArchiveError.unsupportedFormat(
                            "format=\(archive.format) version=\(archive.version)"
                        )
                    )
                    return
                }
                incoming = archive.notes.map(\.note)
                preservesArchiveState = true
            }

            guard !incoming.isEmpty else {
                // A well-formed archive that carries no notes: say so rather
                // than close the panel as if the import had worked.
                presentImportError(ImportReadError.empty(url.lastPathComponent))
                return
            }
            // Every id, soft-deleted rows included: `fetch` hides trashed
            // notes, so collisions with them used to overwrite and un-delete
            // instead of appending a distinct copy.
            let existingIDs = try await store.allKnownIDs()

            for note in prepareIncoming(
                incoming,
                existingIDs: existingIDs,
                preservesArchiveState: preservesArchiveState
            ) {
                try await store.upsert(note)
            }
        } catch {
            presentImportError(error)
        }
    }

    enum ImportReadError: LocalizedError {
        case unreadable(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "\"\(name)\" could not be read as a note."
            case .empty(let name):
                return "\"\(name)\" has nothing in it."
            }
        }
    }

    /// Both note parsers return nil for a file we could not decode at all and
    /// for one that decoded to nothing; the user needs to be told which.
    private static func readFailure(for data: Data, name: String) -> ImportReadError {
        guard let text = String(data: data, encoding: .utf8) else { return .unreadable(name) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .empty(name)
            : .unreadable(name)
    }

    // MARK: - File type dispatch

    private enum ImportKind {
        case markdown
        case plainText
        case archive
    }

    /// Markdown as the system knows it; the open panel filters by the same
    /// type, so the two can never drift apart.
    private static let markdownType = UTType(filenameExtension: "md") ?? .plainText

    /// Dispatches on the file's actual type rather than a literal extension.
    /// The panel offers whole UTI families (any Markdown or plain-text file,
    /// however it is named), so matching on "md"/"txt" dropped valid choices
    /// into the archive branch, where they failed as malformed JSON.
    private static func importKind(of url: URL) -> ImportKind {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return .archive }
        if type.conforms(to: markdownType) { return .markdown }
        if type.conforms(to: .plainText) { return .plainText }
        // `.stickies` has no declared type and JSON is not plain text, so
        // both land here — the archive reader is the right default.
        return .archive
    }

    /// `.stickies` is the lossless format: colors, pinned/archive state and
    /// dates survive a round trip. Plain note files have no state metadata and
    /// therefore arrive active. ID collisions always append a distinct note.
    nonisolated static func prepareIncoming(
        _ incoming: [Note],
        existingIDs: Set<UUID>,
        preservesArchiveState: Bool
    ) -> [Note] {
        incoming.map { original in
            var note = original
            if !preservesArchiveState {
                note.archivedAt = nil
                note.deletedAt = nil
                note.pinned = false
            }
            if existingIDs.contains(note.id) {
                note.id = UUID()
            }
            return note
        }
    }

    // MARK: - Note-file parsing (D7: first heading ⇄ title)

    /// Parses a Markdown note: the first heading line becomes the title,
    /// everything else (minus surrounding blank lines) the body.
    nonisolated static func markdownNote(from data: Data) -> Note? {
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var title = ""
        var foundHeading = false
        var bodyLines: [String] = []

        for line in text.components(separatedBy: "\n") {
            if !foundHeading {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    title = String(trimmed.drop(while: { $0 == "#" || $0 == " " }))
                    foundHeading = true
                    continue
                }
                if trimmed.isEmpty && bodyLines.isEmpty { continue }
            }
            bodyLines.append(line)
        }

        while let first = bodyLines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            bodyLines.removeFirst()
        }
        while let last = bodyLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            bodyLines.removeLast()
        }

        return Note(title: title, body: bodyLines.joined(separator: "\n"))
    }

    /// Parses a plain-text note: the first non-blank line becomes the title.
    nonisolated static func plainTextNote(from data: Data) -> Note? {
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let lines = text.components(separatedBy: "\n")
        guard let titleIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }

        let title = lines[titleIndex].trimmingCharacters(in: .whitespaces)
        var bodyLines = Array(lines.dropFirst(titleIndex + 1))
        while let first = bodyLines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            bodyLines.removeFirst()
        }
        while let last = bodyLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            bodyLines.removeLast()
        }

        return Note(title: title, body: bodyLines.joined(separator: "\n"))
    }

    // MARK: - File naming

    private static func safeFileName(_ note: Note, ext: String, used: inout Set<String>) -> String {
        var base = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Untitled" }
        let invalid = CharacterSet(charactersIn: "/:*?\"<>|\\")
        base = base.components(separatedBy: invalid).joined(separator: "-")
        var name = "\(base).\(ext)"
        var counter = 2
        while used.contains(name.lowercased()) {
            name = "\(base) \(counter).\(ext)"
            counter += 1
        }
        used.insert(name.lowercased())
        return name
    }

    private static func writePerNote(
        _ notes: [Note],
        folder: URL,
        ext: String,
        content: (Note) -> String
    ) -> [ExportFailure] {
        // Seeded with what the folder already holds: de-duplicating only
        // within this run silently destroyed a pre-existing Groceries.md.
        // Colliding names get the same " 2" suffix a repeat title would.
        var used = Set(existingNames(in: folder))
        var failures: [ExportFailure] = []
        for note in notes {
            let name = safeFileName(note, ext: ext, used: &used)
            failures += attempt(name) {
                try content(note).write(
                    to: folder.appendingPathComponent(name),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        return failures
    }

    private static func existingNames(in folder: URL) -> [String] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )
        return (contents ?? []).map { $0.lastPathComponent.lowercased() }
    }

    // MARK: - Write failures

    private struct ExportFailure {
        let name: String
        let error: Error
    }

    /// Runs one write, turning a thrown error into a reportable failure. The
    /// old `try?` discarded them, so a too-long name or a full disk produced
    /// a silently partial export.
    private static func attempt(_ name: String, _ write: () throws -> Void) -> [ExportFailure] {
        do {
            try write()
            return []
        } catch {
            return [ExportFailure(name: name, error: error)]
        }
    }

    private static func presentExportFailures(_ failures: [ExportFailure]) {
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1
            ? "One file could not be written"
            : "\(failures.count) files could not be written"
        var detail = failures.prefix(5)
            .map { "\($0.name): \($0.error.localizedDescription)" }
            .joined(separator: "\n")
        if failures.count > 5 {
            detail += "\n…and \(failures.count - 5) more."
        }
        alert.informativeText = detail
        activateForAlert()
        alert.runModal()
    }

    // MARK: - Content rendering

    nonisolated static func markdown(_ note: Note) -> String {
        var text = "# \(note.title.isEmpty ? "Untitled" : note.title)\n\n"
        if !note.body.isEmpty { text += note.body + "\n" }
        return text
    }

    nonisolated static func plain(_ note: Note) -> String {
        "\(note.title.isEmpty ? "Untitled" : note.title)\n\n\(note.body)"
    }

    // MARK: - Panels

    private static func chooseFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to write the note files"
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    private static func savePanel(name: String, ext: String, prompt: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).\(ext)"
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        panel.message = prompt
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    private static func openPanel() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .stickies archive or a note file (.md, .txt) to import"
        let stickiesType = UTType(filenameExtension: "stickies") ?? .json
        panel.allowedContentTypes = [stickiesType, .json, markdownType, .plainText]
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    private static func presentImportError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = importHeading(for: error)
        alert.informativeText = error.localizedDescription
        activateForAlert()
        alert.runModal()
    }

    /// "Nothing to import" was shown for every failure, including files that
    /// could not be opened at all — the heading now names what happened so the
    /// user knows whether to fix the file, convert it, or pick another one.
    private static func importHeading(for error: Error) -> String {
        switch error {
        case let read as ImportReadError:
            if case .empty = read { return "Nothing to import" }
            return "That file could not be read"
        case is StickyArchiveError, is DecodingError:
            return "Unsupported file format"
        default:
            return "That file could not be read"
        }
    }

    /// `runModal` orders an alert front *within* the app but does not activate
    /// an accessory (LSUIElement) app: without this the alert can sit behind
    /// the frontmost app while its modal run loop blocks Aside — invisible
    /// and unquittable.
    private static func activateForAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
