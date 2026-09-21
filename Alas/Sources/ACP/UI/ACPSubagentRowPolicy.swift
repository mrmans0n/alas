import Foundation

/// Pure presentation decisions for a subagent row, kept out of the view so
/// they can be exercised without SwiftUI.
enum ACPSubagentRowPolicy {
    static func stateLabel(for state: ACPSubagentState) -> String {
        switch state {
        case .running: "Working"
        case .completed: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .disconnected: "Disconnected"
        case .other(let raw): raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// A spinner means "this child is still producing output". Only a
    /// terminal state stops it — an unrecognized state keeps spinning
    /// rather than falsely claiming the child finished.
    static func showsSpinner(state: ACPSubagentState) -> Bool {
        !state.isTerminal
    }

    /// Cancel is offered only when the agent said it would honour it AND
    /// the child is still running: cancelling a finished child would send
    /// an RPC the agent has to reject.
    static func showsCancel(state: ACPSubagentState, capabilities: ACPSubagentCapabilities) -> Bool {
        capabilities.supportsCancel && !state.isTerminal
    }

    /// One-line teaser on the collapsed row: the task, falling back to a
    /// row count so an expandable row never looks empty.
    static func summary(task: String?, messageCount: Int) -> String? {
        if let task, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return task.replacingOccurrences(of: "\n", with: " ")
        }
        guard messageCount > 0 else { return nil }
        return "\(messageCount) \(messageCount == 1 ? "message" : "messages")"
    }

    /// Expanded-state label for the disclosure control.
    static func disclosureLabel(expanded: Bool, messageCount: Int) -> String {
        guard messageCount > 0 else {
            return expanded ? "Hide subagent" : "Show subagent"
        }
        let noun = messageCount == 1 ? "message" : "messages"
        return expanded ? "Hide \(messageCount) \(noun)" : "Show \(messageCount) \(noun)"
    }
}
