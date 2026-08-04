import Foundation

enum MissionBranchName {
    static func make(displayReference: String?, title: String, prefix: String) -> String {
        let referenceComponent = displayReference.map(slug) ?? ""
        let titleComponent = slug(title)
        let components = [referenceComponent, titleComponent.isEmpty ? "issue" : titleComponent]
        return "\(prefix)\(components.joined(separator: "-"))"
    }

    static func make(issueNumber: Int, title: String, prefix: String) -> String {
        make(displayReference: "#\(issueNumber)", title: title, prefix: prefix)
    }

    private static func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
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
        return String(slug.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

enum MissionPromptBuilder {
    static func build(source: MissionSourceSnapshot) -> String {
        var lines = [
            openingLine(for: source),
            "Inspect the attached work item context, keep the change focused, add regression coverage, and verify the result.",
            "",
            "## Work item context",
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
        return lines.joined(separator: "\n")
    }

    static func build(snapshot: MissionIssueSnapshot) -> String {
        build(source: .init(issue: snapshot))
    }

    static func openingLine(for source: MissionSourceSnapshot) -> String {
        guard source.contentOrigin == .provider,
              let displayReference = source.displayReference,
              !displayReference.isEmpty
        else {
            return "Implement the linked work item."
        }
        return "Implement \(source.providerLabel) work item \(displayReference)."
    }
}
