import Testing
import Foundation
@testable import Alas

struct MergeAgentTests {
    @Test func explainPromptIncludesAllThreeSidesAndAsksForOneLine() {
        let block = ConflictBlock(
            local: "let host = \"localhost\"\n",
            base: "let host = \"127.0.0.1\"\n",
            remote: "let host = \"0.0.0.0\"\n",
            localLabel: "HEAD",
            remoteLabel: "feature",
            lineRangeInMerged: 12 ... 18
        )
        let prompt = MergeAgent.explainPrompt(block: block, language: "swift")
        #expect(prompt.contains("LOCAL"))
        #expect(prompt.contains("REMOTE"))
        #expect(prompt.contains("BASE"))
        #expect(prompt.contains("let host = \"localhost\""))
        #expect(prompt.contains("let host = \"127.0.0.1\""))
        #expect(prompt.contains("let host = \"0.0.0.0\""))
        #expect(prompt.contains("one sentence"))
    }

    @Test func explainPromptOmitsBaseWhenNil() {
        let block = ConflictBlock(
            local: "a\n",
            base: nil,
            remote: "b\n",
            localLabel: "HEAD",
            remoteLabel: "feature",
            lineRangeInMerged: 0 ... 4
        )
        let prompt = MergeAgent.explainPrompt(block: block, language: nil)
        #expect(prompt.contains("LOCAL"))
        #expect(prompt.contains("REMOTE"))
        #expect(!prompt.contains("BASE:"))
    }

    @Test func resolvePromptSubstitutesPlaceholdersAndAppendsSides() {
        let prompt = MergeAgent.resolveFilePrompt(
            template: AppConfig.defaultMergeSingleResolvePrompt,
            filePath: "Sources/Foo.swift",
            local: "let a = 1\n",
            base: "let a = 0\n",
            remote: "let a = 2\n",
            mergedWithMarkers: "<<<<<<< HEAD\nlet a = 1\n=======\nlet a = 2\n>>>>>>> feature\n",
            language: "swift"
        )
        #expect(prompt.contains("Sources/Foo.swift"))
        #expect(prompt.contains("LOCAL"))
        #expect(prompt.contains("REMOTE"))
        #expect(prompt.contains("BASE"))
        #expect(prompt.contains("Output ONLY the resolved file"))
        #expect(prompt.contains("swift"))
        #expect(!prompt.contains("{filePath}"))
        #expect(!prompt.contains("{language}"))
    }

    @Test func resolvePromptPreservesUnknownPlaceholders() {
        let template = "Custom prompt for {filePath} in {language}, ticket {ticketId}."
        let prompt = MergeAgent.resolveFilePrompt(
            template: template,
            filePath: "a.swift",
            local: "x",
            base: nil,
            remote: "y",
            mergedWithMarkers: "z",
            language: "swift"
        )
        #expect(prompt.contains("Custom prompt for a.swift in swift, ticket {ticketId}."))
    }

    @Test func parseExplainOutputTakesFirstLineAndTrims() {
        let out = "  LOCAL renamed host; REMOTE changed default.   \n\nignored prose\n"
        let parsed = MergeAgent.parseExplainOutput(out)
        #expect(parsed == "LOCAL renamed host; REMOTE changed default.")
    }

    @Test func parseExplainOutputEmpty() {
        #expect(MergeAgent.parseExplainOutput("") == "")
        #expect(MergeAgent.parseExplainOutput("\n\n") == "")
    }

    @Test func parseResolveOutputStripsLeadingTrailingFencesAndWhitespace() {
        let out = """
        ```swift
        let a = 1
        ```

        """
        let parsed = MergeAgent.parseResolveOutput(out)
        #expect(parsed == "let a = 1\n")
    }

    @Test func parseResolveOutputPassesThroughPlainContent() {
        let out = "let a = 1\nlet b = 2\n"
        #expect(MergeAgent.parseResolveOutput(out) == out)
    }

    @Test func parseResolveOutputPreservesLegitFileStartingWithFence() {
        // A markdown source file that starts with a code fence and never
        // closes the WHOLE document with a fence. Current behavior was to
        // strip; correct behavior is to pass through unchanged.
        let out = """
        ```swift
        let a = 1
        ```
        Some prose after the code block.
        """
        let parsed = MergeAgent.parseResolveOutput(out)
        #expect(parsed == out)
    }

    @Test func parseResolveOutputStripsOnlyWhenFencesAreFullWrappers() {
        let out = """
        ```swift
        let a = 1
        ```
        """
        let parsed = MergeAgent.parseResolveOutput(out)
        #expect(parsed == "let a = 1\n")
    }
}
