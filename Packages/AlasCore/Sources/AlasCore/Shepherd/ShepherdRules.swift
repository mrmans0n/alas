import Foundation

/// Per-project shepherd rules stored in `ProjectConfig.shepherd`.
public struct ProjectShepherdSettings: Codable, Equatable, Sendable {
    public var instructions: String
    public var requiredReviewers: [String]

    private enum CodingKeys: String, CodingKey {
        case instructions, requiredReviewers
    }

    public init(instructions: String = "", requiredReviewers: [String] = []) {
        self.instructions = instructions
        self.requiredReviewers = requiredReviewers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instructions = (try? c.decode(String.self, forKey: .instructions)) ?? ""
        requiredReviewers = (try? c.decode([String].self, forKey: .requiredReviewers)) ?? []
    }

    public var isEmpty: Bool {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ShepherdRulesResolver.normalizedReviewers(requiredReviewers).isEmpty
    }
}

public struct ShepherdRules: Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        case localFile, repoFile, projectSettings, none
    }

    public let source: Source
    public let instructions: String
    /// Lowercased logins without a leading `@`, deduplicated in file order.
    public let requiredReviewers: [String]

    public init(source: Source, instructions: String, requiredReviewers: [String]) {
        self.source = source
        self.instructions = instructions
        self.requiredReviewers = requiredReviewers
    }

    public static let none = ShepherdRules(source: .none, instructions: "", requiredReviewers: [])

    public var sourceLabel: String? {
        switch source {
        case .localFile: ShepherdRulesResolver.localFilePath
        case .repoFile: ShepherdRulesResolver.repoFilePath
        case .projectSettings: "Project settings"
        case .none: nil
        }
    }
}

public enum ShepherdRulesResolver {
    public static let localFilePath = ".alas/shepherd.local.md"
    public static let repoFilePath = ".alas/shepherd.md"

    private static let reviewersKey = "required_reviewers:"

    /// Pure. First non-nil source wins completely; sources are never merged.
    /// A file that exists but is empty still wins, so a local file can switch
    /// off the repo or project rules.
    public static func resolve(
        localFile: String?,
        repoFile: String?,
        projectSettings: ProjectShepherdSettings?
    ) -> ShepherdRules {
        if let localFile { return rules(fromFile: localFile, source: .localFile) }
        if let repoFile { return rules(fromFile: repoFile, source: .repoFile) }
        if let projectSettings, !projectSettings.isEmpty {
            return ShepherdRules(
                source: .projectSettings,
                instructions: projectSettings.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                requiredReviewers: normalizedReviewers(projectSettings.requiredReviewers)
            )
        }
        return .none
    }

    /// Parses optional `---` YAML frontmatter whose only key is
    /// `required_reviewers`, as a flow list (`[a, b]`) or a block list
    /// (`- a`). An unterminated frontmatter block is treated as plain text;
    /// an unclosed flow list yields no reviewers.
    public static func parse(fileContents: String) -> (instructions: String, requiredReviewers: [String]) {
        let text = fileContents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let frontmatter = Array(lines[1..<closing])
        let body = lines[(closing + 1)...].joined(separator: "\n")
        return (
            body.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedReviewers(reviewers(inFrontmatter: frontmatter))
        )
    }

    /// Reads the two files under `worktreePath` (a missing or unreadable file
    /// is nil), over ssh for a remote worktree, then `resolve`.
    public static func load(worktreePath: URL, projectSettings: ProjectShepherdSettings?) async -> ShepherdRules {
        let host = RemoteHostRegistry.shared.host(forPath: worktreePath.path)
        async let localFile = read(worktreePath.appendingPathComponent(localFilePath), host: host)
        async let repoFile = read(worktreePath.appendingPathComponent(repoFilePath), host: host)
        return await resolve(
            localFile: localFile,
            repoFile: repoFile,
            projectSettings: projectSettings
        )
    }

    private static func read(_ url: URL, host: String?) async -> String? {
        guard let host else { return try? String(contentsOf: url, encoding: .utf8) }
        guard case .file(let data, _)? = try? await RemoteFileAccess.read(host: host, path: url.path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func normalizedReviewers(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in raw {
            var login = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if login.hasPrefix("@") { login.removeFirst() }
            guard !login.isEmpty, seen.insert(login).inserted else { continue }
            result.append(login)
        }
        return result
    }

    private static func rules(fromFile contents: String, source: ShepherdRules.Source) -> ShepherdRules {
        let parsed = parse(fileContents: contents)
        return ShepherdRules(
            source: source,
            instructions: parsed.instructions,
            requiredReviewers: parsed.requiredReviewers
        )
    }

    private static func reviewers(inFrontmatter lines: [String]) -> [String] {
        guard let keyIndex = lines.firstIndex(where: { $0.hasPrefix(reviewersKey) }) else { return [] }
        let value = lines[keyIndex].dropFirst(reviewersKey.count).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("[") {
            guard value.hasSuffix("]") else { return [] }
            return value.dropFirst().dropLast().split(separator: ",").map { unquoted(String($0)) }
        }
        if !value.isEmpty { return [unquoted(value)] }
        var items: [String] = []
        for line in lines[(keyIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") else { break }
            items.append(unquoted(String(trimmed.dropFirst())))
        }
        return items
    }

    private static func unquoted(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let first = value.first, first == value.last,
              first == "\"" || first == "'"
        else { return value }
        return String(value.dropFirst().dropLast())
    }
}
