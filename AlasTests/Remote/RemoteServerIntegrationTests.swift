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
}
