// Alas/Sources/Harness/AgentKind.swift
import Foundation

public enum AgentKind: String, CaseIterable, Sendable, Codable, Identifiable {
    case claude
    case codex
    case cursor
    case gemini
    case antigravity
    case opencode
    case pi
    case omp
    case copilot

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        case .antigravity: return "Antigravity"
        case .opencode: return "opencode"
        case .pi: return "Pi"
        case .omp: return "OMP"
        case .copilot: return "Copilot"
        }
    }

    public var logoAssetName: String {
        switch self {
        case .claude:   return "agent-claude"
        case .codex:    return "agent-codex"
        case .cursor:   return "agent-cursor"
        case .gemini:   return "agent-gemini"
        case .antigravity: return "agent-antigravity"
        case .opencode: return "agent-opencode"
        case .pi:       return "agent-pi"
        case .omp:      return "agent-omp"
        case .copilot:  return "agent-copilot"
        }
    }
}

extension AgentKind {
    /// The harness kind of ACP agent `id`, sourced from `AgentBuiltins.catalog`.
    /// Unknown ids fall back to `.claude`: badges are drawn from state, not
    /// from the agent, and click-through works from the session id alone.
    public init(acpAgentID id: String) {
        self = switch id {
        case "codex": .codex
        case "cursor-agent": .cursor
        case "gemini": .gemini
        case "antigravity": .antigravity
        case "opencode": .opencode
        case "pi": .pi
        case "omp": .omp
        case "copilot": .copilot
        default: .claude
        }
    }
}
