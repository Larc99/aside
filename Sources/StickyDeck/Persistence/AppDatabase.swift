import Foundation
import GRDB

struct AppDatabase {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    static func open() throws -> AppDatabase {
        let fm = FileManager.default
        let appSupport: URL
        if let debugPath = ProcessInfo.processInfo.environment["STICKYDECK_DEBUG_DATA_DIR"],
           !debugPath.isEmpty {
            // Visual regression runs must never read or mutate the user's
            // real note library. Relative names live inside the sandbox's
            // writable temporary directory; an absolute path remains useful
            // for unsandboxed `swift run` builds.
            appSupport = debugPath.hasPrefix("/")
                ? URL(fileURLWithPath: debugPath, isDirectory: true)
                : fm.temporaryDirectory.appendingPathComponent(debugPath, isDirectory: true)
        } else {
            appSupport = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("StickyDeck", isDirectory: true)
        }
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let database = try DatabasePool(path: appSupport.appendingPathComponent("notes.sqlite").path)
        return try AppDatabase(writer: database)
    }

    static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue())
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "note") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("bodyEnc", .blob)
                t.column("colorIndex", .integer).notNull().defaults(to: 0)
                t.column("tag", .text).notNull().defaults(to: "")
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("archivedAt", .datetime)
                t.column("deletedAt", .datetime)
            }
            try db.create(indexOn: "note", columns: ["deletedAt"])
            try db.create(indexOn: "note", columns: ["sortIndex"])
            try db.create(indexOn: "note", columns: ["updatedAt"])
        }

        // Bodies are stored as plain text: the sync folder always wrote plain
        // Markdown into the user's own folder, so encrypting only the local
        // copy — with a key sitting on the same disk — bought nothing and cost
        // a keychain dependency that could refuse to open the app at all.
        //
        // `bodyEnc` deliberately stays: LegacyEncryptedBodies reads it once,
        // after launch, to rescue rows written by 0.2.0 and earlier. It can be
        // dropped in a v3 migration once that pass is retired.
        migrator.registerMigration("v2-plain-bodies") { db in
            try db.alter(table: "note") { t in
                t.add(column: "body", .text).notNull().defaults(to: "")
            }
        }

        return migrator
    }
}
