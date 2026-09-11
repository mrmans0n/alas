import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AttentionInboxViewTests {
    @Test func headerAccessibilityIncludesCountAndZeroHidesBadge() {
        #expect(SidebarHeaderView.attentionAccessibilityLabel(count: 4) == "Open attention inbox, 4 items")
        #expect(SidebarHeaderView.attentionAccessibilityLabel(count: 1) == "Open attention inbox, 1 item")
        #expect(SidebarHeaderView.attentionAccessibilityLabel(count: 0) == "Open attention inbox")
        #expect(!SidebarHeaderView.showsAttentionBadge(count: 0))
        #expect(SidebarHeaderView.showsAttentionBadge(count: 4))
    }

    @Test func activeRowsHaveReasonAttributionTimestampAndTypedAction() {
        let targets: [(AttentionJumpTarget, String)] = [
            (.session(sessionID: "s1"), "Open session"),
            (.runScriptFailure(failureID: "f1"), "View failure"),
            (.conflicts(path: nil), "Open conflicts"),
            (.gitOperation, "Open changes"),
            (.reviewRequest(number: 42), "Open review request"),
            (.reviewComment(sessionID: "r1", commentID: "c1"), "Open review reply"),
            (.remoteWorktree, "Open worktree"),
        ]
        for (target, title) in targets {
            let item = makeItem(target: target)
            let presentation = AttentionInboxPresentation(aggregation: aggregation(items: [item]), loadError: nil)
            let row = presentation.activeRows[0]
            #expect(row.title == item.title)
            #expect(row.attribution == "Alas · feature/inbox · build-host")
            #expect(!row.timestampText.isEmpty)
            #expect(!row.absoluteTimestamp.isEmpty)
            #expect(row.actionTitle == title)
        }
    }

    @Test func emptyInboxKeepsHistoryAndPersistenceErrorsSeparate() {
        let item = makeItem(acknowledgedAt: Date(timeIntervalSince1970: 200))
        let presentation = AttentionInboxPresentation(
            aggregation: aggregation(history: [item]), loadError: "Could not load history", writeError: "Could not save history"
        )
        #expect(presentation.emptyTitle == "Nothing needs attention")
        #expect(presentation.historyRows.count == 1)
        #expect(presentation.historyRows[0].acknowledgmentText?.hasPrefix("Addressed ") == true)
        #expect(presentation.errors.map(\.message) == ["Could not load history", "Could not save history"])
        #expect(presentation.activeRows.isEmpty)
    }

    @Test func compactTimestampIncludesDateOnlyForOlderEvents() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_789_128_000)
        let today = AttentionInboxRowPresentation.timestamp(now, now: now, calendar: calendar)
        let yesterday = AttentionInboxRowPresentation.timestamp(now.addingTimeInterval(-86400), now: now, calendar: calendar)
        #expect(today == now.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone)))
        #expect(yesterday != today)
        #expect(yesterday.count > today.count)
    }

    @Test func toolbarHeightDoesNotChangeWithThreeDigitBadge() throws {
        #expect(try headerHeight(count: 0) == headerHeight(count: 999))
    }

    private func headerHeight(count: Int) throws -> Int {
        let view = SidebarHeaderView(worktreeSortMode: .lastUpdateDesc, onSetWorktreeSortMode: { _ in },
                                     onSettings: {}, onAddProject: {}, onSearch: {}, onHideSidebar: {},
                                     attentionCount: count, attentionInboxOpen: false, onOpenAttentionInbox: {})
            .environment(\.theme, try ThemeStore().current)
        let controller = NSHostingController(rootView: view)
        return Int(controller.sizeThatFits(in: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height)
    }

    private func aggregation(items: [AttentionItem] = [], history: [AttentionItem] = []) -> AttentionAggregation {
        AttentionAggregation(items: items, history: history, unresolvedCount: items.count,
                             unresolvedCountByProject: items.isEmpty ? [:] : ["p1": items.count])
    }

    private func makeItem(target: AttentionJumpTarget = .session(sessionID: "s1"), acknowledgedAt: Date? = nil) -> AttentionItem {
        AttentionItem(eventID: UUID(), sourceKey: .init(rawValue: "source"),
                      owner: .init(projectID: "p1", location: .ssh("build-host"), lineageID: "lineage", legacyPath: nil),
                      kind: .agentAwaiting, title: "Codex is waiting for input", body: nil,
                      occurredAt: Date(timeIntervalSince1970: 100), presentation: .live, jumpTarget: target,
                      display: .init(projectName: "Alas", branch: "feature/inbox", path: "/repo", host: "build-host"),
                      worktree: nil, acknowledgedAt: acknowledgedAt)
    }
}
