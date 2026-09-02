import Foundation

/// Tolerant reads of gg's JSON config. gg persists `defaults.branch_username`
/// on first `gg co` (or the user sets it), so config is a reliable source for
/// any repo where gg has been used; when absent we fail closed (callers
/// disable the dependent feature with a hint) rather than re-implementing
/// gg's gh/glab whoami resolution.
enum GGConfigReader {
    static var defaultGlobalConfigPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/gg/config.json")
    }

    /// `defaults.branch_username` from the repo's gg config, falling back to
    /// the global config. Nil when neither sets it (or files are unreadable).
    static func branchUsername(
        repoPath: String,
        globalConfigPath: String? = GGConfigReader.defaultGlobalConfigPath
    ) -> String? {
        if let repoConfig = GGStackGate.ggConfigPath(repoPath: repoPath),
           let username = readDefault(key: "branch_username", atPath: repoConfig) {
            return username
        }
        if let globalConfigPath, let username = readDefault(key: "branch_username", atPath: globalConfigPath) {
            return username
        }
        return nil
    }

    /// `defaults.base` from the repo's gg config, falling back to the global
    /// config. Nil when neither sets it (or files are unreadable). gg records
    /// this on init; when present it is the commit new stacks are expected to
    /// track, so create-as-stack pins the worktree base to it.
    static func defaultBase(
        repoPath: String,
        globalConfigPath: String? = GGConfigReader.defaultGlobalConfigPath
    ) -> String? {
        if let repoConfig = GGStackGate.ggConfigPath(repoPath: repoPath),
           let base = readDefault(key: "base", atPath: repoConfig) {
            return base
        }
        if let globalConfigPath, let base = readDefault(key: "base", atPath: globalConfigPath) {
            return base
        }
        return nil
    }

    static func effectiveConfig(
        repoPath: String,
        globalConfigPath: String? = GGConfigReader.defaultGlobalConfigPath
    ) -> GGEffectiveConfig {
        let localPath = GGStackGate.ggConfigPath(repoPath: repoPath)
        let hasLocalConfig = localPath.map(FileManager.default.fileExists(atPath:)) ?? false
        let effectiveDefaults = hasLocalConfig
            ? localPath.flatMap(readDefaults(at:))
            : globalConfigPath.flatMap(readDefaults(at:))
        return GGEffectiveConfig(
            syncAutoRebase: effectiveDefaults?.syncAutoRebase
                ?? GGEffectiveConfig.defaults.syncAutoRebase,
            syncBehindThreshold: effectiveDefaults?.syncBehindThreshold.flatMap { $0 >= 0 ? $0 : nil }
                ?? GGEffectiveConfig.defaults.syncBehindThreshold,
            syncAutoLint: effectiveDefaults?.syncAutoLint
                ?? GGEffectiveConfig.defaults.syncAutoLint
        )
    }

    /// gg's stack-branch naming convention.
    static func composeStackBranch(username: String, stackName: String) -> String {
        "\(username)/\(stackName)"
    }

    private static func readDefault(key: String, atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaults = object["defaults"] as? [String: Any],
              let value = defaults[key] as? String,
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func readDefaults(at path: String) -> EffectiveDefaults? {
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(EffectiveConfig.self, from: data)
        else { return nil }
        return config.defaults
    }

    private struct EffectiveConfig: Decodable {
        var defaults: EffectiveDefaults?
    }

    private struct EffectiveDefaults: Decodable {
        var syncAutoRebase: Bool?
        var syncBehindThreshold: Int?
        var syncAutoLint: Bool?

        private enum CodingKeys: String, CodingKey {
            case syncAutoRebase = "sync_auto_rebase"
            case syncBehindThreshold = "sync_behind_threshold"
            case syncAutoLint = "sync_auto_lint"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            syncAutoRebase = try? container.decode(Bool.self, forKey: .syncAutoRebase)
            syncBehindThreshold = try? container.decode(Int.self, forKey: .syncBehindThreshold)
            syncAutoLint = try? container.decode(Bool.self, forKey: .syncAutoLint)
        }
    }
}
