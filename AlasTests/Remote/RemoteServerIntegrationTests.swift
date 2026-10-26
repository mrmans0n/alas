import Testing
import Foundation
import Network
import Synchronization
@testable import Alas
@_spi(Testing) import AlasCore

@MainActor
struct RemoteServerIntegrationTests {
    private enum TimeoutError: Error {
        case timedOut
    }

    private func makeManager() throws -> ACPSessionManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-server-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        return ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp", store: store)
    }

    private func startServer(pairing: RemotePairingService,
                             provider: FakeRemoteApp = FakeRemoteApp()) async throws -> (RemoteServer, UInt16) {
        let assets = RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let server = RemoteServer(pairing: pairing, assets: assets, host: provider.host)
        server.present(provider)
        // The fake's reads, which tests hold back to pin ordering.
        server.configureGateway = { $0.hostCalls = provider.hostCalls }
        try server.start(port: 0)
        try await eventually("the server binds a port") { server.port != nil }
        return (server, try #require(server.port))
    }

    /// Records every frame the client receives, as it arrives.
    private func collect(_ task: URLSessionWebSocketTask) -> ReceivedMessages {
        let received = ReceivedMessages()
        Task { @MainActor in
            while let message = try? await receiveServerMessage(task) { received.all.append(message) }
        }
        return received
    }

    private func receiveServerMessage(_ task: URLSessionWebSocketTask) async throws -> RemoteServerMessage {
        let received = try await task.receive()
        let payload: Data
        switch received {
        case .data(let d): payload = d
        case .string(let s): payload = Data(s.utf8)
        @unknown default: throw TimeoutError.timedOut
        }
        return try JSONDecoder().decode(RemoteServerMessage.self, from: payload)
    }

    @Test func teardownCancelsQueuedPredecessorAndSkipsSuccessor() async {
        let gate = CancellableTaskGate()
        let previous = RemoteConnection.MessageProcessingTask(previous: nil)
        previous.start {
            await withTaskCancellationHandler(
                operation: { await gate.waitForRelease() },
                onCancel: { Task { await gate.recordCancellation() } }
            )
            await gate.recordCompletion(wasCancelled: Task.isCancelled)
        }
        guard await gate.waitForEntry() else {
            Issue.record("predecessor did not start")
            await gate.release()
            return
        }

        let successor = RemoteConnection.MessageProcessingTask(previous: previous)
        successor.start {
            await gate.recordHandlerRun()
        }
        successor.cancelForTeardown()

        let didCancelPredecessor = await gate.waitForCancellation()
        await gate.release()

        await previous.task.value
        #expect(didCancelPredecessor)
        #expect(await gate.completedWhileCancelled())
        await successor.task.value
        #expect(await gate.handlerDidRun() == false)
    }

    @Test func stopTimeoutCancellationDoesNotCancelQueuedPredecessor() async {
        let gate = CancellableTaskGate()
        let previous = RemoteConnection.MessageProcessingTask(previous: nil)
        previous.start {
            await withTaskCancellationHandler(
                operation: { await gate.waitForRelease() },
                onCancel: { Task { await gate.recordCancellation() } }
            )
            await gate.recordCompletion(wasCancelled: Task.isCancelled)
        }
        guard await gate.waitForEntry() else {
            Issue.record("predecessor did not start")
            await gate.release()
            return
        }

        let successor = RemoteConnection.MessageProcessingTask(previous: previous)
        successor.start {}
        successor.task.cancel()
        await gate.release()

        await previous.task.value
        #expect(await gate.completedWhileCancelled() == false)
        await successor.task.value
    }

    @Test func completedPredecessorIsPrunedFromSuccessor() async {
        let predecessor = RemoteConnection.MessageProcessingTask(previous: nil)
        predecessor.start {}
        await predecessor.task.value
        predecessor.markFinished()

        let successor = RemoteConnection.MessageProcessingTask(previous: predecessor)
        #expect(successor.hasPredecessor)
        successor.pruneFinishedPredecessors()
        #expect(successor.hasPredecessor == false)
    }

    @Test func pairThenWebSocketSubscribeReceivesSnapshot() async throws {
        // Provider with one session containing one agent message.
        let fixture = try GatewayHostFixture()
        let provider = fixture.provider
        let mgr = try fixture.core.sessionManager(for: fixture.worktree)
        let s = mgr.createSession(agentId: "claude")
        let transcriptText = String(repeating: "hello-remote: the agent is reading the workspace and reporting its changes.\n", count: 2_000)
        s.transcript.messages = [.agent(id: UUID(), StreamingText(transcriptText))]
        provider.summaries = [RemoteSessionSummary(id: s.id, title: "T", agentId: "claude", status: "idle", canDrive: false)]

        let assets = RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let server = RemoteServer(pairing: pairing, assets: assets, host: provider.host)
        server.present(provider)
        // The fake's reads, which tests hold back to pin ordering.
        server.configureGateway = { $0.hostCalls = provider.hostCalls }
        try server.start(port: 0)

        // Wait for port assignment.
        try await eventually("the server binds a port") { server.port != nil }
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

        // `hello` is always the first frame; the snapshot follows it.
        let first = try await receiveServerMessage(task)
        guard case .hello = first else {
            Issue.record("expected hello first, got \(first)")
            task.cancel(with: .goingAway, reason: nil)
            server.stop()
            return
        }
        let second = try await receiveServerMessage(task)
        guard case .transcriptSnapshot(_, _, _, let msgs, _, _, _, _, _) = second else {
            Issue.record("expected snapshot frame, got \(second)")
            task.cancel(with: .goingAway, reason: nil)
            server.stop()
            return
        }
        #expect(msgs.contains { $0.text == transcriptText })

        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    @Test func helloIsTheFirstFrameAfterUpgrade() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "phone")
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            host: nil,
            identity: { RemoteServerIdentity(serverId: "srv-1", name: "Test Mac") }
        )
        try server.start(port: 0)
        defer { server.stop() }
        try await eventually("the server binds a port") { server.port != nil }
        let port = try #require(server.port)

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!, protocols: [token])
        task.resume()
        let first = try await receiveServerMessage(task)
        #expect(first == .hello(protocolVersion: RemoteProtocolVersion.current, serverId: "srv-1", name: "Test Mac", federationEnabled: true, capabilities: PeerConsoleCapability.appHost + [PeerSessionTabsCapability.v1] + HostProtocolCapability.served))
        task.cancel(with: .goingAway, reason: nil)
    }

    @Test func helloCarriesFederationEnabled() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "phone")
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            host: nil,
            identity: { RemoteServerIdentity(serverId: "srv-1", name: "Test Mac") }
        )
        try server.start(port: 0)
        defer { server.stop() }
        try await eventually("the server binds a port") { server.port != nil }
        let port = try #require(server.port)
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!, protocols: [token])
        task.resume()
        let first = try await receiveServerMessage(task)
        #expect(first == .hello(protocolVersion: RemoteProtocolVersion.current, serverId: "srv-1", name: "Test Mac", federationEnabled: true, capabilities: PeerConsoleCapability.appHost + [PeerSessionTabsCapability.v1] + HostProtocolCapability.served))
        task.cancel(with: .goingAway, reason: nil)
    }

    // Regression: broadcastHello()'s target connection is
    // authenticated (added to connectionDevice) well before framesEnabled
    // is set — completeUpgrade() still has to build the gateway, encode
    // its own hello, and wait for that send to complete. A refresh
    // requested inside that window used to be silently dropped by
    // sendHello()'s framesEnabled guard and never redelivered until the
    // client reconnected. This is a source-level check (the race itself
    // isn't practical to force deterministically in an integration test)
    // verifying the pending-refresh state exists and is flushed once
    // frames actually enable.
    @Test func pendingHelloRefreshIsFlushedOnceFramesEnable() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/AlasCore/Sources/AlasHostCore/Remote/Server/RemoteConnection.swift"),
            encoding: .utf8
        )
        #expect(source.contains("private var pendingHelloRefresh = false"))
        #expect(source.contains("self.pendingHelloRefresh = true"))
        let flush = try #require(source.range(of: "private func enableFramesAndFlushPendingHello() {").map { source[$0.lowerBound...].prefix(300) })
        #expect(flush.contains("framesEnabled = true"))
        #expect(flush.contains("if pendingHelloRefresh {"))
        #expect(flush.contains("pendingHelloRefresh = false"))
        #expect(flush.contains("sendHello()"))
    }

    @Test func webSocketWithPublicOriginIsRejectedBeforeTokenValidation() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "phone")
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }

        let conn = loopbackConnection(port: port)
        let queue = DispatchQueue(label: "io.alas.tests.remote.ws-rejected-origin")
        try await start(conn, on: queue)
        defer { conn.cancel() }

        let request = [
            "GET /ws HTTP/1.1",
            "Host: 127.0.0.1",
            "Origin: https://evil.example",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: \(token)"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        try await send(request, on: conn)
        let response = try await receiveHTTPResponse(from: conn, on: queue)
        let text = try #require(String(data: response, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(pairing.devices.first?.lastSeenAt == nil)
        try await waitForConnectionClose(from: conn, on: queue)
    }

    // Regression: the origin-rejected 403 for
    // `POST /pair` carried no CORS header, so a browser surfaced an opaque
    // CORS network error instead of a readable 403 — hub-links.js's pair()
    // could never see `res.status === 403` and tell "not allowed" apart
    // from "unreachable." Echoing the origin back on the rejection grants
    // no access (the request is still refused); it only makes the refusal
    // legible to the calling JS.
    @Test func pairWithRejectedOriginReturns403WithCORSHeaderAndDoesNotRedeemCode() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let code = pairing.beginPairing()
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }

        let conn = loopbackConnection(port: port)
        let queue = DispatchQueue(label: "io.alas.tests.remote.pair-rejected-origin")
        try await start(conn, on: queue)
        defer { conn.cancel() }

        let body = #"{"code":"\#(code)","deviceName":"phone"}"#
        let request = [
            "POST /pair HTTP/1.1",
            "Host: 127.0.0.1",
            "Origin: https://evil.example",
            "Content-Length: \(body.utf8.count)",
            "",
            body
        ].joined(separator: "\r\n")
        try await send(request, on: conn)
        let response = try await receiveHTTPResponse(from: conn, on: queue)
        let text = try #require(String(data: response, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(text.contains("Access-Control-Allow-Origin: https://evil.example\r\n"))
        #expect(text.contains("Vary: Origin\r\n"))

        let token = try pairing.redeem(code: code, deviceName: "after-rejected-origin")
        #expect(pairing.validate(token: token) != nil, "the rejected attempt must not have consumed the single-use code")
    }

    @Test func webSocketWithPrivateOriginUpgrades() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "phone")
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }

        let conn = loopbackConnection(port: port)
        let queue = DispatchQueue(label: "io.alas.tests.remote.ws-private-origin")
        try await start(conn, on: queue)
        defer { conn.cancel() }

        let request = [
            "GET /ws HTTP/1.1",
            "Host: 127.0.0.1",
            "Origin: http://192.168.1.20:8765",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: \(token)"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        try await send(request, on: conn)
        let response = try await receiveHTTPResponse(from: conn, on: queue)
        let text = try #require(String(data: response, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 101 Switching Protocols"))
    }

    @Test func healthWithPrivateOriginCarriesCORSHeader() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }

        let conn = loopbackConnection(port: port)
        let queue = DispatchQueue(label: "io.alas.tests.remote.health-cors")
        try await start(conn, on: queue)
        defer { conn.cancel() }

        try await send("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://192.168.1.20:8765\r\n\r\n", on: conn)
        let response = try await receiveHTTPResponse(from: conn, on: queue)
        let text = try #require(String(data: response, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(text.contains("Access-Control-Allow-Origin: http://192.168.1.20:8765\r\n"))
    }

    @Test func stopBypassesBlockedOrderedQueue() async throws {
        let fixture = try GatewayHostFixture()
        let provider = fixture.provider
        let mgr = try fixture.core.sessionManager(for: fixture.worktree)
        let s = mgr.createSession(agentId: "claude")
        provider.pauseSessionSummaries = true            // blocks the ordered chain
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing, provider: provider)

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
        let received = collect(task)

        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.listSessions)))   // parks the chain
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.stop(sessionId: s.id))))
        // stop must land while listSessions is still parked on its continuation.
        try await eventually("the stop is answered") { received.stopped(s.id) }

        provider.resumeSessionSummaries()
        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    // Regression (codex review, PR #775): the fast-lane stop dispatch must
    // still wait for a preceding drive action (takeOver/sendPrompt) that's
    // already in flight — otherwise stop can overtake it, find no active
    // turn to cancel, and the queued action proceeds anyway right after the
    // user pressed Stop.
    @Test func stopWaitsForPrecedingDriveActionBeforeRunning() async throws {
        let fixture = try GatewayHostFixture()
        let provider = fixture.provider
        let mgr = try fixture.core.sessionManager(for: fixture.worktree)
        let s = mgr.createSession(agentId: "claude")
        if !mgr.isWriter(for: s.id) { #expect(await mgr.acquireWriterLease(sessionId: s.id)) }
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing, provider: provider)
        // A prompt's mentions resolve before it is sent: holding that back
        // keeps the drive action in flight inside the gateway.
        let drive = HeldDriveAction()
        server.configureGateway = { gateway in
            gateway.hostCalls = provider.hostCalls
            gateway.hostCalls.mentionAttachments = { _, _ in await drive.hold() }
        }

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
        let received = collect(task)

        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.sendPrompt(
            sessionId: s.id, text: "@notes", attachments: [], intent: "auto",
            mentions: [RemoteMention(kind: RemoteMention.file, value: "notes.md", name: "notes.md")]))))
        try await eventually("the drive action is held") { drive.isHeld }
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.stop(sessionId: s.id))))

        // Stop must NOT run while the preceding drive action is still suspended.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!received.stopped(s.id), "stop must wait for the preceding drive action to land first")

        drive.release()
        try await eventually("the stop is answered") { received.stopped(s.id) }

        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    // Regression (codex review, PR #775): stop must NOT wait for unrelated
    // queued read work (e.g. a scroll-triggered fetchOlder backfill) — only
    // for a preceding sendPrompt/takeOver. Otherwise the original blocking-
    // queue latency the fast lane exists to fix would reappear whenever a
    // client scrolls up and then presses Stop.
    @Test func stopBypassesBlockedNonDriveFetchOlder() async throws {
        let fixture = try GatewayHostFixture()
        let provider = fixture.provider
        let mgr = try fixture.core.sessionManager(for: fixture.worktree)
        let s = mgr.createSession(agentId: "claude")
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: String(repeating: "abcdef0123456789", count: 400), preview: "abcdef")
        toolCall.truncateForOffWindow()
        // 100 messages: the tail-window snapshot (last 90) excludes index 0,
        // so subscribing never fetches its content — fetchOlder below does
        // the first, pausable fetch.
        s.transcript.messages = [.toolCall(toolCall)] + (0..<99).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.fullToolCallContents["\(s.id)|old"] = "full content"
        provider.pauseFullToolCallContentOnCall = 1   // suspends inside the gateway's own await chain
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing, provider: provider)

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
        let received = collect(task)

        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.subscribe(sessionId: s.id))))
        // Older rows are served only to a subscriber that has its snapshot.
        try await eventually("the subscribe snapshot arrives") { received.snapshotCount == 1 }
        try await task.send(.data(JSONEncoder().encode(
            RemoteClientMessage.fetchOlder(sessionId: s.id, beforeIndex: 10, limit: 90))))
        try await eventually("the fetch reads full content") { provider.fullToolCallContentCallCount > 0 }
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.stop(sessionId: s.id))))

        // stop must land while fetchOlder is still parked on its continuation.
        try await eventually("the stop is answered") { received.stopped(s.id) }

        provider.resumeFullToolCallContent("full content")
        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    // Regression (codex review, PR #775): the preceding fix made stop await
    // the drive action's own task, but that task itself still chains behind
    // whatever ordered read work preceded IT — so a drive action queued
    // right behind a STUCK (not just slow) read still transitively blocks
    // stop, reintroducing the "stop takes forever" failure mode the fast
    // lane exists to prevent. Stop must give up waiting after a bounded
    // interval and act as an emergency brake regardless.
    @Test func stopIsBoundedWhenDriveActionIsQueuedBehindStuckReadWork() async throws {
        let fixture = try GatewayHostFixture()
        let provider = fixture.provider
        let mgr = try fixture.core.sessionManager(for: fixture.worktree)
        let s = mgr.createSession(agentId: "claude")
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: String(repeating: "abcdef0123456789", count: 400), preview: "abcdef")
        toolCall.truncateForOffWindow()
        s.transcript.messages = [.toolCall(toolCall)] + (0..<99).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.fullToolCallContents["\(s.id)|old"] = "full content"
        // Never resumed in this test — simulates a genuinely stuck read.
        provider.pauseFullToolCallContentOnCall = 1
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing, provider: provider)

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
        let received = collect(task)

        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.subscribe(sessionId: s.id))))
        // Older rows are served only to a subscriber that has its snapshot.
        try await eventually("the subscribe snapshot arrives") { received.snapshotCount == 1 }
        try await task.send(.data(JSONEncoder().encode(
            RemoteClientMessage.fetchOlder(sessionId: s.id, beforeIndex: 10, limit: 90))))
        try await eventually("the fetch reads full content") { provider.fullToolCallContentCallCount > 0 }
        // Queue a drive action right behind the stuck fetchOlder, then stop.
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.takeOver(sessionId: s.id))))
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.stop(sessionId: s.id))))

        // Stop must land within the bounded wait even though fetchOlder (and
        // thus the queued takeOver behind it) never completes. The deadline
        // is the emergency brake's promise, not just a timeout.
        try await eventually("the stop is answered", within: .seconds(3)) { received.stopped(s.id) }
        // The queued takeOver never got to run — proves stop didn't wait
        // for the full chain to actually resolve.
        // Only the subscribe snapshot: a takeover would have pushed another.
        #expect(received.snapshotCount == 1)

        provider.resumeFullToolCallContent("full content")   // avoid a leaked continuation
        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    // Regression (codex review, PR #775): the bounded stop wait let stop
    // proceed after a timeout, but the queued drive action itself was never
    // cancelled — it was still sitting in processingTail and would run once
    // its own predecessor eventually cleared, submitting the prompt/takeover
    // AFTER the user already pressed Stop and silently defeating the
    // emergency brake. A timed-out stop must cancel the queued drive action
    // so it never actually executes once unblocked.
    @Test func stopTimeoutCancelsQueuedDriveActionSoItNeverRuns() async throws {
        let fixture = try GatewayHostFixture()
        let provider = fixture.provider
        let mgr = try fixture.core.sessionManager(for: fixture.worktree)
        let s = mgr.createSession(agentId: "claude")
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: String(repeating: "abcdef0123456789", count: 400), preview: "abcdef")
        toolCall.truncateForOffWindow()
        s.transcript.messages = [.toolCall(toolCall)] + (0..<99).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.fullToolCallContents["\(s.id)|old"] = "full content"
        provider.pauseFullToolCallContentOnCall = 1
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing, provider: provider)

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
        let received = collect(task)

        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.subscribe(sessionId: s.id))))
        // Older rows are served only to a subscriber that has its snapshot.
        try await eventually("the subscribe snapshot arrives") { received.snapshotCount == 1 }
        try await task.send(.data(JSONEncoder().encode(
            RemoteClientMessage.fetchOlder(sessionId: s.id, beforeIndex: 10, limit: 90))))
        // The fetch must hold the drive queue before the takeover joins it.
        try await eventually("the fetch reads full content") { provider.fullToolCallContentCallCount > 0 }
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.takeOver(sessionId: s.id))))
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.stop(sessionId: s.id))))

        // Wait past stop's bounded wait so it takes the timeout path.
        try await eventually("the stop is answered") { received.stopped(s.id) }
        // Only the subscribe snapshot: a takeover would have pushed another.
        #expect(received.snapshotCount == 1)

        // Now unblock the stuck predecessor — the queued takeOver's own
        // `await previous?.value` can finally resolve. With the fix it must
        // still never call gateway.handle (it was cancelled), so
        // takeOverCallCount stays 0 even after everything settles.
        provider.resumeFullToolCallContent("full content")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(received.snapshotCount == 1, "a timed-out stop must cancel the queued drive action, not just outrace it")

        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    // Regression (issue #1417): `stop()` must close a live socket
    // synchronously, not merely queue the teardown. The table clear below
    // drops the last strong reference to each `RemoteConnection` in the same
    // turn; `cancel()`'s queued teardown used to lose that race, so the
    // socket died by ARC without ever sending a FIN — and a peer whose link
    // was open kept seeing this Mac as online indefinitely. This is the path
    // `syncRemoteServer()`'s disabled branch hits when Remote Control is
    // toggled off while the app keeps running.
    @Test func stopClosesALiveSocketSynchronouslySoThePeerSeesTheClose() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "phone")
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            host: nil,
            identity: { RemoteServerIdentity(serverId: "srv-a", name: "Mac A") }
        )
        try server.start(port: 0)
        try await eventually("the server binds a port") { server.port != nil }
        let port = try #require(server.port)

        let task = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/ws")!, protocols: [token])
        task.resume()
        // Drain the `hello` so the upgrade has fully completed and the
        // connection is live and authenticated when `stop()` runs.
        _ = try await receiveServerMessage(task)

        server.stop()

        // The next read must fail: `stop()` closed the socket out from under
        // this client. With the bug the socket stayed open indefinitely — no
        // FIN, no close frame — and a bare `receive()` would hang forever
        // (the exact failure mode the issue describes), so race the read
        // against a deadline: a frame or an error decides, and the deadline
        // — only reachable with the bug — records the failure.
        let closed: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask { () -> Bool in
                do {
                    _ = try await task.receive()
                    return false   // a frame arrived: the socket is still open
                } catch {
                    return true    // the read failed: the server closed the socket
                }
            }
            group.addTask { () -> Bool in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false       // deadline: the socket is still open
            }
            let verdict = await group.next() ?? false
            group.cancelAll()
            if !verdict {
                // Deadline won — unblock the stuck receive so the group can exit.
                task.cancel(with: .goingAway, reason: nil)
            }
            return verdict
        }
        #expect(closed, "expected the peer's WS to close after server.stop()")
        task.cancel(with: .goingAway, reason: nil)
    }

    // `authorize` can pass while the device is still valid, but registration
    // into `connectionDevice` lands via a LATER queue → MainActor hop. If
    // the user clicks Forget in that window, `disconnectDevice` cannot find
    // the socket yet and misses it. `authorize` touches the device right
    // after validating it, and that touch saves the store, so revoking from
    // the next save deterministically lands in that exact window regardless
    // of real scheduling timing.
    @Test func aDeviceRevokedJustAfterAuthorizeIsStillClosed() async throws {
        final class RevokeOnSaveStore: RemoteDeviceStore {
            var saved: [RemoteDevice] = []
            var onNextSave: (() -> Void)?
            func load() -> [RemoteDevice] { saved }
            func save(_ devices: [RemoteDevice]) {
                saved = devices
                let hook = onNextSave
                onNextSave = nil
                hook?()
            }
        }
        let store = RevokeOnSaveStore()
        let pairing = RemotePairingService(store: store)
        let peerResult = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac B", peerServerId: "srv-b")
        store.onNextSave = { pairing.revoke(deviceId: peerResult.deviceId) }
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            host: nil,
            identity: { RemoteServerIdentity(serverId: "srv-a", name: "Mac A") }
        )
        try server.start(port: 0)
        defer { server.stop() }
        try await eventually("the server binds a port") { server.port != nil }
        let port = try #require(server.port)

        let wsURL = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let peerTask = URLSession.shared.webSocketTask(with: wsURL, protocols: [peerResult.token])
        peerTask.resume()

        var usable = false
        do {
            _ = try await peerTask.receive()
            try await peerTask.send(.data(JSONEncoder().encode(RemoteClientMessage.listSessions)))
            _ = try await peerTask.receive()
            usable = true
        } catch {
            // Refused outright, or closed before/at the first real exchange
            // — both are the desired outcome.
        }
        #expect(!usable, "a device revoked just after authorize validated it must never end up with a usable connection")
    }

    @Test func revokingDeviceDropsLiveWebSocket() async throws {
        let fixture = try GatewayHostFixture()
        let provider = fixture.provider
        let mgr = try fixture.core.sessionManager(for: fixture.worktree)
        let s = mgr.createSession(agentId: "claude")
        s.transcript.messages = [.agent(id: UUID(), StreamingText("hello-remote"))]
        provider.summaries = [RemoteSessionSummary(id: s.id, title: "T", agentId: "claude", status: "idle", canDrive: false)]

        let assets = RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let server = RemoteServer(pairing: pairing, assets: assets, host: provider.host)
        server.present(provider)
        // The fake's reads, which tests hold back to pin ordering.
        server.configureGateway = { $0.hostCalls = provider.hostCalls }
        try server.start(port: 0)
        try await eventually("the server binds a port") { server.port != nil }
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

    @Test func connectedDeviceCountsReflectAuthenticatedWebSockets() async throws {
        let fixture = try GatewayHostFixture()
        let provider = fixture.provider
        let mgr = try fixture.core.sessionManager(for: fixture.worktree)
        let s = mgr.createSession(agentId: "claude")

        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            host: provider.host
        )
        server.present(provider)
        var publishedCounts: [[String: Int]] = []
        server.onConnectionDeviceCountsChange = { counts in
            publishedCounts.append(counts)
        }
        try server.start(port: 0)
        defer { server.stop() }

        try await eventually("the server binds a port") { server.port != nil }
        let port = try #require(server.port)

        let code = pairing.beginPairing()
        var pairReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        pairReq.httpMethod = "POST"
        pairReq.httpBody = Data(#"{"code":"\#(code)","deviceName":"phone"}"#.utf8)
        let (pairData, _) = try await URLSession.shared.data(for: pairReq)
        struct PairResp: Decodable { let token: String }
        let token = try JSONDecoder().decode(PairResp.self, from: pairData).token
        let deviceId = try #require(pairing.devices.first?.id)

        let wsURL = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let first = URLSession.shared.webSocketTask(with: wsURL, protocols: [token])
        let second = URLSession.shared.webSocketTask(with: wsURL, protocols: [token])
        first.resume()
        second.resume()
        try await first.send(.data(JSONEncoder().encode(RemoteClientMessage.subscribe(sessionId: s.id))))
        try await second.send(.data(JSONEncoder().encode(RemoteClientMessage.subscribe(sessionId: s.id))))
        _ = try await first.receive()
        _ = try await second.receive()

        #expect(server.connectedDeviceCounts()[deviceId] == 2)
        #expect(publishedCounts.contains { $0[deviceId] == 2 })

        server.disconnectDevice(deviceId)

        try await eventually("connected-device counts clear after disconnect") {
            server.connectedDeviceCounts()[deviceId, default: 0] == 0
        }
        #expect(publishedCounts.contains { $0.isEmpty }, "expected connected-device count callback to publish empty counts after disconnect")

        first.cancel(with: .goingAway, reason: nil)
        second.cancel(with: .goingAway, reason: nil)
    }

    @Test func updatePoliciesAppliesToOpenConnectionsAndNewRequests() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }

        let conn = loopbackConnection(port: port)
        let queue = DispatchQueue(label: "io.alas.tests.remote.policy-refresh")
        try await start(conn, on: queue)
        defer { conn.cancel() }

        try await send("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n", on: conn)
        // Accepted before the refresh, so the refresh reaches an open socket.
        try await eventually("the server accepts the socket") { server.unauthenticatedConnectionCount == 1 }

        server.updatePolicies(access: RemoteAccessPolicy(allowedHosts: ["evil.example"]), origin: .loopback)

        // The socket stays open, so a request already written is answered,
        // and under the new rules.
        try await send("\r\n", on: conn)
        let staleResponse = try await receiveHTTPResponse(from: conn, on: queue, timeout: 1)
        let text = try #require(String(data: staleResponse, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 403"), "\(text)")

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.setValue("evil.example", forHTTPHeaderField: "Host")
        let (_, resp) = try await URLSession.shared.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
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

    @Test func pairWithRejectedHostReturns403AndDoesNotRedeemCode() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let code = pairing.beginPairing()
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        req.httpMethod = "POST"
        req.setValue("evil.example", forHTTPHeaderField: "Host")
        req.httpBody = Data(#"{"code":"\#(code)","deviceName":"x"}"#.utf8)

        let (_, resp) = try await URLSession.shared.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 403)

        let token = try pairing.redeem(code: code, deviceName: "after-403")
        #expect(pairing.validate(token: token) != nil)
    }

    @Test func remoteDiagnosticsRoutesReturnSafeJSON() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        _ = try pairing.redeem(code: pairing.beginPairing(), deviceName: "iPhone")
        var diagnosticsPorts: [UInt16?] = []

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: root),
            host: nil,
            accessPolicy: RemoteAccessPolicy(allowedHosts: ["127.0.0.1"]),
            diagnostics: { providerPort in
                diagnosticsPorts.append(providerPort)
                return RemoteDiagnosticsSnapshot(
                    appName: "Alas",
                    port: providerPort,
                    addresses: [
                        RemoteAdvertisedAddress(
                            kind: .lan,
                            interfaceName: "en0",
                            host: "192.168.1.23",
                            port: providerPort ?? 0,
                            isRecommended: true
                        )
                    ],
                    usesPlainHTTP: true,
                    pairedDeviceCount: 1
                )
            }
        )
        try server.start(port: 0)
        defer { server.stop() }

        try await eventually("the server binds a port") { server.port != nil }
        let port = try #require(server.port)

        let (healthData, healthResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/health")!
        )
        #expect((healthResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: healthData, encoding: .utf8)?.contains(#""ok":true"#) == true)

        let (infoData, infoResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/remote-info")!
        )
        #expect((infoResponse as? HTTPURLResponse)?.statusCode == 200)
        let snapshot = try JSONDecoder().decode(RemoteDiagnosticsSnapshot.self, from: infoData)
        // /health now also reads diagnostics() for its serverId (PR #1337's
        // health-probe identity check), so this request above already added
        // one call before /remote-info's own.
        #expect(diagnosticsPorts == [port, port])
        #expect(snapshot.port == port)
        #expect(snapshot.appName == "Alas")
        #expect(snapshot.pairedDeviceCount == 1)
        #expect(snapshot.usesPlainHTTP)
        let address = try #require(snapshot.addresses.first)
        #expect(snapshot.addresses.count == 1)
        #expect(address.kind == .lan)
        #expect(address.interfaceName == "en0")
        #expect(address.host == "192.168.1.23")
        #expect(address.port == port)
        #expect(address.url == "http://192.168.1.23:\(port)")
        #expect(address.isRecommended)

        let text = try #require(String(data: infoData, encoding: .utf8))
        #expect(!text.contains("token"))
        #expect(!text.contains("code"))
        #expect(!text.contains("session"))
        #expect(!text.contains("/Users/"))
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

    @Test func webSocketWithRejectedHostIsRejectedBeforeTokenValidation() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "phone")
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }

        let conn = loopbackConnection(port: port)
        let queue = DispatchQueue(label: "io.alas.tests.remote.ws-rejected-host")
        try await start(conn, on: queue)
        defer { conn.cancel() }

        let request = [
            "GET /ws HTTP/1.1",
            "Host: evil.example",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: \(token)"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        try await send(request, on: conn)
        let response = try await receiveHTTPResponse(from: conn, on: queue)
        let text = try #require(String(data: response, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(pairing.devices.first?.lastSeenAt == nil)
        try await waitForConnectionClose(from: conn, on: queue)
    }

    @Test func webSocketUpgradeIsOnlyAcceptedOnWsPath() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "phone")
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }

        let conn = loopbackConnection(port: port)
        let queue = DispatchQueue(label: "io.alas.tests.remote.ws-route")
        try await start(conn, on: queue)
        defer { conn.cancel() }

        let request = [
            "GET /health HTTP/1.1",
            "Host: 127.0.0.1",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: \(token)"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        try await send(request, on: conn)
        let response = try await receiveHTTPResponse(from: conn, on: queue)
        let text = try #require(String(data: response, encoding: .utf8))

        #expect(text.hasPrefix("HTTP/1.1 404 Not Found"))
        #expect(pairing.devices.first?.lastSeenAt == nil)
        try await waitForConnectionClose(from: conn, on: queue)
    }

    @Test func remoteWebAssetsServePWAContentTypes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-web-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"name":"Alas Remote"}"#.utf8)
            .write(to: root.appendingPathComponent("manifest.webmanifest"))
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
            .write(to: root.appendingPathComponent("icon.svg"))
        try Data([0x89, 0x50, 0x4E, 0x47])
            .write(to: root.appendingPathComponent("icon.png"))

        let assets = RemoteWebAssets(root: root)

        #expect(assets.asset(forPath: "/manifest.webmanifest")?.contentType == "application/manifest+json; charset=utf-8")
        #expect(assets.asset(forPath: "/icon.svg")?.contentType == "image/svg+xml; charset=utf-8")
        #expect(assets.asset(forPath: "/icon.png")?.contentType == "image/png")
    }

    @Test func remoteServerServesManifestWithManifestContentType() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-web-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"name":"Alas Remote"}"#.utf8)
            .write(to: root.appendingPathComponent("manifest.webmanifest"))

        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let assets = RemoteWebAssets(root: root)
        let server = RemoteServer(pairing: pairing, assets: assets, host: nil)
        try server.start(port: 0)
        defer { server.stop() }

        try await eventually("the server binds a port") { server.port != nil }
        let port = try #require(server.port)

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/manifest.webmanifest")!
        )
        let http = try #require(resp as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/manifest+json; charset=utf-8")
        #expect(String(data: data, encoding: .utf8) == #"{"name":"Alas Remote"}"#)
    }

    @Test func serverForwardsPeerPairingToTheApp() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            host: nil,
            identity: { RemoteServerIdentity(serverId: "srv-a", name: "Mac A") }
        )
        final class Sink { var requests: [RemotePeerPairingRequest] = [] }
        let sink = Sink()
        server.onPeerPaired = { sink.requests.append($0) }
        try server.start(port: 0)
        defer { server.stop() }
        try await eventually("the server binds a port") { server.port != nil }
        let port = try #require(server.port)
        let code = pairing.beginPairing()
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"code":"\#(code)","deviceName":"Mac B","peer":{"serverId":"srv-b","name":"Mac B","origins":["http://127.0.0.1:1"],"counterCode":"X"}}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["serverId"] as? String == "srv-a")
        try await eventually("the peer pairing is forwarded") { !sink.requests.isEmpty }
        #expect(sink.requests.first?.peerServerId == "srv-b")
        #expect(sink.requests.first?.counterCode == "X")
    }

    // Regression: any authenticated browser or peer could send a `helloAck`
    // challenge up to the WebSocket message limit and have it forwarded
    // straight into CryptoKit signing on the main actor, up to
    // `maxIdentityProofs` times per connection — hashing and signing
    // attacker-controlled megabytes while freezing UI work. An oversized
    // challenge must be dropped before any signature is even attempted: no
    // `identityProof` reply for it, and the connection stays alive and
    // responsive to everything after it.
    @Test func anOversizedIdentityChallengeIsDroppedRatherThanSigned() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "phone")
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            host: nil,
            identity: { RemoteServerIdentity(serverId: "srv-a", name: "Mac A") },
            signer: RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore())
        )
        try server.start(port: 0)
        defer { server.stop() }
        try await eventually("the server binds a port") { server.port != nil }
        let port = try #require(server.port)
        let wsURL = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let task = URLSession.shared.webSocketTask(with: wsURL, protocols: [token])
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await receiveServerMessage(task)   // hello

        let oversized = String(repeating: "a", count: 5_000_000)
        let ack = RemoteClientMessage.helloAck(protocolVersion: RemoteProtocolVersion.current, challenge: oversized)
        try await task.send(.data(JSONEncoder().encode(ack)))
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.listSessions)))

        // The only reply that can ever arrive is the one `listSessions`
        // earns. A signed `identityProof` for the oversized challenge would
        // arrive first if the length were never checked.
        let reply = try await receiveServerMessage(task)
        guard case .sessionList = reply else {
            Issue.record("expected sessionList, got \(reply) — an oversized challenge must never be signed")
            return
        }
    }

    @Test func aConnectionOpenedAfterFederationIsSetSeesPeerRows() async throws {
        let provider = FakeRemoteApp()
        provider.summaries = [RemoteSessionSummary(id: "local", title: "L", agentId: "claude", status: "idle", canDrive: true)]
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing, provider: provider)
        defer { server.stop() }
        let links = FederatedSessionsProviderTests.FakeLinks()
        let federation = FederatedSessionsProvider(links: links)
        server.federation = federation
        links.goOnline("srv-b", name: "Mac B")
        links.receive(.sessionList(sessions: [
            RemoteSessionSummary(id: "s1", title: "B1", agentId: "claude", status: "idle", canDrive: false)
        ]), from: "srv-b")

        let code = pairing.beginPairing()
        var pairReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        pairReq.httpMethod = "POST"
        pairReq.httpBody = Data(#"{"code":"\#(code)","deviceName":"test"}"#.utf8)
        let (pairData, _) = try await URLSession.shared.data(for: pairReq)
        struct PairResp: Decodable { let token: String }
        let token = try JSONDecoder().decode(PairResp.self, from: pairData).token
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!, protocols: [token])
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.listSessions)))
        _ = try await receiveServerMessage(task)   // hello
        var list: [RemoteSessionSummary]?
        for _ in 0..<5 where list == nil {
            if case .sessionList(let rows) = try await receiveServerMessage(task) { list = rows }
        }
        #expect(list?.map(\.id) == ["local", "srv-b:s1"])
    }

    private func loopbackConnection(port: UInt16) -> NWConnection {
        let parameters = NWParameters.tcp
        // Use an OS-assigned source port on the loopback interface.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }

    private func start(_ conn: NWConnection, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = Completion<Void>()
            let portRetries = Mutex(3)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(.success(()), continuation: continuation)
                case .waiting(.posix(.EADDRINUSE)):
                    // CI can reuse a recently closed loopback tuple. Waiting
                    // for a path change never retries that local port collision.
                    let retry = portRetries.withLock { remaining in
                        guard remaining > 0 else { return false }
                        remaining -= 1
                        return true
                    }
                    if retry { conn.restart() }
                    else { completion.finish(.failure(NWError.posix(.EADDRINUSE)), continuation: continuation) }
                case .waiting(let error), .failed(let error):
                    completion.finish(.failure(error), continuation: continuation)
                case .cancelled:
                    completion.finish(.failure(TimeoutError.timedOut), continuation: continuation)
                default:
                    break
                }
            }
            // 2s wasn't always enough for real loopback connection setup on a
            // loaded CI runner — this file's tests have been observed timing
            // out here under the same cooperative-pool contention that hits
            // NextPromptSettingsTests' in-process waits.
            queue.asyncAfter(deadline: .now() + 10) {
                completion.finish(.failure(TimeoutError.timedOut), continuation: continuation)
            }
            conn.start(queue: queue)
        }
    }

    private func send(_ request: String, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(request.utf8), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveHTTPResponse(from conn: NWConnection,
                                     on queue: DispatchQueue,
                                     timeout: TimeInterval = 10) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let completion = Completion<Data>()
            let accumulator = DataAccumulator()

            Self.pumpUntilHeaderTerminator(
                conn: conn,
                completion: completion,
                accumulator: accumulator,
                continuation: continuation
            )
            queue.asyncAfter(deadline: .now() + timeout) {
                completion.finish(.failure(TimeoutError.timedOut), continuation: continuation)
            }
        }
    }

    /// Recursive read pump for `receiveHTTPResponse`. A `nonisolated static`
    /// method rather than a local function so the `@Sendable` receive handler
    /// captures only the explicit, lock-backed parameters — a local function
    /// running concurrently would capture the enclosing scope implicitly.
    private nonisolated static func pumpUntilHeaderTerminator(
        conn: NWConnection,
        completion: Completion<Data>,
        accumulator: DataAccumulator,
        continuation: CheckedContinuation<Data, Error>
    ) {
        let headerTerminator = Data("\r\n\r\n".utf8)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            if let error {
                completion.finish(.failure(error), continuation: continuation)
                return
            }
            if let data, !data.isEmpty {
                let snapshot = accumulator.append(data)
                if let terminatorRange = snapshot.range(of: headerTerminator) {
                    // Trim to the header block only. A fast local write can
                    // coalesce the response headers with whatever the server
                    // sends immediately after (e.g. a WebSocket upgrade's
                    // very next binary frame) into this same read; including
                    // those trailing bytes made `String(data:encoding:.utf8)`
                    // return nil on an otherwise-successful response.
                    completion.finish(.success(snapshot.subdata(in: snapshot.startIndex..<terminatorRange.upperBound)), continuation: continuation)
                    return
                }
            }
            if isComplete {
                completion.finish(.failure(TimeoutError.timedOut), continuation: continuation)
            } else if !completion.isFinished {
                Self.pumpUntilHeaderTerminator(
                    conn: conn,
                    completion: completion,
                    accumulator: accumulator,
                    continuation: continuation
                )
            }
        }
    }

    private func waitForConnectionClose(from conn: NWConnection,
                                        on queue: DispatchQueue,
                                        timeout: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = Completion<Void>()

            Self.pumpUntilClosed(conn: conn, completion: completion, continuation: continuation)
            queue.asyncAfter(deadline: .now() + timeout) {
                completion.finish(.failure(TimeoutError.timedOut), continuation: continuation)
            }
        }
    }

    /// Recursive drain for `waitForConnectionClose`, hoisted out of a local
    /// function for the same reason as `pumpUntilHeaderTerminator` above.
    private nonisolated static func pumpUntilClosed(
        conn: NWConnection,
        completion: Completion<Void>,
        continuation: CheckedContinuation<Void, Error>
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, isComplete, error in
            if error != nil || isComplete {
                completion.finish(.success(()), continuation: continuation)
            } else if !completion.isFinished {
                Self.pumpUntilClosed(conn: conn, completion: completion, continuation: continuation)
            }
        }
    }

    private final class Completion<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var didComplete = false

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didComplete
        }

        func finish(_ result: Result<Value, Error>,
                    continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            guard !didComplete else {
                lock.unlock()
                return
            }
            didComplete = true
            lock.unlock()

            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }

    private final class DataAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) -> Data {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
            return data
        }
    }
}

