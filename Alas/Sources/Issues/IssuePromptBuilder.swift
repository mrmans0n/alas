import Foundation

enum IssueBranchName {
    static func make(displayReference: String?, title: String, prefix: String) -> String {
        let referenceComponent = displayReference.map(slug).flatMap { $0.isEmpty ? nil : $0 }
        let titleComponent = slug(title)
        let components = [referenceComponent, titleComponent].compactMap { $0 }
        return "\(prefix)\(components.joined(separator: "-"))"
    }

    static func make(issueNumber: Int, title: String, prefix: String) -> String {
        let legacyTitle = slug(title).isEmpty ? "issue" : title
        return make(displayReference: "#\(issueNumber)", title: legacyTitle, prefix: prefix)
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

enum IssuePromptBuilder {
    static func build(source: IssueSnapshot) -> String {
        var lines = [
            openingLine(for: source),
            "Inspect the attached issue context, keep the change focused, add regression coverage, and verify the result.",
            "",
            "## Issue context",
            "**Source:** \(source.providerLabel)",
        ]
        if let repository = source.repositoryLocator {
            lines.append("**Repository:** \(repository.repositorySlug)")
        }
        if let reference = source.displayReference, !reference.isEmpty {
            lines.append("**Reference:** \(reference)")
        }
        lines += [
            "**URL:** \(source.canonicalURL.absoluteString)",
            "**Title:** \(source.title)",
        ]
        if !source.labels.isEmpty {
            lines.append("**Labels:** \(source.labels.joined(separator: ", "))")
        }
        if !source.assignees.isEmpty {
            lines.append("**Assignees:** \(source.assignees.joined(separator: ", "))")
        }
        if !source.body.isEmpty {
            lines += ["", "**Body:**", source.body]
        }
        return lines.joined(separator: "\n")
    }

    static func openingLine(for source: IssueSnapshot) -> String {
        guard source.contentOrigin == .provider,
              let reference = source.displayReference,
              !reference.isEmpty else { return "Implement the linked issue." }
        return "Implement \(source.providerLabel) issue \(reference)."
    }
}
