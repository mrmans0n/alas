import Testing
import Foundation
@testable import Alas

@MainActor
struct RemoteServerIntegrationTests {
    private func makeManager() throws -> ACPSessionManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-server-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        return ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp", store: store)
    }

    private func startServer(pairing: RemotePairingService,
                             provider: RemoteSessionsProvider = FakeSessionsProvider()) async throws -> (RemoteServer, UInt16) {
        let assets = RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let server = RemoteServer(pairing: pairing, assets: assets, provider: provider)
        try server.start(port: 0)
        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return (server, try #require(server.port))
    }

    @Test func pairThenWebSocketSubscribeReceivesSnapshot() async throws {
        // Provider with one session containing one agent message.
        let provider = FakeSessionsProvider()
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        s.transcript.messages = [.agent(id: UUID(), StreamingText("hello-remote"))]
        provider.sessions[s.id] = s
        provider.summaries = [RemoteSessionSummary(id: s.id, title: "T", agentId: "claude", status: "idle")]

        let assets = RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let server = RemoteServer(pairing: pairing, assets: assets, provider: provider)
        try server.start(port: 0)

        // Wait for port assignment.
        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = try #require(server.port)

        // Pair: mint a code in-process (UI would show its QR), redeem via HTTP.
        let code = pairing.beginPairing()
        var pairReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        pairReq.httpMethod = "POST"
        pairReq.httpBody = Data(#"{"code":"\#(code)","deviceName":"test"}"#.utf8)
        let (pairData, _) = try await URLSession.shared.data(for: pairReq)
        struct PairResp: Decodable { let token: String }
        let token = try JSONDecoder().decode(PairResp.self, from: pairData).token

        // Connect WS with token as subprotocol.
        let wsURL = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let task = URLSession.shared.webSocketTask(with: wsURL, protocols: [token])
        task.resume()
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.subscribe(sessionId: s.id))))

        // The server emits text frames; URLSession surfaces those as `.string`.
        let received = try await task.receive()
        let payload: Data?
        switch received {
        case .data(let d): payload = d
        case .string(let str): payload = Data(str.utf8)
        @unknown default: payload = nil
        }
        guard let data = payload,
              case .transcriptSnapshot(_, _, let msgs)? = try? JSONDecoder().decode(RemoteServerMessage.self, from: data) else {
            Issue.record("expected snapshot frame, got \(received)")
            task.cancel(with: .goingAway, reason: nil)
            server.stop()
            return
        }
        #expect(msgs.contains { $0.text == "hello-remote" })

        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    @Test func revokingDeviceDropsLiveWebSocket() async throws {
        let provider = FakeSessionsProvider()
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        s.transcript.messages = [.agent(id: UUID(), StreamingText("hello-remote"))]
        provider.sessions[s.id] = s
        provider.summaries = [RemoteSessionSummary(id: s.id, title: "T", agentId: "claude", status: "idle")]

        let assets = RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let server = RemoteServer(pairing: pairing, assets: assets, provider: provider)
        try server.start(port: 0)
        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = try #require(server.port)

        // Pair + connect.
        let code = pairing.beginPairing()
        var pairReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        pairReq.httpMethod = "POST"
        pairReq.httpBody = Data(#"{"code":"\#(code)","deviceName":"test"}"#.utf8)
        let (pairData, _) = try await URLSession.shared.data(for: pairReq)
        struct PairResp: Decodable { let token: String }
        let token = try JSONDecoder().decode(PairResp.self, from: pairData).token

        let wsURL = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let task = URLSession.shared.webSocketTask(with: wsURL, protocols: [token])
        task.resume()
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.subscribe(sessionId: s.id))))

        // Drain the initial snapshot so we know the socket is live and the
        // server has recorded this connection's device mapping.
        _ = try await task.receive()

        // Revoke the just-paired device and immediately drop its socket. Go
        // through the same path AppState.revokeRemoteDevice uses.
        let deviceId = try #require(pairing.devices.first?.id)
        pairing.revoke(deviceId: deviceId)
        server.disconnectDevice(deviceId)

        // The server-side cancel closes the socket; the next receive must fail.
        // Poll a few times so we don't depend on exact delivery timing of the
        // close frame / FIN through URLSession.
        var closed = false
        for _ in 0..<50 {
            do {
                _ = try await task.receive()
            } catch {
                closed = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(closed, "expected the WS to close after the device was revoked")

        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    @Test func unknownPathReturns404() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let (_, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/nope")!)
        #expect((resp as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func badPairCodeReturns401() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        _ = pairing.beginPairing()  // a valid code exists, but the client sends the wrong one
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"code":"WRONGCODE","deviceName":"x"}"#.utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 401)
    }

    @Test func webSocketWithBadTokenIsRejected() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let task = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/ws")!, protocols: ["bogus-token"])
        task.resume()
        do {
            _ = try await task.receive()
            Issue.record("expected the WS upgrade to be rejected for an unpaired token")
        } catch {
            // Expected: the server returns 401 instead of 101, so receive fails.
        }
        task.cancel(with: .goingAway, reason: nil)
    }
}