private actor CancellableTaskGate {
    private static let timeoutNanoseconds: UInt64 = 1_000_000_000
    private var entered = false
    private var released = false
    private var cancelled = false
    private var completedWithCancellation = false
    private var handlerRan = false
    private var entryContinuation: CheckedContinuation<Bool, Never>?
    private var cancellationContinuation: CheckedContinuation<Bool, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        entered = true
        finishEntry(true)
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitForEntry() async -> Bool {
        guard !entered else { return true }
        return await withCheckedContinuation { continuation in
            entryContinuation = continuation
            scheduleEntryTimeout()
        }
    }

    func recordCancellation() {
        cancelled = true
        finishCancellation(true)
    }

    func waitForCancellation() async -> Bool {
        guard !cancelled else { return true }
        return await withCheckedContinuation { continuation in
            cancellationContinuation = continuation
            scheduleCancellationTimeout()
        }
    }

    func recordCompletion(wasCancelled: Bool) {
        completedWithCancellation = wasCancelled
    }

    func completedWhileCancelled() -> Bool {
        completedWithCancellation
    }

    func recordHandlerRun() {
        handlerRan = true
    }

    func handlerDidRun() -> Bool {
        handlerRan
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func scheduleEntryTimeout() {
        Task {
            try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
            finishEntry(false)
        }
    }

    private func scheduleCancellationTimeout() {
        Task {
            try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
            finishCancellation(false)
        }
    }

    private func finishEntry(_ value: Bool) {
        entryContinuation?.resume(returning: value)
        entryContinuation = nil
    }

    private func finishCancellation(_ value: Bool) {
        cancellationContinuation?.resume(returning: value)
        cancellationContinuation = nil
    }
}

@MainActor
private final class ReceivedMessages {
    var all: [RemoteServerMessage] = []

    func stopped(_ id: String) -> Bool { all.contains(.stopPending(sessionId: id)) }

    var snapshotCount: Int { all.filter { if case .transcriptSnapshot = $0 { true } else { false } }.count }
}

/// A drive action a test holds in flight until it lets it go.
@MainActor
private final class HeldDriveAction {
    private(set) var isHeld = false
    private var waiter: CheckedContinuation<Void, Never>?

    func hold() async -> [ACPMessage.Attachment]? {
        isHeld = true
        await withCheckedContinuation { waiter = $0 }
        return []
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}
