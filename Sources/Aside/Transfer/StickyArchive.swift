import Foundation

enum StickyArchiveError: LocalizedError {
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let detail):
            return "Not an Aside sticky archive (\(detail))."
        }
    }
}

/// The .stickies archive: a portable JSON document carrying colors, states
/// and dates so an export can round-trip without loss.
struct StickyArchive: Codable, Sendable {
    var format = "edge-notes-stickies"
    var version = 1
    var exportedAt: Date
    var notes: [StickiedNote]

    init(notes: [StickiedNote]) {
        exportedAt = Date()
        self.notes = notes
    }
}

struct StickiedNote: Codable, Sendable {
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

    init(note: Note) {
        id = note.id
        title = note.title
        body = note.body
        colorIndex = note.colorIndex
        tag = note.tag
        pinned = note.pinned
        sortIndex = note.sortIndex
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        archivedAt = note.archivedAt
        deletedAt = note.deletedAt
    }

    var note: Note {
        Note(
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
}

extension StickyArchive {
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> StickyArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StickyArchive.self, from: data)
    }
}
