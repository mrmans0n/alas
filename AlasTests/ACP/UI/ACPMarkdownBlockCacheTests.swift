import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPMarkdownBlockCache")
struct ACPMarkdownBlockCacheTests {
    @Test("table columns distribute available width after dividers")
    func tableColumnsDistributeAvailableWidth() {
        let width = ACPMarkdownText.tableColumnWidth(availableWidth: 720, columnCount: 3)
        #expect(abs(width - 719.0 / 3.0) < 0.001)
    }

    @Test("table columns retain their minimum width")
    func tableColumnsRetainMinimumWidth() {
        #expect(ACPMarkdownText.tableColumnWidth(availableWidth: 600, columnCount: 8) == 100)
    }

    @Test("table columns have no width without columns")
    func tableColumnsHaveNoWidthWithoutColumns() {
        #expect(ACPMarkdownText.tableColumnWidth(availableWidth: 720, columnCount: 0) == 0)
    }

    @Test("two paragraphs separated by blank line both become stable once a third arrives")
    func paragraphsPromoteOnBoundary() async {
        let cache = ACPMarkdownBlockCache()
        cache.update(with: "para 1\n\npara 2")
        let firstStable = cache.stableBlocks.count
        cache.update(with: "para 1\n\npara 2\n\npara 3")
        #expect(cache.stableBlocks.count > firstStable)
    }

    @Test("blank line inside an unclosed fence does NOT promote stable blocks")
    func fenceKeepsUnstable() async {
        let cache = ACPMarkdownBlockCache()
        cache.update(with: "intro\n\n```\ncode line 1")
        let stableAfterOpen = cache.stableBlocks.count
        cache.update(with: "intro\n\n```\ncode line 1\n\ncode line 2 still inside fence")
        // Blank line inside the fence: no new stable blocks.
        #expect(cache.stableBlocks.count == stableAfterOpen)
        cache.update(with: "intro\n\n```\ncode line 1\n\ncode line 2\n```\n\nafter")
        // Fence closed + blank line: the code block (and intro) are now stable.
        #expect(cache.stableBlocks.count > stableAfterOpen)
    }

