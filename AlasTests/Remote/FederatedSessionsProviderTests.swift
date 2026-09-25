import Testing
import Foundation
@testable import Alas

@MainActor
struct FederatedSessionsProviderTests {
    @MainActor
    final class FakeLinks: FederatedPeerLinks {
        var sessionCarryingPeers: [FederatedPeerInfo] = []
        var onFederationEvent: (@MainActor (FederatedPeerLinkEvent) -> Void)?
        var sent: [(serverId: String, message: RemoteClientMessage)] = []
        func sendToPeer(_ message: RemoteClientMessage, serverId: String) {
            guard sessionCarryingPeers.contains(where: { $0.serverId == serverId }) else { return }
            sent.append((serverId, message))
        }
        func goOnline(_ serverId: String, name: String) {
            sessionCarryingPeers.append(FederatedPeerInfo(serverId: serverId, name: name))
            onFederationEvent?(.availabilityChanged(serverId: serverId))
        }
        func goOffline(_ serverId: String) {
            sessionCarryingPeers.removeAll { $0.serverId == serverId }
            onFederationEvent?(.availabilityChanged(serverId: serverId))
        }
        func receive(_ message: RemoteServerMessage, from serverId: String) {
            onFederationEvent?(.message(serverId: serverId, message))
        }
        func sent(to serverId: String) -> [RemoteClientMessage] { sent.filter { $0.serverId == serverId }.map(\.message) }
    }

    @MainActor
    final class Client {
        var received: [RemoteServerMessage] = []
        var listRefreshes = 0
        private(set) var downstream: FederatedDownstream!
        init() {
            downstream = FederatedDownstream(
                send: { [weak self] in self?.received.append($0) },
                sessionListChanged: { [weak self] in self?.listRefreshes += 1 })
        }
        /// Drops the downstream without detaching it, the way a connection
        /// torn down by `RemoteServer.stop()` can. The client itself stays
        /// around so the test can still see what it did or did not receive.
        func loseDownstream() { downstream = nil }
    }

    private func row(_ id: String, serverId: String? = nil) -> RemoteSessionSummary {
        RemoteSessionSummary(id: id, title: "T \(id)", agentId: "claude", status: "idle", canDrive: false,
                             serverId: serverId, serverName: serverId.map { "Name \($0)" })
    }

