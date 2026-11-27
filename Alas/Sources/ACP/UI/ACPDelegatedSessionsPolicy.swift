import Foundation

enum ACPDelegatedSessionsPolicy {
    static func statusLabel(for state: String) -> String {
        switch state {
        case "creating_worktree": return "Creating worktree"
        case "starting": return "Starting"
        case "running": return "Working"
        case "awaiting_input": return "Needs input"
        case "reported": return "Done"
        case "reported_failed": return "Failed (reported)"
        case "on_peer": return "On another Mac"
        case "failed": return "Failed"
        case "closed": return "Closed"
        default: return "Idle"
        }
    }

    /// States in which the child is still on its way to a result.
    static func isWorking(_ state: String) -> Bool {
        ["creating_worktree", "starting", "running"].contains(state)
    }

    /// The `prompt` a `session_new` call sent, flattened to one line. Nil for
    /// a CLI call, whose input is a shell command rather than the arguments.
    static func task(fromRawInput rawInput: String?) -> String? {
        guard let data = rawInput?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = (object["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty
        else { return nil }
        return prompt.replacingOccurrences(of: "\n", with: " ")
    }

    static func ordered(_ sessions: [ACPOrchestrationSessionSummary]) -> [ACPOrchestrationSessionSummary] {
        sessions.sorted {
            if $0.relationship != $1.relationship { return $0.relationship == "parent" }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.sessionId < $1.sessionId
        }
    }
}
