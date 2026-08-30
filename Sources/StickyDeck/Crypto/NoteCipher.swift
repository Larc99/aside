import Foundation
import CryptoKit

enum NoteCipherError: Error {
    case decryptionFailed
}

enum NoteCipher {
    static func encrypt(_ plaintext: String, key: SymmetricKey) throws -> Data? {
        guard !plaintext.isEmpty else { return nil }
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else { throw NoteCipherError.decryptionFailed }
        return combined
    }

    static func decrypt(_ data: Data?, key: SymmetricKey) throws -> String {
        guard let data, !data.isEmpty else { return "" }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: key)
        return String(decoding: plain, as: UTF8.self)
    }
}
