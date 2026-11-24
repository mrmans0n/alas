import Foundation

/// A finding from an earlier round that is still open, with the owner's
/// replies, so the reviewer can check whether it was fixed.
public struct CodeReviewEarlierFinding: Equatable, Sendable {
    public let id: String
    public let path: String
    public let line: Int?
    public let body: String
    /// "Author: text", oldest first.
    public let replies: [String]

    public init(id: String, path: String, line: Int?, body: String, replies: [String]) {
        self.id = id
        self.path = path
        self.line = line
        self.body = body
        self.replies = replies
    }
}

public struct CodeReviewPromptInput: Equatable, Sendable {
    public var globalPrompt: String
    public var instructions: CodeReviewInstructions
    public var branch: String
    public var base: String
    public var headSHA: String
    public var round: Int
    public var maxRounds: Int
    public var diff: CodeReviewDiff
    public var earlierFindings: [CodeReviewEarlierFinding]

    /// Characters of patch text the prompt carries before it lists the
    /// remaining files by path.
    public static let diffCap = 200_000

    public init(
        globalPrompt: String,
        instructions: CodeReviewInstructions,
        branch: String,
        base: String,
        headSHA: String,
        round: Int,
        maxRounds: Int,
        diff: CodeReviewDiff,
        earlierFindings: [CodeReviewEarlierFinding]
    ) {
        self.globalPrompt = globalPrompt
        self.instructions = instructions
        self.branch = branch
        self.base = base
        self.headSHA = headSHA
        self.round = round
        self.maxRounds = maxRounds
        self.diff = diff
        self.earlierFindings = earlierFindings
    }
}

public enum CodeReviewPromptBuilder {
    /// Global prompt, then the repo, project and local instruction layers
    /// (empty ones skipped), then the Alas section: what to review, earlier
    /// findings, rules, the diff and the output format.
    public static func build(_ input: CodeReviewPromptInput) -> String {
        var sections: [String] = []
        if let global = nonBlank(input.globalPrompt) { sections.append(global) }
        let layers: [(String, String?)] = [
            ("## Repository review instructions", input.instructions.repoFile),
            ("## Project review instructions", input.instructions.project),
            ("## Your review instructions", input.instructions.localFile),
        ]
        for (heading, text) in layers {
            if let text = nonBlank(text) { sections.append("\(heading)\n\n\(text)") }
        }

        let shortSHA = String(input.headSHA.prefix(7))
        sections.append(
            "## What to review\n\nBranch \(input.branch) → \(input.base), head \(shortSHA), round \(input.round) of \(input.maxRounds)."
        )

        if !input.earlierFindings.isEmpty {
            var lines = ["## Earlier findings", ""]
            for finding in input.earlierFindings {
                let location = finding.line.map { "\(finding.path):\($0)" } ?? finding.path
                lines.append("- [\(finding.id)] \(location) \(finding.body)")
                lines.append(contentsOf: finding.replies.map { "  - \($0)" })
            }
            lines.append("")
            lines.append(
                "Check each one. Put the ids of the ones now fixed in `resolved`. Report any that still apply again as new findings."
            )
            sections.append(lines.joined(separator: "\n"))
        }

        sections.append(
            "## Rules\n\nYou are reviewing, not editing. Don't modify files, run commands, or call Alas tools. You may read files in the worktree for context."
        )

        let split = input.diff.included(cap: CodeReviewPromptInput.diffCap)
        var diffSection = ["## Diff"]
        if !split.included.isEmpty {
            let patches = split.included.map(\.patch).joined(separator: "\n")
            let fence = ShepherdPromptBuilder.fence(for: patches)
            diffSection.append("\(fence)diff\n\(patches)\n\(fence)")
        }
        if !split.omitted.isEmpty {
            diffSection.append(
                "These files are part of the change but too large to include. Read these files from the worktree:\n"
                    + split.omitted.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        sections.append(diffSection.joined(separator: "\n\n"))

        sections.append("## Output\n\n" + outputFormat)
        return sections.joined(separator: "\n\n")
    }

    private static let outputSchema = """
        {"verdict": "approve" | "request_changes" | "comment",
         "summary": "<two or three sentences>",
         "findings": [{"path": "<repo-relative path>", "line": <new-side line>, "end_line": <optional>, "body": "<problem and concrete fix, Markdown>"}],
         "resolved": ["<earlier finding id>"]}
        """

    private static var outputFormat: String {
        let fence = ShepherdPromptBuilder.fence(for: outputSchema)
        return """
            End your reply with exactly one JSON block in this shape and nothing after it:
            \(fence)json
            \(outputSchema)
            \(fence)
            Use "approve" when nothing needs fixing, "request_changes" when any finding must be fixed before pushing, and "comment" for optional suggestions only.
            """
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
