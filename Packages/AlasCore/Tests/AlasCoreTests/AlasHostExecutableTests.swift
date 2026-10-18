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

    /// Hostless, over the wire: the built host serves a project, a worktree,
    /// a session with a scripted agent and a run, then stops and frees its
    /// data directory.
    @Test func aHostDrivesAWorktreeASessionAndARunOverTheWire() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-e2e-\(UUID().uuidString)")
        let dataDirectory = root.appendingPathComponent("data")
        let repo = root.appendingPathComponent("repo")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRepository(at: repo)
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
        #expect(try await client.request(.runOutput(runID: runID, projectID: project.id)) == .runOutput(output: .text("hello from run\n")))

        host.process.terminate()
        #expect(try await host.exitStatus() == 0)
        _ = try DataDirectoryLock.acquire(in: dataDirectory)
    }

    /// A repository on `main` with one commit and a run script.
    private func makeRepository(at repo: URL) throws {
        let scripts = repo.appendingPathComponent(RunScriptStore.repoScriptsRelativeDir)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = scripts.appendingPathComponent("hello.sh")
        try "#!/bin/sh\necho hello from run\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "add", "."],
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "initial"],
        ] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = arguments
            git.currentDirectoryURL = repo
            try git.run()
            git.waitUntilExit()
            try #require(git.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
        }
    }
}
