import Foundation
import CryptoKit
import Security

enum KeyStoreError: Error, LocalizedError {
    case unhandledStatus(OSStatus)
    case keychainUnavailable

    var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            return "The keychain returned an unexpected status (\(status))."
        case .keychainUnavailable:
            return """
            StickyDeck could not reach your login keychain, so it cannot unlock \
            your notes. Minting a new key here would make every existing note \
            unreadable, so StickyDeck stopped instead. Unlock your keychain and \
            open StickyDeck again.
            """
        }
    }
}

/// Small lock-guarded box. The keychain probes hand a value between a
/// background queue and the caller across a *timed-out* wait, where the
/// producer is still running — an unsynchronised `var` there is a real race
/// on a reference-holding `Optional<Data>`.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// Outcome of a keychain probe. The distinction between `absent` and
/// `unavailable` is the whole point: only `absent` makes it safe to mint a
/// brand-new key, because only `absent` proves no existing key is out there
/// holding the user's note bodies.
private enum KeychainLookup {
    case found(Data)
    case absent
    case unavailable
}

/// Provides the 256-bit key used to encrypt note bodies.
///
/// Policy (divergence-proof — the key never silently changes):
///
/// 1. A file key, once created, is the *stable* key for this install and is
///    used from then on. Re-signing a dev build changes the keychain ACL and
///    would otherwise block launch on an invisible security prompt or orphan
///    existing bodies — so dev builds pin to the file key (0600 perms).
/// 2. Fresh installs (no file key) prefer the login keychain — the production
///    path for signed builds. The query runs off the main thread with a short
///    deadline so a locked keychain can never stall launch.
/// 3. A new file key is created ONLY when the keychain positively reports
///    that no item exists. A timeout or a locked keychain is never treated as
///    "absent" — minting a key there would orphan every existing note body.
enum KeyStore {
    private static let service = "StickyDeck"
    private static let account = "note-body-key"
    private static let keychainTimeout: TimeInterval = 0.5
    /// Patient second attempt before we are willing to conclude anything.
    private static let keychainRetryTimeout: TimeInterval = 5.0

    static func noteBodyKey() throws -> SymmetricKey {
        if let existing = existingFileKey() {
            return SymmetricKey(data: existing)
        }

        // A contended keychain daemon (fresh boot, pending ACL prompt) can miss
        // the fast deadline. Retry patiently before concluding anything: the
        // old code treated a timeout as "no key exists" and minted a new one,
        // which orphaned every existing note body permanently.
        for deadline in [keychainTimeout, keychainRetryTimeout] {
            switch keychainLookup(deadline: deadline) {
            case .found(let keyData):
                return SymmetricKey(data: keyData)
            case .absent:
                // Nothing is stored, so nothing can be orphaned — creating a
                // key here is safe. Prefer the keychain, but fall back to the
                // on-disk key when it refuses, which is the ordinary case for
                // unsigned and ad-hoc dev builds (D16). Without this fallback
                // a refused keychain leaves the app unable to launch at all.
                if let created = createKeychainKey() {
                    return SymmetricKey(data: created)
                }
                return SymmetricKey(data: try fileKey())
            case .unavailable:
                continue
            }
        }

        // Every attempt came back "would not answer" rather than "nothing
        // stored". Refuse to invent a key: failing to launch is recoverable,
        // silently orphaning the user's library is not.
        throw KeyStoreError.keychainUnavailable
    }

    /// One-shot attempt to read a *legacy* body key from the keychain (e.g.
    /// written by an earlier build before the key policy changed). Runs off
    /// the main thread with a generous deadline so a one-time ACL consent
    /// prompt can be answered. Returns nil if denied, absent, or timed out.
    private static var legacyAttemptDone = false

    static func legacyKeychainKey(deadline: TimeInterval = 90) -> SymmetricKey? {
        guard !legacyAttemptDone else { return nil }
        legacyAttemptDone = true

        let group = DispatchGroup()
        group.enter()
        let box = LockedBox<Data?>(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            var query = keychainQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data {
                box.value = data
            }
        }
        // Same rule as keychainLookup: never read the box after a timeout,
        // because the producer is still writing it.
        guard group.wait(timeout: .now() + deadline) == .success else { return nil }
        return box.value.map(SymmetricKey.init)
    }

    // MARK: - Keychain (production path)

    private static func keychainLookup(deadline: TimeInterval) -> KeychainLookup {
        let group = DispatchGroup()
        group.enter()

        let box = LockedBox<KeychainLookup>(.unavailable)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            box.value = probeKeychain()
        }

        // On timeout the producer is still running, so the box must be read
        // under the same lock it is written under.
        guard group.wait(timeout: .now() + deadline) == .success else {
            return .unavailable
        }
        return box.value
    }

    /// Reads the stored key. Deliberately never creates one: "no item exists"
    /// and "the keychain would not answer" must lead to different outcomes,
    /// and only the caller can make that policy decision.
    private static func probeKeychain() -> KeychainLookup {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data {
            return .found(data)
        }
        if status == errSecItemNotFound {
            return .absent
        }
        // Locked, denied, interaction-required: an existing key may well be in
        // there, so this is emphatically not "absent".
        return .unavailable
    }

    /// Stores a fresh key in the login keychain. Returns nil when the keychain
    /// refuses — unsigned and ad-hoc builds routinely cannot add items — so
    /// the caller can fall back to the on-disk key instead of failing.
    private static func createKeychainKey() -> Data? {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        var addQuery = keychainQuery()
        addQuery[kSecValueData as String] = keyData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            return nil
        }
        return keyData
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - File fallback (dev path)

    private static func fileKeyURL() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport
            .appendingPathComponent("StickyDeck", isDirectory: true)
            .appendingPathComponent("key.bin")
    }

    private static func existingFileKey() -> Data? {
        guard let url = fileKeyURL(),
              let data = try? Data(contentsOf: url),
              data.count == 32 else {
            return nil
        }
        return data
    }

    private static func fileKey() throws -> Data {
        let fm = FileManager.default
        guard let url = fileKeyURL() else {
            throw KeyStoreError.unhandledStatus(errSecMissingEntitlement)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let existing = existingFileKey() {
            return existing
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        // Created 0600 in one step. An atomic write followed by a chmod leaves
        // the key world-readable in between — and permanently so if the chmod
        // fails, which the old `try?` hid.
        guard fm.createFile(
            atPath: url.path,
            contents: keyData,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw KeyStoreError.unhandledStatus(errSecIO)
        }
        return keyData
    }
}
