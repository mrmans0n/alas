import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite
@MainActor
struct NativeContextMenuTests {
    @Test func nativeContextMenuRefreshesDynamicSubmenus() throws {
        func makeView(_ titles: [String]) -> some View {
            Color.clear.nativeContextMenu {
                Menu("Parent") {
                    ForEach(titles, id: \.self) { title in
                        Button(title) {}
                    }
                }
            }
        }

        let controller = NSHostingController(rootView: makeView(["One"]))
        controller.view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        controller.view.layoutSubtreeIfNeeded()
        controller.rootView = makeView(["Two", "Three"])
        controller.view.layoutSubtreeIfNeeded()

        let menuView = try #require(descendants(of: controller.view).first {
            $0.accessibilityRole() == .menuButton
        })
        #expect(menuView.frame.size == controller.view.bounds.size)
        #expect(menuView.isAccessibilityElement())
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try #require(menuView.menu(for: event))
        let submenu = try #require(menu.items.first { $0.title == "Parent" }?.submenu)
        #expect(submenu.items.map(\.title) == ["Two", "Three"])
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}

@Suite(.serialized)
@MainActor
struct WorktreeRowHeightTests {
    @Test func projectHeaderExpandsToRevealWorktrees() throws {
        let collapsedHeight = try projectHeight(collapsed: true)
        let expandedHeight = try projectHeight(collapsed: false)
        #expect(expandedHeight > collapsedHeight)
    }

    private func projectHeight(collapsed: Bool) throws -> Int {
        let project = ProjectConfig(id: "p1", name: "Alas", path: "/tmp/alas", color: "blue", addedAt: Date())
        let worktree = Worktree(id: "wt1", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/tmp/alas"), status: .clean, lastActivity: Date())
        let view = RepoGroupView(
            project: project, icon: { $0.icon }, worktrees: [worktree], collapsed: .constant(collapsed), selectedWorktreeId: nil,
            isMain: { _ in true }, upstreamStatus: { _ in nil }, workspaceCheckout: { _ in nil }, operationState: { _ in nil }, harnessSummary: { _ in nil },
            ggMenuModel: { _ in .init(selectedMode: .inherit, context: .inactive(reason: .policyOff), hasStackSummary: false) },
            onSelect: { _ in }, onNewWorktree: {}, onEditProject: {}, onRemoveProject: {}, onOpenGGInbox: nil,
            onResetSort: {}, spaces: [], activeSpaceId: "", isProjectInSpace: { _ in true },
            canRemoveFromSpace: { _ in false }, onToggleSpaceMembership: { _ in }, onOpenTerminal: { _ in },
            onCopyPath: { _ in }, onCopyBranch: { _ in }, onRevealInFinder: { _ in }, onArchive: { _ in },
            onCleanupWorktrees: {},
            onDelete: { _ in }, onDeleteKeepBranch: { _ in }, showKeepBranchOption: false,
            onActivateHarness: { _, _ in }, onCopyError: { _ in }, onRetryCreate: { _ in }, onRetryLaunch: { _ in }, onRetryDelete: { _ in },
            onSetGGWorktreeMode: { _, _ in }, onRemoveFailed: { _ in }, onDropWorktree: { _, _ in },
            onDropProject: { _, _ in }
        ).environment(\.theme, try ThemeStore().current)
        let controller = NSHostingController(rootView: view)
        return Int(controller.sizeThatFits(in: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height)
    }

    @Test func mainWorktreeDoesNotShowRemovalActions() {
        #expect(!WorktreeRowView.showsRemovalActions(isMain: true))
        #expect(WorktreeRowView.showsRemovalActions(isMain: false))
    }

    @Test func workspaceOwnedWorktreeDoesNotShowRemovalActions() {
        #expect(!WorktreeRowView.showsRemovalActions(isMain: false, workspaceOwned: true))
        #expect(WorktreeRowView.showsRemovalActions(isMain: false, workspaceOwned: false))
    }

    @Test func thirdHarnessSessionRemainsVisibleBeforeOverflow() {
        #expect(WorktreeRowView.visibleHarnessSessionCount(for: 2) == 2)
        #expect(WorktreeRowView.visibleHarnessSessionCount(for: 3) == 3)
        #expect(WorktreeRowView.visibleHarnessSessionCount(for: 4) == 3)
    }

    @Test func ggModeMenuUsesStackedDiffsName() {
        #expect(WorktreeRowView.ggModeMenuTitle == "Stacked Diffs Mode")
    }

    @Test func ggStackTooltipUsesCommitTerminology() {
        #expect(WorktreeRowView.stackSummaryTooltip(merged: 1, total: 1)
            == "gg stack · 1 of 1 commit merged")
        #expect(WorktreeRowView.stackSummaryTooltip(merged: 2, total: 3)
            == "gg stack · 2 of 3 commits merged")
    }

