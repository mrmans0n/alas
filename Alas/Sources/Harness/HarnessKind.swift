import Foundation

enum HarnessKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "claude-code"
    case codex      = "codex-cli"
    case cursor     = "cursor-agent"
    case gemini     = "gemini"
    case opencode   = "opencode"
    case pi         = "pi"
    case omp        = "omp"
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
        case .omp:        return "OMP"
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
        case .omp:        return ["omp"]
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
        case .omp:        return .omp
        case .copilot:    return .copilot
        }
    }
}

extension HarnessKind {
    /// The harness a registry agent id runs in a terminal, or nil when the
    /// agent is not one the detector can recognise — a custom agent, whose
    /// binary matches no `processNames`.
    ///
    /// Two lookups because the built-in ids do not all belong to one
    /// vocabulary: most match `AgentKind`, but Cursor is registered as
    /// `cursor-agent`, which is this enum's own raw value rather than
    /// `AgentKind.cursor`'s. Falling through to the raw value covers that
    /// without pinning a list that a new built-in would silently fall out
    /// of.
    static func forAgentID(_ agentID: String) -> HarnessKind? {
        if let viaAgentKind = AgentKind(rawValue: agentID)?.asHarnessKind {
            return viaAgentKind
        }
        return HarnessKind(rawValue: agentID)
    }

    /// The harness an agent runs, identified by its id when that is a
    /// built-in's and otherwise by the binary it launches.
    ///
    /// A custom agent's id is a UUID, which says nothing about what will be
    /// running, but a custom agent is often just a wrapper around one of
    /// these same CLIs. The binary is what the detector will actually see,
    /// so it is the thing worth asking about.
    static func forAgent(id: String, binary: String) -> HarnessKind? {
        if let viaID = forAgentID(id) { return viaID }
        let executable = (binary as NSString).lastPathComponent
        return HarnessDetector.matchKind(processName: executable)
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
        case .omp:      return .omp
        case .copilot:  return .copilot
        }
    }
}
