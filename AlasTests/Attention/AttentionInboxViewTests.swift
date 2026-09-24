import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AttentionInboxViewTests {
    @Test func sidebarPresentationHidesAttentionWhenFeatureIsDisabled() {
        let aggregation = aggregation(items: [makeItem()])

        let disabled = SidebarAttentionPresentation(enabled: false, aggregation: aggregation)
        #expect(disabled.showsInbox == false)
        #expect(disabled.count == 0)

        let enabled = SidebarAttentionPresentation(enabled: true, aggregation: aggregation)
        #expect(enabled.showsInbox == true)
        #expect(enabled.count == 1)
    }

    @Test func livePeerAttentionAddsOnceToBadgeAndInboxWithoutChangingLocalRows() {
        let local = aggregation(items: [makeItem(), makeItem()])
        let peer = RemoteSessionSummary(id: "B:s", title: "Peer request", agentId: "claude",
                                        status: "awaitingInput", canDrive: false,
                                        serverId: "B", serverName: "Mac B")
        let snapshot = NativePeerSidebarSnapshot.build(
            peers: [.init(serverId: "B", name: "Mac B", state: "online")],
            rows: [peer, peer], enabled: true
        )
        let badge = SidebarAttentionPresentation(enabled: true, aggregation: local,
                                                 peerRows: snapshot.attentionRows)
        let inbox = AttentionInboxPresentation(aggregation: local, loadError: nil,
                                               peerRows: snapshot.attentionRows)

        #expect(snapshot.attentionCount == 1)
        #expect(badge.count == 3)
        #expect(inbox.totalCount == badge.count)
        #expect(inbox.activeRows.count == 2)
        #expect(inbox.peerRows.map(\.id) == ["B:s"])
        #expect(inbox.acknowledgeLabel == "Acknowledge local")

        let peerOnly = AttentionInboxPresentation(aggregation: aggregation(), loadError: nil,
                                                  peerRows: snapshot.attentionRows)
        #expect(peerOnly.emptyTitle == nil)
        #expect(peerOnly.totalCount == 1)
        #expect(peerOnly.acknowledgeLabel == nil)
    }

    @Test func clearingOrDisablingPeerAttentionRemovesOnlyLiveContribution() {
        let local = aggregation(items: [makeItem()])
        let peer = RemoteSessionSummary(id: "B:s", title: "Peer request", agentId: "claude",
                                        status: "awaitingInput", canDrive: false,
                                        serverId: "B", serverName: "Mac B")
        let cleared = RemoteSessionSummary(id: "B:s", title: "Peer request", agentId: "claude",
                                           status: "idle", canDrive: false,
                                           serverId: "B", serverName: "Mac B")
        let peers = [RemoteHelloPeer(serverId: "B", name: "Mac B", state: "online")]
        let active = NativePeerSidebarSnapshot.build(peers: peers, rows: [peer], enabled: true)
        let resolved = NativePeerSidebarSnapshot.build(peers: peers, rows: [cleared], enabled: true)
        let disabled = NativePeerSidebarSnapshot.build(peers: peers, rows: [peer], enabled: false)

        #expect(SidebarAttentionPresentation(enabled: true, aggregation: local,
                                            peerRows: active.attentionRows).count == 2)
        #expect(SidebarAttentionPresentation(enabled: true, aggregation: local,
                                            peerRows: resolved.attentionRows).count == 1)
        #expect(SidebarAttentionPresentation(enabled: true, aggregation: local,
                                            peerRows: disabled.attentionRows).count == 1)
        #expect(SidebarAttentionPresentation(enabled: false, aggregation: local,
                                            peerRows: active.attentionRows).count == 0)
        #expect(local.unresolvedCount == 1)
    }

    @Test func headerBadgeOnlyAppearsForNonzeroAttention() {
        #expect(!SidebarHeaderView.showsAttentionBadge(count: 0))
        #expect(SidebarHeaderView.showsAttentionBadge(count: 4))
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

    @Test func acknowledgmentQuietsTheAlertWithoutChangingTheCurrentCondition() {
        let active = AttentionInboxRowPresentation(item: makeItem(), now: Date())
        let acknowledged = AttentionInboxRowPresentation(
            item: makeItem(acknowledgedAt: Date(timeIntervalSince1970: 200)), now: Date()
        )
        let historical = AttentionInboxRowPresentation(item: makeItem(presentation: .historical), now: Date())

        #expect(active.emphasizesAction)
        #expect(!acknowledged.emphasizesAction)
        #expect(!historical.emphasizesAction)
        #expect(acknowledged.stateExplanation == active.stateExplanation)
        #expect(acknowledged.stateExplanation != historical.stateExplanation)
        #expect(active.dismissAccessibilityLabel != nil)
        #expect(acknowledged.dismissAccessibilityLabel == nil)
        #expect(historical.dismissAccessibilityLabel == nil)
    }

    @Test func unverifiedConditionStaysAcknowledgeableWithoutAFreshAlert() {
        let current = AttentionInboxRowPresentation(item: makeItem(), now: Date())
        let unverified = AttentionInboxRowPresentation(item: makeItem(presentation: .unverified), now: Date())
        let acknowledged = AttentionInboxRowPresentation(
            item: makeItem(acknowledgedAt: Date(timeIntervalSince1970: 200), presentation: .unverified),
            now: Date()
        )
        let historical = AttentionInboxRowPresentation(item: makeItem(presentation: .historical), now: Date())

        #expect(!unverified.emphasizesAction)
        #expect(unverified.dismissAccessibilityLabel != nil)
        #expect(unverified.title != current.title)
        #expect(unverified.stateExplanation != current.stateExplanation)
        #expect(unverified.stateExplanation != historical.stateExplanation)
        #expect(acknowledged.stateExplanation == unverified.stateExplanation)
        #expect(!acknowledged.emphasizesAction)
        #expect(acknowledged.dismissAccessibilityLabel == nil)
    }

    @Test func quietInboxKeepsCurrentActivityAndPastEventsAccessible() {
        let current = makeItem(acknowledgedAt: Date(timeIntervalSince1970: 200))
        let unverified = makeItem(acknowledgedAt: Date(timeIntervalSince1970: 200), presentation: .unverified)
        let informational = makeItem(kind: .failedChecks)
        let historical = makeItem(presentation: .historical)
        let events = [current, unverified, informational, historical]
        let presentation = AttentionInboxPresentation(aggregation: aggregation(history: events), loadError: nil)

        #expect(presentation.activeRows.isEmpty)
        #expect(presentation.emptyTitle != nil)
        #expect(presentation.historyRows.map(\.id) == events.map(\.eventID))
        #expect(presentation.historyRows.allSatisfy { !$0.emphasizesAction })
        #expect(presentation.historyRows.allSatisfy { $0.dismissAccessibilityLabel == nil })
        #expect(presentation.historyRows[0].stateExplanation != presentation.historyRows[3].stateExplanation)
        #expect(presentation.historyRows[1].stateExplanation != presentation.historyRows[3].stateExplanation)
        #expect(presentation.historyRows[2].stateExplanation != presentation.historyRows[0].stateExplanation)
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
                          ownerAvailable: Bool = false, presentation: AttentionItemPresentation = .live,
                          kind: AttentionKind = .agentAwaiting) -> AttentionItem {
        let display = AttentionWorktreeDisplaySnapshot(projectName: "Alas", branch: "feature/inbox", path: "/repo", host: "build-host")
        return AttentionItem(eventID: UUID(), sourceKey: .init(rawValue: "source"),
                      owner: .init(projectID: "p1", location: .ssh("build-host"), lineageID: "lineage", legacyPath: nil),
                      kind: kind, title: "Codex is waiting for input", body: nil,
                      occurredAt: Date(timeIntervalSince1970: 100), presentation: presentation, jumpTarget: target,
                      display: display,
                      worktree: ownerAvailable ? .init(id: "worktree", projectID: "p1", display: display) : nil,
                      acknowledgedAt: acknowledgedAt)
    }
}
