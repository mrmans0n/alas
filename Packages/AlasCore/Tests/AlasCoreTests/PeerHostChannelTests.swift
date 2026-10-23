import Foundation
import Testing
import AlasCore
import AlasHostCore

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
        let connecting = Task { await channel.connect() }
        try await eventually { @MainActor in sent.messages.count == 1 }
        #expect(sent.messages[0].request == .snapshot)

        channel.receive(.response(id: 1, result: .snapshot(snapshot: snapshot([feature]))))
        try await eventually { @MainActor in sent.messages.count == 2 }
        #expect(channel.state?.worktrees == [feature])
        #expect(sent.messages[1].request == .subscribe(after: cursor))
        #expect(!channel.isSubscribed)

        channel.receive(.response(id: 2, result: .subscribed))
        await connecting.value
        #expect(channel.isSubscribed)
    }

    @Test func eventsApplyOnlyWhileSubscribedAndResyncTakesANewSnapshot() async throws {
        let (channel, sent) = await connected([feature])
        var archived = feature
        archived.isArchived = true
        channel.receive(.events(events: [.worktreeChanged(archived)], cursor: cursor))
        #expect(channel.state?.worktrees.first?.isArchived == true)
        channel.receive(.events(events: [.worktreeRemoved(projectID: "p", worktreeID: feature.worktree.id)], cursor: cursor))
        #expect(channel.state?.worktrees == [])

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
}
