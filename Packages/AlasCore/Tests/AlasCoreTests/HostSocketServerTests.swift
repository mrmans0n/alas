import Darwin
import Foundation
import Testing
@testable import AlasCore

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
        let core = try AlasCoreContext(
            loadingFrom: PersistenceStore(),
            projectsFile: root.appendingPathComponent("projects.json"),
            runHistoryStore: nil,
            workspaceStore: WorkspaceStore(url: root.appendingPathComponent("workspaces.json"))
        )
        let project = try await core.addProject(path: repo, displayName: "repo", icon: .default())
        let path = root.appendingPathComponent("run/host.sock").path
        let first = try #require(HostSocketServer(path: path, server: HostProtocolServer(host: AlasHost(core: core))))
        // One host per socket, even when its socket file is gone for a moment
        // or another host starts at the same time.
        unlink(path)
        #expect(HostSocketServer(path: path, server: HostProtocolServer(host: AlasHost(core: core))) == nil, "one host per socket")
        first.stop()
        let socket = try #require(HostSocketServer(path: path, server: HostProtocolServer(host: AlasHost(core: core))))
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
        #expect(try await client.request(.archiveWorktree(worktree: ref, lineageID: created.lineageID, branch: created.branch)) == .done)
        try await client.waitForEvent { event in
            if case .worktreeChanged(let worktree) = event { worktree.worktree.id == created.id && worktree.isArchived } else { false }
        }

        #expect(try await client.request(.deleteWorktree(
            worktree: ref, lineageID: created.lineageID, branch: created.branch, force: false, deleteBranchIfMerged: false
        )) == .done)
        try await client.waitForEvent { $0 == .worktreeRemoved(projectID: project.id, worktreeID: created.id) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

/// A host protocol client over a Unix socket: requests by id, and the events
/// that arrive meanwhile.
@MainActor
private final class SocketClient {
    private let fd: Int32
    private var nextID = 0
    private var responses: [Int: HostResponse] = [:]
    private var events: [HostEvent] = []

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
