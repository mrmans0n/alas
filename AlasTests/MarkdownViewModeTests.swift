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

    @Test func previewCacheReturnsValueOnlyForMatchingIdentity() {
        let first = MarkdownRenderIdentity(
            worktreePath: "/repo",
            tabId: "tab-1",
            relativePath: "README.md",
            externalAbsolutePath: nil
        )
        let second = MarkdownRenderIdentity(
            worktreePath: "/repo",
            tabId: "tab-2",
            relativePath: "README.md",
            externalAbsolutePath: nil
        )
        var cache = MarkdownPreviewCache<String>()

        cache.beginRender(for: first)
        cache.storeCompletedRender("first preview", for: first)

        #expect(cache.value(for: first) == "first preview")
        #expect(cache.value(for: second) == nil)
    }

    @Test func previewCacheHidesStaleFileContentForReusedMarkdownViewSlot() {
        let readme = MarkdownRenderIdentity(
            worktreePath: "/repo",
            tabId: "readme-tab",
            relativePath: "README.md",
            externalAbsolutePath: nil
        )
        let changelog = MarkdownRenderIdentity(
            worktreePath: "/repo",
            tabId: "changelog-tab",
            relativePath: "CHANGELOG.md",
            externalAbsolutePath: nil
        )
        var cache = MarkdownPreviewCache<String>()

        cache.beginRender(for: readme)
        cache.storeCompletedRender("readme preview", for: readme)

        #expect(cache.value(for: changelog) == nil)
    }

    @Test func previewCacheRejectsLateRenderCompletionAfterIdentityChanges() {
        let readme = MarkdownRenderIdentity(
            worktreePath: "/repo",
            tabId: "readme-tab",
            relativePath: "README.md",
            externalAbsolutePath: nil
        )
        let changelog = MarkdownRenderIdentity(
            worktreePath: "/repo",
            tabId: "changelog-tab",
            relativePath: "CHANGELOG.md",
            externalAbsolutePath: nil
        )
        var cache = MarkdownPreviewCache<String>()

        cache.beginRender(for: readme)
        cache.beginRender(for: changelog)

        #expect(cache.storeCompletedRender("readme preview", for: readme) == false)
        #expect(cache.value(for: readme) == nil)
        #expect(cache.value(for: changelog) == nil)
    }

    @Test func previewCacheInvalidateClearsStoredValue() {
        let identity = MarkdownRenderIdentity(
            worktreePath: "/repo",
            tabId: "tab-1",
            relativePath: "README.md",
            externalAbsolutePath: nil
        )
        var cache = MarkdownPreviewCache<String>()

        cache.beginRender(for: identity)
        cache.storeCompletedRender("preview", for: identity)
        cache.invalidate()

        #expect(cache.value(for: identity) == nil)
    }
}
