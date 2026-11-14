import Foundation
import Security

/// A Mac this phone paired with. The token is not here: it lives in the
/// Keychain, keyed by `id`.
struct PairedHost: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var serverId: String?
    /// Every origin the Mac advertised; the connection picks one that works.
    var origins: [String]
    var lastOrigin: String?
    var publicKey: String?
    let addedAt: Date
}

/// Persists paired hosts as JSON in Application Support and their tokens as
/// Keychain generic passwords.
struct HostStore {
    static let keychainService = "io.nlopez.alas.remote"

    let fileURL: URL

    init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "hosts.json")) {
        self.fileURL = fileURL
    }

    func load() -> [PairedHost] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PairedHost].self, from: data)) ?? []
    }

    func save(_ hosts: [PairedHost]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(hosts).write(to: fileURL, options: .atomic)
    }

    func token(for id: UUID) -> String? {
        var query = Self.query(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// False when the Keychain refused the write; the caller still holds the
    /// token in memory for this run.
    @discardableResult
    func setToken(_ token: String, for id: UUID) -> Bool {
        deleteToken(for: id)
        var item = Self.query(for: id)
        item[kSecValueData as String] = Data(token.utf8)
        // Never leaves this device, not even through a backup restore.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func deleteToken(for id: UUID) {
        SecItemDelete(Self.query(for: id) as CFDictionary)
    }

    private static func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "host.\(id.uuidString)",
        ]
    }
}
