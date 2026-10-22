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
    /// agent over the Remote channel. A paired device cannot mint codes.
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
        let host = try AlasHostProcess(dataDirectory: dataDirectory)
        _ = try await host.socketPath()
        try await eventually { [host] in host.output.contains("remote ") || !host.process.isRunning }
        let line = try #require(host.output.split(separator: "\n").first { $0.hasPrefix("remote ") }, "\(host.errorOutput)")
        let address = try #require(URL(string: String(line.dropFirst("remote ".count))))
        #expect(address.host == "127.0.0.1")

        let pair = try AlasHostProcess(dataDirectory: dataDirectory, arguments: ["pair"])
        #expect(try await pair.exitStatus() == 0)
        let code = String(pair.output.prefix { $0 != "\n" })
        var redeem = URLRequest(url: address.appendingPathComponent("pair"))
        redeem.httpMethod = "POST"
        redeem.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "deviceName": "e2e"])
        let (paired, _) = try await URLSession.shared.data(for: redeem)
        let token = try #require((try JSONSerialization.jsonObject(with: paired) as? [String: Any])?["token"] as? String)

        var components = try #require(URLComponents(url: address, resolvingAgainstBaseURL: false))
        components.scheme = "ws"
        components.path = "/ws"
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

    /// The host listens where its own `host` settings say, over the shared
    /// `remote` section: loopback with Remote off serves, off with Remote on
    /// does not.
    @Test func aHostServesTheReachabilityItsSettingsName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-reach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func profile(_ name: String, _ configure: (inout AppConfig) -> Void) throws -> URL {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var config = AppConfig.defaults
            configure(&config)
            var json = try JSONSerialization.jsonObject(with: PersistenceStore().encode(config)) as? [String: Any] ?? [:]
            json["fromANewerApp"] = 1
            try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("app.json"))
            return directory
        }
        let port = try freePort()
        let loopback = try AlasHostProcess(dataDirectory: profile("loopback") {
            $0.remote.enabled = false
            $0.host = HostSettings(reachability: .loopback, port: port)
        })
        _ = try await loopback.socketPath()
        try await eventually { [loopback] in loopback.output.contains("remote ") || !loopback.process.isRunning }
        #expect(loopback.output.split(separator: "\n").contains("remote http://127.0.0.1:\(port)"), "\(loopback.errorOutput)")
        loopback.process.terminate()
        #expect(try await loopback.exitStatus() == 0)
        // Saving the assigned server id keeps settings this build does not model.
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("loopback/app.json"))) as? [String: Any]
        #expect(saved?["fromANewerApp"] as? Int == 1)
        #expect(((saved?["remote"] as? [String: Any])?["serverId"] as? String)?.isEmpty == false)

        let off = try AlasHostProcess(dataDirectory: profile("off") {
            $0.remote.enabled = true
            $0.host = HostSettings(reachability: .off)
        })
        _ = try await off.socketPath()
        off.process.terminate()
        #expect(try await off.exitStatus() == 0)
        #expect(!off.output.split(separator: "\n").contains { $0.hasPrefix("remote ") })
    }

    /// With no host running, settings and projects are changed in the
    /// profile's files: an invalid value is refused and leaves the old one.
    @Test func aProfileIsConfiguredFromTheCommandLine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-config-\(UUID().uuidString)")
        let dataDirectory = root.appendingPathComponent("data")
        let repo = root.appendingPathComponent("repo")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try GitTemplate.repository(at: repo)
        func run(_ arguments: String...) async throws -> (status: Int32, output: String, error: String) {
            let process = try AlasHostProcess(dataDirectory: dataDirectory, arguments: arguments)
            return (try await process.exitStatus(), process.output, process.errorOutput)
        }

        #expect(try await run("config", "set", "host.port", "18999").status == 0)
        #expect(try await run("config", "get", "host.port").output == "18999\n")
        let refused = try await run("config", "set", "host.port", "70000")
        #expect(refused.status == 1)
        #expect(refused.error.contains("host.port"))
        #expect(try await run("config", "get", "host.port").output == "18999\n")

        let added = try await run("project", "add", repo.path)
        #expect(added.status == 0, "\(added.error)")
        let listed = try await run("project", "list")
        #expect(listed.output.contains("  repo  \(repo.standardizedFileURL.path)\n"), "\(listed.output)")
        let removed = try await run("project", "remove", repo.path)
        #expect(removed.status == 0, "\(removed.error)")
        #expect(try await run("project", "list").output.isEmpty)
    }

    /// A project added before the host started, from the command line or by
    /// the app, has its worktrees once the host serves, as after a restart.
    @Test func aHostServesTheWorktreesOfProjectsAddedBeforeItStarted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-boot-\(UUID().uuidString)")
        let dataDirectory = root.appendingPathComponent("data")
        let repo = root.appendingPathComponent("repo")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try GitTemplate.repository(at: repo)
        let add = try AlasHostProcess(dataDirectory: dataDirectory, arguments: ["project", "add", repo.path])
        #expect(try await add.exitStatus() == 0, "\(add.errorOutput)")

        let host = try AlasHostProcess(dataDirectory: dataDirectory)
        let client = try SocketClient(path: try await host.socketPath())
        defer { client.close() }
        try await eventually {
            guard case .snapshot(let snapshot) = try? await client.request(.snapshot) else { return false }
            return snapshot.worktrees.contains { $0.worktree.path.standardizedFileURL == repo.standardizedFileURL }
        }
    }

    /// A Mac pairs with the host through the link `alas-host pair` prints,
    /// and the host proves the identity key it answers with, the same one
    /// after a restart.
    @Test func aMacCanPairWithTheHostAndProveItsIdentity() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("alas-peer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        var config = AppConfig.defaults
        config.host = HostSettings(reachability: .lan, port: try freePort())
        try PersistenceStore().write(config, to: dataDirectory.appendingPathComponent("app.json"))
        // Nothing listens where the Mac says it is: the host's pair-back fails.
        let mac = RemotePeerAdvertisement(
            serverId: "laptop", name: "Laptop", origins: ["http://127.0.0.1:\(try freePort())"], counterCode: nil
        )
        func pairAsMac() async throws -> String? {
            let host = try AlasHostProcess(dataDirectory: dataDirectory)
            _ = try await host.socketPath()
            try await eventually { [host] in host.output.contains("remote ") || !host.process.isRunning }
            let line = try #require(host.output.split(separator: "\n").first { $0.hasPrefix("remote ") }, "\(host.errorOutput)")
            let pair = try AlasHostProcess(dataDirectory: dataDirectory, arguments: ["pair"])
            #expect(try await pair.exitStatus() == 0, "\(pair.errorOutput)")
            let lines = pair.output.split(separator: "\n").map(String.init)
            #expect(lines.count == 2, "\(pair.output)")
            let link = try #require(RemotePairingLink.parse(lines.last ?? ""), "\(pair.output)")
            #expect(link.code == lines.first)
            // The link names this machine's interfaces; loopback alone is
            // reachable wherever the test runs.
            #expect(link.origins.contains { !RunEndpointPolicy.isLoopback(URL(string: $0)!) }, "\(link.origins)")
            let outcome = await RemotePeerPairer.live.pair(
                origins: [String(line.dropFirst("remote ".count))], code: link.code, deviceName: "Laptop", advertisement: mac
            )
            // Stopped before the next start, which needs the data directory.
            host.process.terminate()
            #expect(try await host.exitStatus() == 0)
            guard case .paired(_, _, _, let publicKey, _) = outcome else {
                Issue.record("expected the host to pair, got \(outcome)")
                return nil
            }
            return publicKey
        }

        let key = try #require(try await pairAsMac())
        #expect(!key.isEmpty)
        #expect(try await pairAsMac() == key)
    }

    /// A port nothing listens on now, for a host to bind.
    private func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        try #require(bound)
        return UInt16(bigEndian: address.sin_port)
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
