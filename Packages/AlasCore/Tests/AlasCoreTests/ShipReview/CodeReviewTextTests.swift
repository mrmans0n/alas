import Foundation
import Testing
import AlasModel
@testable import AlasIntegrations

@Suite struct CodeReviewTextTests {
    static let twoFileDiff = """
    diff --git a/Sources/A.swift b/Sources/A.swift
    index 1111111..2222222 100644
    --- a/Sources/A.swift
    +++ b/Sources/A.swift
    @@ -10,3 +10,4 @@ struct A {
         let x = 1
    +    // ponytail: remove me
         let y = 2
         let z = 3
    diff --git a/Sources/B.swift b/Sources/B.swift
    new file mode 100644
    --- /dev/null
    +++ b/Sources/B.swift
    @@ -0,0 +1,2 @@
    +let b = 1
    +let c = 2
    """

    @Test func diffSplitsFilesAndHunkRanges() {
        let diff = CodeReviewDiff(rawDiff: Self.twoFileDiff)
        #expect(diff.files.map(\.path) == ["Sources/A.swift", "Sources/B.swift"])
        #expect(diff.files[0].newLineRanges == [10...13])
        #expect(diff.files[1].newLineRanges == [1...2])
    }

    @Test("quoted Git paths decode to the repository path", arguments: [
        // A modified file, from its +++ line.
        #"""
        diff --git "a/Sources/caf\303\251.swift" "b/Sources/caf\303\251.swift"
        --- "a/Sources/caf\303\251.swift"
        +++ "b/Sources/caf\303\251.swift"
        @@ -1,1 +1,2 @@
         let a = 1
        +let b = 2
        """#,
        // A binary file has only the header.
        #"""
        diff --git "a/Sources/caf\303\251.swift" "b/Sources/caf\303\251.swift"
        Binary files differ
        """#,
    ])
    func quotedPaths(_ raw: String) {
        #expect(CodeReviewDiff(rawDiff: raw).files.map(\.path) == ["Sources/café.swift"])
    }

    @Test("the cap keeps whole files in order and lists the rest", arguments: [(Int.max, 2, 0), (1, 0, 2)])
    func diffCap(cap: Int, included: Int, omitted: Int) {
        let split = CodeReviewDiff(rawDiff: Self.twoFileDiff).included(cap: cap)
        #expect(split.included.count == included)
        #expect(split.omitted.count == omitted)
    }

    @Test("prompt layers appear in order and empty ones are skipped", arguments: [
        (CodeReviewInstructions(repoFile: "REPO", project: "PROJ", localFile: "LOCAL"), ["GLOBAL", "## Repository review instructions", "REPO", "## Project review instructions", "PROJ", "## Your review instructions", "LOCAL"]),
        (CodeReviewInstructions(repoFile: nil, project: "  \n", localFile: "LOCAL"), ["GLOBAL", "## Your review instructions", "LOCAL"]),
    ])
    func promptLayerOrder(_ instructions: CodeReviewInstructions, expectedInOrder: [String]) {
        let prompt = CodeReviewPromptBuilder.build(.init(
            globalPrompt: "GLOBAL", instructions: instructions, branch: "feat", base: "main",
            headSHA: "abc1234def", round: 1, maxRounds: 3,
            diff: CodeReviewDiff(rawDiff: Self.twoFileDiff), earlierFindings: []
        ))
        var cursor = prompt.startIndex
        for needle in expectedInOrder {
            let found = prompt.range(of: needle, range: cursor..<prompt.endIndex)
            #expect(found != nil, "missing or out of order: \(needle)")
            if let found { cursor = found.upperBound }
        }
        if instructions.project == "  \n" { #expect(!prompt.contains("## Project review instructions")) }
    }

    @Test func promptListsOmittedFilesAndEarlierFindings() {
        var input = CodeReviewPromptInput(
            globalPrompt: "G", instructions: .init(), branch: "feat", base: "main", headSHA: "abc1234def",
            round: 2, maxRounds: 3, diff: CodeReviewDiff(rawDiff: Self.twoFileDiff),
            earlierFindings: [.init(id: "f1", path: "Sources/A.swift", line: 11, body: "Leftover marker", replies: ["Claude Code: fixed"])]
        )
        let small = CodeReviewPromptBuilder.build(input)
        #expect(small.contains("f1") && small.contains("Leftover marker") && small.contains("Claude Code: fixed"))
        // Force the cap below the first file by building the prompt from a diff whose first patch is huge.
        input.diff = CodeReviewDiff(rawDiff: Self.twoFileDiff.replacingOccurrences(of: "let x = 1", with: String(repeating: "x", count: CodeReviewPromptInput.diffCap)))
        let capped = CodeReviewPromptBuilder.build(input)
        #expect(capped.contains("Sources/A.swift") && capped.contains("Read these files from the worktree"))
    }

    @Test("parser: last JSON block wins, fenced or bare", arguments: [
        "Thinking…\n```json\n{\"verdict\":\"approve\",\"summary\":\"old\",\"findings\":[]}\n```\nThen:\n```json\n{\"verdict\":\"comment\",\"summary\":\"new\",\"findings\":[]}\n```",
        "{\"verdict\":\"comment\",\"summary\":\"new\",\"findings\":[]}",
    ])
    func parserTakesLastBlock(_ message: String) throws {
        let result = try CodeReviewResultParser.parse(message, diff: CodeReviewDiff(rawDiff: Self.twoFileDiff)).get()
        #expect(result.summary == "new")
        #expect(result.isClean)
    }

    @Test func parserMapsAnchors() throws {
        let message = """
        ```json
        {"verdict":"request_changes","summary":"S","findings":[
          {"path":"Sources/A.swift","line":11,"end_line":11,"body":"in hunk"},
          {"path":"Sources/A.swift","line":400,"body":"outside hunk"},
          {"path":"Docs/X.md","line":3,"body":"not in diff"}
        ],"resolved":["f1"]}
        ```
        """
        let result = try CodeReviewResultParser.parse(message, diff: CodeReviewDiff(rawDiff: Self.twoFileDiff)).get()
        #expect(result.verdict == .requestChanges)
        #expect(result.findings == [
            .init(path: "Sources/A.swift", anchor: .line(start: 11, end: 11), body: "in hunk"),
            .init(path: "Sources/A.swift", anchor: .file, body: "outside hunk"),
        ])
        #expect(result.summary.contains("Docs/X.md:3") && result.summary.contains("not in diff"))
        #expect(result.resolvedIDs == ["f1"])
        #expect(result.unfiledCount == 1)
        #expect(!result.isClean)
    }

    @Test("parser failures", arguments: [("no json here", CodeReviewResultParser.Failure.noResult)])
    func parserFailures(_ message: String, expected: CodeReviewResultParser.Failure) {
        #expect(CodeReviewResultParser.parse(message, diff: CodeReviewDiff(rawDiff: "")) == .failure(expected))
    }

    @Test func parserRejectsAnUnknownVerdict() {
        let result = CodeReviewResultParser.parse(#"{"verdict":"lgtm","summary":"","findings":[]}"#, diff: CodeReviewDiff(rawDiff: ""))
        guard case .failure(.malformed) = result else {
            Issue.record("expected malformed, got \(result)")
            return
        }
    }
}
