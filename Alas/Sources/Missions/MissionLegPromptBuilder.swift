import Foundation

enum MissionLegPromptBuilder {
    static func build(
        issue: MissionIssueSnapshot,
        existingLegs: [MissionLeg],
        projectName: String,
        branch: String,
        instructions: String
    ) -> String {
        var lines = [
            "Implement the repository-specific portion of \(issue.identity.provider.displayName) issue #\(issue.identity.number).",
            "Work in \(projectName) on branch \(branch). Inspect the shared issue context, keep the change focused, add regression coverage, and verify the result.",
            "",
            "## Issue context",
            "**Provider:** \(issue.identity.provider.displayName)",
            "**Repository:** \(issue.identity.repositorySlug)",
            "**Number:** #\(issue.identity.number)",
            "**URL:** \(issue.canonicalURL.absoluteString)",
            "**Title:** \(issue.title)",
        ]
        if !issue.labels.isEmpty { lines.append("**Labels:** \(issue.labels.joined(separator: ", "))") }
        if !issue.assignees.isEmpty { lines.append("**Assignees:** \(issue.assignees.joined(separator: ", "))") }
        if !issue.body.isEmpty {
            lines.append("")
            lines.append("**Body:**")
            lines.append(issue.body)
        }

        lines.append("")
        lines.append("## Existing Mission legs")
        let orderedLegs = existingLegs.sorted { lhs, rhs in
            if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
            if lhs.projectId != rhs.projectId { return lhs.projectId < rhs.projectId }
            if lhs.branch != rhs.branch { return lhs.branch < rhs.branch }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        if orderedLegs.isEmpty {
            lines.append("- No existing Mission legs.")
        } else {
            lines.append(contentsOf: orderedLegs.map {
                "- \($0.projectId) · \($0.branch) · \(displayName(for: $0.state))"
            })
        }

        lines.append("")
        lines.append("## Repository-specific instructions")
        lines.append(instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }

    private static func displayName(for state: MissionLegState) -> String {
        switch state {
        case .creating: "Creating"
        case .running: "Running"
        case .needsAttention: "Needs attention"
        case .ready: "Ready"
        }
    }
}
