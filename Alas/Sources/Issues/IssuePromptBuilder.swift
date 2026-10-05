import Foundation

enum IssueBranchName {
    /// The issue's branch *name*, without any configured branch prefix.
    /// Dialogs compose the prefix themselves (the same way gg composes
    /// `<username>/`), so a seeded name never carries the prefix twice.
    static func make(displayReference: String?, title: String) -> String {
        let titleComponent = slug(title)
        let components = [referenceComponent(displayReference), titleComponent].compactMap { $0 }
        return components.joined(separator: "-")
    }

    /// The slugged ticket reference that leads every issue branch name.
    static func referenceComponent(_ displayReference: String?) -> String? {
        displayReference.map(slug).flatMap { $0.isEmpty ? nil : $0 }
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
    static func build(source: IssueSnapshot, kind: IssueKind? = nil) -> String {
        var lines = [
            openingLine(for: source, kind: kind),
            instructions(for: kind),
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

    static func openingLine(for source: IssueSnapshot, kind: IssueKind? = nil) -> String {
        let verb = verb(for: kind)
        guard source.contentOrigin == .provider,
              let reference = source.displayReference,
              !reference.isEmpty else { return "\(verb) the linked issue." }
        return "\(verb) \(source.providerLabel) issue \(reference)."
    }

    private static func verb(for kind: IssueKind?) -> String {
        switch kind {
        case .bug: "Fix"
        case .research: "Investigate"
        case .docs: "Update documentation for"
        case .chore: "Handle"
        case .enhancement, nil: "Implement"
        }
    }

    private static func instructions(for kind: IssueKind?) -> String {
        switch kind {
        case nil:
            "Inspect the attached issue context, keep the change focused, add regression coverage, and verify the result."
        case .bug:
            "Reproduce the problem first and add a regression test that fails before the fix. Find the root cause instead of patching the symptom, fix it, and verify the test passes."
        case .enhancement:
            "Confirm the scope and acceptance criteria from the issue and call out ambiguities before building. Plan briefly, implement with focused tests, and verify the result."
        case .research:
            "Investigate using the code and other available sources. Report findings, options with trade-offs, and a recommendation. Do not change code unless asked."
        case .docs:
            "Keep the change to documentation and make it accurate against the current code. No build or test run is needed."
        case .chore:
            "No behavior change is intended. Keep the diff minimal and the existing tests green."
        }
    }
}
