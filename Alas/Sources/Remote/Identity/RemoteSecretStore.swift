import Foundation
import Security
import os

/// Where this Mac's own remote credentials live: the peer identity private
/// key, and the bearer tokens paired peers issued to us. Both are secrets
/// this Mac presents outbound, which is why they belong in the Keychain
/// rather than beside the records that reference them.
///
/// Not actor-isolated: `FilePeerStore` is a plain object the peer manager
/// calls synchronously, so a `@MainActor` protocol here would force every
/// save through a hop. Implementations are internally synchronized instead.
protocol RemoteSecretStore: AnyObject, Sendable {
    func secret(for account: String) -> Data?
    /// Stores (or, with nil, removes) a secret. Returns whether it landed
    /// somewhere durable — callers that cannot tolerate a lost secret check
    /// this rather than assuming success.
    @discardableResult
    func setSecret(_ data: Data?, for account: String) -> Bool
}

enum RemoteSecretStores {
    static let service = "io.nlopez.alas.remote"

    /// The production store: Keychain, falling back to owner-only files.
    static func makeDefault() -> any RemoteSecretStore {
        RemoteKeychainSecretStore(fallback: RemoteFileSecretStore())
    }
}

/// Keychain-backed storage, with a file fallback for the cases where the
/// Keychain is not available to this build at all.
///
/// Uses the **data protection** keychain (`kSecUseDataProtectionKeychain`)
/// rather than the legacy file keychain. Access there is decided by the
/// app's entitlements, so it never raises the "«app» wants to use your
/// confidential information" panel that the legacy keychain shows whenever a
/// binary's code signature changes — which, for a locally rebuilt app, is
/// every single build. A modal panel on the pairing path would be worse than
/// the problem this type solves.
///
/// The price is that a build with no application identifier to scope items
/// by (an ad-hoc signed local build) gets `errSecMissingEntitlement` and
/// cannot use it at all. That is what `fallback` is for: the secret still
/// leaves the peer record, and still lands in an owner-only file, which is
/// no worse than where it lived before. Whichever store answers, a secret
/// written to the Keychain is removed from the fallback, so the plaintext
/// copy does not outlive the migration.
final class RemoteKeychainSecretStore: RemoteSecretStore, @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "remote-identity")

    private let service: String
    private let fallback: any RemoteSecretStore
    private let lock = NSLock()
    /// Logged-once guard, so an unavailable Keychain does not repeat itself
    /// on every save.
    private var didLogUnavailable = false

    init(service: String = RemoteSecretStores.service, fallback: any RemoteSecretStore) {
        self.service = service
        self.fallback = fallback
    }

    func secret(for account: String) -> Data? {
        if let data = read(account: account) { return data }
        // Either the Keychain is unusable here, or this secret predates the
        // move to it — an older build wrote it to a file. Reading through
        // means the next `setSecret` migrates it without the user noticing.
        return fallback.secret(for: account)
    }

    @discardableResult
    func setSecret(_ data: Data?, for account: String) -> Bool {
        guard let data else {
            delete(account: account)
            return fallback.setSecret(nil, for: account)
        }
        if write(data, account: account) {
            // Never leave the pre-migration plaintext copy behind.
            fallback.setSecret(nil, for: account)
            return true
        }
        noteUnavailable()
        return fallback.setSecret(data, for: account)
    }

    private func noteUnavailable() {
        lock.lock()
        defer { lock.unlock() }
        guard !didLogUnavailable else { return }
        didLogUnavailable = true
        Self.logger.notice("Keychain unavailable for remote credentials; using owner-only files instead.")
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private func write(_ data: Data, account: String) -> Bool {
        let query = baseQuery(account: account)
        let update = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        // The server can start before the user ever unlocks the screen after
        // a reboot; `AfterFirstUnlock` is what lets a relaunched app still
        // reach its own key then, without widening access beyond this device.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

/// Owner-only (0600) files under Application Support. The fallback for builds
/// the data protection keychain refuses, and the source a pre-Keychain secret
/// is migrated out of.
final class RemoteFileSecretStore: RemoteSecretStore, @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()

    init(root: URL = Paths.remoteSecretsDir) {
        self.root = root
    }

    private func url(for account: String) -> URL {
        // Accounts are compile-time constants, but a path separator smuggled
        // into one would write outside `root`; keep only characters that
        // cannot traverse.
        let safe = account.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return root.appendingPathComponent(safe.isEmpty ? "secret" : safe)
    }

    func secret(for account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: url(for: account))
    }

    @discardableResult
    func setSecret(_ data: Data?, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let target = url(for: account)
        guard let data else {
            try? FileManager.default.removeItem(at: target)
            return true
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: target, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return true
        } catch {
            return false
        }
    }
}

/// Test double. Also what a `RemoteIdentityKeyProvider` built for a unit test
/// uses, so no test ever reaches the real Keychain.
final class RemoteInMemorySecretStore: RemoteSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]
    /// When false, every write reports failure — the "no durable storage
    /// anywhere" case callers must degrade gracefully for.
    private let writable: Bool

    init(writable: Bool = true) {
        self.writable = writable
    }

    func secret(for account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    @discardableResult
    func setSecret(_ data: Data?, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard writable else { return false }
        secrets[account] = data
        return true
    }
}
