import Foundation
import Testing
import AlasCore
@testable import AlasHostCore

@MainActor
struct PeerHostChannelTests {
    /// What the channel sent; `replies` are delivered as soon as the request
    /// with that id is sent, before `send` returns.
    @MainActor final class Sent {
        var messages: [HostClientMessage] = []
        var replies: [Int: [HostServerMessage]] = [:]
        weak var channel: PeerHostChannel?

        func append(_ message: HostClientMessage) {
            messages.append(message)
            for reply in replies[message.id] ?? [] { channel?.receive(reply) }
        }
    }

    let cursor = HostCursor(generation: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!, sequence: 7)
    let feature: WorktreeSnapshot = {
        let path = URL(fileURLWithPath: "/srv/feature")
        return WorktreeSnapshot(
            worktree: Worktree(
                id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
                path: path, status: .clean, lastActivity: .distantPast
            ),
            operation: nil, isArchived: false
        )
    }()

    func snapshot(_ worktrees: [WorktreeSnapshot]) -> HostSnapshot {
        HostSnapshot(cursor: cursor, projects: [], worktrees: worktrees, workspaceCheckouts: [], runs: [], sessions: [])
    }

    /// A channel subscribed after a snapshot listing `worktrees`; it used ids 1 and 2.
    func connected(_ worktrees: [WorktreeSnapshot]) async -> (PeerHostChannel, Sent) {
        let sent = Sent()
        let channel = PeerHostChannel(send: sent.append)
        sent.channel = channel
        sent.replies = [
            1: [.response(id: 1, result: .snapshot(snapshot: snapshot(worktrees)))],
            2: [.response(id: 2, result: .subscribed)],
        ]
        await channel.connect()
        return (channel, sent)
    }

    @Test func connectTakesASnapshotThenSubscribesAfterItsCursor() async throws {
        let sent = Sent()
        let channel = PeerHostChannel(send: sent.append)
        var changes = 0
        channel.onChange = { changes += 1 }
        let connecting = Task { await channel.connect() }
        try await eventually { @MainActor in sent.messages.count == 1 }
        #expect(sent.messages[0].request == .snapshot)

        channel.receive(.response(id: 1, result: .snapshot(snapshot: snapshot([feature]))))
        try await eventually { @MainActor in sent.messages.count == 2 }
        #expect(channel.state?.worktrees == [feature])
        #expect(sent.messages[1].request == .subscribeAccepting(after: cursor, events: ["notice", "worktreeNotice"]))
        #expect(!channel.isSubscribed)
        #expect(changes == 1)

        // The host forwards events right after `.subscribed`, before `connect()` resumes.
        channel.receive(.response(id: 2, result: .subscribed))
        // Readiness is a change: reads gated on it can start now.
        #expect(channel.isSubscribed)
        #expect(changes == 2)
        channel.receive(.events(events: [.worktreeRemoved(projectID: "p", worktreeID: feature.worktree.id)], cursor: cursor))
        await connecting.value
        #expect(channel.isSubscribed)
        #expect(channel.state?.worktrees == [])
    }

