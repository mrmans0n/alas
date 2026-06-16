import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct WorktreeRowHeightTests {
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

    private func renderHeight(
        harnessSummary: HarnessService.WorktreeHarnessSummary?
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

        let view = WorktreeRowView(
            worktree: worktree,
            isSelected: false,
            isMain: false,
            operationState: nil,
            harnessSummary: harnessSummary,
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
            onRetryDelete: {}
        )
        .environment(\.theme, try ThemeStore().current)

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
        controller.view.layoutSubtreeIfNeeded()

        let fittingSize = controller.sizeThatFits(in: NSSize(width: 260, height: CGFloat.greatestFiniteMagnitude))
        return Int(fittingSize.height)
    }
}
