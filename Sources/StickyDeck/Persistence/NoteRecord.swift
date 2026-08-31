import Foundation
import GRDB

struct NoteRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "note"

    var id: String
    var title: String
    var body: String
    var bodyEnc: Data?
    var colorIndex: Int
    var tag: String
    var pinned: Bool
    var sortIndex: Int
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    var deletedAt: Date?
}

enum NoteRecordError: Error, LocalizedError {
    case invalidIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value):
            return "A stored note has an invalid identifier (\(value)). The database was left unchanged."
        }
    }
}

enum NoteMapper {
    static func record(from note: Note) -> NoteRecord {
        NoteRecord(
            id: note.id.uuidString,
            title: note.title,
            body: note.body,
            bodyEnc: nil,
            colorIndex: note.colorIndex,
            tag: note.tag,
            pinned: note.pinned,
            sortIndex: note.sortIndex,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            archivedAt: note.archivedAt,
            deletedAt: note.deletedAt
        )
    }

    static func note(from record: NoteRecord) throws -> Note {
        guard let id = UUID(uuidString: record.id) else {
            // Inventing a new UUID on every fetch made the same damaged row
            // appear under a different identity each time and made it
            // impossible to update or remove safely.
            throw NoteRecordError.invalidIdentifier(record.id)
        }
        return Note(
            id: id,
            title: record.title,
            body: record.body,
            colorIndex: record.colorIndex,
            tag: record.tag,
            pinned: record.pinned,
            sortIndex: record.sortIndex,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            archivedAt: record.archivedAt,
            deletedAt: record.deletedAt,
            bodyNeedsMigration: record.body.isEmpty && record.bodyEnc != nil
        )
    }
}
