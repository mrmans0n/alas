import Foundation

enum HarnessKind: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "claude-code"
    case codex      = "codex-cli"
    case cursor     = "cursor-agent"
    case gemini     = "gemini"
    case opencode   = "opencode"
    case pi         = "pi"
    case copilot    = "copilot"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        case .cursor:     return "Cursor"
        case .gemini:     return "Gemini CLI"
        case .opencode:   return "opencode"
        case .pi:         return "Pi"
        case .copilot:    return "Copilot"
        }
    }

    var processNames: [String] {
        switch self {
        case .claudeCode: return ["claude"]
        case .codex:      return ["codex"]
        case .cursor:     return ["cursor-agent"]
        case .gemini:     return ["gemini"]
        case .opencode:   return ["opencode"]
        case .pi:         return ["pi"]
        case .copilot:    return ["copilot"]
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
        case .gemini:     return .gemini
        case .opencode:   return .opencode
        case .pi:         return .pi
        case .copilot:    return .copilot
        }
    }
}

extension AgentKind {
    var asHarnessKind: HarnessKind {
        switch self {
        case .claude:   return .claudeCode
        case .codex:    return .codex
        case .cursor:   return .cursor
        case .gemini:   return .gemini
        case .opencode: return .opencode
        case .pi:       return .pi
        case .copilot:  return .copilot
        }
    }
}
