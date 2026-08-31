import Foundation
import CryptoKit
import GRDB
import Security

/// One-shot rescue for bodies written by 0.2.0 and earlier, which stored them
/// AES-GCM-encrypted under a key in the login keychain or, for source and
/// ad-hoc builds, a 0600 fallback file in Application Support.
///
/// This is the whole remaining cost of that design, and it is temporary: once
/// no install can still be carrying ciphertext, delete this file and drop the
/// `bodyEnc` column in a v3 migration.
///
/// Two rules make it safe to run on every launch:
///
/// - Recovered text is installed with a compare-and-swap update. Plaintext the
///   user writes while recovery waits always wins over the old ciphertext.
/// - Legacy keys are removed only after the database confirms that no
///   ciphertext remains. A failed write or an unreadable row keeps every
///   recovery path available for the next launch.
enum LegacyEncryptedBodies {
    private static let service = "StickyDeck"
    private static let account = "note-body-key"

    /// Runs off the main thread. The keychain read can sit behind a consent
    /// prompt for as long as the user needs — the app is already open and
    /// usable by then, which is the point of doing this after launch rather
    /// than inside the migrator.
    static func migrate(in database: AppDatabase) async {
        let fileKeyURL = legacyFileKeyURL()
        await migrate(
            in: database,
            fileKeyURL: fileKeyURL,
            keychainKeyProvider: { await keychainKey() },
            cleanup: {
                SecItemDelete(keychainQuery() as CFDictionary)
                if let fileKeyURL {
                    try? FileManager.default.removeItem(at: fileKeyURL)
                }
            }
        )
    }

    /// Dependency-injected entry point for exercising the one-way migration
    /// against an isolated database without touching the user's keychain.
    static func migrate(
        in database: AppDatabase,
        fileKeyURL: URL?,
        keychainKeyProvider: @escaping @Sendable () async -> SymmetricKey?,
        cleanup: @escaping @Sendable () -> Void
    ) async {
        // A library with no legacy ciphertext must never touch the keychain.
        // Besides being unnecessary, an ad-hoc build can prompt for access.
        guard (try? await hasEncryptedRows(in: database)) == true else { return }

        var changedRows = 0

        // Source and ad-hoc builds fell back to this 0600 file whenever the
        // keychain refused an insertion. Try it first: for those installs it
        // avoids a pointless keychain prompt and is the only usable key.
        if let fileKeyURL,
           let data = try? Data(contentsOf: fileKeyURL),
           data.count == 32 {
            changedRows += (try? await migrateRows(
                in: database,
                using: SymmetricKey(data: data)
            )) ?? 0
        }

        // A single install can contain rows written under the file key and an
        // older keychain key, so only skip the second source when every blob
        // has already been resolved.
        if (try? await hasEncryptedRows(in: database)) == true,
           let key = await keychainKeyProvider() {
            changedRows += (try? await migrateRows(in: database, using: key)) ?? 0
        }

        let hasEncryptedRows = try? await hasEncryptedRows(in: database)
        guard hasEncryptedRows == false else {
            if changedRows > 0 {
                NotificationCenter.default.post(name: .noteStoreChanged, object: nil)
            }
            return
        }

        // Every ciphertext is gone, so neither legacy secret protects
        // anything. Cleanup is intentionally last: a read or write failure
        // above retains both keys for the next launch.
        cleanup()
        if changedRows > 0 {
            NotificationCenter.default.post(name: .noteStoreChanged, object: nil)
        }
    }

    /// Re-reads rows inside the database write and updates each one with a
    /// compare-and-swap predicate. A user can type while a keychain prompt is
    /// open; their now-nonempty plaintext wins and the stale snapshot can
    /// never overwrite it.
    private static func migrateRows(
        in database: AppDatabase,
        using key: SymmetricKey
    ) async throws -> Int {
        try await database.writer.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, body, bodyEnc FROM note WHERE bodyEnc IS NOT NULL"
            )
            var changedRows = 0

            for row in rows {
                guard let id: String = row["id"],
                      let body: String = row["body"],
                      let ciphertext: Data = row["bodyEnc"] else { continue }

                if !body.isEmpty {
                    // Plaintext written while recovery was waiting is the
                    // user's newer intent. Retire only the obsolete blob.
                    try db.execute(
                        sql: "UPDATE note SET bodyEnc = NULL WHERE id = ? AND body = ? AND bodyEnc = ?",
                        arguments: [id, body, ciphertext]
                    )
                } else if let recovered = decrypt(ciphertext, key: key) {
                    try db.execute(
                        sql: """
                            UPDATE note SET body = ?, bodyEnc = NULL
                            WHERE id = ? AND body = '' AND bodyEnc = ?
                            """,
                        arguments: [recovered, id, ciphertext]
                    )
                } else {
                    continue
                }
                changedRows += db.changesCount
            }
            return changedRows
        }
    }

    private static func hasEncryptedRows(in database: AppDatabase) async throws -> Bool {
        try await database.writer.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM note WHERE bodyEnc IS NOT NULL)"
            ) ?? false
        }
    }

    private static func decrypt(_ data: Data, key: SymmetricKey) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }

    /// Suspends rather than blocks: the query can be parked behind a keychain
    /// prompt indefinitely, and a cooperative-pool thread is not ours to hold.
    private static func keychainKey() async -> SymmetricKey? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var query = keychainQuery()
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne

                var item: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: SymmetricKey(data: data))
            }
        }
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func legacyFileKeyURL() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return appSupport
            .appendingPathComponent("StickyDeck", isDirectory: true)
            .appendingPathComponent("key.bin")
    }
}
