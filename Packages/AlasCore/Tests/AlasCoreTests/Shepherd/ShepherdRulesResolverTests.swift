import Foundation
import Testing
@testable import AlasCore

struct ShepherdRulesResolveCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let localFile: String?
    let repoFile: String?
    let settings: ProjectShepherdSettings?
    let source: ShepherdRules.Source
    let instructions: String
    let reviewers: [String]
}

struct ShepherdRulesParseCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let contents: String
    let instructions: String
    let reviewers: [String]
}

private let sampleSettings = ProjectShepherdSettings(
    instructions: "  Settings rules\n",
    requiredReviewers: ["@Codex-Bot", "codex-bot", " "]
)
private let repoFileContents = "---\nrequired_reviewers: [maintainer]\n---\nRepo rules"

private let resolveCases: [ShepherdRulesResolveCase] = [
    .init(testDescription: "local file beats repo file and settings",
          localFile: "Local rules", repoFile: repoFileContents, settings: sampleSettings,
          source: .localFile, instructions: "Local rules", reviewers: []),
    .init(testDescription: "repo file beats settings",
          localFile: nil, repoFile: repoFileContents, settings: sampleSettings,
          source: .repoFile, instructions: "Repo rules", reviewers: ["maintainer"]),
    .init(testDescription: "settings apply when no file exists",
          localFile: nil, repoFile: nil, settings: sampleSettings,
          source: .projectSettings, instructions: "Settings rules", reviewers: ["codex-bot"]),
    .init(testDescription: "empty settings resolve to none",
          localFile: nil, repoFile: nil, settings: ProjectShepherdSettings(),
          source: .none, instructions: "", reviewers: []),
    .init(testDescription: "no source resolves to none",
          localFile: nil, repoFile: nil, settings: nil,
          source: .none, instructions: "", reviewers: []),
    .init(testDescription: "an empty local file still wins",
          localFile: "", repoFile: repoFileContents, settings: sampleSettings,
          source: .localFile, instructions: "", reviewers: []),
]

private let parseCases: [ShepherdRulesParseCase] = [
    .init(testDescription: "flow list",
          contents: "---\nrequired_reviewers: [chatgpt-codex-connector, \"Maintainer\"]\n---\nBatch fixes.\n",
          instructions: "Batch fixes.", reviewers: ["chatgpt-codex-connector", "maintainer"]),
    .init(testDescription: "block list",
          contents: "---\nrequired_reviewers:\n  - chatgpt-codex-connector\n  - '@maintainer'\n---\n\nBatch fixes.",
          instructions: "Batch fixes.", reviewers: ["chatgpt-codex-connector", "maintainer"]),
    .init(testDescription: "no frontmatter",
          contents: "Batch fixes.\n",
          instructions: "Batch fixes.", reviewers: []),
    .init(testDescription: "unterminated frontmatter is plain text",
          contents: "---\nrequired_reviewers: [a]\nBatch fixes.",
          instructions: "---\nrequired_reviewers: [a]\nBatch fixes.", reviewers: []),
    .init(testDescription: "unclosed flow list is ignored",
          contents: "---\nrequired_reviewers: [a, b\n---\nBatch fixes.",
          instructions: "Batch fixes.", reviewers: []),
    .init(testDescription: "unknown keys only",
          contents: "---\nowner: me\n---\n",
          instructions: "", reviewers: []),
    .init(testDescription: "empty file",
          contents: "",
          instructions: "", reviewers: []),
    .init(testDescription: "CRLF line endings",
          contents: "---\r\nrequired_reviewers: [a]\r\n---\r\nBatch fixes.\r\n",
          instructions: "Batch fixes.", reviewers: ["a"]),
]

@Suite struct ShepherdRulesResolverTests {
    @Test("first available source wins completely", arguments: resolveCases)
    func resolve(_ c: ShepherdRulesResolveCase) {
        let rules = ShepherdRulesResolver.resolve(
            localFile: c.localFile, repoFile: c.repoFile, projectSettings: c.settings
        )
        #expect(rules.source == c.source)
        #expect(rules.instructions == c.instructions)
        #expect(rules.requiredReviewers == c.reviewers)
    }

    @Test("frontmatter yields instructions and normalized reviewers", arguments: parseCases)
    func parse(_ c: ShepherdRulesParseCase) {
        let parsed = ShepherdRulesResolver.parse(fileContents: c.contents)
        #expect(parsed.instructions == c.instructions)
        #expect(parsed.requiredReviewers == c.reviewers)
    }

    /// `.alas/shepherd.md` is a directory, so reading it fails.
    @Test("an unreadable repo file fails the load unless the local file wins", arguments: [true, false])
    func unreadableRepoFile(hasLocalFile: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ShepherdRulesResolver.repoFilePath), withIntermediateDirectories: true
        )
        if hasLocalFile {
            try "Local rules".write(
                to: root.appendingPathComponent(ShepherdRulesResolver.localFilePath), atomically: true, encoding: .utf8
            )
            let rules = try await ShepherdRulesResolver.load(worktreePath: root, projectSettings: sampleSettings)
            #expect(rules.source == .localFile)
        } else {
            await #expect(throws: (any Error).self) {
                try await ShepherdRulesResolver.load(worktreePath: root, projectSettings: sampleSettings)
            }
        }
    }

    @Test("a remote read is missing only when cat reports ENOENT", arguments: [
        (Int32(0), "", "rules" as String?),
        (1, "cat: /r/.alas/shepherd.md: No such file or directory\n", nil),
        (1, "cat: can't open '/r/.alas/shepherd.md': No such file or directory\n", nil),
        (1, "cat: /r/.alas/shepherd.md: Permission denied\n", "throws"),
        (1, "cat: /r/.alas/shepherd.md: Is a directory\n", "throws"),
        (255, "ssh: connect to host box: No such file or directory\n", "throws"),
    ])
    func remoteReadContents(exitCode: Int32, stderr: String, expected: String?) throws {
        let result = ProcessResultData(exitCode: exitCode, stdout: Data("rules".utf8), stderr: stderr)
        if expected == "throws" {
            #expect(throws: ShepherdRulesReadError.self) {
                try ShepherdRulesResolver.remoteReadContents(result, file: "shepherd.md", host: "box")
            }
        } else {
            #expect(try ShepherdRulesResolver.remoteReadContents(result, file: "shepherd.md", host: "box") == expected)
        }
    }
}
