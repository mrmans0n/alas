import Foundation

/// One of the supported commit-message AI CLIs. The set is hard-coded —
/// settings only stores which one (by `id`) and an editable prompt.
enum CommitAITool: String, CaseIterable, Equatable, Codable {
    case none
    case claude
    case codex
    case cursorAgent = "cursor-agent"
    case pi

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:        return "None"
        case .claude:      return "Claude Code"
        case .codex:       return "Codex"
        case .cursorAgent: return "Cursor Agent"
        case .pi:          return "Pi"
        }
    }

    var subtitle: String {
        switch self {
        case .none:        return "Don't generate commit messages"
        case .claude:      return "claude -p"
        case .codex:       return "codex exec"
        case .cursorAgent: return "cursor-agent -p"
        case .pi:          return "pi -p"
        }
    }

    /// Binary name to look up via `which`. nil for `.none`.
    var binary: String? {
        switch self {
        case .none:        return nil
        case .claude:      return "claude"
        case .codex:       return "codex"
        case .cursorAgent: return "cursor-agent"
        case .pi:          return "pi"
        }
    }

    /// CLIs that may be detected on PATH (excludes `.none`).
    static var detectable: [CommitAITool] {
        allCases.filter { $0 != .none }
    }
}
