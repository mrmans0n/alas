import Foundation
import Testing
@testable import AlasCore

@MainActor
struct AlasHostExecutableTests {
    /// The host serves its data directory alone: it prints where it serves,
    /// a second host there exits naming the first, and SIGTERM stops it and
    /// frees the directory.
    @Test func aHostOwnsItsDataDirectoryUntilStopped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alas-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try AlasHostProcess(dataDirectory: directory)

        let socket = try await host.socketPath()
        #expect(FileManager.default.fileExists(atPath: socket))

        let second = try AlasHostProcess(dataDirectory: directory)
        #expect(try await second.exitStatus() == 1)
        #expect(second.errorOutput.contains("process \(host.process.processIdentifier)"))

        host.process.terminate()
        #expect(try await host.exitStatus() == 0)
        _ = try DataDirectoryLock.acquire(in: directory)
    }

    /// A profile with Remote enabled is served on loopback too, under the
    /// server id the host saved to the profile.
    @Test func aHostServesRemoteWhenItsProfileEnablesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alas-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = AppConfig.defaults
        config.remote.enabled = true
        let configFile = directory.appendingPathComponent("app.json")
        try PersistenceStore().write(config, to: configFile)
        let host = try AlasHostProcess(dataDirectory: directory)

        _ = try await host.socketPath()
        try await eventually { [host] in host.output.contains("remote ") || !host.process.isRunning }
        let line = try #require(host.output.split(separator: "\n").first { $0.hasPrefix("remote ") }, "\(host.errorOutput)")
        let address = try #require(URL(string: String(line.dropFirst("remote ".count))))
        #expect(address.host == "127.0.0.1")
        let (body, _) = try await URLSession.shared.data(from: address.appendingPathComponent("health"))
        let health = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let saved = try #require(try PersistenceStore().readIfExists(AppConfig.self, from: configFile))
        #expect(!saved.remote.serverId.isEmpty)
        #expect(health["serverId"] as? String == saved.remote.serverId)
    }

    /// Hostless, over the wire: the built host serves a project, a worktree,
    /// a session with a scripted agent and a run, then stops and frees its
    /// data directory.
    @Test func aHostDrivesAWorktreeASessionAndARunOverTheWire() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-e2e-\(UUID().uuidString)")
        let dataDirectory = root.appendingPathComponent("data")
        let repo = root.appendingPathComponent("repo")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try GitTemplate.repository(at: repo)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/acp_fixture_agent.py")
        var config = AppConfig.defaults
        let agent = ACPRegistryInstalledAgent(
            registryID: "e2e-fixture", displayName: "Fixture", version: "1",
            command: "/usr/bin/python3", arguments: [fixture.path], environment: [:], isEnabled: true
        )
        config.agents.registry = [agent]
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try PersistenceStore().write(config, to: dataDirectory.appendingPathComponent("app.json"))

        let host = try AlasHostProcess(dataDirectory: dataDirectory)
        let client = try SocketClient(path: try await host.socketPath())
        defer { client.close() }
        guard case .snapshot(let snapshot) = try await client.request(.snapshot) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(try await client.request(.subscribe(after: snapshot.cursor)) == .subscribed)

        guard case .project(let project) = try await client.request(.addProject(
            path: repo.path, displayName: "repo", host: nil, kind: .git
        )) else {
            Issue.record("expected the added project")
            return
        }
        let destination = root.appendingPathComponent("feature")
        guard case .worktree(let worktree) = try await client.request(.createWorktree(
            projectID: project.id, base: "main", branch: "feature", destination: destination.path
        )) else {
            Issue.record("expected the created worktree")
            return
        }
        let ref = WorktreeRef(projectID: project.id, path: worktree.path.path)

        guard case .session(let session) = try await client.request(.createSession(
            target: .worktree(ref), agentID: agent.agentDefinition.id, modelID: nil, autoRun: false
        )) else {
            Issue.record("expected the created session")
            return
        }
        let id = session.id
        try await client.waitForEvent { if case .sessionChanged(let summary) = $0 { summary.id == id && summary.isWriter } else { false } }
        #expect(try await client.request(.followSession(sessionID: id, from: nil)) == .done)
        #expect(try await client.request(.sendPrompt(sessionID: id, prompt: "hello")) == .done)
        try await client.waitForEvent { event in
            guard case .transcript(_, id, let delta) = event else { return false }
            return delta.messages.contains { $0.kind == "agent" && $0.payload.contains("fixture reply") }
        }

        guard case .runStart(.started(let runID)) = try await client.request(.startRun(scriptKey: "repo:hello.sh", worktree: ref)) else {
            Issue.record("expected the run to start")
            return
        }
        try await client.waitForEvent { event in
            guard case .runChanged(let record) = event, record.id == runID, case .finished = record.status else { return false }
            return true
        }
        #expect(try await client.request(.runOutput(runID: runID, projectID: project.id)) == .runOutput(output: .text("hello from run\n", truncated: false)))

        host.process.terminate()
        #expect(try await host.exitStatus() == 0)
        _ = try DataDirectoryLock.acquire(in: dataDirectory)
    }
}
