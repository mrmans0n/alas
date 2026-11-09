import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Tolerant reads of gg's JSON config. gg persists `defaults.branch_username`
/// on first `gg co` (or the user sets it), so config is a reliable source for
/// any repo where gg has been used; when absent we fail closed (callers
/// disable the dependent feature with a hint) rather than re-implementing
/// gg's gh/glab whoami resolution.
public enum GGConfigReader: Sendable {
    public struct SidebarSnapshot: Equatable, Sendable {
        public var hasConfig = false
        public var branchUsername: String?

        public init(hasConfig: Bool = false, branchUsername: String? = nil) {
            self.hasConfig = hasConfig
            self.branchUsername = branchUsername
        }
    }

    /// Read once per project off the main actor, never while building a row.
    public static func sidebarSnapshots(repoPaths: [String]) async -> [String: SidebarSnapshot] {
        await Task.detached(priority: .utility) {
            var snapshots: [String: SidebarSnapshot] = [:]
            for path in Set(repoPaths) {
                snapshots[path] = SidebarSnapshot(
                    hasConfig: GGStackGate.repoHasGGConfig(repoPath: path),
                    branchUsername: branchUsername(repoPath: path)
                )
            }
            return snapshots
        }.value
    }

    public static var defaultGlobalConfigPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/gg/config.json")
    }

    /// `defaults.branch_username` from the repo's gg config, falling back to
    /// the global config. Nil when neither sets it (or files are unreadable).
    public static func branchUsername(
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
    public static func defaultBase(
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

    public static func effectiveConfig(
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

    /// Repository-local saved review membership. It never proves entry order or current heads.
    /// An absent local file is unknown: gg can inherit global stacks in that case, which
    /// must not be associated with this provider repository. A valid local file replaces
    /// all global stack maps; missing stack/mrs keys therefore mean verified-empty membership.
    public static func stackReviewMembership(repoPath: String) throws -> [String: [Int]] {
        struct Stack: Decodable {
            let mrs: [String: Int]
            enum CodingKeys: CodingKey { case mrs }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                mrs = container.contains(.mrs) ? try container.decode([String: Int].self, forKey: .mrs) : [:]
            }
        }
        struct Config: Decodable {
            let stacks: [String: Stack]
            enum CodingKeys: CodingKey { case stacks }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                stacks = container.contains(.stacks) ? try container.decode([String: Stack].self, forKey: .stacks) : [:]
            }
        }
        guard let path = GGStackGate.ggConfigPath(repoPath: repoPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw GGServiceError.malformedOutput("Repository-local gg review membership is unavailable. Refresh native gg before using inbox actions.")
        }
        guard data.count <= 4_000_000,
              let config = try? JSONDecoder().decode(Config.self, from: data),
              config.stacks.count <= 500 else {
            throw GGServiceError.malformedOutput("Repository-local gg review membership is malformed or oversized.")
        }
        var membership: [String: [Int]] = [:]
        for (name, stack) in config.stacks {
            let values = stack.mrs
            guard values.count <= 500, values.values.allSatisfy({ $0 > 0 }) else {
                throw GGServiceError.malformedOutput("Saved gg review membership for \(name) is invalid or oversized.")
            }
            membership[name] = Set(values.values).sorted()
        }
        return membership
    }

    /// gg's stack-branch naming convention.
    public static func composeStackBranch(username: String, stackName: String) -> String {
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

        public init(defaults: EffectiveDefaults? = nil) {
            self.defaults = defaults
        }
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
