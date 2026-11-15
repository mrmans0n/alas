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

/// Storage the app shares with its extensions. Both read their ids from
/// Info.plist, so the extension sets the same keys to the app's values.
enum AppGroup {
    static var id: String {
        Bundle.main.object(forInfoDictionaryKey: "AlasAppGroup") as? String ?? ""
    }

    /// The Keychain access group paired-host tokens live in; nil when unset.
    static var keychainGroup: String? {
        let group = Bundle.main.object(forInfoDictionaryKey: "AlasKeychainGroup") as? String
        return group?.isEmpty == false ? group : nil
    }

    /// The group container, or Application Support when the build carries no
    /// app-group entitlement (unsigned simulator builds).
    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? URL.applicationSupportDirectory
    }
}

/// Persists paired hosts as JSON in the app group container and their tokens
/// as Keychain generic passwords in the shared access group.
struct HostStore {
    static let keychainService = "io.nlopez.alas.remote"

    let fileURL: URL

    init(fileURL: URL = AppGroup.containerURL.appending(path: "hosts.json")) {
        self.fileURL = fileURL
    }

    /// Moves what older builds kept in Application Support and the default
    /// Keychain group into the shared locations. Idempotent; every step
    /// removes the old copy only after the new one is written, and anything
    /// that cannot move stays where it is.
    func migrateIfNeeded() {
        let fm = FileManager.default
        let old = URL.applicationSupportDirectory.appending(path: "hosts.json")
        if old != fileURL, fm.fileExists(atPath: old.path), !fm.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: old) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? data.write(to: fileURL, options: .atomic)) != nil {
                try? fm.removeItem(at: old)
            }
        }
        guard let shared = AppGroup.keychainGroup else { return }
        for host in load() {
            var query = Self.query(for: host.id)
            query[kSecReturnAttributes as String] = true
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let attrs = result as? [String: Any],
                  let group = attrs[kSecAttrAccessGroup as String] as? String, group != shared,
                  let data = attrs[kSecValueData as String] as? Data else { continue }
            var item = Self.query(for: host.id)
            item[kSecAttrAccessGroup as String] = shared
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else { continue }
            var old = Self.query(for: host.id)
            old[kSecAttrAccessGroup as String] = group
            SecItemDelete(old as CFDictionary)
        }
    }

    func load() -> [PairedHost] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([PairedHost].self, from: data)
        } catch {
            // Set the file aside so the next save cannot wipe hosts a later
            // build (or a fix) could still read.
            let aside = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return []
        }
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
        if let group = AppGroup.keychainGroup {
            var shared = item
            shared[kSecAttrAccessGroup as String] = group
            if SecItemAdd(shared as CFDictionary, nil) == errSecSuccess { return true }
            // No entitlement for the group (unsigned build): keep the app working.
        }
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
