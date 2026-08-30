import Foundation

struct Note: Identifiable, Equatable, Sendable, Hashable {
    var id: UUID
    var title: String
    var body: String
    var colorIndex: Int
    var tag: String
    var pinned: Bool
    var sortIndex: Int
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    var deletedAt: Date?

    /// True when the stored body could not be decrypted, so `body` is a
    /// placeholder rather than the user's text. Stores must never overwrite
    /// the stored ciphertext from such a note — an incidental edit (colour,
    /// pin, archive) would otherwise destroy recoverable content. Never
    /// persisted; it describes this in-memory copy only.
    var bodyUnavailable: Bool = false

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        colorIndex: Int = 0,
        tag: String = "",
        pinned: Bool = false,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil,
        deletedAt: Date? = nil,
        bodyUnavailable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.colorIndex = colorIndex
        self.tag = tag
        self.pinned = pinned
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
        self.bodyUnavailable = bodyUnavailable
    }

    var isActive: Bool { archivedAt == nil && deletedAt == nil }
    var isArchived: Bool { archivedAt != nil && deletedAt == nil }

    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return title.lowercased().contains(q)
            || body.lowercased().contains(q)
            || tag.lowercased().contains(q)
    }
}

enum NoteFilter: String, CaseIterable, Sendable {
    case all
    case active
    case archived
}
