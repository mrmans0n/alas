import Foundation

/// Pure presentation decisions for a subagent row, kept out of the view so
/// they can be exercised without SwiftUI.
enum ACPSubagentRowPolicy {
    static func stateLabel(for state: ACPSubagentState) -> String {
        switch state {
        case .running: "Working"
        case .requiresAction: "Waiting for input"
        case .unconfirmed: "Not active"
        case .completed: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .disconnected: "Disconnected"
        case .other(let raw): raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// A spinner means "this child is still producing output". A terminal
    /// state stops it, and so does a child blocked on the user — an
    /// unrecognized state keeps spinning rather than falsely claiming the
    /// child finished.
    static func showsSpinner(state: ACPSubagentState) -> Bool {
        !state.isTerminal && state != .requiresAction
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

    /// Header caption from what the child itself reported, e.g.
    /// "GPT-5 · High · in pkg". `cwd` nil means the child inherits the
    /// parent's directory, which is not worth repeating. Historical values
    /// (restored or replayed, not seen on this connection) get the suffix
    /// " (last seen)" — once at the end when every shown part is historical,
    /// otherwise on the historical part only.
    static func observationCaption(
        config: ACPSubagentConfigSummary?, cwd: String?, worktreeRoot: String?, directoriesConfirmed: Bool
    ) -> String? {
        var parts: [(text: String, isHistorical: Bool)] = []
        if let config {
            let labels = [config.model, config.effort].compactMap { $0 } + config.parameters
            if !labels.isEmpty { parts.append((labels.joined(separator: " · "), !config.isConfirmed)) }
        }
        if let cwd, let place = directoryLabel(cwd, worktreeRoot: worktreeRoot) {
            parts.append(("in \(place)", !directoriesConfirmed))
        }
        guard !parts.isEmpty else { return nil }
        let suffix = " (last seen)"
        if parts.allSatisfy(\.isHistorical) {
            return parts.map(\.text).joined(separator: " · ") + suffix
        }
        return parts.map { $0.isHistorical ? $0.text + suffix : $0.text }.joined(separator: " · ")
    }

    /// `path` relative to `worktreeRoot` when inside it, else its last
    /// component. The root itself is shown by its own name.
    private static func directoryLabel(_ path: String, worktreeRoot: String?) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if let worktreeRoot {
            let root = URL(fileURLWithPath: worktreeRoot).standardizedFileURL.pathComponents
            if components.count > root.count, Array(components.prefix(root.count)) == root {
                return components.dropFirst(root.count).joined(separator: "/")
            }
        }
        return components.last.flatMap { $0 == "/" ? nil : $0 }
    }

    /// "From parent" / "From <name>" / "Sent to parent" / "Sent to <name>"
    /// for a row that carried a delegation message, seen from
    /// `viewingSessionId`. A participant that is not a known child is the
    /// parent, whichever id it had when the message was sent.
    static func delegationCaption(
        link: ACPDelegationLink, viewingSessionId: String, childNames: [String: String]
    ) -> String {
        func name(_ id: String?) -> String? {
            id.map { childNames[$0] ?? "parent" }
        }
        if link.recipientSessionId == viewingSessionId {
            return name(link.senderSessionId).map { "From \($0)" } ?? "Received message"
        }
        if link.senderSessionId == viewingSessionId {
            return name(link.recipientSessionId).map { "Sent to \($0)" } ?? "Sent message"
        }
        return "Delegated message"
    }

    /// What a delegated row inside `viewingSessionId`'s transcript (a child,
    /// or the root's own tool call) offers to show, labelled by where it
    /// lands. The child's own row in the parent is the row the user is
    /// already inside, so that fallback is dropped rather than offered.
    /// `childNames` holds every known child.
    static func delegationAction(
        link: ACPDelegationLink, viewingSessionId: String,
        parentToolCallIds: Set<String>, childNames: [String: String]
    ) -> ACPDelegationAction? {
        guard let target = ACPDelegationNavigation.counterpart(
            of: link, viewingSessionId: viewingSessionId,
            parentToolCallIds: parentToolCallIds, knownChildIds: Set(childNames.keys)),
            target != .subagentRow(subagentSessionId: viewingSessionId)
        else { return nil }
        let label: String
        switch target {
        case .parentToolCall:
            label = "Show request"
        case .subagentRow(let id), .childMessage(let id, _):
            label = "Show in \(childNames[id] ?? "subagent")"
        }
        return ACPDelegationAction(label: label, target: target)
    }
}

/// A button that reveals the other side of a delegation message.
struct ACPDelegationAction: Equatable {
    let label: String
    let target: ACPDelegationNavigationTarget
}
