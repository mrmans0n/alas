enum ReviewRequestContextBuilder {
    static func build(
        provider: String,
        repository: String,
        branch: String,
        base: String,
        hasUncommittedChanges: Bool,
        commitSubjects: [String],
        diff: String
    ) -> String {
        var lines: [String] = []
        lines.append("# Provider: \(provider)")
        lines.append("# Repository: \(repository)")
        lines.append("# Branch: \(branch)")
        lines.append("# Base: \(base)")
        lines.append("# Uncommitted changes: \(hasUncommittedChanges ? "present but excluded" : "none")")
        if !commitSubjects.isEmpty {
            lines.append("# Commit subjects:")
            for subject in commitSubjects {
                lines.append("#   \(subject)")
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + diff
    }
}
