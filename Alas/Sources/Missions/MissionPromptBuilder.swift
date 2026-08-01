import Foundation

enum MissionBranchName {
    static func make(issueNumber: Int, title: String, prefix: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var slug = ""
        var needsHyphen = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsHyphen, !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                needsHyphen = false
            } else {
                needsHyphen = !slug.isEmpty
            }
        }
        let titleComponent = String(slug.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(prefix)\(issueNumber)-\(titleComponent.isEmpty ? "issue" : titleComponent)"
    }
}

enum MissionPromptBuilder {
    static func build(snapshot: MissionIssueSnapshot) -> String {
        var lines = [
            "Implement \(snapshot.identity.provider.displayName) issue #\(snapshot.identity.number).",
            "Inspect the attached issue context, keep the change focused, add regression coverage, and verify the result.",
            "",
            "## Issue context",
            "**Provider:** \(snapshot.identity.provider.displayName)",
            "**Repository:** \(snapshot.identity.repositorySlug)",
            "**Number:** #\(snapshot.identity.number)",
            "**URL:** \(snapshot.canonicalURL.absoluteString)",
            "**Title:** \(snapshot.title)",
        ]
        if !snapshot.labels.isEmpty { lines.append("**Labels:** \(snapshot.labels.joined(separator: ", "))") }
        if !snapshot.assignees.isEmpty { lines.append("**Assignees:** \(snapshot.assignees.joined(separator: ", "))") }
        if !snapshot.body.isEmpty {
            lines.append("")
            lines.append("**Body:**")
            lines.append(snapshot.body)
        }
        return lines.joined(separator: "\n")
    }
}
