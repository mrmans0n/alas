import Testing
import Markdown
@testable import Alas

struct MarkdownParserTests {
    @Test func parsesSimpleParagraph() {
        let doc = MarkdownParser.parse("Hello, world.")
        #expect(doc.childCount == 1)
        #expect(doc.child(at: 0) is Paragraph)
    }

    @Test func parsesHeadings() {
        let doc = MarkdownParser.parse("# Title")
        let heading = doc.child(at: 0) as? Heading
        #expect(heading?.level == 1)
    }

    @Test func parsesGFMTable() {
        let source = """
        | a | b |
        | - | - |
        | 1 | 2 |
        """
        let doc = MarkdownParser.parse(source)
        #expect(doc.children.contains(where: { $0 is Table }))
    }

    @Test func parsesTaskList() {
        let doc = MarkdownParser.parse("- [x] done\n- [ ] todo")
        let list = doc.child(at: 0) as? UnorderedList
        let items = list?.listItems.map { $0 } ?? []
        #expect(items.count == 2)
        #expect(items[0].checkbox == .checked)
        #expect(items[1].checkbox == .unchecked)
    }

    @Test func parsesStrikethrough() {
        let doc = MarkdownParser.parse("~~gone~~")
        // Walk down to find a Strikethrough node.
        let para = doc.child(at: 0) as? Paragraph
        let hasStrike = para?.children.contains(where: { $0 is Strikethrough }) ?? false
        #expect(hasStrike)
    }
}
