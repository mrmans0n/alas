import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct WorktreeRowHeightTests {
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

        #expect(WorktreeRowView.isPending(operationState: .deleting))
        #expect(WorktreeRowView.statusText(for: .deleting) == "Deleting…")
        #expect(WorktreeRowView.showsProgress(operationState: .deleting))

        #expect(!WorktreeRowView.showsProgress(operationState: .creating))
    }

    @Test func rowHeightIsStableWithAndWithoutBadge() throws {
        let withoutBadge = try renderHeight(harnessSummary: nil)
        let withBadge = try renderHeight(harnessSummary: .init(
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
            state: .running,
            agent: .claude,
            primarySessionId: "s1",
            runningSessionCount: 1,
            awaitingSessionCount: 0
        ))
        let awaiting = try renderHeight(harnessSummary: .init(
            state: .awaiting,
            agent: .claude,
            primarySessionId: "s1",
            runningSessionCount: 0,
            awaitingSessionCount: 1
        ))

        #expect(running == awaiting)
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
        let withStack = try renderHeight(harnessSummary: nil, stackSummary: GGStackSummary(merged: 2, total: 3))

        #expect(withoutStack == withStack)
    }

    private func renderHeight(
        harnessSummary: HarnessService.WorktreeHarnessSummary?,
        ggMenuModel: GGWorktreeMenuModel = GGWorktreeMenuModel(
            selectedMode: .inherit,
            context: .inactive(reason: .policyOff),
            hasStackSummary: false
        ),
        stackSummary: GGStackSummary? = nil
    ) throws -> Int {
        let worktree = Worktree(
            id: "wt-1",
            projectId: "p1",
            name: "feature",
            branch: "feature/test",
            path: URL(fileURLWithPath: "/tmp/wt"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
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
            onActivateHarness: {},
            onCopyError: { _ in },
            onRemoveFailed: {},
            onRetryCreate: {},
            onRetryDelete: {},
            onSetGGWorktreeMode: { _ in }
        )
        .environment(\.theme, try ThemeStore().current)

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
        controller.view.layoutSubtreeIfNeeded()

        let fittingSize = controller.sizeThatFits(in: NSSize(width: 260, height: CGFloat.greatestFiniteMagnitude))
        return Int(fittingSize.height)
    }
}
