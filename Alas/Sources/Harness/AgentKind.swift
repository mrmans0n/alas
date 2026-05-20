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
}
