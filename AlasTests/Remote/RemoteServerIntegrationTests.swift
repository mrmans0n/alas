import Testing
import Foundation
import Network
@testable import Alas

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
                             provider: RemoteSessionsProvider = FakeSessionsProvider()) async throws -> (RemoteServer, UInt16) {
        let assets = RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let server = RemoteServer(pairing: pairing, assets: assets, provider: provider)
        try server.start(port: 0)
        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return (server, try #require(server.port))
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
        let provider = FakeSessionsProvider()
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        s.transcript.messages = [.agent(id: UUID(), StreamingText("hello-remote"))]
        provider.sessions[s.id] = s
        provider.summaries = [RemoteSessionSummary(id: s.id, title: "T", agentId: "claude", status: "idle", canDrive: false)]

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
              case .transcriptSnapshot(_, _, _, let msgs, _, _, _, _)? = try? JSONDecoder().decode(RemoteServerMessage.self, from: data) else {
            Issue.record("expected snapshot frame, got \(received)")
            task.cancel(with: .goingAway, reason: nil)
            server.stop()
            return
        }
        #expect(msgs.contains { $0.text == "hello-remote" })

        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    @Test func stopBypassesBlockedOrderedQueue() async throws {
        let provider = FakeSessionsProvider()
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        provider.sessions[s.id] = s
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

        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.listSessions)))   // parks the chain
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.stop(sessionId: s.id))))
        // stop must land while listSessions is still parked on its continuation.
        for _ in 0..<100 where provider.stopped.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.stopped == [s.id])

        provider.resumeSessionSummaries()
        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    // Regression (codex review, PR #775): the fast-lane stop dispatch must
    // still wait for a preceding drive action (takeOver/sendPrompt) that's
    // already in flight — otherwise stop can overtake it, find no active
    // turn to cancel, and the queued action proceeds anyway right after the
    // user pressed Stop.
    @Test func stopWaitsForPrecedingTakeOverBeforeRunning() async throws {
        let provider = FakeSessionsProvider()
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        provider.sessions[s.id] = s
        provider.pauseTakeOver = true   // suspends inside the gateway's own await chain
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

        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.takeOver(sessionId: s.id))))
        for _ in 0..<100 where provider.takeOverCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.stop(sessionId: s.id))))

        // Stop must NOT run while the preceding takeOver is still suspended.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(provider.stopped.isEmpty, "stop must wait for the preceding takeOver to land first")

        provider.resumeTakeOver()
        for _ in 0..<100 where provider.stopped.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.stopped == [s.id])

        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    // Regression (codex review, PR #775): stop must NOT wait for unrelated
    // queued read work (e.g. a scroll-triggered fetchOlder backfill) — only
    // for a preceding sendPrompt/takeOver. Otherwise the original blocking-
    // queue latency the fast lane exists to fix would reappear whenever a
    // client scrolls up and then presses Stop.
    @Test func stopBypassesBlockedNonDriveFetchOlder() async throws {
        let provider = FakeSessionsProvider()
        let mgr = try makeManager()
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
        provider.sessions[s.id] = s
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

        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.subscribe(sessionId: s.id))))
        try await task.send(.data(JSONEncoder().encode(
            RemoteClientMessage.fetchOlder(sessionId: s.id, beforeIndex: 10, limit: 90))))
        for _ in 0..<100 where provider.fullToolCallContentCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.stop(sessionId: s.id))))

        // stop must land while fetchOlder is still parked on its continuation.
        for _ in 0..<100 where provider.stopped.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.stopped == [s.id])

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
        let provider = FakeSessionsProvider()
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: String(repeating: "abcdef0123456789", count: 400), preview: "abcdef")
        toolCall.truncateForOffWindow()
        s.transcript.messages = [.toolCall(toolCall)] + (0..<99).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.sessions[s.id] = s
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

        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.subscribe(sessionId: s.id))))
        try await task.send(.data(JSONEncoder().encode(
            RemoteClientMessage.fetchOlder(sessionId: s.id, beforeIndex: 10, limit: 90))))
        for _ in 0..<100 where provider.fullToolCallContentCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Queue a drive action right behind the stuck fetchOlder, then stop.
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.takeOver(sessionId: s.id))))
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.stop(sessionId: s.id))))

        // Stop must land within the bounded wait even though fetchOlder (and
        // thus the queued takeOver behind it) never completes.
        for _ in 0..<150 where provider.stopped.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.stopped == [s.id])
        // The queued takeOver never got to run — proves stop didn't wait
        // for the full chain to actually resolve.
        #expect(provider.takeOverCallCount == 0)

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
        let provider = FakeSessionsProvider()
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: String(repeating: "abcdef0123456789", count: 400), preview: "abcdef")
        toolCall.truncateForOffWindow()
        s.transcript.messages = [.toolCall(toolCall)] + (0..<99).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.sessions[s.id] = s
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

        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.subscribe(sessionId: s.id))))
        try await task.send(.data(JSONEncoder().encode(
            RemoteClientMessage.fetchOlder(sessionId: s.id, beforeIndex: 10, limit: 90))))
        for _ in 0..<100 where provider.fullToolCallContentCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.takeOver(sessionId: s.id))))
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.stop(sessionId: s.id))))

        // Wait past stop's bounded wait so it takes the timeout path.
        for _ in 0..<150 where provider.stopped.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.stopped == [s.id])
        #expect(provider.takeOverCallCount == 0)

        // Now unblock the stuck predecessor — the queued takeOver's own
        // `await previous?.value` can finally resolve. With the fix it must
        // still never call gateway.handle (it was cancelled), so
        // takeOverCallCount stays 0 even after everything settles.
        provider.resumeFullToolCallContent("full content")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(provider.takeOverCallCount == 0, "a timed-out stop must cancel the queued drive action, not just outrace it")

        task.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    @Test func revokingDeviceDropsLiveWebSocket() async throws {
        let provider = FakeSessionsProvider()
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        s.transcript.messages = [.agent(id: UUID(), StreamingText("hello-remote"))]
        provider.sessions[s.id] = s
        provider.summaries = [RemoteSessionSummary(id: s.id, title: "T", agentId: "claude", status: "idle", canDrive: false)]

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

    @Test func connectedDeviceCountsReflectAuthenticatedWebSockets() async throws {
        let provider = FakeSessionsProvider()
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        provider.sessions[s.id] = s

        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            provider: provider
        )
        var publishedCounts: [[String: Int]] = []
        server.onConnectionDeviceCountsChange = { counts in
            publishedCounts.append(counts)
        }
        try server.start(port: 0)
        defer { server.stop() }

        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
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

        var cleanedUp = false
        for _ in 0..<50 {
            if server.connectedDeviceCounts()[deviceId, default: 0] == 0 {
                cleanedUp = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(cleanedUp, "expected connected-device counts to clear after disconnect")
        #expect(publishedCounts.contains { $0.isEmpty }, "expected connected-device count callback to publish empty counts after disconnect")

        first.cancel(with: .goingAway, reason: nil)
        second.cancel(with: .goingAway, reason: nil)
    }

    @Test func updateAccessPolicyClosesIdleConnectionsAndAppliesToNewRequests() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing)
        defer { server.stop() }

        let conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let queue = DispatchQueue(label: "io.alas.tests.remote.policy-refresh")
        try await start(conn, on: queue)
        defer { conn.cancel() }

        try await send("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n", on: conn)
        try await Task.sleep(nanoseconds: 20_000_000)

        server.updateAccessPolicy(RemoteAccessPolicy(allowedHosts: ["evil.example"]))

        try await send("\r\n", on: conn)
        do {
            let staleResponse = try await receiveHTTPResponse(from: conn, on: queue, timeout: 1)
            let text = try #require(String(data: staleResponse, encoding: .utf8))
            #expect(!text.hasPrefix("HTTP/1.1 200 OK"))
        } catch {
            // Expected if the server closed the pre-refresh idle connection.
        }

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
            provider: FakeSessionsProvider(),
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

        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
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
        #expect(diagnosticsPorts == [port])
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

        let conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
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

        let conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
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
        let server = RemoteServer(pairing: pairing, assets: assets, provider: FakeSessionsProvider())
        try server.start(port: 0)
        defer { server.stop() }

        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = try #require(server.port)

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/manifest.webmanifest")!
        )
        let http = try #require(resp as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/manifest+json; charset=utf-8")
        #expect(String(data: data, encoding: .utf8) == #"{"name":"Alas Remote"}"#)
    }

    private func start(_ conn: NWConnection, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = Completion<Void>()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(.success(()), continuation: continuation)
                case .failed(let error):
                    completion.finish(.failure(error), continuation: continuation)
                case .cancelled:
                    completion.finish(.failure(TimeoutError.timedOut), continuation: continuation)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + 2) {
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
                                     timeout: TimeInterval = 2) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let completion = Completion<Data>()
            let accumulator = DataAccumulator()
            let headerTerminator = Data("\r\n\r\n".utf8)

            func receiveMore() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let error {
                        completion.finish(.failure(error), continuation: continuation)
                        return
                    }
                    if let data, !data.isEmpty {
                        let snapshot = accumulator.append(data)
                        if snapshot.range(of: headerTerminator) != nil {
                            completion.finish(.success(snapshot), continuation: continuation)
                            return
                        }
                    }
                    if isComplete {
                        completion.finish(.failure(TimeoutError.timedOut), continuation: continuation)
                    } else if !completion.isFinished {
                        receiveMore()
                    }
                }
            }

            receiveMore()
            queue.asyncAfter(deadline: .now() + timeout) {
                completion.finish(.failure(TimeoutError.timedOut), continuation: continuation)
            }
        }
    }

    private func waitForConnectionClose(from conn: NWConnection,
                                        on queue: DispatchQueue,
                                        timeout: TimeInterval = 2) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = Completion<Void>()

            func receiveUntilClosed() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, isComplete, error in
                    if error != nil || isComplete {
                        completion.finish(.success(()), continuation: continuation)
                    } else if !completion.isFinished {
                        receiveUntilClosed()
                    }
                }
            }

            receiveUntilClosed()
            queue.asyncAfter(deadline: .now() + timeout) {
                completion.finish(.failure(TimeoutError.timedOut), continuation: continuation)
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
