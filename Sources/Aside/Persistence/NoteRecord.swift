import Foundation
import CryptoKit
import GRDB

struct NoteRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "note"

    var id: String
    var title: String
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

enum NoteMapper {
    static func record(from note: Note, key: SymmetricKey) throws -> NoteRecord {
        NoteRecord(
            id: note.id.uuidString,
            title: note.title,
            bodyEnc: try NoteCipher.encrypt(note.body, key: key),
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

    static func note(from record: NoteRecord, key: SymmetricKey) throws -> Note {
        Note(
            id: UUID(uuidString: record.id) ?? UUID(),
            title: record.title,
            body: try NoteCipher.decrypt(record.bodyEnc, key: key),
            colorIndex: record.colorIndex,
            tag: record.tag,
            pinned: record.pinned,
            sortIndex: record.sortIndex,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            archivedAt: record.archivedAt,
            deletedAt: record.deletedAt
        )
    }

    /// Metadata-only mapping for rows whose body cannot be decrypted with any
    /// known key. Never throws — a damaged row must not blank the whole list.
    static func noteSkippingBody(from record: NoteRecord) -> Note {
        Note(
            id: UUID(uuidString: record.id) ?? UUID(),
            title: record.title,
            body: "",
            colorIndex: record.colorIndex,
            tag: record.tag,
            pinned: record.pinned,
            sortIndex: record.sortIndex,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            archivedAt: record.archivedAt,
            deletedAt: record.deletedAt,
            bodyUnavailable: true
        )
    }
}
