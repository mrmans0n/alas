import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPMarkdownBlockCache")
struct ACPMarkdownBlockCacheTests {
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
}
