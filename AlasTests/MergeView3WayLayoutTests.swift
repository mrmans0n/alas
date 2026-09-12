import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct MergeView3WayLayoutTests {
    @Test func minimapIsHiddenWhenCenterPaneIsTooNarrow() throws {
        let model = Self.makeModel()
        try assertMinimapVisibility(width: 700, visible: false, model: model)
        try assertMinimapVisibility(width: 1_200, visible: true, model: model)
    }

    private static func makeModel() -> MergeConflictTabModel {
        let model = MergeConflictTabModel(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-layout-test"),
            relativePath: "long.swift",
            gitService: GitService()
        )
        model.resultText = longConflictText(lineCount: 1_200)
        model.reparse()
        return model
    }

    @discardableResult
    private func assertMinimapVisibility(width: CGFloat, visible: Bool, model: MergeConflictTabModel) throws -> NSHostingController<AnyView> {
        let view = MergeView3Way(
            model: model,
            fileExtension: "swift",
            codeFontFamily: "SF Mono",
            codeFontSize: 13,
            showBase: false,
            onJumpToConflict: { _ in }
        )
        .environment(\.theme, try ThemeStore().current)
        let controller = NSHostingController(rootView: AnyView(view))
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        controller.view.layoutSubtreeIfNeeded()

        let divider = controller.view.descendantViews { view in
            abs(view.frame.width - 6) < 0.5 && abs(view.frame.height - 14) < 0.5
        }
        if visible {
            #expect(!divider.isEmpty)
        } else {
            #expect(divider.isEmpty)
        }
        return controller
    }

    @Test func longConflictedFilesDoNotExpandMergeViewHeight() throws {
        let model = MergeConflictTabModel(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-layout-test"),
            relativePath: "long.swift",
            gitService: GitService()
        )
        model.resultText = Self.longConflictText(lineCount: 1_200)
        model.reparse()

        let view = MergeView3Way(
            model: model,
            fileExtension: "swift",
            codeFontFamily: "SF Mono",
            codeFontSize: 13,
            showBase: false,
            onJumpToConflict: { _ in }
        )
        .environment(\.theme, try ThemeStore().current)

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 600)
        controller.view.layoutSubtreeIfNeeded()

        let fittingSize = controller.sizeThatFits(
            in: NSSize(width: 1_200, height: 600)
        )

        #expect(fittingSize.height <= 600)

        controller.view.layoutSubtreeIfNeeded()
        let scrollFrames = controller.view.descendantScrollViews().map { $0.convert($0.bounds, to: controller.view) }
        let scrollViews = controller.view.descendantScrollViews()
        let scrollWidths = scrollFrames.map(\.width)
        #expect(scrollWidths.count == 3)
        #expect(scrollWidths.allSatisfy { $0 > 250 })
        #expect(scrollFrames.allSatisfy { $0.minX >= 0 })
        #expect(scrollFrames.allSatisfy { $0.maxX <= 1_200 })
        #expect(scrollViews.filter { $0.verticalRulerView != nil }.count == 2)
        #expect(scrollViews.filter(\.rulersVisible).count == 2)
        let documentFrames = scrollViews.compactMap { $0.documentView?.frame }
        #expect(documentFrames.count == 3)
        #expect(documentFrames.allSatisfy { $0.width > 250 })
        #expect(documentFrames.allSatisfy { $0.height > 100 })
    }

    private static func longConflictText(lineCount: Int) -> String {
        let prefix = (0..<lineCount).map { "let before\($0) = \($0)" }.joined(separator: "\n")
        let suffix = (0..<lineCount).map { "let after\($0) = \($0)" }.joined(separator: "\n")
        return """
        \(prefix)
        <<<<<<< HEAD
        let value = "local"
        =======
        let value = "remote"
        >>>>>>> branch
        \(suffix)
        """
    }
}

private extension NSView {
    func descendantScrollViews() -> [NSScrollView] {
        descendantViews { $0 is NSScrollView }.compactMap { $0 as? NSScrollView }
    }

    func descendantViews(where predicate: (NSView) -> Bool) -> [NSView] {
        var result: [NSView] = []
        if predicate(self) { result.append(self) }
        for subview in subviews {
            result.append(contentsOf: subview.descendantViews(where: predicate))
        }
        return result
    }
}
