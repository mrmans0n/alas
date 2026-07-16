import Foundation

enum ACPDelegatedSessionsPolicy {
    static func statusLabel(for state: String) -> String {
        switch state {
        case "creating_worktree": return "Creating worktree"
        case "starting": return "Starting"
        case "running": return "Working"
        case "awaiting_input": return "Needs input"
        case "failed": return "Failed"
        case "closed": return "Closed"
        default: return "Idle"
        }
    }

    static func ordered(_ sessions: [ACPOrchestrationSessionSummary]) -> [ACPOrchestrationSessionSummary] {
        sessions.sorted {
            if $0.relationship != $1.relationship { return $0.relationship == "parent" }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.sessionId < $1.sessionId
        }
    }
}
