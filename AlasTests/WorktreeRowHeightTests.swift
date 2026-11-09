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

    /// An empty row, an agent waiting, and every piece of metadata at once.
    enum RowContent: CaseIterable {
        case nothing, waitingAgent, everything
    }

    /// The filter's keyboard cursor draws through the same path as the pointer.
    @Test(arguments: RowContent.allCases, [DesignScale.comfortable, DesignScale.compact])
    func hoverAndSelectionNeverChangeTheRowHeight(content: RowContent, scale: DesignScale) throws {
        let atRest = try renderHeight(content, isSelected: false, scale: scale)
        let hovered = try renderHeight(content, isSelected: false, isHighlighted: true, scale: scale)
        let selected = try renderHeight(content, isSelected: true, scale: scale)
        let selectedHovered = try renderHeight(content, isSelected: true, isHighlighted: true, scale: scale)

        #expect(atRest >= Int(scale.sidebarRowMinHeight))
        #expect(Set([atRest, hovered, selected, selectedHovered]).count == 1)
    }

    private func agentSummary(_ state: HarnessService.AggregatedState) -> HarnessService.WorktreeHarnessSummary {
        .init(
            sessions: [.init(id: "s1", state: state, agent: .claude)],
            state: state,
            agent: .claude,
            primarySessionId: "s1",
            runningSessionCount: state == .running ? 1 : 0,
            awaitingSessionCount: state == .awaiting ? 1 : 0
        )
    }

    private func renderHeight(_ content: RowContent, isSelected: Bool, isHighlighted: Bool = false, scale: DesignScale) throws -> Int {
        let hasStack = content == .everything
        let hasDiff = content == .everything
        let hasCommits = content == .everything
        let hasWorkspaceLink = content == .everything
        let harnessSummary: HarnessService.WorktreeHarnessSummary? = switch content {
        case .waitingAgent: agentSummary(.awaiting)
        case .everything: agentSummary(.running)
        case .nothing: nil
        }
        let ggIsActive = hasStack
        let ggMenuModel = GGWorktreeMenuModel(
            selectedMode: ggIsActive ? .on : .inherit,
            context: ggIsActive ? .active(stackName: "feature") : .inactive(reason: .policyOff),
            hasStackSummary: hasStack
        )
        let stackSummary = hasStack ? GGStackSummary(merged: 2, total: 3) : nil
        let workspaceCheckout: WorktreeWorkspaceCheckoutPresentation? = hasWorkspaceLink
            ? .init(name: "Workspace Release", state: .active, checkoutID: UUID(), memberID: UUID())
            : nil
        let addedLines = hasDiff ? 412 : 0
        let deletedLines = hasDiff ? 88 : 0

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
        // A commit count only shows on a clean row, once its count has loaded.
        let commitQuery = WorktreeRowView.CommitQuery(
            path: worktree.path,
            branch: worktree.branch,
            baseBranch: "main",
            preferLocal: true,
            revision: 0
        )
        if hasCommits {
            WorktreeStatusStore.shared.apply([worktree.path.path: .clean])
            WorktreeRowView.loadedCommitCounts[commitQuery.identity] = .init(
                query: commitQuery,
                commits: GitService.BranchCommitCount(count: 2, baseRef: "main")
            )
        }
        defer {
            GGStackSummaryStore.shared.summaries.removeAll()
            WorktreeStatusStore.shared.prune(keepingPaths: [])
            WorktreeRowView.loadedCommitCounts[commitQuery.identity] = nil
        }

        let view = WorktreeRowView(
            worktree: worktree,
            isSelected: isSelected,
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
            workspaceCheckout: workspaceCheckout,
            commitQuery: hasCommits ? commitQuery : nil,
            isHighlighted: isHighlighted
        )
        .environment(\.theme, try ThemeStore().current)
        .environment(\.designScale, scale)

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
        controller.view.layoutSubtreeIfNeeded()

        let fittingSize = controller.sizeThatFits(in: NSSize(width: 260, height: CGFloat.greatestFiniteMagnitude))
        return Int(fittingSize.height)
    }
}
