import Foundation

/// Pure gating logic for the stacked-diffs integration. UI renders only
/// when every gate passes: master toggle → gg installed → per-project
/// mode → the current branch is actually stack-shaped.
enum GGStackGate {
    /// Gate 3 (auto mode): the repo's main worktree carries gg config.
    /// `repoPath` is the project's primary checkout, where `.git` is a
    /// real directory (linked worktrees have a `.git` file instead).
    static func repoHasGGConfig(repoPath: String) -> Bool {
        let path = (repoPath as NSString).appendingPathComponent(".git/gg/config.json")
        return FileManager.default.fileExists(atPath: path)
    }

    /// Gates 1–3 combined for a project.
    static func projectEnabled(
        masterEnabled: Bool,
        ggInstalled: Bool,
        mode: GGProjectMode,
        repoPath: String
    ) -> Bool {
        guard masterEnabled, ggInstalled else { return false }
        switch mode {
        case .off: return false
        case .on: return true
        case .auto: return repoHasGGConfig(repoPath: repoPath)
        }
    }

    /// Gate 4: any commit ahead of base carries a `GG-ID:` trailer line.
    /// Pure check over already-loaded commit bodies — no extra git call.
    static func isStackShaped(commits: [CommitInfo]) -> Bool {
        commits.contains { commit in
            commit.body.split(whereSeparator: \.isNewline).contains {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("GG-ID:")
            }
        }
    }
}
