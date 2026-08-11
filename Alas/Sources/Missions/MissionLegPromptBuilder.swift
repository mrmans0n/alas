import Foundation

enum MissionLegPromptBuilder {
    static func build(
        source: IssueSnapshot,
        existingLegs: [MissionLeg],
        existingProjectNames: [String: String] = [:],
        projectName: String,
        branch: String,
        instructions: String
    ) -> String {
        var lines = [
            repositoryOpeningLine(for: source),
            "Work in \(projectName) on branch \(branch). Inspect the shared issue context, keep the change focused, add regression coverage, and verify the result.",
            "",
            "## Issue context",
            "**Source:** \(source.providerLabel)",
        ]
        if let repositoryLocator = source.repositoryLocator {
            lines.append("**Repository:** \(repositoryLocator.repositorySlug)")
        }
        if let displayReference = source.displayReference, !displayReference.isEmpty {
            lines.append("**Reference:** \(displayReference)")
        }
        lines += [
            "**URL:** \(source.canonicalURL.absoluteString)",
            "**Title:** \(source.title)",
        ]
        if !source.labels.isEmpty { lines.append("**Labels:** \(source.labels.joined(separator: ", "))") }
        if !source.assignees.isEmpty { lines.append("**Assignees:** \(source.assignees.joined(separator: ", "))") }
        if !source.body.isEmpty {
            lines.append("")
            lines.append("**Body:**")
            lines.append(source.body)
        }

        appendLegs(
            to: &lines,
            existingLegs: existingLegs,
            existingProjectNames: existingProjectNames,
            instructions: instructions
        )
        return lines.joined(separator: "\n")
    }

    static func build(
        issue: CodeHostIssueSnapshot,
        existingLegs: [MissionLeg],
        existingProjectNames: [String: String] = [:],
        projectName: String,
        branch: String,
        instructions: String
    ) -> String {
        build(
            source: .init(codeHostIssue: issue),
            existingLegs: existingLegs,
            existingProjectNames: existingProjectNames,
            projectName: projectName,
            branch: branch,
            instructions: instructions
        )
    }

    private static func appendLegs(
        to lines: inout [String],
        existingLegs: [MissionLeg],
        existingProjectNames: [String: String],
        instructions: String
    ) {
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
                let name = existingProjectNames[$0.projectId] ?? $0.projectId
                return "- \(name) · \($0.branch) · \(displayName(for: $0.state))"
            })
        }

        lines.append("")
        lines.append("## Repository-specific instructions")
        lines.append(instructions.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func repositoryOpeningLine(for source: IssueSnapshot) -> String {
        guard source.contentOrigin == .provider,
              let displayReference = source.displayReference,
              !displayReference.isEmpty
        else {
            return "Implement the repository-specific portion of the linked issue."
        }
        return "Implement the repository-specific portion of \(source.providerLabel) issue \(displayReference)."
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
