import Foundation
import SwiftData
import Security

enum SSHKeyPairError: LocalizedError {
    case privateKeyUnavailable
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .privateKeyUnavailable:
            return "SSH private key is unavailable. Re-import the key."
        case .keychainWriteFailed(let status):
            return "Failed to save SSH key to Keychain (\(status))."
        case .keychainReadFailed(let status):
            return "Failed to read SSH key from Keychain (\(status))."
        case .keychainDeleteFailed(let status):
            return "Failed to delete SSH key from Keychain (\(status))."
        }
    }
}

private enum SSHPrivateKeyKeychain {
    private static let service = "com.tianyizhuang.OpenCAN.ssh-private-keys"

    static func load(identifier: String) throws -> Data? {
        var query = baseQuery(identifier: identifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SSHKeyPairError.keychainReadFailed(errSecInternalError)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SSHKeyPairError.keychainReadFailed(status)
        }
    }

    static func save(privateKeyPEM: Data, identifier: String) throws {
        let query = baseQuery(identifier: identifier)
        let attributesToUpdate: [String: Any] = [kSecValueData as String: privateKeyPEM]

        var status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = privateKeyPEM
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            #endif
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw SSHKeyPairError.keychainWriteFailed(status)
        }
    }

    static func delete(identifier: String) throws {
        let status = SecItemDelete(baseQuery(identifier: identifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHKeyPairError.keychainDeleteFailed(status)
        }
    }

    private static func baseQuery(identifier: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
        ]
    }
}

@Model
final class SSHKeyPair {
    var name: String
    /// Legacy on-disk storage kept only for one-time migration to Keychain.
    var privateKeyPEM: Data
    /// Keychain account identifier for the private key bytes.
    var keychainIdentifier: String?
    var createdAt: Date

    @Relationship(inverse: \Node.sshKey)
    var nodes: [Node]?

    init(name: String, privateKeyPEM: Data) throws {
        self.name = name
        self.privateKeyPEM = Data()
        self.keychainIdentifier = nil
        self.createdAt = Date()
        try storePrivateKeyPEM(privateKeyPEM)
    }

    func privateKeyDataForConnection() throws -> Data {
        if let keyFromKeychain = try loadPrivateKeyFromKeychain() {
            return keyFromKeychain
        }

        guard !privateKeyPEM.isEmpty else {
            throw SSHKeyPairError.privateKeyUnavailable
        }

        // Backward compatibility: old versions persisted raw PEM in SwiftData.
        try storePrivateKeyPEM(privateKeyPEM)
        let migratedKey = privateKeyPEM
        privateKeyPEM = Data()
        return migratedKey
    }

    @discardableResult
    func migrateLegacyPrivateKeyIfNeeded() throws -> Bool {
        if try loadPrivateKeyFromKeychain() != nil {
            if privateKeyPEM.isEmpty {
                return false
            }
            privateKeyPEM = Data()
            return true
        }

        guard !privateKeyPEM.isEmpty else {
            return false
        }

        try storePrivateKeyPEM(privateKeyPEM)
        privateKeyPEM = Data()
        return true
    }

    func deletePrivateKeyFromKeychain() {
        guard let identifier = keychainIdentifier, !identifier.isEmpty else { return }
        do {
            try SSHPrivateKeyKeychain.delete(identifier: identifier)
        } catch {
            Log.log(
                level: "error",
                component: "Security",
                "Failed to remove SSH key from Keychain: \(error.localizedDescription)"
            )
        }
    }

    private func loadPrivateKeyFromKeychain() throws -> Data? {
        guard let identifier = keychainIdentifier, !identifier.isEmpty else {
            return nil
        }
        return try SSHPrivateKeyKeychain.load(identifier: identifier)
    }

    private func storePrivateKeyPEM(_ privateKeyPEM: Data) throws {
        let identifier = resolvedKeychainIdentifier()
        try SSHPrivateKeyKeychain.save(privateKeyPEM: privateKeyPEM, identifier: identifier)
    }

    private func resolvedKeychainIdentifier() -> String {
        if let keychainIdentifier, !keychainIdentifier.isEmpty {
            return keychainIdentifier
        }
        let identifier = UUID().uuidString
        keychainIdentifier = identifier
        return identifier
    }
}
