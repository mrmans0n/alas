import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct RepoGroupViewLayoutTests {
    @Test func repoHeaderAnchorDoesNotShiftWhenExpanded() throws {
        let collapsedX = try repoIconMinX(collapsed: true)
        let expandedX = try repoIconMinX(collapsed: false)

        #expect(collapsedX == expandedX)
    }

    @Test func projectIconSymbolHeaderAnchorDoesNotShiftWhenExpanded() throws {
        let icon = ProjectIcon(mode: .symbol, color: "#ff0000", symbolName: "terminal")
        let collapsedX = try repoIconMinX(collapsed: true, icon: icon)
        let expandedX = try repoIconMinX(collapsed: false, icon: icon)

        #expect(collapsedX == expandedX)
    }

    private func repoIconMinX(
        collapsed: Bool,
        icon: ProjectIcon = ProjectIcon.default(color: "#ff0000")
    ) throws -> Int {
        let project = ProjectConfig(
            id: "project-1",
            name: "Sample",
            path: "/tmp/sample",
            color: icon.color,
            addedAt: Date(timeIntervalSince1970: 0),
            icon: icon
        )
        let worktrees = [
            Worktree(
                id: "worktree-1",
                projectId: project.id,
                name: "main",
                branch: "main",
                path: URL(fileURLWithPath: "/tmp/sample"),
                status: .clean,
                lastActivity: Date(timeIntervalSince1970: 0)
            )
        ]

        let view = RepoGroupView(
            project: project,
            worktrees: worktrees,
            collapsed: .constant(collapsed),
            selectedWorktreeId: nil,
            isMain: { _ in false },
            operationState: { _ in nil },
            harnessSummary: { _ in nil },
            ggMenuModel: { _ in
                GGWorktreeMenuModel(
                    selectedMode: .inherit,
                    context: .inactive(reason: .policyOff),
                    hasStackSummary: false
                )
            },
            onSelect: { _ in },
            onNewWorktree: {},
            onEditProject: {},
            onRemoveProject: {},
            onOpenGGInbox: nil,
            onResetSort: {},
            spaces: [],
            activeSpaceId: "",
            isProjectInSpace: { _ in false },
            canRemoveFromSpace: { _ in true },
            onToggleSpaceMembership: { _ in },
            onOpenTerminal: { _ in },
            onCopyPath: { _ in },
            onCopyBranch: { _ in },
            onRevealInFinder: { _ in },
            onArchive: { _ in },
            onDelete: { _ in },
            onDeleteKeepBranch: { _ in },
            showKeepBranchOption: false,
            onActivateHarness: { _ in },
            onCopyError: { _ in },
            onRetryCreate: { _ in },
            onRetryDelete: { _ in },
            onSetGGWorktreeMode: { _, _ in },
            onRemoveFailed: { _ in },
            onDropWorktree: { _, _ in },
            onDropProject: { _, _ in }
        )
        .environment(\.theme, try ThemeStore().current)

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: collapsed ? 40 : 100)
        controller.view.layoutSubtreeIfNeeded()

        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)

        var minX: Int?
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.8,
                   color.greenComponent < 0.2,
                   color.blueComponent < 0.2,
                   color.alphaComponent > 0.5 {
                    minX = min(minX ?? x, x)
                }
            }
        }

        return try #require(minX)
    }
}
