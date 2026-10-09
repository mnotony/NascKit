import Foundation
import Security

/// Per-server device credentials in the Keychain — secrets never belong in UserDefaults. Keyed by
/// the server's `ws://` URL. Every failure throws: a read the Keychain refused (a denied prompt, a
/// locked keychain) is not "no credential", and must never be saved over as one.
public struct CredentialStore: Sendable {
    private let service: String

    public init(service: String = "com.mnotony.nasc.credential") {
        self.service = service
    }

    /// The credential stored for `url`, or nil when there is none.
    public func credential(server url: String) throws -> String? {
        var query = item(url)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    /// Store `credential` for `url` (an empty one removes it), then drop the one under `previous` —
    /// a server whose URL changed — only once the new one is stored, so a failure never loses both.
    public func save(_ credential: String, server url: String, replacing previous: String? = nil) throws {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteCredential(server: url)
        } else {
            let data = Data(trimmed.utf8)
            var status = SecItemUpdate(item(url) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = item(url)
                add[kSecValueData as String] = data
                #if os(iOS)
                // Readable while the phone is locked (a push wakes the app); macOS's keychain has no
                // such class.
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                #endif
                status = SecItemAdd(add as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
        if let previous, previous != url { try deleteCredential(server: previous) }
    }

    public func deleteCredential(server url: String) throws {
        let status = SecItemDelete(item(url) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func item(_ url: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: url,
        ]
    }
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        "Keychain: " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)")
    }
}
