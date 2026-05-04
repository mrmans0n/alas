import Foundation

enum HarnessKind: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "claude-code"
    case codex      = "codex-cli"
    case aider      = "aider"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        case .aider:      return "Aider"
        }
    }

    /// Process names (basename of executable) used for detection.
    var processNames: [String] {
        switch self {
        case .claudeCode: return ["claude", "claude-code"]
        case .codex:      return ["codex", "codex-cli"]
        case .aider:      return ["aider"]
        }
    }
}
