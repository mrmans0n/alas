import Foundation

/// Per-project stacked-diffs mode.
/// - `auto` (default): enabled when the repo's main worktree has
///   `.git/gg/config.json`.
/// - `on`: skip the config-file check (still requires a stack-shaped branch).
/// - `off`: hide all gg UI for this project.
enum GGProjectMode: String, Codable, Equatable, CaseIterable {
    case off, auto, on
}
