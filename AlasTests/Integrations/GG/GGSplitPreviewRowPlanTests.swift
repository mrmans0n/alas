import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("GG split preview row plan")
struct GGSplitPreviewRowPlanTests {
    @Test("text files, images, and other files retain legacy order with pane-scoped IDs")
    func rowOrderAndIdentity() {
        let store = GGSplitPreviewImageStore()
        let preview = GGSplitPreview(
            files: [previewFile(path: "Sources/First.swift"), previewFile(path: "Sources/Second.swift")],
            nonTextualFiles: ["Assets/result.png", "Assets/archive.bin"]
        )

        let plan = GGSplitPreviewRowPlanBuilder.build(input: input(
            previewID: "remainder",
            preview: preview,
            showsResultingImages: true,
            imageStore: store
        ))
        let ids = plan.rows.map(\.id)

        let firstHeader = try! #require(ids.firstIndex(of: "gg-preview:remainder:file:Sources/First.swift:header"))
        let secondHeader = try! #require(ids.firstIndex(of: "gg-preview:remainder:file:Sources/Second.swift:header"))
        let image = try! #require(ids.firstIndex(of: "gg-preview:remainder:image:Assets/result.png"))
        let other = try! #require(ids.firstIndex(of: "gg-preview:remainder:other:Assets/archive.bin"))
        #expect(firstHeader < secondHeader)
        #expect(secondHeader < image)
        #expect(image < other)
        #expect(ids.filter { $0.contains("Sources/First.swift:hunk:") }.isEmpty == false)
        #expect(ids.filter { $0.contains("Sources/Second.swift:hunk:") }.isEmpty == false)
        #expect(Set(ids).count == ids.count)

        let firstPane = GGSplitPreviewRowPlanBuilder.build(input: input(
            previewID: "first-commit",
            preview: preview,
            showsResultingImages: true,
            imageStore: GGSplitPreviewImageStore()
        ))
        #expect(Set(ids).isDisjoint(with: Set(firstPane.rows.map(\.id))))
    }

    @Test("image state survives plan rebuilds and removed paths are pruned")
    func imageStateRetentionAndPruning() throws {
        let store = GGSplitPreviewImageStore()
        let original = GGSplitPreview(files: [], nonTextualFiles: ["a.png", "b.png"])
        _ = GGSplitPreviewRowPlanBuilder.build(input: input(
            previewID: "remainder", preview: original, showsResultingImages: true, imageStore: store
        ))
        let key = GGSplitPreviewImageKey(
            worktreePath: URL(fileURLWithPath: "/repo"), revision: "abc", relativePath: "a.png"
        )
        let retained = store.state(for: key)

        _ = GGSplitPreviewRowPlanBuilder.build(input: input(
            previewID: "remainder",
            preview: .init(files: [], nonTextualFiles: ["a.png"]),
            showsResultingImages: true,
            imageStore: store
        ))

        #expect(store.state(for: key) === retained)
        #expect(store.keysForTests == [key])
    }

    @Test("feature flag selects only the native preview scroller")
    func featureFlagSwitch() {
        #expect(GGSplitCommitTabView.usesAppKitPreviewScroller(flagEnabled: true))
        #expect(!GGSplitCommitTabView.usesAppKitPreviewScroller(flagEnabled: false))
    }

    @Test("text hunk state survives a preview rebuild and is pruned with its file")
    func textStateRetentionAndPruning() {
        let imageStore = GGSplitPreviewImageStore()
        let presentationStore = GGSplitPreviewPresentationStore()
        let preview = GGSplitPreview(files: [previewFile(path: "Sources/Retained.swift")], nonTextualFiles: [])
        _ = GGSplitPreviewRowPlanBuilder.build(input: input(
            previewID: "remainder", preview: preview, showsResultingImages: false,
            imageStore: imageStore, presentationStore: presentationStore
        ))
        let state = presentationStore.state(previewID: "remainder", filePath: "Sources/Retained.swift")
        state.expandedCollapsedRowIDs = ["collapsed"]

        _ = GGSplitPreviewRowPlanBuilder.build(input: input(
            previewID: "remainder", preview: preview, showsResultingImages: false,
            imageStore: imageStore, presentationStore: presentationStore
        ))
        #expect(presentationStore.state(previewID: "remainder", filePath: "Sources/Retained.swift") === state)
        #expect(state.expandedCollapsedRowIDs == ["collapsed"])

        _ = GGSplitPreviewRowPlanBuilder.build(input: input(
            previewID: "first-commit", preview: .init(files: [previewFile(path: "Sources/First.swift")], nonTextualFiles: []),
            showsResultingImages: false, imageStore: imageStore, presentationStore: presentationStore
        ))
        #expect(presentationStore.state(previewID: "remainder", filePath: "Sources/Retained.swift") === state)

        _ = GGSplitPreviewRowPlanBuilder.build(input: input(
            previewID: "remainder", preview: .init(files: [], nonTextualFiles: []), showsResultingImages: false,
            imageStore: imageStore, presentationStore: presentationStore
        ))
        #expect(presentationStore.keysForTests == ["first-commit:Sources/First.swift"])
    }

    private func input(
        previewID: String,
        preview: GGSplitPreview,
        showsResultingImages: Bool,
        imageStore: GGSplitPreviewImageStore,
        presentationStore: GGSplitPreviewPresentationStore = GGSplitPreviewPresentationStore()
    ) -> GGSplitPreviewRowPlanInput {
        GGSplitPreviewRowPlanInput(
            previewID: previewID,
            preview: preview,
            showsResultingImages: showsResultingImages,
            worktreePath: URL(fileURLWithPath: "/repo"),
            revision: "abc",
            layoutMode: .stacked,
            wrapLines: false,
            showWhitespace: false,
            codeFontFamily: "SF Mono",
            codeFontSize: 13,
            theme: try! ThemeStore().current,
            imageStore: imageStore,
            presentationStore: presentationStore
        )
    }

    private func previewFile(path: String) -> GGSplitPreviewFile {
        let diff = DiffParser.parse("""
        @@ -1 +1 @@
        -let old = 1
        +let new = 1
        """)
        return .init(path: path, hunkIDs: [path], diff: diff)
    }
}
