import Foundation

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

/// A rules file on an SSH host that exists but could not be read, or a host
/// that could not be reached.
public struct ShepherdRulesReadError: LocalizedError, Equatable, Sendable {
    public let file: String
    public let host: String
    public let detail: String

    public var errorDescription: String? {
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Could not read \(file) on \(host)" + (detail.isEmpty ? "." : ": \(detail)")
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
                requiredReviewers: ProjectShepherdSettings.normalizedReviewers(projectSettings.requiredReviewers)
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
            ProjectShepherdSettings.normalizedReviewers(reviewers(inFrontmatter: frontmatter))
        )
    }

    /// Reads the two files under `worktreePath`, over ssh for a remote
    /// worktree, then `resolve`. Only a missing file is nil: a read that
    /// fails throws, so a dropped connection can't pass for a repository
    /// without rules and let the shepherd merge past its required reviewers.
    /// Reads in precedence order, so a source that `resolve` would ignore
    /// can't fail the load.
    public static func load(worktreePath: URL, projectSettings: ProjectShepherdSettings?) async throws -> ShepherdRules {
        let host = RemoteHostRegistry.shared.host(forPath: worktreePath.path)
        if let localFile = try await read(worktreePath.appendingPathComponent(localFilePath), host: host) {
            return resolve(localFile: localFile, repoFile: nil, projectSettings: projectSettings)
        }
        return try await resolve(
            localFile: nil,
            repoFile: read(worktreePath.appendingPathComponent(repoFilePath), host: host),
            projectSettings: projectSettings
        )
    }

    /// Follows symlinks on both sides, so a linked rules file reads the same
    /// locally and over ssh.
    private static func read(_ url: URL, host: String?) async throws -> String? {
        guard let host else {
            do {
                return try String(contentsOf: url, encoding: .utf8)
            } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
                return nil
            }
        }
        let script = "LC_ALL=C cat -- \(SSHCommand.shellQuote(url.path))"
        let result = try await RemoteExec.runData(host: host, cwd: nil, command: script)
        return try remoteReadContents(result, file: url.lastPathComponent, host: host)
    }

    /// The remote `cat`'s result. Only `cat` itself reporting ENOENT means
    /// missing, as a local read's no-such-file does (a dangling link
    /// included). A permission error on the file or a parent, an ssh failure,
    /// or bytes that aren't UTF-8 throw.
    static func remoteReadContents(_ result: ProcessResultData, file: String, host: String) throws -> String? {
        if result.exitCode == 0, let text = String(data: result.stdout, encoding: .utf8) {
            return text
        }
        let catReportedMissing = result.stderr.split(whereSeparator: \.isNewline).contains {
            $0.hasPrefix("cat: ") && $0.hasSuffix(": No such file or directory")
        }
        if result.exitCode == 1, catReportedMissing { return nil }
        throw ShepherdRulesReadError(file: file, host: host, detail: result.stderr)
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
