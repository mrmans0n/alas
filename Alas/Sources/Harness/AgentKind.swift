// Alas/Sources/Harness/AgentKind.swift
import Foundation

enum AgentKind: String, CaseIterable, Sendable, Codable, Identifiable {
    case claude
    case codex
    case cursor
    case gemini
    case opencode
    case pi
    case copilot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        case .opencode: return "opencode"
        case .pi: return "Pi"
        case .copilot: return "Copilot"
        }
    }

    var logoAssetName: String {
        switch self {
        case .claude:   return "agent-claude"
        case .codex:    return "agent-codex"
        case .cursor:   return "agent-cursor"
        case .gemini:   return "agent-gemini"
        case .opencode: return "agent-opencode"
        case .pi:       return "agent-pi"
        case .copilot:  return "agent-copilot"
        }
    }
}
