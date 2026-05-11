import Testing
@testable import Alas

struct MarkdownViewModeTests {
    @Test func cyclesEditorSplitPreview() {
        #expect(MarkdownViewMode.editor.next() == .split)
        #expect(MarkdownViewMode.split.next() == .preview)
        #expect(MarkdownViewMode.preview.next() == .editor)
    }

    @Test func rawValuesAreStable() {
        // Persisted in JSON. If these change, in-flight tab state files will
        // silently fall back to the default — keep them locked.
        #expect(MarkdownViewMode.editor.rawValue == "editor")
        #expect(MarkdownViewMode.split.rawValue == "split")
        #expect(MarkdownViewMode.preview.rawValue == "preview")
    }
}
