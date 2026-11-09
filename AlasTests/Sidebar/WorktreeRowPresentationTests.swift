import Foundation
import SwiftUI
import Testing
@testable import Alas

struct WorktreeRowPresentationTests {
    /// A plain file count is the only state without a coloured dot.
    @Test(arguments: [
        (HarnessService.AggregatedState?.some(.running), WorktreeDirtyState.clean, true),
        (.some(.awaiting), .dirty(fileCount: 3, conflictCount: 0), true),
        (nil, .dirty(fileCount: 3, conflictCount: 1), true),
        (nil, .dirty(fileCount: 3, conflictCount: 0), false),
        (nil, .clean, false),
        (nil, .unknown, false),
    ])
    func loudStatus(harnessState: HarnessService.AggregatedState?, worktreeStatus: WorktreeDirtyState, loud: Bool) {
        #expect(WorktreeRowPresentation.isStatusLoud(harnessState: harnessState, worktreeStatus: worktreeStatus) == loud)
    }

    @Test(arguments: [
        (TimeInterval(30), "now"), (90, "1m"), (3_700, "1h"), (90_000, "1d"),
        (700_000, "1w"), (2_700_000, "1mo"), (32_000_000, "1y"),
    ])
    func compactAgeFitsBesideAName(elapsed: TimeInterval, expected: String) {
        let now = Date(timeIntervalSince1970: 100_000_000)
        #expect(WorktreeRowPresentation.compactAge(since: now.addingTimeInterval(-elapsed), now: now) == expected)
    }

    @Test(arguments: ["cool-slate", "light"], ["add", "del", "mod", "warn", "caution", "accent", "fg-dim"])
    func statusTextReachesContrastOnTheSelectedFill(themeId: String, token: String) throws {
        let theme = try Theme.loadBundled(id: themeId)
        let fillToken = WorktreeRowView.sidebarFillToken
        let ratio = Color.contrastRatio(theme.legibleOnSelection(token, over: fillToken), theme.selectionFill(over: fillToken))
        #expect(ratio >= 4.5, "\(token) on \(themeId): \(ratio)")
    }

    @Test func beingBehindUpstreamIsVisibleAtRestAndBeingAheadIsNot() {
        let items = WorktreeUpstreamStatus(ahead: 2, behind: 3, upstreamRef: "origin/main").subtitleItems

        #expect(WorktreeRowPresentation.upstreamItemsAtRest(items).map(\.text) == ["↓3"])
    }

    /// Reads the fields by reflection, so a new one the label forgets fails here.
    @Test func accessibilityLabelSaysEveryFieldARowCanHave() {
        let content = WorktreeRowAccessibilityContent(
            name: "feat/invoice-export",
            statusNote: "1 file",
            added: 48,
            deleted: 6,
            workspaceCheckout: "Workspace Release",
            commits: "2 commits beyond main",
            upstream: ["1 commit behind origin/main"],
            stack: "gg stack · 1 of 3 commits merged",
            agents: ["Claude · running"],
            explanation: "Adds invoice export",
            lastActivity: "9 mo ago"
        )
        let label = WorktreeRowPresentation.accessibilityLabel(content)
        for field in Mirror(reflecting: content).children {
            let values: [String]
            switch field.value {
            case let list as [String]: values = list
            case let text as String: values = [text]
            case let number as Int: values = ["\(number) lines"]
            default:
                Issue.record("Unhandled field \(field.label ?? "?")")
                values = []
            }
            for value in values {
                #expect(label.contains(value), "\(field.label ?? "?") is missing from the label")
            }
        }
    }

    @Test func accessibilityLabelSkipsWhatARowDoesNotHave() {
        let label = WorktreeRowPresentation.accessibilityLabel(WorktreeRowAccessibilityContent(
            name: "main",
            statusNote: nil,
            added: 0,
            deleted: 0,
            workspaceCheckout: nil,
            commits: nil,
            upstream: [],
            stack: nil,
            agents: [],
            explanation: nil,
            lastActivity: "9 mo ago"
        ))
        #expect(label == "main, 9 mo ago")
    }
}
