import Foundation
import Testing
@testable import Alas

@MainActor
struct NativePeerSessionsTests {
    private final class FakeLinks: FederatedPeerLinks {
        var sessionCarryingPeers: [FederatedPeerInfo] = []
        var onFederationEvent: (@MainActor (FederatedPeerLinkEvent) -> Void)?
        var sent: [(String, RemoteClientMessage)] = []

        func sendToPeer(_ message: RemoteClientMessage, serverId: String) {
            sent.append((serverId, message))
        }
        func online(_ id: String, name: String) {
            sessionCarryingPeers.append(.init(serverId: id, name: name))
            onFederationEvent?(.availabilityChanged(serverId: id))
        }
        func offline(_ id: String) {
            sessionCarryingPeers.removeAll { $0.serverId == id }
            onFederationEvent?(.availabilityChanged(serverId: id))
        }
        func receive(_ message: RemoteServerMessage, from id: String) {
            onFederationEvent?(.message(serverId: id, message))
        }
        func sent(to id: String) -> [RemoteClientMessage] {
            sent.filter { $0.0 == id }.map { $0.1 }
        }
    }

    private func row(_ id: String, status: String = "idle") -> RemoteSessionSummary {
        .init(id: id, title: id, agentId: "claude", status: status, canDrive: true)
    }

