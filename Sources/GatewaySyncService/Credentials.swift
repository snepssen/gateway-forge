import Foundation
import GatewaySync
import GatewaySyncTransport
import Security

public struct SyncPairedDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String { clientID }
    public var clientID: String
    public var displayName: String
    public var bearerToken: String
    public var tlsIdentity: Data
    public var tlsSecret: Data
    public var pairedAt: Date

    public init(clientID: String, displayName: String, bearerToken: String,
                tlsIdentity: Data, tlsSecret: Data, pairedAt: Date) {
        self.clientID = clientID
        self.displayName = displayName
        self.bearerToken = bearerToken
        self.tlsIdentity = tlsIdentity
        self.tlsSecret = tlsSecret
        self.pairedAt = pairedAt
    }

    public var tlsKey: SyncTLSKey {
        SyncTLSKey(identity: tlsIdentity, secret: tlsSecret)
    }
}

public struct SyncDesktopIdentity: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var serverID: String
    public var devices: [SyncPairedDevice]

    public init(serverID: String = "desktop-\(UUID().uuidString.lowercased())",
                devices: [SyncPairedDevice] = []) {
        self.serverID = serverID
        self.devices = devices
    }
}

public typealias SyncPairingOffer = SyncPairingPayload

public extension SyncPairingPayload {
    var tlsKey: SyncTLSKey {
        SyncTLSKey(identity: tlsIdentity, secret: tlsSecret)
    }
}

public enum SyncCredentialError: Error, LocalizedError {
    case randomFailure(OSStatus)
    case keychainFailure(OSStatus)
    case corruptVault

    public var errorDescription: String? {
        switch self {
        case .randomFailure(let status): "Secure random generation failed (\(status))."
        case .keychainFailure(let status): "Keychain operation failed (\(status))."
        case .corruptVault: "The companion credential record in Keychain is unreadable."
        }
    }
}

public enum SyncSecrets {
    public static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw SyncCredentialError.randomFailure(status) }
        return data
    }

    public static func randomToken(bytes: Int = 32) throws -> String {
        try randomData(count: bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public final class SyncCredentialVault: @unchecked Sendable {
    private let service: String
    private let account = "desktop-sync-identity"

    public init(service: String = "local.gatewayforge.sync") {
        self.service = service
    }

    public func load() throws -> SyncDesktopIdentity {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            let identity = SyncDesktopIdentity()
            try save(identity)
            return identity
        }
        guard status == errSecSuccess else { throw SyncCredentialError.keychainFailure(status) }
        guard let data = result as? Data,
              let value = try? JSONDecoder().decode(SyncDesktopIdentity.self, from: data),
              value.schemaVersion == 1 else { throw SyncCredentialError.corruptVault }
        return value
    }

    public func save(_ identity: SyncDesktopIdentity) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(identity)
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SyncCredentialError.keychainFailure(addStatus)
            }
        } else if status != errSecSuccess {
            throw SyncCredentialError.keychainFailure(status)
        }
    }
}
