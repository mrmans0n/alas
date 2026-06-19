import Foundation

enum AlasCLIReviewTargetResolver {
    enum Target: Equatable {
        case number(Int)
        case url(host: String, repositorySlug: String, number: Int)
    }

    static func parse(_ raw: String) -> Target? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(trimmed), number > 0 {
            return .number(number)
        }
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
