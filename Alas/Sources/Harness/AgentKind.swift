// Alas/Sources/Harness/AgentKind.swift
import Foundation

enum AgentKind: String, CaseIterable, Sendable, Codable, Identifiable {
    case claude
    case codex
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        }
    }
}
