import Foundation

enum AlasCLIReviewTargetResolver {
    enum Target: Equatable {
        case number(Int)
        case url(host: String, repositorySlug: String, number: Int)
        case range(base: String, head: String, threeDot: Bool)
        /// A bare ref (branch, SHA, HEAD~n, tag). Whether it is a branch or
        /// a commit requires git and is decided at execution time.
        case revision(String)
    }

    static func parse(_ raw: String) -> Target? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let number = Int(trimmed) {
            return number > 0 ? .number(number) : nil
        }
        // Ranges before URLs: neither separator appears in provider URLs.
        if let range = parseRange(trimmed, separator: "...", threeDot: true) {
            return range
        }
        if trimmed.contains("...") { return nil }
        if let range = parseRange(trimmed, separator: "..", threeDot: false) {
            return range
        }
        if trimmed.contains("..") { return nil }
        if trimmed.contains("://") {
            return parseProviderURL(trimmed)
        }
        // A bare revision candidate: branch name, SHA, HEAD~n, tag. Reject
        // whitespace so shell-quoting accidents fail loudly.
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        return .revision(trimmed)
    }

    private static func parseRange(_ value: String, separator: String, threeDot: Bool) -> Target? {
        guard let separatorRange = value.range(of: separator) else { return nil }
        let base = String(value[..<separatorRange.lowerBound])
        let head = String(value[separatorRange.upperBound...])
        guard !base.isEmpty, !head.isEmpty,
              base.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              head.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !head.contains("..")
        else { return nil }
        return .range(base: base, head: head, threeDot: threeDot)
    }

    private static func parseProviderURL(_ trimmed: String) -> Target? {
        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased() else {
            return nil
        }
        let parts = components.path.split(separator: "/").map(String.init)
        if host == "github.com",
           let pullIndex = parts.firstIndex(of: "pull"),
           pullIndex >= 2,
           pullIndex + 1 < parts.count,
           let number = Int(parts[pullIndex + 1]),
           number > 0 {
            return .url(
                host: host,
                repositorySlug: parts[..<pullIndex].joined(separator: "/"),
                number: number
            )
        }
        if host == "gitlab.com" || host.split(separator: ".").first == "gitlab",
           let mergeIndex = parts.firstIndex(of: "merge_requests"),
           mergeIndex >= 2,
           mergeIndex + 1 < parts.count,
           let number = Int(parts[mergeIndex + 1]),
           number > 0 {
            let slugParts = parts[..<mergeIndex].filter { $0 != "-" }
            return .url(
                host: host,
                repositorySlug: slugParts.joined(separator: "/"),
                number: number
            )
        }
        return nil
    }
}
