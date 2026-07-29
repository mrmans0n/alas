import Testing
@testable import Alas

struct MarkdownFileTypeTests {
    @Test func detectsByExtension() {
        #expect(MarkdownFileType.isMarkdown(relativePath: "README.md"))
        #expect(MarkdownFileType.isMarkdown(relativePath: "docs/guide.markdown"))
        #expect(MarkdownFileType.isMarkdown(relativePath: "Notes.MD"))
        #expect(MarkdownFileType.isMarkdown(relativePath: "page.mdx"))
    }

    @Test func detectsExtensionlessConventionalNames() {
        #expect(MarkdownFileType.isMarkdown(relativePath: "README"))
        #expect(MarkdownFileType.isMarkdown(relativePath: "readme"))
        #expect(MarkdownFileType.isMarkdown(relativePath: "CHANGELOG"))
        #expect(MarkdownFileType.isMarkdown(relativePath: "CONTRIBUTING"))
        #expect(MarkdownFileType.isMarkdown(relativePath: "LICENSE"))
        #expect(MarkdownFileType.isMarkdown(relativePath: "NOTICE"))
        #expect(MarkdownFileType.isMarkdown(relativePath: "AUTHORS"))
    }

    @Test func detectsNestedPaths() {
        #expect(MarkdownFileType.isMarkdown(relativePath: "src/docs/README.md"))
        #expect(MarkdownFileType.isMarkdown(relativePath: "a/b/c/CHANGELOG"))
    }

    @Test func rejectsNonMarkdown() {
        #expect(!MarkdownFileType.isMarkdown(relativePath: "Cargo.toml"))
        #expect(!MarkdownFileType.isMarkdown(relativePath: "foo.txt"))
        #expect(!MarkdownFileType.isMarkdown(relativePath: "src/main.swift"))
        #expect(!MarkdownFileType.isMarkdown(relativePath: "README.txt"))
        #expect(!MarkdownFileType.isMarkdown(relativePath: ""))
    }

    @Test func recognizesStandaloneMermaidFiles() {
        #expect(MarkdownFileType.isStandaloneMermaid(relativePath: "docs/flow.mmd"))
        #expect(MarkdownFileType.isStandaloneMermaid(relativePath: "ARCH.MERMAID"))
        #expect(!MarkdownFileType.isStandaloneMermaid(relativePath: "README.md"))
        #expect(MarkdownFileType.supportsRichPreview(relativePath: "flow.mmd"))
    }
}