    @Test func startSelectionAndStopOwnOneDownstream() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        #expect(federation.isPollingPeerLists)
        links.receive(.sessionList(sessions: [row("s"), row("t")]), from: "B")
        #expect(client.snapshot.groups.first?.sessions.count == 2)
        client.select("B:s")
        #expect(client.selectedSessionId == "B:s")
        #expect(links.sent(to: "B").contains(.subscribe(sessionId: "s")))
        client.select("B:t")
        #expect(links.sent(to: "B").contains(.unsubscribe(sessionId: "s")))
        #expect(links.sent(to: "B").contains(.subscribe(sessionId: "t")))
        client.clearSelection()
        #expect(links.sent(to: "B").contains(.unsubscribe(sessionId: "t")))
        client.stop()
        #expect(!federation.isPollingPeerLists)
        #expect(client.snapshot.groups.isEmpty)
        #expect(client.selectedSessionId == nil)
    }

    @Test func offlineRemovesRowsAndAttentionButPreservesDraftUntilForgotten() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        var peers = [RemoteHelloPeer(serverId: "B", name: "Mac B", state: "online")]
        let client = NativePeerSessions(federation: federation, peers: { peers })
        client.start()
        links.receive(.sessionList(sessions: [row("s", status: "awaitingInput")]), from: "B")
        client.select("B:s")
        client.draft = "keep this"
        #expect(client.snapshot.attentionCount == 1)
        links.offline("B")
        peers = [.init(serverId: "B", name: "Mac B", state: "offline")]
        client.refresh()
        #expect(client.snapshot.attentionCount == 0)
        #expect(client.snapshot.groups.first?.sessions.isEmpty == true)
        #expect(client.selectedSessionId == "B:s")
        #expect(client.transcript?.isClosed == true)
        #expect(client.draft == "keep this")
        peers = []
        client.refresh()
        #expect(client.selectedSessionId == nil)
    }

    @Test func onlyHomeConfirmedDriveCanSendAndRejectionKeepsDraft() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        client.draft = "hello"
        client.sendPrompt()
        #expect(!links.sent(to: "B").contains { if case .sendPrompt = $0 { true } else { false } })
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0), from: "B")
        client.sendPrompt()
        #expect(links.sent(to: "B").contains(.sendPrompt(sessionId: "s", text: "hello", attachments: [], intent: "auto")))
        links.receive(.promptRejected(sessionId: "s"), from: "B")
        #expect(client.draft == "hello")
        #expect(client.deliveryError != nil)
    }

    @Test func selectedSessionResubscribesWhenPeerReturns() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        var peers = [RemoteHelloPeer(serverId: "B", name: "Mac B", state: "online")]
        let client = NativePeerSessions(federation: federation, peers: { peers })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        client.draft = "continue later"
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 4, revision: 0), from: "B")
        links.offline("B")
        peers = [.init(serverId: "B", name: "Mac B", state: "offline")]
        client.refresh()
        #expect(client.transcript?.isClosed == true)

        peers = [.init(serverId: "B", name: "Mac B", state: "online")]
        links.online("B", name: "Mac B")
        let subscriptionsBefore = links.sent(to: "B").filter { $0 == .subscribe(sessionId: "s") }.count
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        let subscriptionsAfter = links.sent(to: "B").filter { $0 == .subscribe(sessionId: "s") }.count
        #expect(subscriptionsAfter == subscriptionsBefore + 1)
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0), from: "B")
        #expect(client.transcript?.canDrive == true)
        #expect(client.draft == "continue later")
    }

    @Test func planRejectionRequiresAndTrimsReason() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0), from: "B")
        links.receive(.planRequest(sessionId: "s", payload: .init(
            requestId: .string("plan-1"), toolCallId: "tool-1", name: "Plan", overview: "",
            plan: "", todos: [], isProject: false, phases: []
        )), from: "B")

        client.respondToPlan(requestId: .string("plan-1"), action: "reject", reason: "  \n ")
        #expect(!links.sent(to: "B").contains {
            if case .planResponse(_, .string("plan-1"), _, _) = $0 { return true }
            return false
        })

        client.respondToPlan(requestId: .string("plan-1"), action: "reject", reason: "  Needs a clearer scope.  ")
        #expect(links.sent(to: "B").contains(
            .planResponse(sessionId: "s", requestId: .string("plan-1"),
                          action: "reject", reason: "Needs a clearer scope.")
        ))
    }

    @Test func urlElicitationCannotBeAcceptedBeforeOpeningBrowser() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0), from: "B")
        links.receive(.elicitationRequest(sessionId: "s", payload: .init(
            requestId: "url-request", title: nil, message: "Sign in", mode: "url", fields: [],
            elicitationId: "oauth", url: "https://example.com/connect"
        )), from: "B")

        client.respondToElicitation(requestId: "url-request", action: "accept", content: [:])

        #expect(!links.sent(to: "B").contains {
            if case .elicitationResponse(_, "url-request", "accept", _) = $0 { return true }
            return false
        })

        var requestedURL: URL?
        var finishOpening: (@MainActor (Bool) -> Void)?
        var didOpen = false
        client.openElicitationURL(requestId: "url-request", openURL: { url, finish in
            requestedURL = url
            finishOpening = finish
        }, completion: { didOpen = $0 })
        #expect(requestedURL?.absoluteString == "https://example.com/connect")
        finishOpening?(false)
        #expect(!didOpen)
        #expect(!links.sent(to: "B").contains {
            if case .elicitationResponse(_, "url-request", "accept", _) = $0 { return true }
            return false
        })

        client.openElicitationURL(requestId: "url-request", openURL: { url, finish in
            requestedURL = url
            finishOpening = finish
        }, completion: { didOpen = $0 })
        finishOpening?(true)
        #expect(didOpen)
        #expect(links.sent(to: "B").contains(
            .elicitationResponse(sessionId: "s", requestId: "url-request", action: "accept", content: [:])
        ))
    }

    @Test func arrayElicitationSubmitsSelectedOptionsAsStringArray() {
        let field = RemoteElicitationField(
            key: "scopes", type: "array", title: "Scopes", description: nil, required: true,
            minLength: nil, maxLength: nil, minimum: nil, maximum: nil, minItems: 1, maxItems: nil,
            format: nil, pattern: nil,
            options: [
                .init(value: "read", title: "Read", description: nil),
                .init(value: "write", title: "Write", description: nil),
                .init(value: "admin", title: "Admin", description: nil),
            ],
            defaultValue: nil
        )

        let content = NativePeerElicitationForm.submittedContent(
            fields: [field], values: [:], selectedOptions: ["scopes": ["write", "read"]]
        )

        #expect(content == ["scopes": .strings(["read", "write"])])
    }
}