    @Test("unclosed fenced code remains a streaming block")
    func unclosedFenceParsesAsStreamingCode() async {
        let cache = ACPMarkdownBlockCache()
        cache.update(with: "```swift\nfunc greet() {\n")

        #expect(ACPMarkdownText.parse(cache.tailUnparsed) == [
            .streamingCode(language: "swift", body: "func greet() {\n"),
        ])

        cache.update(with: "```swift\nfunc greet() {\n}\n```")

        #expect(ACPMarkdownText.parse(cache.tailUnparsed) == [
            .code(language: "swift", body: "func greet() {\n}"),
        ])
    }

    @Test("closed mermaid fence becomes diagram but open fence stays streaming code")
    func mermaidFenceLifecycle() {
        #expect(ACPMarkdownText.parse("""
        ```mermaid
        graph TD; A-->B
        ```
        """) == [.mermaid(source: "graph TD; A-->B")])

        #expect(ACPMarkdownText.parse("""
        ```mermaid
        graph TD; A-->B
        """) == [.streamingCode(language: "mermaid", body: "graph TD; A-->B")])
    }

    @Test("blank line inside an unclosed tilde fence does NOT promote stable blocks")
    func tildeFenceKeepsUnstable() async {
        let cache = ACPMarkdownBlockCache()
        cache.update(with: "intro\n\n~~~sh\ncurl https://example.com/api")
        let stableAfterOpen = cache.stableBlocks.count
        cache.update(with: "intro\n\n~~~sh\ncurl https://example.com/api\n\nstill code")
        #expect(cache.stableBlocks.count == stableAfterOpen)
        cache.update(with: "intro\n\n~~~sh\ncurl https://example.com/api\n\nstill code\n~~~\n\nafter")
        #expect(cache.stableBlocks.count > stableAfterOpen)
    }

    @Test("cached output equals direct parse for the same input")
    func cacheParityWithDirectParse() async {
        let raw = """
        # Heading

        First paragraph with **bold**.

        ```
        let x = 1
        ```

        Closing paragraph.
        """
        let cache = ACPMarkdownBlockCache()
        cache.update(with: raw)
        let cached = cache.stableBlocks + ACPMarkdownText.parse(cache.tailUnparsed)
        let direct = ACPMarkdownText.parse(raw)
        // Block-by-block comparison: Block must conform to Equatable
        // (synthesized; its associated values are String / [String] / Int).
        #expect(cached == direct)
    }

    @Test("contiguous top-level task lines parse into one task list")
    func parsesTaskListItems() {
        #expect(ACPMarkdownText.parse("""
        - [ ] **Write** `tests`
        - [x] [Review](https://example.com)
        - [X]
        """) == [
            .taskList([
                .init(isChecked: false, text: "**Write** `tests`"),
                .init(isChecked: true, text: "[Review](https://example.com)"),
                .init(isChecked: true, text: ""),
            ]),
        ])
    }

    @Test("ordinary and indented task-looking bullets remain paragraph text")
    func taskLookingBulletsFallBackToParagraphs() {
        #expect(ACPMarkdownText.parse("""
        * [ ] alternate marker
          - [ ] nested item
        - [ ]not a task
        """) == [
            .paragraph("""
            * [ ] alternate marker
              - [ ] nested item
            - [ ]not a task
            """),
        ])
    }

    @Test("task list ends before following prose")
    func taskListToProseBoundary() {
        #expect(ACPMarkdownText.parse("""
        Before tasks
        - [ ] First task
        - [x] Second task
        After tasks
        """) == [
            .paragraph("Before tasks"),
            .taskList([
                .init(isChecked: false, text: "First task"),
                .init(isChecked: true, text: "Second task"),
            ]),
            .paragraph("After tasks"),
        ])
    }

    @Test("cached task list parsing matches direct parsing")
    func taskListCacheParityWithDirectParse() {
        let raw = """
        Intro

        - [ ] First task
        - [X] **Second** task

        Closing paragraph.
        """
        let cache = ACPMarkdownBlockCache()
        cache.update(with: raw)
        let cached = cache.stableBlocks + ACPMarkdownText.parse(cache.tailUnparsed)

        #expect(cached == ACPMarkdownText.parse(raw))
        #expect(cached.contains(where: { block in
            if case .taskList = block { return true }
            return false
        }))
    }

    @Test("streaming updates scan only the appended markdown tail")
    func streamingUpdatesScanOnlyAppendedTail() async {
        let cache = ACPMarkdownBlockCache()
        let longParagraph = String(repeating: "a", count: 10_000)
        cache.update(with: longParagraph)
        let afterInitial = cache.promotionScanCharacterCountForTests

        cache.update(with: longParagraph + "b")

        #expect(cache.promotionScanCharacterCountForTests == afterInitial + 1)
    }

    @Test("streaming hint scans suffix once per revision")
    func streamingHintScansSuffixOncePerRevision() async {
        let cache = ACPMarkdownBlockCache()
        final class Source {}
        let source = Source()
        let sourceID = ObjectIdentifier(source)
        let first = String(repeating: "a", count: 10_000)
        cache.update(with: first, revision: 0, sourceID: sourceID)
        let afterInitial = cache.promotionScanCharacterCountForTests

        let second = first + "b"
        cache.update(with: second, knownAppendedSuffix: "b", revision: 1, sourceID: sourceID)
        cache.update(with: second, knownAppendedSuffix: "b", revision: 1, sourceID: sourceID)

        #expect(cache.promotionScanCharacterCountForTests == afterInitial + 1)
    }

    @Test("same revision from a replacement source reparses new text")
    func repeatedRevisionFromReplacementSourceReparses() async {
        final class Source {}
        let cache = ACPMarkdownBlockCache()
        let oldSource = Source()
        let newSource = Source()
        cache.update(with: "old", revision: 0, sourceID: ObjectIdentifier(oldSource))

        cache.update(with: "new", revision: 0, sourceID: ObjectIdentifier(newSource))

        let cached = cache.stableBlocks + ACPMarkdownText.parse(cache.tailUnparsed)
        #expect(cached == ACPMarkdownText.parse("new"))
    }

    @Test("streaming hint keeps tail length valid when suffix joins previous grapheme")
    func streamingHintHandlesCombiningMarkSuffix() async {
        let cache = ACPMarkdownBlockCache()
        final class Source {}
        let sourceID = ObjectIdentifier(Source())
        cache.update(with: "e", revision: 0, sourceID: sourceID)
        cache.update(with: "e\u{0301}", knownAppendedSuffix: "\u{0301}", revision: 1, sourceID: sourceID)

        cache.update(with: "e\u{0301}\n\nnext", knownAppendedSuffix: "\n\nnext", revision: 2, sourceID: sourceID)

        let cached = cache.stableBlocks + ACPMarkdownText.parse(cache.tailUnparsed)
        let direct = ACPMarkdownText.parse("e\u{0301}\n\nnext")
        #expect(cached == direct)
    }

    @Test("streaming hint handles joining suffix that contains promotion boundary")
    func streamingHintHandlesCombiningMarkSuffixWithBoundary() async {
        let cache = ACPMarkdownBlockCache()
        final class Source {}
        let sourceID = ObjectIdentifier(Source())
        cache.update(with: "e", revision: 0, sourceID: sourceID)

        cache.update(
            with: "e\u{0301}\n\nnext",
            knownAppendedSuffix: "\u{0301}\n\nnext",
            revision: 1,
            sourceID: sourceID
        )

        let cached = cache.stableBlocks + ACPMarkdownText.parse(cache.tailUnparsed)
        let direct = ACPMarkdownText.parse("e\u{0301}\n\nnext")
        #expect(cached == direct)
    }
}
