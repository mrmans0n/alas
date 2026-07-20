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
           let username = readBranchUsername(atPath: repoConfig) {
            return username
        }
        if let globalConfigPath, let username = readBranchUsername(atPath: globalConfigPath) {
            return username
        }
        return nil
    }

    /// gg's stack-branch naming convention.
    static func composeStackBranch(username: String, stackName: String) -> String {
        "\(username)/\(stackName)"
    }

    private static func readBranchUsername(atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaults = object["defaults"] as? [String: Any],
              let username = defaults["branch_username"] as? String,
              !username.isEmpty
        else { return nil }
        return username
    }
}