    @Test func eventsApplyOnlyWhileSubscribedAndResyncTakesANewSnapshot() async throws {
        let (channel, sent) = await connected([feature])
        var archived = feature
        archived.isArchived = true
        channel.receive(.events(events: [.worktreeChanged(archived)], cursor: cursor))
        #expect(channel.state?.worktrees.first?.isArchived == true)
        channel.receive(.events(events: [.worktreeRemoved(projectID: "p", worktreeID: feature.worktree.id)], cursor: cursor))
        #expect(channel.state?.worktrees == [])
        // A notice is handed on, and changes no state.
        var got: [HostNotice] = []
        channel.onNotice = { got.append($0) }
        let notice = HostNotice(id: UUID(), owner: .worktree("w"), sessionID: "s", agent: "codex", title: "Q", body: "Pick one")
        let before = channel.state
        channel.receive(.events(events: [.notice(notice)], cursor: cursor))
        #expect(got == [notice])
        #expect(channel.state == before)

        var gotWorktree: [HostWorktreeNotice] = []
        channel.onWorktreeNotice = { gotWorktree.append($0) }
        let worktreeNotice = HostWorktreeNotice(id: UUID(), worktreeID: "w", title: nil, body: "Tests failed")
        channel.receive(.events(events: [.worktreeNotice(worktreeNotice)], cursor: cursor))
        #expect(gotWorktree == [worktreeNotice])
        #expect(channel.state == before)

        var summary = HostSessionSummary(
            owner: .worktree("w"), id: "s", agentId: "codex", title: "T", remoteSessionId: "r",
            createdAt: 1, updatedAt: 2, lastOpenedAt: 3, streamingState: .idle, isWriter: true
        )
        summary.shepherd = HostSessionShepherd(badge: "fixing", number: "#7", tooltip: "t")
        channel.receive(.events(events: [.sessionChanged(summary)], cursor: cursor))
        #expect(channel.state?.shepherds["s"] == summary.shepherd)
        channel.receive(.events(events: [.sessionRemoved(owner: .worktree("w"), id: "s")], cursor: cursor))
        #expect(channel.state?.shepherds["s"] == nil)

        // Batches of the replaced subscription keep coming until the new one starts.
        var deleting = feature
        deleting.operation = .deleting
        let stale = HostServerMessage.events(events: [.worktreeChanged(deleting)], cursor: cursor)
        channel.receive(.events(events: [.resync], cursor: cursor))
        channel.receive(stale)
        #expect(channel.state?.worktrees == [])
        try await eventually { @MainActor in sent.messages.count == 3 }
        #expect(sent.messages[2].request == .snapshot)
        channel.receive(stale)
        channel.receive(.response(id: 3, result: .snapshot(snapshot: snapshot([]))))
        try await eventually { @MainActor in sent.messages.count == 4 }
        channel.receive(stale)
        channel.receive(.response(id: 4, result: .subscribed))
        try await eventually { @MainActor in channel.isSubscribed }
        #expect(channel.state?.worktrees == [])
    }

    @Test func answersAreMatchedToTheirRequestsById() async throws {
        let sent = Sent()
        let channel = PeerHostChannel(send: sent.append)
        let sessions = Task { await channel.request(.listSessions) }
        try await eventually { @MainActor in sent.messages.count == 1 }
        let capabilities = Task { await channel.request(.capabilities) }
        try await eventually { @MainActor in sent.messages.count == 2 }

        channel.receive(.response(id: 2, result: .capabilities(capabilities: ["host.v1"])))
        channel.receive(.response(id: 1, result: .sessions(sessions: [])))
        #expect(await sessions.value == .sessions(sessions: []))
        #expect(await capabilities.value == .capabilities(capabilities: ["host.v1"]))
    }

    @Test func anUnansweredRequestFailsAfterItsTimeoutAndItsLateAnswerIsDropped() async {
        let sent = Sent()
        let channel = PeerHostChannel(timeout: .milliseconds(20), send: sent.append)
        sent.channel = channel
        #expect(await channel.request(.snapshot) == .failure(error: .failed(message: PeerHostChannel.unansweredMessage)))

        // The late answer arrives while the next request is out; only that request's own answer resolves it.
        sent.replies[2] = [
            .response(id: 1, result: .done),
            .response(id: 2, result: .capabilities(capabilities: [])),
        ]
        #expect(await channel.request(.capabilities) == .capabilities(capabilities: []))
    }

    @Test func disconnectFailsPendingRequestsAndForgetsTheState() async throws {
        let (channel, sent) = await connected([feature])
        let pending = Task { await channel.request(.listSessions) }
        try await eventually { @MainActor in sent.messages.count == 3 }

        channel.disconnect()
        #expect(await pending.value == .failure(error: .failed(message: FederatedSessionsProvider.peerUnavailableMessage)))
        #expect(channel.state == nil)
        #expect(!channel.isSubscribed)
        channel.receive(.events(events: [.worktreeChanged(feature)], cursor: cursor))
        #expect(channel.state == nil)
    }

    @Test func aResyncDoesNotReconnectAfterADisconnect() async {
        let (channel, sent) = await connected([feature])
        channel.receive(.events(events: [.resync], cursor: cursor))
        channel.disconnect()
        // Main-actor jobs run in order: this one runs after the resync's.
        await Task {}.value
        #expect(sent.messages.count == 2)
    }

    @Test func connectAfterADisconnectMidConnectStartsOver() async throws {
        let sent = Sent()
        let channel = PeerHostChannel(send: sent.append)
        let first = Task { await channel.connect() }
        try await eventually { @MainActor in sent.messages.count == 1 }
        channel.disconnect()
        let second = Task { await channel.connect() }
        try await eventually { @MainActor in sent.messages.count == 2 }
        #expect(sent.messages[1].request == .snapshot)
        await first.value
        channel.disconnect()
        await second.value
    }
}
