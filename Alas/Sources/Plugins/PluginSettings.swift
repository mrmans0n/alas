import Foundation
import Observation

/// One plugin's settings, app-wide rather than per project: plain values in a `PluginStorage` file,
/// secrets in the Keychain. A plugin can read the plain values; it can only use a secret, through
/// `{{secret:key}}` in an `http/fetch` header to one of that secret's hosts.
@MainActor
@Observable
final class PluginSettings {
    let pluginID: String
    let declared: [PluginSetting]
    /// Called after the user commits a change.
    @ObservationIgnored var didChange: () -> Void = {}
    /// Bumped by every change; the getters read it so SwiftUI redraws.
    private var revision = 0
    @ObservationIgnored private let storage: PluginStorage
    @ObservationIgnored private let secrets: any RemoteSecretStore

    init(pluginID: String, declared: [PluginSetting], storage: PluginStorage, secrets: any RemoteSecretStore) {
        self.pluginID = pluginID
        self.declared = declared
        self.storage = storage
        self.secrets = secrets
    }

    /// The production store for `pluginID`.
    static func make(pluginID: String, declared: [PluginSetting], root: URL = Paths.appSupportRoot) -> PluginSettings {
        let folder = root.appending(path: "PluginData").appending(path: pluginID)
        // Project files are always `<name>.json`, so these extensionless names never collide with one.
        return PluginSettings(
            pluginID: pluginID, declared: declared,
            storage: PluginStorage.shared(file: folder.appending(path: "settings")),
            secrets: RemoteKeychainSecretStore(
                service: keychainService, fallback: RemoteFileSecretStore(root: folder.appending(path: "secrets"))))
    }

    /// An isolated profile gets its own service, as for remote credentials.
    private static var keychainService: String {
        guard let runtime = AlasProfile.current.runtimeDirectory else { return "io.nlopez.alas.plugin" }
        return "io.nlopez.alas.plugin.\(runtime.lastPathComponent)"
    }

    /// Every non-secret value, defaults applied: what `settings/get` and `settings/changed` carry.
    func values() -> [String: PluginSettingValue] {
        _ = revision
        var values: [String: PluginSettingValue] = [:]
        for setting in declared {
            switch setting.kind {
            case .string: values[setting.key] = .string(string(setting.key))
            case .bool: values[setting.key] = .bool(bool(setting.key))
            case .secret: break
            }
        }
        return values
    }

    func string(_ key: String) -> String {
        if case .string(let value)? = stored(key) { return value }
        if case .string(let value)? = declaration(key)?.defaultValue { return value }
        return ""
    }

    func bool(_ key: String) -> Bool {
        if case .bool(let value)? = stored(key) { return value }
        if case .bool(let value)? = declaration(key)?.defaultValue { return value }
        return false
    }

    /// Settings are configuration, not data: a value this size always fits the messages that carry them.
    nonisolated static let maxStringBytes = 4096

    func set(_ key: String, _ value: PluginSettingValue) {
        if case .string(let text) = value, text.utf8.count > Self.maxStringBytes { return }
        guard let setting = declaration(key), setting.kind != .secret,
              let data = try? JSONEncoder().encode(value),
              storage.set(key, value: data) == .stored
        else { return }
        changed()
    }

    func isSecretSet(_ key: String) -> Bool {
        _ = revision
        return secret(key) != nil
    }

    /// Only for substituting into a request; never sent to the plugin.
    func secret(_ key: String) -> String? {
        guard declaration(key)?.kind == .secret else { return nil }
        return secrets.secret(for: account(key)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Empty or nil clears it.
    /// Returns false when nothing was stored, so the form can keep what the user pasted.
    @discardableResult
    func setSecret(_ key: String, _ value: String?) -> Bool {
        guard declaration(key)?.kind == .secret else { return false }
        let value = value?.isEmpty == false ? value : nil
        guard secrets.setSecret(value.map { Data($0.utf8) }, for: account(key)) else { return false }
        changed()
        return true
    }

    func declaration(_ key: String) -> PluginSetting? {
        declared.first { $0.key == key }
    }

    private func stored(_ key: String) -> PluginSettingValue? {
        _ = revision
        return storage.get(key).flatMap { try? JSONDecoder().decode(PluginSettingValue.self, from: $0) }
    }

    private func account(_ key: String) -> String { "\(pluginID)/\(key)" }

    private func changed() {
        revision += 1
        didChange()
    }
}
