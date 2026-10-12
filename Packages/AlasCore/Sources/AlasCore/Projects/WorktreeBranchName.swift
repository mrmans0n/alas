import Foundation

public enum WorktreeBranchName: Sendable {
    /// Blank settings inherit the next layer; absent templates preserve the
    /// legacy prefix and typed name without sanitizing either.
    public static func compose(
        name: String,
        prefix: String,
        globalTemplate: String? = nil,
        projectTemplate: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard let template = normalizedTemplate(projectTemplate) ?? normalizedTemplate(globalTemplate) else {
            return prefix + name
        }
        return RunSchedulePlanner.renderBranch(template: template, name: name, now: now, calendar: calendar)
    }

    public static func normalizedTemplate(_ template: String?) -> String? {
        guard let value = template?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
