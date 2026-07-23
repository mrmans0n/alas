import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct ImageDiffStandaloneFailureTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private func theme() -> Theme { try! ThemeStore().current }

    private func waitForRenderPass<V: View>(
        _ controller: NSHostingController<V>,
        until predicate: () -> Bool
    ) async throws {
        for _ in 0..<50 {
            controller.view.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ImageDiffStandaloneFailureTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for render pass",
        ])
    }

    private func subview(
        withAccessibilityIdentifier identifier: String,
        in view: NSView
    ) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap {
            subview(withAccessibilityIdentifier: identifier, in: $0)
        }.first
    }

    @Test func workingCopyLoaderFailureRendersRetryableImagePair() async throws {
        let missingRepository = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-imgdiff-missing-repository-\(UUID().uuidString)")
        let state = AppState(store: MemoryStore())
        let view = DiffTabView(
            worktreePath: missingRepository,
            relativePath: "Assets/logo.png",
            staged: false,
            originalPath: nil,
            compareWithHEAD: false,
            worktreeId: "worktree",
            appState: state,
            onOpenFile: nil,
            onRequestDiscardFile: nil
        )
        .environment(\.theme, theme())
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 520)

        try await waitForRenderPass(controller) {
            subview(withAccessibilityIdentifier: "image-diff-retry", in: controller.view) != nil
        }
    }

    @Test func commitLoaderFailureRendersRetryableImagePair() async throws {
        let missingRepository = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-imgdiff-missing-repository-\(UUID().uuidString)")
        var layoutMode = DiffLayoutMode.split
        var wrapLines = false
        var showWhitespace = false
        let file = CommitChangedFile(
            path: "Assets/logo.png",
            originalPath: nil,
            status: "M",
            add: 0,
            del: 0
        )
        let view = CommitDiffView(
            worktreePath: missingRepository,
            sha: "deadbeef",
            file: file,
            path: file.path,
            diff: ParsedDiff(hunks: []),
            displayModel: nil,
            loading: false,
            error: nil,
            layoutMode: Binding(get: { layoutMode }, set: { layoutMode = $0 }),
            wrapLines: Binding(get: { wrapLines }, set: { wrapLines = $0 }),
            showWhitespace: Binding(get: { showWhitespace }, set: { showWhitespace = $0 }),
            onOpenFile: nil
        )
        .environment(\.theme, theme())
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 520)

        try await waitForRenderPass(controller) {
            subview(withAccessibilityIdentifier: "image-diff-retry", in: controller.view) != nil
        }
    }
}
