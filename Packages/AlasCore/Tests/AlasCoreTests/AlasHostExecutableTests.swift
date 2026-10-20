import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

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

    /// With Remote enabled, a device pairs with a code the running host
    /// mints for its local user, and drives a session with the scripted
    /// agent over the Remote channel. A paired device cannot mint codes, and
    /// a Mac paired earlier, with no key pinned, cannot connect.
    @Test func aDevicePairedWithAHeadlessHostDrivesASessionOverRemote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-remote-\(UUID().uuidString)")
        let dataDirectory = root.appendingPathComponent("data")
        let repo = root.appendingPathComponent("repo")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try GitTemplate.repository(at: repo)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/acp_fixture_agent.py")
        var config = AppConfig.defaults
        config.remote.enabled = true
        let agent = ACPRegistryInstalledAgent(
            registryID: "e2e-fixture", displayName: "Fixture", version: "1",
            command: "/usr/bin/python3", arguments: [fixture.path], environment: [:], isEnabled: true
        )
        config.agents.registry = [agent]
        let configFile = dataDirectory.appendingPathComponent("app.json")
        try PersistenceStore().write(config, to: configFile)
        let earlierPairing = RemotePairingService(store: FileDeviceStore(url: dataDirectory.appendingPathComponent("remote-devices.json")))
        let macToken = try earlierPairing.redeemPeer(code: earlierPairing.beginPairing(), deviceName: "Old Mac", peerServerId: "old-mac").token
        let host = try AlasHostProcess(dataDirectory: dataDirectory)
        _ = try await host.socketPath()
        try await eventually { [host] in host.output.contains("remote ") || !host.process.isRunning }
        let line = try #require(host.output.split(separator: "\n").first { $0.hasPrefix("remote ") }, "\(host.errorOutput)")
        let address = try #require(URL(string: String(line.dropFirst("remote ".count))))
        #expect(address.host == "127.0.0.1")

        let pair = try AlasHostProcess(dataDirectory: dataDirectory, arguments: ["pair"])
        #expect(try await pair.exitStatus() == 0)
        let code = pair.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var redeem = URLRequest(url: address.appendingPathComponent("pair"))
        redeem.httpMethod = "POST"
        redeem.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "deviceName": "e2e"])
        let (paired, _) = try await URLSession.shared.data(for: redeem)
        let token = try #require((try JSONSerialization.jsonObject(with: paired) as? [String: Any])?["token"] as? String)

        var components = try #require(URLComponents(url: address, resolvingAgainstBaseURL: false))
        components.scheme = "ws"
        components.path = "/ws"
        let macSocket = URLSession.shared.webSocketTask(with: try #require(components.url), protocols: [macToken])
        macSocket.resume()
        defer { macSocket.cancel() }
        #expect((try? await macSocket.receive()) == nil)
        let socket = URLSession.shared.webSocketTask(with: try #require(components.url), protocols: [token])
        socket.resume()
        defer { socket.cancel() }
        func receive() async throws -> RemoteServerMessage? {
            guard case .string(let text) = try await socket.receive() else { return nil }
            return try? JSONDecoder().decode(RemoteServerMessage.self, from: Data(text.utf8))
        }
        func send(_ message: RemoteClientMessage) async throws {
            try await socket.send(.string(String(decoding: try JSONEncoder().encode(message), as: UTF8.self)))
        }
        guard case .hello(let version, let serverId, _, _, _, _)? = try await receive() else {
            Issue.record("expected hello")
            return
        }
        let saved = try #require(try PersistenceStore().readIfExists(AppConfig.self, from: configFile))
        #expect(serverId == saved.remote.serverId)
        try await send(.helloAck(protocolVersion: version))
        var nextID = 0
        var events: [HostEvent] = []
        func request(_ request: HostRequest) async throws -> HostResponse {
            nextID += 1
            let id = nextID
            try await send(.host(HostClientMessage(id: id, request: request)))
            while true {
                switch try await receive() {
                case .host(.response(id, let result)): return result
                case .host(.events(let batch, _)): events += batch
                default: continue
                }
            }
        }
        func waitForEvent(_ matches: (HostEvent) -> Bool) async throws {
            while !events.contains(where: matches) {
                if case .host(.events(let batch, _)) = try await receive() { events += batch }
            }
        }

        guard case .failure = try await request(.remotePairingCode) else {
            Issue.record("a paired device minted a pairing code")
            return
        }
        guard case .snapshot(let snapshot) = try await request(.snapshot) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(try await request(.subscribe(after: snapshot.cursor)) == .subscribed)
        guard case .project(let project) = try await request(.addProject(path: repo.path, displayName: "repo", host: nil, kind: .git)) else {
            Issue.record("expected the added project")
            return
        }
        let ref = WorktreeRef(projectID: project.id, path: repo.standardizedFileURL.path)
        guard case .session(let session) = try await request(.createSession(
            target: .worktree(ref), agentID: agent.agentDefinition.id, modelID: nil, autoRun: false
        )) else {
            Issue.record("expected the created session")
            return
        }
        let id = session.id
        try await waitForEvent { if case .sessionChanged(let summary) = $0 { summary.id == id && summary.isWriter } else { false } }
        #expect(try await request(.followSession(sessionID: id, from: nil)) == .done)
        #expect(try await request(.sendPrompt(sessionID: id, prompt: "hello")) == .done)
        try await waitForEvent { event in
            guard case .transcript(_, id, let delta) = event else { return false }
            return delta.messages.contains { $0.kind == "agent" && $0.payload.contains("fixture reply") }
        }

        host.process.terminate()
        #expect(try await host.exitStatus() == 0)
    }

    /// Inside the app, the host serves the web client the app ships, beside
    /// its own directory, when started through a link as the cask installs it.
    @Test func aBundledHostServesTheWebClientBesideIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Alas.app/Contents/Resources")
        let bundled = resources.appendingPathComponent("alas-host/alas-host")
        try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: AlasHostProcess.binary, to: bundled)
        let marker = "bundled web client \(UUID().uuidString)"
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("RemoteWeb"), withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: resources.appendingPathComponent("RemoteWeb/index.html"))
        let link = root.appendingPathComponent("bin/alas-host")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundled)
        let dataDirectory = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        var config = AppConfig.defaults
        config.remote.enabled = true
        try PersistenceStore().write(config, to: dataDirectory.appendingPathComponent("app.json"))

        let host = try AlasHostProcess(dataDirectory: dataDirectory, binary: link)
        _ = try await host.socketPath()
        try await eventually { [host] in host.output.contains("remote ") || !host.process.isRunning }
        let line = try #require(host.output.split(separator: "\n").first { $0.hasPrefix("remote ") }, "\(host.errorOutput)")
        let address = try #require(URL(string: String(line.dropFirst("remote ".count))))
        let (page, _) = try await URLSession.shared.data(from: address)
        #expect(String(decoding: page, as: UTF8.self) == marker)
        host.process.terminate()
        #expect(try await host.exitStatus() == 0)
    }

    /// The launch agent's host stops when an upgrade replaces its executable,
    /// so launchd starts the new one in its place.
    @Test func anAgentsHostStopsWhenItsExecutableIsReplaced() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-upgrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("alas-host")
        let dataDirectory = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: AlasHostProcess.binary, to: installed)
        let host = try AlasHostProcess(dataDirectory: dataDirectory, arguments: ["--wait-for-lock"], binary: installed)
        _ = try await host.socketPath()

        let upgrade = root.appendingPathComponent("alas-host.new")
        try FileManager.default.copyItem(at: AlasHostProcess.binary, to: upgrade)
        #expect(rename(upgrade.path, installed.path) == 0)
        #expect(try await host.exitStatus() == 0)
    }

    /// An upgrade while the agent's host waits for the app counts too: once
    /// the app lets go, the old host exits instead of serving.
    @Test func anAgentsHostUpgradedWhileWaitingExitsInsteadOfServing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-upgrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("alas-host")
        let dataDirectory = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: AlasHostProcess.binary, to: installed)
        var app: DataDirectoryLock? = try DataDirectoryLock.acquire(in: dataDirectory)
        let host = try AlasHostProcess(dataDirectory: dataDirectory, arguments: ["--wait-for-lock"], binary: installed)
        try await eventually { [host] in host.errorOutput.contains("waiting for process \(getpid())") }

        let upgrade = root.appendingPathComponent("alas-host.new")
        try FileManager.default.copyItem(at: AlasHostProcess.binary, to: upgrade)
        #expect(rename(upgrade.path, installed.path) == 0)
        app = nil
        _ = app
        #expect(try await host.exitStatus() == 0)
        #expect(host.output.isEmpty)
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
