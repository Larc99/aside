import Foundation
import Darwin

/// Raised when the thing at a note's path is not a plain file — a directory,
/// a symlink, a device node. StickyDeck never writes over or deletes those:
/// `removeItem` would take a whole directory tree with it, and an atomic
/// write would replace a symlink with a regular file and orphan its target.
enum SyncStoreError: Error, LocalizedError {
    case unexpectedFileShape(URL)

    var errorDescription: String? {
        switch self {
        case .unexpectedFileShape(let url):
            return "“\(url.lastPathComponent)” in the sync folder isn’t a note file, so it was left alone."
        }
    }
}

/// Sync-folder store: one Markdown file per note (`<uuid>.md` with a
/// versioned frontmatter block), written atomically so file providers
/// (iCloud Drive et al.) never sync a half-written note. Two Macs never
/// fight over the same file because the filename is the note's UUID;
/// conflicting edits resolve last-writer-wins on `updatedAt`.
///
/// Deletes are written as tombstones (`deletedAt` in the file) so the
/// deletion propagates to other machines; `purge` removes the file.
/// Inbound changes from other machines are picked up by a directory
/// watcher and surfaced through `.noteStoreChanged`.
///
/// Only files named `<uuid>.md` are adopted; arbitrary Markdown dropped
/// into the folder is left untouched (importing foreign files is
/// TransferService's job).
actor SyncNoteStore: NoteStore {
    private let folder: URL
    private var source: DispatchSourceFileSystemObject? = nil
    private var debounceTask: Task<Void, Never>? = nil
    private var rearmTask: Task<Void, Never>? = nil
    private var pollTask: Task<Void, Never>? = nil
    /// Hard deadline for the current burst of watcher events, so a continuous
    /// stream cannot postpone the import forever. See `scheduleImport`.
    private var burstDeadline: Date? = nil
    private var lastSnapshot: [Note] = []
    private var lastFingerprint: [String: String] = [:]

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Priming is deliberately deferred. `loadAll` enumerates the folder and
        // reads every file, which on an iCloud folder with evicted files
        // triggers on-demand downloads — and this initialiser is called from
        // the main actor, so doing it here beachballs launch.
        Task { [weak self] in await self?.primeAndArmWatcher() }
    }

    deinit {
        debounceTask?.cancel()
        rearmTask?.cancel()
        pollTask?.cancel()
        source?.cancel()
    }

    // MARK: - NoteStore

    func fetch(filter: NoteFilter, query: String) async throws -> [Note] {
        Self.apply(filter: filter, query: query, to: try Self.loadAll(folder: folder))
    }

    func allKnownIDs() async throws -> Set<UUID> {
        // Tombstoned notes keep their file, so this covers soft-deleted ids too.
        // Throws rather than reporting an empty set: see `loadAll`.
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return Set(names.compactMap { name in
            guard name.hasSuffix(".\(Self.fileExtension)") else { return nil }
            return UUID(uuidString: String(name.dropLast(Self.fileExtension.count + 1)))
        })
    }

    func upsert(_ note: Note) async throws {
        let url = Self.fileURL(for: note.id, folder: folder)
        var note = note
        switch Self.readStored(at: url) {
        case .missing:
            break
        case .unexpectedShape:
            // A directory, a symlink, a device node. Overwriting it would
            // destroy something we do not own (an atomic write replaces a
            // symlink with a plain file and orphans its target).
            throw SyncStoreError.unexpectedFileShape(url)
        case .unreadable:
            // The file is there but we cannot parse it — another editor
            // rewrote it, or it is still being written. We have no timestamp
            // to compare against, so overwriting it would clobber content
            // last-writer-wins is supposed to protect. Report it as a
            // conflict: `DeckViewModel.persist` reloads on `.staleWrite`.
            throw NoteStoreError.staleWrite
        case .note(let existing):
            // Last-writer-wins: a remote file that is strictly newer than the
            // incoming note stays untouched (its change arrives via the
            // watcher). This is reported, not swallowed — returning success
            // here made undo silently fail and let clock skew discard edits
            // while the editor still said "Saved".
            if existing.updatedAt > note.updatedAt {
                guard Self.isImplausiblyFuture(existing.updatedAt) else {
                    throw NoteStoreError.staleWrite
                }
                note.updatedAt = Self.stamp(after: existing.updatedAt)
            }
        }
        try Self.write(note, to: url)
        absorbSnapshot()
    }

    func softDelete(id: UUID) async throws {
        try await stampInPlace(id: id) { $0.deletedAt = Date() }
    }

    func restore(id: UUID) async throws {
        try await stampInPlace(id: id) { $0.deletedAt = nil }
    }

    func purge(id: UUID) async throws {
        // An unreadable folder is not an empty one: without this, purging a
        // note on an unmounted volume "succeeded" and left the file behind.
        try Self.requireReadableFolder(folder)
        let url = Self.fileURL(for: id, folder: folder)
        switch Self.shape(at: url) {
        case .none:
            // Already gone — that is the desired end state, and nothing
            // changed, so observers have nothing to hear about.
            return
        case .regularFile:
            try FileManager.default.removeItem(at: url)
        case .other:
            // `removeItem` deletes a directory *recursively*, so a stray
            // `<uuid>.md` folder would take everything under it with it.
            throw SyncStoreError.unexpectedFileShape(url)
        }
        absorbSnapshot()
    }

    /// Shared body of `softDelete`/`restore`: re-reads the stored copy, lets
    /// `mutate` change the state fields, and re-stamps `updatedAt`.
    ///
    /// These used to skip every guard `upsert` applies, which meant a
    /// vanished folder made them silent no-ops and an unparseable file was
    /// treated as an absent one. The policy is now uniform across all three
    /// writers.
    private func stampInPlace(id: UUID, _ mutate: (inout Note) -> Void) async throws {
        try Self.requireReadableFolder(folder)
        let url = Self.fileURL(for: id, folder: folder)
        switch Self.readStored(at: url) {
        case .missing:
            // Nothing to tombstone or revive; the note is genuinely not here.
            return
        case .unexpectedShape:
            throw SyncStoreError.unexpectedFileShape(url)
        case .unreadable:
            throw NoteStoreError.staleWrite
        case .note(var note):
            mutate(&note)
            note.updatedAt = Self.stamp(after: note.updatedAt)
            try Self.write(note, to: url)
            absorbSnapshot()
        }
    }

    // MARK: - Snapshot / observation

    /// Records the on-disk state as already-seen so the watcher does not
    /// echo our own writes back to observers.
    private func absorbSnapshot() {
        reloadSnapshot()
        postChanged()
    }

    /// Re-reads the folder and reports whether the loaded set actually
    /// changed. An unreadable folder leaves the last known snapshot in place:
    /// an unmounted volume is not "every note was deleted".
    @discardableResult
    private func reloadSnapshot() -> Bool {
        guard let notes = try? Self.loadAll(folder: folder) else { return false }
        lastFingerprint = Self.fingerprint(folder: folder)
        guard notes != lastSnapshot else { return false }
        lastSnapshot = notes
        return true
    }

    private func importExternalChanges() {
        guard reloadSnapshot() else { return }
        postChanged()
    }

    private func postChanged() {
        NotificationCenter.default.post(name: .noteStoreChanged, object: nil)
    }

    // MARK: - Directory watcher

    private func primeAndArmWatcher() {
        reloadSnapshot()
        armWatcher()
        // Anything that landed between that baseline read and the watcher
        // arming produced no event and is already absorbed as "seen", so it
        // would never be announced — the wider the folder, the wider that
        // window. Read once more now that we are listening.
        importExternalChanges()
        startPolling()
    }

    /// Opens a vnode source on the folder, retrying with backoff while the
    /// path is momentarily absent (renamed, replaced, a volume remounting).
    /// A single failed attempt used to leave `source` nil forever, and
    /// `watcherFired` — the only thing that re-armed — could then never run
    /// again, so the store went permanently deaf. The reconciliation poll is
    /// the final backstop once the retries are spent.
    private func armWatcher(attempt: Int = 0) {
        rearmTask?.cancel()
        rearmTask = nil
        source = Self.makeWatcher(on: folder) { [weak self] in
            Task { await self?.watcherFired() }
        }
        guard source == nil, attempt < Self.rearmAttempts else { return }
        let delay = Self.rearmBackoff(attempt: attempt)
        rearmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            await self?.armWatcher(attempt: attempt + 1)
        }
    }

    /// Low-frequency safety net. A directory vnode source fires when entries
    /// appear or disappear, not when a file's bytes change in place — our own
    /// writes are atomic (temp + rename) so they register, but another editor
    /// or a file provider writing in place produces no event at all. This
    /// compares a stat-only fingerprint (no file contents, so no iCloud
    /// downloads) and only pays for a real read when it differs.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard !Task.isCancelled else { return }
                await self?.reconcile()
            }
        }
    }

    private func reconcile() {
        // Also the last line of defence for a watcher that never came back.
        if source == nil { armWatcher() }
        guard Self.fingerprint(folder: folder) != lastFingerprint else { return }
        importExternalChanges()
    }

    /// Builds (and resumes) a vnode source on the folder. Nonisolated so any
    /// context can construct one; assigning the result to `source` is the
    /// caller's job.
    nonisolated private static func makeWatcher(
        on folder: URL,
        eventHandler: @escaping @Sendable () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue(label: "StickyDeck.sync-folder-watcher", qos: .utility)
        )
        source.setEventHandler(handler: eventHandler)
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    private func watcherFired() {
        if let source, source.data.contains(.delete) || source.data.contains(.rename) {
            // The watched folder itself went away (moved/replaced) — re-arm
            // on the current path so live updates resume.
            source.cancel()
            self.source = nil
            armWatcher()
        }
        scheduleImport()
    }

    /// Coalesces a burst of events into one import, but never past
    /// `maxImportDelay`. Cancelling the pending task on every event meant a
    /// stream arriving faster than the debounce — exactly what an initial
    /// iCloud download looks like — never fired at all, so nothing appeared
    /// until the download finished.
    private func scheduleImport() {
        let now = Date()
        let deadline = burstDeadline ?? now.addingTimeInterval(Self.maxImportDelay)
        burstDeadline = deadline
        let delay = max(0, min(Self.importDebounce, deadline.timeIntervalSince(now)))
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flushImport()
        }
    }

    private func flushImport() {
        burstDeadline = nil
        importExternalChanges()
    }

    // MARK: - Watcher tuning

    private static let importDebounce: TimeInterval = 0.25
    private static let maxImportDelay: TimeInterval = 1.0
    private static let pollInterval: TimeInterval = 15
    private static let rearmAttempts = 6

    /// 100 ms, 200, 400, … capped — long enough to outlast a folder being
    /// swapped underneath us, short enough that the user never notices.
    private static func rearmBackoff(attempt: Int) -> Int {
        min(100 << min(attempt, 5), 3_000)
    }

    // MARK: - Disk format

    private static let fileExtension = "md"
    private static let formatVersion = 1
    private static let formatKey = "stickyDeck"
    // The app has been renamed twice. Sync-folder files live in the user's own
    // folder, outside the container, so they outlive every rename and each old
    // key has to keep loading. New writes always use the current key.
    private static let legacyFormatKeys = ["aside", "edgeNotes"]

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func fileURL(for id: UUID, folder: URL) -> URL {
        folder.appendingPathComponent("\(id.uuidString).\(fileExtension)")
    }

    /// Enumerates the folder and reads every note file.
    ///
    /// Throws when the *folder* cannot be read. Swallowing that error made an
    /// unmounted volume or an evicted iCloud folder indistinguishable from an
    /// empty library: `fetch` returned nothing, callers could not find the
    /// note they were editing and dropped the write without telling anyone.
    /// An individual unreadable *file* is still skipped — one bad file must
    /// not blank the whole list.
    nonisolated private static func loadAll(folder: URL) throws -> [Note] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        var notes: [Note] = []
        for name in names where name.hasSuffix(".\(fileExtension)") {
            let stem = String(name.dropLast(fileExtension.count + 1))
            guard UUID(uuidString: stem) != nil,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let note = parse(data) else { continue }
            notes.append(note)
        }
        return notes
    }

    /// Throws if the folder cannot be enumerated right now. Callers that would
    /// otherwise treat "no file at that path" as "nothing to do" use this
    /// first, so a vanished folder is an error instead of a silent no-op.
    nonisolated private static func requireReadableFolder(_ folder: URL) throws {
        _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    /// What sits at a note's path. `unreadable` is deliberately *not* folded
    /// into `missing`: a file that exists but cannot be parsed still holds a
    /// user's content, and treating it as absent skipped the last-writer-wins
    /// check and let the next write overwrite it unconditionally.
    private enum StoredFile {
        case missing
        case note(Note)
        case unreadable
        case unexpectedShape
    }

    nonisolated private static func readStored(at url: URL) -> StoredFile {
        switch shape(at: url) {
        case .none: return .missing
        case .other: return .unexpectedShape
        case .regularFile:
            guard let data = try? Data(contentsOf: url), let note = parse(data) else {
                return .unreadable
            }
            return .note(note)
        }
    }

    private enum FileShape {
        case regularFile
        case other
    }

    /// `attributesOfItem` does not follow symlinks, so a symlink reports as
    /// itself rather than as its target — which is the point: we must not
    /// replace or delete anything that is not a plain file.
    nonisolated private static func shape(at url: URL) -> FileShape? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.type] as? FileAttributeType) == .typeRegular ? .regularFile : .other
    }

    /// Writes a note over its own file, atomically so a file provider never
    /// syncs a half-written note.
    nonisolated private static func write(_ note: Note, to url: URL) throws {
        try serialize(note).write(to: url, options: .atomic)
    }

    /// Stat-only view of the folder (name → size/mtime). Used by the
    /// reconciliation poll: it never opens a file, so it costs one `readdir`
    /// plus a `stat` per entry and cannot trigger an iCloud download.
    nonisolated private static func fingerprint(folder: URL) -> [String: String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]
        ) else { return [:] }

        var result: [String: String] = [:]
        for url in urls where url.lastPathComponent.hasSuffix(".\(fileExtension)") {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let size = values?.fileSize ?? 0
            result[url.lastPathComponent] = "\(modified)/\(size)"
        }
        return result
    }

    // MARK: - Clock skew

    /// How far ahead of our clock a stored timestamp may be and still be
    /// believed. Peers' clocks disagree by seconds, not minutes.
    private static let clockSkewTolerance: TimeInterval = 120

    /// A file synced from a Mac whose clock runs fast is stamped in our
    /// future, so every edit we make — stamped `Date()` — loses
    /// last-writer-wins and the note becomes permanently uneditable: the
    /// write throws `.staleWrite` and the deck reloads the old text over the
    /// user's typing. A timestamp that far ahead is not a real edit from the
    /// future, so it does not get to win.
    nonisolated private static func isImplausiblyFuture(_ date: Date) -> Bool {
        date > Date().addingTimeInterval(clockSkewTolerance)
    }

    /// The stamp for a write that deliberately replaces `previous`. Normally
    /// just now — but when `previous` is a future timestamp we chose to
    /// override, stamping an older time would let the same file win again on
    /// the next comparison, here and on every other Mac. Nudging past it
    /// keeps "this is the newer intent" true everywhere.
    nonisolated private static func stamp(after previous: Date) -> Date {
        max(Date(), previous.addingTimeInterval(0.001))
    }

    /// Internal (not private) so the test target can stage files in the
    /// store's exact on-disk format.
    nonisolated static func serialize(_ note: Note) -> Data {
        var lines = ["---"]
        lines.append("\(formatKey): \(formatVersion)")
        lines.append("id: \(quote(note.id.uuidString))")
        lines.append("title: \(quote(note.title))")
        lines.append("colorIndex: \(note.colorIndex)")
        lines.append("tag: \(quote(note.tag))")
        lines.append("pinned: \(note.pinned ? "true" : "false")")
        lines.append("sortIndex: \(note.sortIndex)")
        lines.append("createdAt: \(quote(dateFormatter.string(from: note.createdAt)))")
        lines.append("updatedAt: \(quote(dateFormatter.string(from: note.updatedAt)))")
        lines.append("archivedAt: \(optionalDate(note.archivedAt))")
        lines.append("deletedAt: \(optionalDate(note.deletedAt))")
        lines.append("---")
        let text = lines.joined(separator: "\n") + "\n" + note.body
        return Data(text.utf8)
    }

    nonisolated private static func parse(_ data: Data) -> Note? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Normalise CRLF first: an editor on the other end of the sync folder
        // that saves Windows line endings turns the fence into "---\r", and
        // the note then vanished from `fetch` while its id stayed "known".
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard lines.first == "---",
              let closing = lines.dropFirst().firstIndex(of: "---") else { return nil }

        let header = lines[1..<closing]
        let body = lines[(closing + 1)...].joined(separator: "\n")

        var id: UUID?
        var title = ""
        var colorIndex = 0
        var tag = ""
        var pinned = false
        var sortIndex = 0
        var createdAt = Date()
        var updatedAt = Date()
        var archivedAt: Date?
        var deletedAt: Date?
        var sawFormat = false

        for line in header {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case formatKey: sawFormat = Int(value) == formatVersion
            case let key where legacyFormatKeys.contains(key):
                sawFormat = Int(value) == formatVersion
            case "id": id = UUID(uuidString: unquote(value))
            case "title": title = unquote(value)
            case "colorIndex": colorIndex = Int(value) ?? 0
            case "tag": tag = unquote(value)
            case "pinned": pinned = value == "true"
            case "sortIndex": sortIndex = Int(value) ?? 0
            case "createdAt": createdAt = date(value) ?? Date()
            case "updatedAt": updatedAt = date(value) ?? Date()
            case "archivedAt": archivedAt = optionalDate(value)
            case "deletedAt": deletedAt = optionalDate(value)
            default: break
            }
        }

        guard sawFormat, let id else { return nil }
        return Note(
            id: id,
            title: title,
            body: body,
            colorIndex: colorIndex,
            tag: tag,
            pinned: pinned,
            sortIndex: sortIndex,
            createdAt: createdAt,
            updatedAt: updatedAt,
            archivedAt: archivedAt,
            deletedAt: deletedAt
        )
    }

    // MARK: - Field encoding

    nonisolated private static func quote(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    nonisolated private static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        let inner = value.dropFirst().dropLast()
        var output = ""
        var iterator = inner.makeIterator()
        while let character = iterator.next() {
            if character == "\\" {
                guard let next = iterator.next() else { break }
                switch next {
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                default: output.append(next)
                }
            } else {
                output.append(character)
            }
        }
        return output
    }

    nonisolated private static func optionalDate(_ date: Date?) -> String {
        guard let date else { return "null" }
        return quote(dateFormatter.string(from: date))
    }

    nonisolated private static func optionalDate(_ value: String) -> Date? {
        value == "null" ? nil : date(value)
    }

    nonisolated private static func date(_ value: String) -> Date? {
        dateFormatter.date(from: unquote(value))
    }

    // MARK: - Query semantics (mirrors LocalNoteStore)

    nonisolated private static func apply(filter: NoteFilter, query: String, to notes: [Note]) -> [Note] {
        var result = notes.filter { $0.deletedAt == nil }
        if filter == .active { result = result.filter { $0.archivedAt == nil } }
        if filter == .archived { result = result.filter { $0.archivedAt != nil } }
        if !query.isEmpty {
            result = result.filter { $0.matches(query: query) }
        }
        return result.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.createdAt > $1.createdAt
        }
    }
}
