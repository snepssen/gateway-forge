import Foundation
import GatewaySyncTransport
import Security

struct CompanionCredential: Codable, Equatable, Sendable {
    var serverID: String
    var serviceName: String?
    var clientID: String
    var displayName: String
    var bearerToken: String
    var tlsIdentity: Data
    var tlsSecret: Data
    var pairedAt: Date

    var tlsKey: SyncTLSKey { SyncTLSKey(identity: tlsIdentity, secret: tlsSecret) }
}

enum CompanionCredentialError: Error, LocalizedError {
    case keychain(OSStatus)
    case corrupt

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "Secure credential storage failed (\(status))."
        case .corrupt: "The saved desktop credential is unreadable. Pair again."
        }
    }
}

final class CompanionCredentialVault: @unchecked Sendable {
    private let service = "local.gatewayforge.companion"
    private let account = "paired-desktop"

    func load() throws -> CompanionCredential? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CompanionCredentialError.keychain(status) }
        guard let data = result as? Data,
              let credential = try? JSONDecoder().decode(CompanionCredential.self, from: data)
        else { throw CompanionCredentialError.corrupt }
        return credential
    }

    func save(_ credential: CompanionCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemUpdate(match as CFDictionary,
                                   [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw CompanionCredentialError.keychain(added) }
        } else if status != errSecSuccess {
            throw CompanionCredentialError.keychain(status)
        }
    }

    func remove() throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CompanionCredentialError.keychain(status)
        }
    }
}