    @Test func ggStackAccessibilityLabelMatchesTooltipTerminology() {
        #expect(WorktreeRowView.stackSummaryAccessibilityLabel(merged: 1, total: 1)
            == "gg stack · 1 of 1 commit merged")
        #expect(WorktreeRowView.stackSummaryAccessibilityLabel(merged: 2, total: 3)
            == "gg stack · 2 of 3 commits merged")
    }

    @Test func pendingGGStackIndicatorUsesMutedColorUntilCommitSyncs() {
        #expect(WorktreeRowView.pendingStackIndicatorColorToken() == "fg-faint")
    }

    @Test func deletePhasesUsePendingProgressPresentation() {
        #expect(WorktreeRowView.isPending(operationState: .preparingDelete))
        #expect(WorktreeRowView.statusText(for: .preparingDelete) == "Preparing deletion…")
        #expect(WorktreeRowView.showsProgress(operationState: .preparingDelete))

        #expect(WorktreeRowView.isPending(operationState: .deleting(projectId: "p")))
        #expect(WorktreeRowView.statusText(for: .deleting(projectId: "p")) == "Deleting…")
        #expect(WorktreeRowView.showsProgress(operationState: .deleting(projectId: "p")))

        #expect(!WorktreeRowView.showsProgress(operationState: .creating))
    }

    @Test func rowHeightIsStableWithAndWithoutBadge() throws {
        let withoutBadge = try renderHeight(harnessSummary: nil)
        let withBadge = try renderHeight(harnessSummary: .init(
            sessions: [.init(id: "s1", state: .running, agent: .claude)],
            state: .running,
            agent: .claude,
            primarySessionId: "s1",
            runningSessionCount: 1,
            awaitingSessionCount: 0
        ))

        #expect(withoutBadge == withBadge)
    }

    @Test func rowHeightIsStableAcrossBadgeStates() throws {
        let running = try renderHeight(harnessSummary: .init(
            sessions: [.init(id: "s1", state: .running, agent: .claude)],
            state: .running,
            agent: .claude,
            primarySessionId: "s1",
            runningSessionCount: 1,
            awaitingSessionCount: 0
        ))
        let awaiting = try renderHeight(harnessSummary: .init(
            sessions: [.init(id: "s1", state: .awaiting, agent: .claude)],
            state: .awaiting,
            agent: .claude,
            primarySessionId: "s1",
            runningSessionCount: 0,
            awaitingSessionCount: 1
        ))

        #expect(running == awaiting)
    }

    @Test func diffBarAndCountsKeepTheTwoLineHeightAtNarrowWidths() throws {
        let withoutDiff = try renderHeight(harnessSummary: nil)
        let withDiff = try renderHeight(harnessSummary: nil, addedLines: 412, deletedLines: 88)
        #expect(withDiff == withoutDiff)
    }

    @Test func rowHeightIsStableWithActiveGGIndicator() throws {
        let inactive = try renderHeight(harnessSummary: nil)
        let active = try renderHeight(
            harnessSummary: nil,
            ggMenuModel: GGWorktreeMenuModel(
                selectedMode: .on,
                context: .active(stackName: "feature"),
                hasStackSummary: false
            )
        )

        #expect(inactive == active)
    }

    @Test func rowHeightIsStableWithAndWithoutGGStackMarker() throws {
        let withoutStack = try renderHeight(harnessSummary: nil, stackSummary: nil)
        let withStack = try renderHeight(
            harnessSummary: nil,
            ggMenuModel: .init(selectedMode: .on, context: .active(stackName: "feature"), hasStackSummary: true),
            stackSummary: GGStackSummary(merged: 2, total: 3)
        )

        #expect(withoutStack == withStack)
    }
    @Test func rowHeightIsStableWithWorkspaceCheckout() throws {
        let withoutWorkspaceCheckout = try renderHeight(harnessSummary: nil)
        let withWorkspaceCheckout = try renderHeight(
            harnessSummary: nil,
            workspaceCheckout: .init(name: "Workspace Release", state: .active)
        )

        #expect(withoutWorkspaceCheckout == withWorkspaceCheckout)
    }

    private func renderHeight(
        harnessSummary: HarnessService.WorktreeHarnessSummary?,
        ggMenuModel: GGWorktreeMenuModel = GGWorktreeMenuModel(
            selectedMode: .inherit,
            context: .inactive(reason: .policyOff),
            hasStackSummary: false
        ),
        stackSummary: GGStackSummary? = nil,
        workspaceCheckout: WorktreeWorkspaceCheckoutPresentation? = nil,
        addedLines: Int = 0,
        deletedLines: Int = 0
    ) throws -> Int {
        let worktree = Worktree(
            id: "wt-1",
            projectId: "p1",
            name: "feature",
            branch: "feature/test",
            path: URL(fileURLWithPath: "/tmp/wt"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0),
            addedLines: addedLines,
            deletedLines: deletedLines
        )

        GGStackSummaryStore.shared.summaries.removeAll()
        if let stackSummary {
            GGStackSummaryStore.shared.summaries[worktree.path.path] = stackSummary
        }
        defer {
            GGStackSummaryStore.shared.summaries.removeAll()
        }

        let view = WorktreeRowView(
            worktree: worktree,
            isSelected: false,
            isMain: false,
            upstreamStatus: nil,
            operationState: nil,
            harnessSummary: harnessSummary,
            ggMenuModel: ggMenuModel,
            onTap: {},
            onOpenTerminal: {},
            onCopyPath: {},
            onCopyBranch: {},
            onRevealInFinder: {},
            onArchive: {},
            onDelete: {},
            onDeleteKeepBranch: {},
            showKeepBranchOption: false,
            onActivateHarness: { _ in },
            onCopyError: { _ in },
            onRemoveFailed: {},
            onRetryCreate: {},
            onRetryLaunch: {},
            onRetryDelete: {},
            onSetGGWorktreeMode: { _ in },
            workspaceCheckout: workspaceCheckout
        )
        .environment(\.theme, try ThemeStore().current)

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
        controller.view.layoutSubtreeIfNeeded()

        let fittingSize = controller.sizeThatFits(in: NSSize(width: 260, height: CGFloat.greatestFiniteMagnitude))
        return Int(fittingSize.height)
    }
}
