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

    @Test func historyToggleLabelReflectsCountAndCollapsedState() {
        #expect(AttentionInboxPresentation.historyToggleLabel(count: 1, isExpanded: false) == "Show 1 earlier event")
        #expect(AttentionInboxPresentation.historyToggleLabel(count: 3, isExpanded: false) == "Show 3 earlier events")
        #expect(AttentionInboxPresentation.historyToggleLabel(count: 3, isExpanded: true) == "Hide 3 earlier events")
    }

    @Test func inboxStartsWithHistoryCollapsed() throws {
        let active = makeItem()
        let acknowledged = makeItem(acknowledgedAt: Date(timeIntervalSince1970: 200))
        let collapsed = try inboxListHeight(aggregation: aggregation(items: [active], history: [acknowledged]), historyExpanded: false)
        let expanded = try inboxListHeight(aggregation: aggregation(items: [active], history: [acknowledged]), historyExpanded: true)
        let withoutHistory = try inboxListHeight(aggregation: aggregation(items: [active]), historyExpanded: false)
        let historyRow = try historyRowHeight(ownerAvailable: true)
        // Collapsed only grows by the toggle header, never by a full history row; expanding reveals it.
        #expect(collapsed > withoutHistory)
        #expect(collapsed - withoutHistory < historyRow)
        #expect(expanded - collapsed > historyRow / 2)
    }

    @Test func activeRowsExposeDismissActionButHistoryRowsDoNot() {
        let active = makeItem()
        let acknowledged = makeItem(acknowledgedAt: Date(timeIntervalSince1970: 200))
        let presentation = AttentionInboxPresentation(
            aggregation: aggregation(items: [active], history: [acknowledged]), loadError: nil
        )
        #expect(presentation.activeRows[0].dismissAccessibilityLabel == "Dismiss, \(active.title), Alas · feature/inbox · build-host")
        #expect(presentation.historyRows[0].dismissAccessibilityLabel == nil)
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
        #expect(try headerSize(count: 0).height == headerSize(count: 999).height)
    }

    @Test func toolbarFitsDefaultAndMinimumSidebarWidths() throws {
        let baselineHeight = try headerSize(count: 0).height
        for width in [CGFloat(200), CGFloat(244)] {
            for count in [0, 999] {
                for workspacesEnabled in [false, true] {
                    let size = try headerSize(count: count, width: width, workspacesEnabled: workspacesEnabled)
                    #expect(size.width <= width)
                    #expect(size.height == baselineHeight)
                }
            }
        }
    }

    @Test func historyWithDeletedOwnerShowsDestinationExplanation() throws {
        let unavailable = try historyRowHeight(ownerAvailable: false)
        let available = try historyRowHeight(ownerAvailable: true)
        #expect(unavailable > available)
    }

    private func inboxListHeight(aggregation: AttentionAggregation, historyExpanded: Bool) throws -> CGFloat {
        let presentation = AttentionInboxPresentation(aggregation: aggregation, loadError: nil)
        let view = AttentionInboxList(presentation: presentation, historyExpanded: .constant(historyExpanded),
                                      navigationErrors: [:], onDismiss: { _ in }, onOpen: { _ in })
            .environment(\.theme, try ThemeStore().current)
        let controller = NSHostingController(rootView: view)
        return controller.sizeThatFits(in: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)).height
    }

    private func historyRowHeight(ownerAvailable: Bool) throws -> CGFloat {
        let item = makeItem(acknowledgedAt: Date(timeIntervalSince1970: 200), ownerAvailable: ownerAvailable)
        let view = AttentionInboxRow(presentation: .init(item: item, now: Date()), isHistory: true,
                                    navigationError: nil, onDismiss: { _ in }, onOpen: { _ in })
            .environment(\.theme, try ThemeStore().current)
        let controller = NSHostingController(rootView: view)
        return controller.sizeThatFits(in: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)).height
    }

    private func headerSize(count: Int, width: CGFloat = 300, workspacesEnabled: Bool = false) throws -> NSSize {
        let view = SidebarHeaderView(worktreeSortMode: .lastUpdateDesc, onSetWorktreeSortMode: { _ in },
                                     onSettings: {}, onAddProject: {}, onSearch: {}, onHideSidebar: {},
                                     onNewWorkspace: workspacesEnabled ? {} : nil,
                                     attentionCount: count, attentionInboxOpen: .constant(false))
            .environment(\.theme, try ThemeStore().current)
        let controller = NSHostingController(rootView: view)
        return controller.sizeThatFits(in: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }

    private func aggregation(items: [AttentionItem] = [], history: [AttentionItem] = []) -> AttentionAggregation {
        AttentionAggregation(items: items, history: history, unresolvedCount: items.count,
                             unresolvedCountByProject: items.isEmpty ? [:] : ["p1": items.count])
    }

    private func makeItem(target: AttentionJumpTarget = .session(sessionID: "s1"), acknowledgedAt: Date? = nil,
                          ownerAvailable: Bool = false) -> AttentionItem {
        let display = AttentionWorktreeDisplaySnapshot(projectName: "Alas", branch: "feature/inbox", path: "/repo", host: "build-host")
        return AttentionItem(eventID: UUID(), sourceKey: .init(rawValue: "source"),
                      owner: .init(projectID: "p1", location: .ssh("build-host"), lineageID: "lineage", legacyPath: nil),
                      kind: .agentAwaiting, title: "Codex is waiting for input", body: nil,
                      occurredAt: Date(timeIntervalSince1970: 100), presentation: .live, jumpTarget: target,
                      display: display,
                      worktree: ownerAvailable ? .init(id: "worktree", projectID: "p1", display: display) : nil,
                      acknowledgedAt: acknowledgedAt)
    }
}
