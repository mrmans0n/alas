import Testing
import Markdown
@testable import Alas

struct MarkdownParserTests {
    @Test func parsesSimpleParagraph() {
        let doc = MarkdownParser.parseDocument("Hello, world.")
        #expect(doc.childCount == 1)
        #expect(doc.child(at: 0) is Paragraph)
    }

    @Test func parsesHeadings() {
        let doc = MarkdownParser.parseDocument("# Title")
        let heading = doc.child(at: 0) as? Heading
        #expect(heading?.level == 1)
    }

    @Test func parsesGFMTable() {
        let source = """
        | a | b |
        | - | - |
        | 1 | 2 |
        """
        let doc = MarkdownParser.parseDocument(source)
        #expect(doc.children.contains(where: { $0 is Table }))
    }

    @Test func parsesTaskList() {
        let doc = MarkdownParser.parseDocument("- [x] done\n- [ ] todo")
        let list = doc.child(at: 0) as? UnorderedList
        let items = list?.listItems.map { $0 } ?? []
        #expect(items.count == 2)
        #expect(items[0].checkbox == .checked)
        #expect(items[1].checkbox == .unchecked)
    }

    @Test func parsesStrikethrough() {
        let doc = MarkdownParser.parseDocument("~~gone~~")
        // Walk down to find a Strikethrough node.
        let para = doc.child(at: 0) as? Paragraph
        let hasStrike = para?.children.contains(where: { $0 is Strikethrough }) ?? false
        #expect(hasStrike)
    }

    @Test func parsesLeadingFrontmatterEntries() {
        let parsed = MarkdownParser.parse("""
        ---
        title: "Release Notes"
        date: 2026-05-21
        draft: false
        tags: [swift, markdown]
        # ignored
        invalid
        ---

        # Body
        """)

        #expect(parsed.frontmatter?.entries == [
            MarkdownFrontmatterEntry(key: "title", value: "Release Notes"),
            MarkdownFrontmatterEntry(key: "date", value: "2026-05-21"),
            MarkdownFrontmatterEntry(key: "draft", value: "false"),
            MarkdownFrontmatterEntry(key: "tags", value: "[swift, markdown]")
        ])

        let heading = parsed.document.child(at: 0) as? Heading
        #expect(heading?.plainText == "Body")
    }

    @Test func leavesEmptyFrontmatterBlockAsMarkdown() {
        let parsed = MarkdownParser.parse("""
        ---
        ---

        Body
        """)

        #expect(parsed.frontmatter == nil)
        #expect(parsed.document.children.contains(where: { $0 is ThematicBreak }))
        #expect(parsed.document.children.contains(where: { $0 is Paragraph }))
    }

    @Test func leavesMalformedFrontmatterBlockAsMarkdown() {
        let parsed = MarkdownParser.parse("""
        ---
        invalid
        ---

        Body
        """)

        #expect(parsed.frontmatter == nil)
        #expect(parsed.document.children.contains(where: { $0 is ThematicBreak }))
        #expect(parsed.document.children.contains(where: { $0 is Paragraph }))
    }

    @Test func leavesDocumentsWithoutFrontmatterUnchanged() {
        let parsed = MarkdownParser.parse("Hello\n\n---\n\nWorld")

        #expect(parsed.frontmatter == nil)
        #expect(parsed.document.children.contains(where: { $0 is ThematicBreak }))
    }

    @Test func leavesUnclosedFrontmatterAsMarkdown() {
        let parsed = MarkdownParser.parse("""
        ---
        title: Missing close
        """)

        #expect(parsed.frontmatter == nil)
        #expect(parsed.document.children.contains(where: { $0 is ThematicBreak }))
    }
}
