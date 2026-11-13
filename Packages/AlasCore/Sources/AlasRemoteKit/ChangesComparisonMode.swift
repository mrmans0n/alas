import Foundation

/// How the Commits section chooses its comparison base.
/// - `auto` (default): compare against `origin/<base>` (falls back to
///   local `<base>`); stable across rebases.
/// - `branchUpstream`: compare against the branch's own `@{u}`.
/// - `manual`: compare against the per-worktree selected base branch.
public enum ChangesComparisonMode: String, Codable, Sendable {
    case auto
    case branchUpstream
    case manual
}