    @Test func aPeerComingOnlineIsAskedForItsSessionsAndItsRowsAreTaggedAndNamespaced() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        #expect(links.sent(to: "srv-b") == [.listSessions])
        links.receive(.sessionList(sessions: [row("s1"), row("s2")]), from: "srv-b")
        let rows = provider.peerSessionSummaries
        #expect(rows.map(\.id) == ["srv-b:s1", "srv-b:s2"])
        #expect(rows.allSatisfy { $0.serverId == "srv-b" && $0.serverName == "Mac B" })
        #expect(rows.first?.title == "T s1")
        #expect(client.listRefreshes == 1)
    }

    @Test func rowsAPeerItselfForwardedAreNeverReExported() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        links.goOnline("srv-b", name: "Mac B")
        links.receive(.sessionList(sessions: [row("s1"), row("srv-c:s9", serverId: "srv-c")]), from: "srv-b")
        #expect(provider.peerSessionSummaries.map(\.id) == ["srv-b:s1"])
    }

    @Test func anUnchangedPeerListDoesNotRefreshDownstreams() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        links.receive(.sessionList(sessions: [row("s1")]), from: "srv-b")
        links.receive(.sessionList(sessions: [row("s1")]), from: "srv-b")
        #expect(client.listRefreshes == 1)
    }

    @Test func listSessionsFromAClientIsForwardedToEveryPeerAndStillHandledLocally() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        links.goOnline("srv-c", name: "Mac C")
        links.sent.removeAll()
        #expect(provider.route(.listSessions, from: client.downstream) == false)
        #expect(links.sent(to: "srv-b") == [.listSessions])
        #expect(links.sent(to: "srv-c") == [.listSessions])
    }

    @Test func subscribeIsForwardedWithTheLocalIdAndRepliesComeBackNamespaced() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        #expect(provider.route(.subscribe(sessionId: "srv-b:s1"), from: client.downstream))
        #expect(links.sent(to: "srv-b").contains(.subscribe(sessionId: "s1")))
        links.receive(.transcriptDelta(sessionId: "s1", streamingState: "idle", canDrive: true, upserts: [], epoch: 0, revision: 1),
                      from: "srv-b")
        #expect(client.received == [
            .transcriptDelta(sessionId: "srv-b:s1", streamingState: "idle", canDrive: true, upserts: [], epoch: 0, revision: 1)
        ])
    }

    @Test func framesForASessionNobodySubscribedToAreDropped() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        links.receive(.stopPending(sessionId: "s1"), from: "srv-b")
        links.receive(.worktreeList(worktrees: []), from: "srv-b")
        #expect(client.received.isEmpty)
    }

    @Test func localAndUnknownIdsAreNotRouted() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        #expect(provider.route(.subscribe(sessionId: "s1"), from: client.downstream) == false)
        #expect(provider.route(.subscribe(sessionId: "srv-z:s1"), from: client.downstream) == false)
        #expect(provider.route(.createSession(worktreeId: "w", agentId: "a"), from: client.downstream) == false)
        #expect(links.sent(to: "srv-b") == [.listSessions])
    }

    @Test func driveVerbsAreForwardedVerbatimApartFromTheId() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        links.sent.removeAll()
        let prompt = RemoteClientMessage.sendPrompt(sessionId: "srv-b:s1", text: "go", attachments: [], intent: "steer")
        #expect(provider.route(prompt, from: client.downstream))
        #expect(provider.route(.stop(sessionId: "srv-b:s1"), from: client.downstream))
        #expect(provider.route(.fetchOlder(sessionId: "srv-b:s1", beforeIndex: 4, limit: 20), from: client.downstream))
        #expect(links.sent(to: "srv-b") == [
            .sendPrompt(sessionId: "s1", text: "go", attachments: [], intent: "steer"),
            .stop(sessionId: "s1"),
            .fetchOlder(sessionId: "s1", beforeIndex: 4, limit: 20),
        ])
    }

    @Test func twoClientsShareOneUpstreamSubscriptionAndBothGetFrames() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let one = Client()
        let two = Client()
        provider.attach(one.downstream)
        provider.attach(two.downstream)
        links.goOnline("srv-b", name: "Mac B")
        links.sent.removeAll()
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: one.downstream)
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: two.downstream)
        // Each downstream subscribe re-asks upstream so the newcomer gets a
        // fresh snapshot; the peer answers a re-subscribe with one.
        #expect(links.sent(to: "srv-b") == [.subscribe(sessionId: "s1"), .subscribe(sessionId: "s1")])
        links.receive(.stopPending(sessionId: "s1"), from: "srv-b")
        #expect(one.received == [.stopPending(sessionId: "srv-b:s1")])
        #expect(two.received == [.stopPending(sessionId: "srv-b:s1")])
        // The first to leave does not unsubscribe upstream; the last does.
        _ = provider.route(.unsubscribe(sessionId: "srv-b:s1"), from: one.downstream)
        #expect(!links.sent(to: "srv-b").contains(.unsubscribe(sessionId: "s1")))
        links.receive(.stopPending(sessionId: "s1"), from: "srv-b")
        #expect(one.received.count == 1)
        #expect(two.received.count == 2)
        provider.detach(two.downstream)
        #expect(links.sent(to: "srv-b").contains(.unsubscribe(sessionId: "s1")))
    }

    @Test func aNewSubscriberReceivesActivePlanAndElicitationRequestsWithoutDuplicatingThem() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let first = Client()
        let newcomer = Client()
        provider.attach(first.downstream)
        provider.attach(newcomer.downstream)
        links.goOnline("srv-b", name: "Mac B")
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: first.downstream)

        let plan = RemotePlanPayload(
            requestId: .string("plan-1"), toolCallId: "tool-1", name: "Plan", overview: "Overview",
            plan: "Do the work", todos: [], isProject: false, phases: [])
        let elicitation = RemoteElicitationPayload(
            requestId: "elicitation-1", title: "Input", message: "Provide input", mode: "form",
            fields: [], elicitationId: nil, url: nil)
        links.receive(.planRequest(sessionId: "s1", payload: plan), from: "srv-b")
        links.receive(.elicitationRequest(sessionId: "s1", payload: elicitation), from: "srv-b")

        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: newcomer.downstream)

        #expect(newcomer.received == [
            .planRequest(sessionId: "srv-b:s1", payload: plan),
            .elicitationRequest(sessionId: "srv-b:s1", payload: elicitation),
        ])
        #expect(first.received == [
            .planRequest(sessionId: "srv-b:s1", payload: plan),
            .elicitationRequest(sessionId: "srv-b:s1", payload: elicitation),
        ])
    }

    @Test func resolvedRequestsAreNotReplayedToLaterSubscribers() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let first = Client()
        let newcomer = Client()
        provider.attach(first.downstream)
        provider.attach(newcomer.downstream)
        links.goOnline("srv-b", name: "Mac B")
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: first.downstream)
        let plan = RemotePlanPayload(
            requestId: .string("plan-1"), toolCallId: "tool-1", name: "Plan", overview: "Overview",
            plan: "Do the work", todos: [], isProject: false, phases: [])
        let elicitation = RemoteElicitationPayload(
            requestId: "elicitation-1", title: "Input", message: "Provide input", mode: "form",
            fields: [], elicitationId: nil, url: nil)
        links.receive(.planRequest(sessionId: "s1", payload: plan), from: "srv-b")
        links.receive(.elicitationRequest(sessionId: "s1", payload: elicitation), from: "srv-b")
        links.receive(.planResolved(sessionId: "s1", requestId: .string("plan-1")), from: "srv-b")
        links.receive(.elicitationResolved(sessionId: "s1", requestId: "elicitation-1"), from: "srv-b")

        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: newcomer.downstream)

        #expect(newcomer.received.isEmpty)
    }

    @Test func aClosedSessionDoesNotReplayItsPendingRequests() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let first = Client()
        let newcomer = Client()
        provider.attach(first.downstream)
        provider.attach(newcomer.downstream)
        links.goOnline("srv-b", name: "Mac B")
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: first.downstream)
        let plan = RemotePlanPayload(
            requestId: .string("plan-1"), toolCallId: "tool-1", name: "Plan", overview: "Overview",
            plan: "Do the work", todos: [], isProject: false, phases: [])
        links.receive(.planRequest(sessionId: "s1", payload: plan), from: "srv-b")
        links.receive(.sessionClosed(sessionId: "s1"), from: "srv-b")

        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: newcomer.downstream)

        #expect(newcomer.received.isEmpty)
    }

    @Test func aPeerGoingOfflineDoesNotReplayItsOldPendingRequestsAfterReturning() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let first = Client()
        let newcomer = Client()
        provider.attach(first.downstream)
        provider.attach(newcomer.downstream)
        links.goOnline("srv-b", name: "Mac B")
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: first.downstream)
        let plan = RemotePlanPayload(
            requestId: .string("plan-1"), toolCallId: "tool-1", name: "Plan", overview: "Overview",
            plan: "Do the work", todos: [], isProject: false, phases: [])
        links.receive(.planRequest(sessionId: "s1", payload: plan), from: "srv-b")
        links.goOffline("srv-b")
        links.goOnline("srv-b", name: "Mac B")

        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: newcomer.downstream)

        #expect(newcomer.received.isEmpty)
    }

    @Test func aLastUnsubscribeClearsPendingRequestsUntilThePeerReemitsThem() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let first = Client()
        let newcomer = Client()
        provider.attach(first.downstream)
        provider.attach(newcomer.downstream)
        links.goOnline("srv-b", name: "Mac B")
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: first.downstream)
        let plan = RemotePlanPayload(
            requestId: .string("plan-1"), toolCallId: "tool-1", name: "Plan", overview: "Overview",
            plan: "Do the work", todos: [], isProject: false, phases: [])
        let request = RemoteServerMessage.planRequest(sessionId: "srv-b:s1", payload: plan)
        links.receive(.planRequest(sessionId: "s1", payload: plan), from: "srv-b")
        _ = provider.route(.unsubscribe(sessionId: "srv-b:s1"), from: first.downstream)

        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: newcomer.downstream)
        #expect(newcomer.received.isEmpty)
        links.receive(.planRequest(sessionId: "s1", payload: plan), from: "srv-b")

        #expect(newcomer.received == [request])
    }

    @Test func aPeerGoingOfflineClosesItsSessionsAndDropsItsRows() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        links.receive(.sessionList(sessions: [row("s1")]), from: "srv-b")
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: client.downstream)
        let refreshesBefore = client.listRefreshes
        links.goOffline("srv-b")
        #expect(client.received.contains(.sessionClosed(sessionId: "srv-b:s1")))
        #expect(provider.peerSessionSummaries.isEmpty)
        #expect(client.listRefreshes == refreshesBefore + 1)
        // Nothing further is forwarded for a peer that is gone, and its id
        // no longer parses as federated.
        links.receive(.stopPending(sessionId: "s1"), from: "srv-b")
        #expect(!client.received.contains(.stopPending(sessionId: "srv-b:s1")))
        #expect(provider.route(.subscribe(sessionId: "srv-b:s1"), from: client.downstream) == false)
    }

    @Test func sessionClosedFromThePeerForgetsTheSubscription() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: client.downstream)
        links.receive(.sessionClosed(sessionId: "s1"), from: "srv-b")
        #expect(client.received == [.sessionClosed(sessionId: "srv-b:s1")])
        links.sent.removeAll()
        provider.detach(client.downstream)
        #expect(links.sent.isEmpty)   // nothing left to unsubscribe
    }

    @Test func aDownstreamThatGoesAwayWithoutDetachingIsForgottenOnTheNextFrame() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let client = Client()
        provider.attach(client.downstream)
        links.goOnline("srv-b", name: "Mac B")
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: client.downstream)
        #expect(provider.isPollingPeerLists)
        links.sent.removeAll()
        client.loseDownstream()
        links.receive(.stopPending(sessionId: "s1"), from: "srv-b")
        // Nothing is delivered for a client that is gone, its subscription is
        // released upstream, and the idle poll has nobody left to tell.
        #expect(client.received.isEmpty)
        #expect(links.sent(to: "srv-b") == [.unsubscribe(sessionId: "s1")])
        #expect(!provider.isPollingPeerLists)
    }

    @Test func aDownstreamThatGoesAwayWithoutDetachingLeavesSurvivingSubscriptionsAlone() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        let survivor = Client()
        let lost = Client()
        provider.attach(survivor.downstream)
        provider.attach(lost.downstream)
        links.goOnline("srv-b", name: "Mac B")
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: survivor.downstream)
        _ = provider.route(.subscribe(sessionId: "srv-b:s1"), from: lost.downstream)
        links.sent.removeAll()
        lost.loseDownstream()
        links.receive(.stopPending(sessionId: "s1"), from: "srv-b")
        #expect(survivor.received == [.stopPending(sessionId: "srv-b:s1")])
        #expect(!links.sent(to: "srv-b").contains(.unsubscribe(sessionId: "s1")))
        #expect(provider.isPollingPeerLists)
        // The survivor leaving is still what ends the upstream subscription:
        // the lost downstream no longer holds the set open.
        provider.detach(survivor.downstream)
        #expect(links.sent(to: "srv-b").contains(.unsubscribe(sessionId: "s1")))
        #expect(!provider.isPollingPeerLists)
    }

    @Test func downstreamsLostAcrossServerRestartsDoNotAccumulate() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        links.goOnline("srv-b", name: "Mac B")
        // One leaked downstream per restart; the provider outlives them all.
        var clients: [Client] = []
        for index in 0..<5 {
            let client = Client()
            provider.attach(client.downstream)
            _ = provider.route(.subscribe(sessionId: "srv-b:s\(index)"), from: client.downstream)
            clients.append(client)
        }
        links.sent.removeAll()
        for client in clients { client.loseDownstream() }
        // A single read clears all of them, releasing each subscription once.
        links.receive(.stopPending(sessionId: "s0"), from: "srv-b")
        #expect(clients.allSatisfy { $0.received.isEmpty })
        let sent = links.sent(to: "srv-b")
        #expect(sent.count == 5)
        for index in 0..<5 { #expect(sent.contains(.unsubscribe(sessionId: "s\(index)"))) }
        #expect(!provider.isPollingPeerLists)
    }

    @Test func availabilityCallbackFiresOnEveryReconciliationIncludingNonCarryingTransitions() {
        let links = FakeLinks()
        let provider = FederatedSessionsProvider(links: links)
        var fired = 0
        provider.onPeerAvailabilityChanged = { fired += 1 }
        links.goOnline("srv-b", name: "Mac B")
        #expect(fired == 1)
        links.goOffline("srv-b")
        #expect(fired == 2)
        // A peer that never carries sessions (e.g. mid-handshake, or a
        // record that failed verification) still has a place in `hello`'s
        // `peers` list, so a transition among its own non-carrying states
        // — invisible to `sessionCarryingPeers`, which only ever reports
        // "srv-c" once it's online AND verified — must still refresh it.
        // `RemotePeerManager` itself never re-signals an unchanged state
        // (`RemotePeerConnection.setState` guards on it), so this is a
        // realistic, non-redundant sequence of distinct transitions, not a
        // repeat of the same one.
        links.onFederationEvent?(.availabilityChanged(serverId: "srv-c"))
        #expect(fired == 3)
        links.onFederationEvent?(.availabilityChanged(serverId: "srv-c"))
        #expect(fired == 4)
    }
}
