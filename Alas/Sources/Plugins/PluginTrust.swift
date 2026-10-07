import CryptoKit
import Foundation

/// Approval key for a plugin. Mirrors `RepoHookTrust`: any byte change to the
/// manifest or the entry script yields a new hash, so the user must approve again.
enum PluginTrust {
    /// v1 separates the manifest and the entry with one NUL, safe only because a JSON manifest cannot hold a raw NUL.
    /// Two scripts can, so a plugin with a `web` page uses v2, which frames every field with its name and length.
    /// Plugins without one keep v1, so their approvals and catalog records stay valid.
    static func hash(manifest: Data, entry: Data, web: Data? = nil) -> String {
        var payload: Data
        if let web {
            payload = Data("alas-plugin-trust-v2\u{0}".utf8)
            for (name, bytes) in [("manifest", manifest), ("entry", entry), ("web", web)] {
                payload.append(Data("\(name)\u{0}\(bytes.count)\u{0}".utf8))
                payload.append(bytes)
            }
        } else {
            payload = Data("alas-plugin-trust-v1\u{0}".utf8)
            payload.append(manifest)
            payload.append(0)
            payload.append(entry)
        }
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

/// What an update asks for that the approved version it replaces did not, covering everything the approval sheet
/// discloses. Empty means the update keeps or drops permissions, so it installs approved without asking again.
enum PluginPermissionChange {
    static func added(approved old: PluginManifest, granted: [PluginCapability], update new: PluginManifest) -> [String] {
        var added = new.capabilities.filter { !granted.contains($0) }.map(\.summary)
        added += new.network.filter { !old.network.contains($0) }.map { "Make web requests to \($0)" }
        // A command that took appended arguments already ran anything starting with it; one that did not, only itself.
        for process in new.processes {
            let covered = old.processes.contains {
                $0.appendArgs ? process.command.starts(with: $0.command) : $0.command == process.command && !process.appendArgs
            }
            if !covered { added.append("Run \(PluginArgv.display(process.command))\(process.appendArgs ? " …" : "")") }
        }
        for setting in new.settings where setting.kind == .secret {
            let before = old.settings.first { $0.kind == .secret && $0.key == setting.key }?.hosts ?? []
            for host in setting.hosts where !before.contains(host) { added.append("Use \(setting.title) with \(host)") }
        }
        if new.remote, !old.remote { added.append("Act in projects on SSH hosts, as your user there") }
        if new.web != nil, old.web == nil { added.append("Show its own web content, with no network access") }
        return added
    }
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
