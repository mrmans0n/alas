import Foundation

enum HarnessKind: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "claude-code"
    case codex      = "codex-cli"
    case cursor     = "cursor-agent"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        case .cursor:     return "Cursor"
        }
    }

    var processNames: [String] {
        switch self {
        case .claudeCode: return ["claude"]
        case .codex:      return ["codex"]
        case .cursor:     return ["cursor-agent"]
        }
    }

    /// Corresponding `AgentKind` used for activity tracking and notifications.
    /// `HarnessKind` is the process-detector vocabulary; `AgentKind` is the
    /// installer/notifier vocabulary. The mapping is 1:1.
    var asAgentKind: AgentKind {
        switch self {
        case .claudeCode: return .claude
        case .codex:      return .codex
        case .cursor:     return .cursor
        }
    }
}
