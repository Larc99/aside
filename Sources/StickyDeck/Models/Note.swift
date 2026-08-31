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

    /// True only for an old encrypted row whose plaintext has not been
    /// recovered yet. A draft loaded in that window carries an empty body, so
    /// writers use this marker to keep the placeholder from erasing text that
    /// the background migration recovers moments later. It is transient and
    /// can disappear with `bodyEnc` after the compatibility migration retires.
    var bodyNeedsMigration: Bool = false

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
        bodyNeedsMigration: Bool = false
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
        self.bodyNeedsMigration = bodyNeedsMigration
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
