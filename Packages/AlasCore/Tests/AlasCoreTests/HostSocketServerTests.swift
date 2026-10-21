import Darwin
import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

@MainActor
struct HostSocketServerTests {
    /// A client of the host socket takes a snapshot, follows its events, and
    /// creates, archives and deletes a worktree, all over the wire.
    @Test func aSocketClientDrivesAWorktreeThroughItsLifecycle() async throws {
        // Short: a socket path must fit in `sun_path`.
        let root = URL(fileURLWithPath: "/tmp/alas-host-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "maintenance.auto", "false"],
            ["commit", "-q", "--allow-empty", "-m", "init"],
        ] {
            let result = try await Process.git(args, cwd: repo)
            guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        }
        let core = AlasCoreContext(
            projects: ProjectsManager(persistedProjects: []),
            projectsFile: root.appendingPathComponent("projects.json"),
            runHistoryStore: nil,
            workspaceStore: WorkspaceStore(url: root.appendingPathComponent("workspaces.json")),
            attentionStore: .scratch(),
            environment: NoCheckpointsEnvironment()
        )
        let project = try await core.addProject(path: repo, displayName: "repo", icon: .default())
        let path = root.appendingPathComponent("run/host.sock").path
        let first = try #require(HostSocketServer(path: path, server: HostProtocolServer(host: AlasHost(core: core))))
        // One host per socket, even when its socket file is gone for a moment
        // or another host starts at the same time.
        unlink(path)
        #expect(HostSocketServer(path: path, server: HostProtocolServer(host: AlasHost(core: core))) == nil, "one host per socket")
        // Free once stopped, even while a child still holds a copy of the
        // lock's descriptor.
        let socket = try withChildHolding(first.lockFD) {
            first.stop()
            return try #require(HostSocketServer(path: path, server: HostProtocolServer(host: AlasHost(core: core))))
        }
        defer { socket.stop() }
        let client = try SocketClient(path: path)
        defer { client.close() }

        guard case .snapshot(let snapshot) = try await client.request(.snapshot) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(snapshot.projects.map(\.id) == [project.id])
        #expect(try await client.request(.subscribe(after: snapshot.cursor)) == .subscribed)

        let destination = root.appendingPathComponent("feature")
        guard case .worktree(let created) = try await client.request(.createWorktree(
            projectID: project.id, base: "main", branch: "feature", destination: destination.path
        )) else {
            Issue.record("expected the created worktree")
            return
        }
        #expect(created.branch == "feature")
        try await client.waitForEvent { event in
            if case .worktreeChanged(let worktree) = event { worktree.worktree.id == created.id && worktree.operation == nil } else { false }
        }

        let ref = WorktreeRef(projectID: project.id, path: destination.path)
        let archived = try await client.request(.archiveWorktree(worktree: ref, lineageID: created.lineageID, branch: created.branch))
        #expect(archived == .done, "\(archived)")
        try await client.waitForEvent { event in
            if case .worktreeChanged(let worktree) = event { worktree.worktree.id == created.id && worktree.isArchived } else { false }
        }

        let deleted = try await client.request(.deleteWorktree(
            worktree: ref, lineageID: created.lineageID, branch: created.branch, force: false, deleteBranchIfMerged: false
        ))
        #expect(deleted == .done, "\(deleted)")
        try await client.waitForEvent { $0 == .worktreeRemoved(projectID: project.id, worktreeID: created.id) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// The accept loop survives a failed accept unless its socket is gone:
    /// otherwise the host would keep its path while serving nobody.
    @Test(arguments: [
        (ECONNABORTED, HostSocketServer.AcceptFailure.retry),
        (EINTR, .retry),
        (EMFILE, .backOff),
        (ENFILE, .backOff),
        (EBADF, .stop),
        (EINVAL, .stop),
    ])
    func acceptFailuresEndTheLoopOnlyWhenTheSocketIsGone(_ code: Int32, _ outcome: HostSocketServer.AcceptFailure) {
        #expect(HostSocketServer.afterAcceptFailure(errno: code) == outcome)
    }

    /// A host older than a request cannot decode it and answers under id 0;
    /// a one-shot request returns that answer instead of waiting for id 1.
    @Test(.timeLimit(.minutes(1))) func aOneShotRequestReturnsAnOlderHostsRefusal() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString.prefix(8)).sock").path
        defer { unlink(path) }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener) }
        #expect(HostSocketServer.withAddress(path, { bind(listener, $0, $1) }) == 0)
        #expect(listen(listener, 1) == 0)
        let refusal = HostServerMessage.response(id: 0, result: .failure(error: .invalidRequest(reason: "unknown request")))
        var reply = try JSONEncoder().encode(refusal)
        reply.append(UInt8(ascii: "\n"))
        Thread.detachNewThread { [reply] in
            let client = accept(listener, nil, nil)
            var byte: UInt8 = 0
            while read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {}
            _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            // Left open, as a host keeps the connection after a bad message.
        }

        let response = try await Task.detached { try HostSocketServer.request(.remotePairingCode, at: path) }.value
        #expect(response == .failure(error: .invalidRequest(reason: "unknown request")))
    }
}

/// A host whose checkpoint store has nothing to recover, so a removal does
/// not depend on the checkpoints this machine's profile holds.
@MainActor
private final class NoCheckpointsEnvironment: AlasHostEnvironment {
    func checkpointRecoveryBlocksRemoval(_ worktree: Worktree) async -> Bool { false }
}

/// A host protocol client over a Unix socket: requests by id, and the events
/// that arrive meanwhile.
@MainActor
final class SocketClient {
    private let fd: Int32
    private var nextID = 0
    private var responses: [Int: HostResponse] = [:]
    private(set) var events: [HostEvent] = []

    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, HostSocketServer.withAddress(path, { connect(fd, $0, $1) }) == 0 else {
            throw POSIXError(.ECONNREFUSED)
        }
        self.fd = fd
        Thread.detachNewThread { [weak self] in
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { return }
                pending.append(contentsOf: chunk[0 ..< count])
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Data(pending[pending.startIndex ..< newline])
                    pending.removeSubrange(pending.startIndex ... newline)
                    guard let message = try? JSONDecoder().decode(HostServerMessage.self, from: line) else { continue }
                    Task { @MainActor in self?.deliver(message) }
                }
            }
        }
    }

    func close() {
        Darwin.close(fd)
    }

    func request(_ request: HostRequest) async throws -> HostResponse {
        nextID += 1
        let id = nextID
        var line = try JSONEncoder().encode(HostClientMessage(id: id, request: request))
        line.append(UInt8(ascii: "\n"))
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        try await eventually(within: .seconds(30)) { await self.responses[id] != nil }
        return try #require(responses[id])
    }

    func waitForEvent(_ matches: @escaping @Sendable (HostEvent) -> Bool) async throws {
        try await eventually(within: .seconds(30)) { await self.events.contains(where: matches) }
    }

    private func deliver(_ message: HostServerMessage) {
        switch message {
        case .response(let id, let result): responses[id] = result
        case .events(let batch, _): events += batch
        }
    }
}
