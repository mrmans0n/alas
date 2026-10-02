import CryptoKit
import Foundation

/// Approval key for a plugin. Mirrors `RepoHookTrust`: any byte change to the
/// manifest or the entry script yields a new hash, so the user must approve again.
enum PluginTrust {
    private static let version = "alas-plugin-trust-v1"

    static func hash(manifest: Data, entry: Data) -> String {
        var payload = Data("\(version)\u{0}".utf8)
        payload.append(manifest)
        payload.append(0)
        payload.append(entry)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

/// `capabilities` is what the user granted, stored separately from the
/// manifest's request so later versions can grant a subset.
struct PluginApproval: Codable, Equatable, Sendable {
    let id: String
    let hash: String
    let capabilities: [PluginCapability]
}

struct PluginApprovalStore {
    private static let key = "pluginApprovals.v1"
    private let defaults: UserDefaults

    /// The profile's suite, so an isolated instance never shares approvals or disabled plugins.
    init(defaults: UserDefaults = AlasProfile.userDefaults) {
        self.defaults = defaults
    }

    func approval(id: String, hash: String) -> PluginApproval? {
        guard let approval = all()[id], approval.hash == hash else { return nil }
        return approval
    }

    func approve(_ approval: PluginApproval) {
        var approvals = all()
        approvals[approval.id] = approval
        save(approvals)
    }

    private static let disabledKey = "pluginDisabledIDs.v1"

    /// Disabling keeps the approval, so re-enabling needs no new prompt.
    func isDisabled(id: String) -> Bool {
        defaults.stringArray(forKey: Self.disabledKey)?.contains(id) == true
    }

    func setDisabled(id: String, _ disabled: Bool) {
        var ids = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
        if disabled { ids.insert(id) } else { ids.remove(id) }
        defaults.set(ids.sorted(), forKey: Self.disabledKey)
    }

    func revoke(id: String) {
        var approvals = all()
        approvals[id] = nil
        save(approvals)
    }

    private func all() -> [String: PluginApproval] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: PluginApproval].self, from: data)) ?? [:]
    }

    private func save(_ approvals: [String: PluginApproval]) {
        defaults.set(try? JSONEncoder().encode(approvals), forKey: Self.key)
    }
}
