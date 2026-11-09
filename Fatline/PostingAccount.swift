import CryptoKit
import Foundation
import Security

struct PostingAccount: Codable {
    private let keyBytes: Data
    var token: String?
    var fid: UInt64?
    var username: String?
    var pending: SignedCast?
    var registration: SignerRegistration?

    init() {
        keyBytes = Curve25519.Signing.PrivateKey().rawRepresentation
    }

    var signingKey: Curve25519.Signing.PrivateKey {
        get throws { try Curve25519.Signing.PrivateKey(rawRepresentation: keyBytes) }
    }

    var publicKey: String {
        get throws { try signingKey.publicKey.rawRepresentation.hex }
    }
}

enum PostingKeychain {
    private static let item = KeychainValue<PostingAccount>(account: "posting-account-v1")

    static func load() throws -> PostingAccount? { try item.load() }
    static func remove() throws { try item.remove() }
    static func save(_ account: PostingAccount) throws { try item.save(account) }
}

/// One value in the device-only Keychain.
struct KeychainValue<Value: Codable>: Sendable {
    let account: String

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "Fatline",
            kSecAttrAccount as String: account,
            // The app gets the older file-based keychain unless it asks for this one, and only
            // this one honors device-only access.
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    func load() throws -> Value? {
        var request: [String: Any] = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(request as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let bytes = item as? Data else { throw PostingError.keychain(result) }
        return try JSONDecoder().decode(Value.self, from: bytes)
    }

    func remove() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw PostingError.keychain(result)
        }
    }

    func save(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = attributes
            for (key, value) in query { item[key] = value }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw PostingError.keychain(added) }
        } else if result != errSecSuccess {
            throw PostingError.keychain(result)
        }
    }
}
