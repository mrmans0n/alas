import Foundation

enum CommitContextBuilder {
    /// Build the stdin payload for the AI CLI: a `#`-commented header
    /// followed by `---` followed by the staged diff. Empty header
    /// sections are omitted.
    static func build(
        branch: String?,
        base: String?,
        recentSubjects: [String],
        priorMessage: GitService.HeadMessage?,
        diff: String
    ) -> String {
        var lines: [String] = []
        lines.append("# Branch: \(branch ?? "(detached)")")
        if let base { lines.append("# Base: \(base)") }
        if !recentSubjects.isEmpty {
            lines.append("# Recent subjects on this branch:")
            for s in recentSubjects {
                lines.append("#   \(s)")
            }
        }
        if let prior = priorMessage {
            lines.append("# Amending previous commit:")
            lines.append("#   \(prior.subject)")
            if !prior.body.isEmpty {
                lines.append("#")
                for line in prior.body.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("#   \(line)")
                }
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + diff
    }

    static func buildForCommitEdit(
        branch: String?,
        base: String?,
        nearbySubjects: [String],
        priorMessage: GitService.HeadMessage,
        diff: String
    ) -> String {
        var lines: [String] = []
        lines.append("# Editing existing commit message")
        lines.append("# Branch: \(branch ?? "(detached)")")
        if let base { lines.append("# Base: \(base)") }
        if !nearbySubjects.isEmpty {
            lines.append("# Nearby subjects on this branch:")
            for subject in nearbySubjects { lines.append("#   \(subject)") }
        }
        lines.append("# Current commit message:")
        lines.append("#   \(priorMessage.subject)")
        if !priorMessage.body.isEmpty {
            lines.append("#")
            for line in priorMessage.body.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("#   \(line)")
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + diff
    }
}
