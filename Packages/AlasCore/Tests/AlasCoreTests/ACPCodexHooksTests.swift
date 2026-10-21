import Foundation
import Testing
import AlasCore

struct ACPCodexHooksTests {
    @Test(arguments: ["session/new", "session/load", "session/resume", "session/fork", "session/prompt", "_session/steering", "_session/goal"])
    @MainActor func executionWaitsForReviewAndRebuildsStaleToken(method: String) async throws {
        let mock = ACPMockClient()
        mock.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"agentInfo":{"name":"@alas-ide/codex-acp","version":"2.2.2-alas.4"},"_meta":{"codexHooks":{"version":1,"reviewToken":true}}}"#.utf8) }
        let connection = ACPConnection(client: mock)
        connection.codexHooksReviewEnabled = true
        try await connection.initialize()
        var reviews = 0
        connection.reviewCodexHooks = {
            reviews += 1
            connection.codexHooksReviewToken = "review-\(reviews)"
        }
        mock.script(method: method) { request in
            let params = try #require(request.params)
            let value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])
            let meta = try #require(value["_meta"] as? [String: Any])
            let token = try #require((meta["codexHooks"] as? [String: String])?["reviewToken"])
            if token == "review-1" {
                throw ACPClientError.jsonrpc(JSONRPCError(code: -32044, message: "Changed", data: AnyCodable(["kind": "codex_hook_changed"])))
            }
            #expect(token == "review-2")
            return Data(#"{"sessionId":"s","outcome":"injected"}"#.utf8)
        }
        switch method {
        case "session/new": _ = try await connection.newSession(cwd: "/p", mcpServers: [])
        case "session/load": _ = try await connection.loadSession(cwd: "/p", sessionId: "s", mcpServers: [])
        case "session/resume": _ = try await connection.resumeSession(cwd: "/p", sessionId: "s", mcpServers: [])
        case "session/fork": _ = try await connection.forkSession(cwd: "/p", sessionId: "s", mcpServers: [])
        case "session/prompt": _ = try await connection.prompt(sessionId: "s", blocks: [])
        case "_session/steering": _ = try await connection.steer(sessionId: "s", blocks: [])
        default: try await connection.controlGoal(sessionId: "s", capability: .init(version: 1, controlMethod: method, actions: [.resume]), action: .resume)
        }
        #expect(reviews == 2)
        #expect(mock.sent.filter { $0.method == method }.count == 2)
    }

    @Test(arguments: [false, true])
    @MainActor func attachmentReviewSurvivesStartupAndPreservesQueuedDraft(cancel: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hook-manager-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let mock = ACPMockClient()
        mock.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"agentInfo":{"name":"@alas-ide/codex-acp","version":"2.2.2-alas.4"},"_meta":{"codexHooks":{"version":1,"reviewToken":true}}}"#.utf8) }
        mock.script(method: "_codex/hooks/list") { _ in
            Data(#"{"cwd":"/p","hooks":[],"warnings":["Review startup configuration"],"errors":[],"reviewToken":"token","codexHome":"/actual/codex"}"#.utf8)
        }
        mock.script(method: "session/new") { _ in Data(#"{"sessionId":"remote"}"#.utf8) }
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        let connection = ACPConnection(client: mock)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/p", persistence: ACPSessionPersistence(path: path.path), setupEvaluator: { _ in .ready }, connectionFactory: { _, _, _ in connection })
        defer { manager.shutdownBackgroundTasks() }
        let session = manager.createSession(agentId: "codex", autoRunDefault: false)
        session.enqueue(blocks: [.text("saved draft")])
        let queued = session.queue
        let attach = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await eventually { await session.codexHooksReview?.presentation?.isBusy == false }
        let review = try #require(session.codexHooksReview)
        let id = try #require(review.presentation?.id)
        #expect(mock.sent.allSatisfy { $0.method != "session/new" })
        #expect(session.queue == queued)
        if cancel {
            review.cancel(presentationID: id)
            await attach.value
            #expect(mock.sent.allSatisfy { $0.method != "session/new" })
            #expect(session.queue == queued)
        } else {
            review.continueWithoutTrusting(presentationID: id)
            await attach.value
            #expect(mock.sent.filter { $0.method == "session/new" }.count == 1)
            try await eventually { await session.queue.isEmpty }
            #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
            await connection.invalidateCodexHooksReview()
            let prompt = Task { try await connection.prompt(sessionId: "remote", blocks: []) }
            let concurrent = Task { try await connection.prompt(sessionId: "remote", blocks: []) }
            try await eventually { await session.codexHooksReview?.presentation?.isBusy == false }
            #expect(mock.sent.filter { $0.method == "_codex/hooks/list" }.count == 2)
            #expect(review.continueWithoutTrusting(presentationID: id) == nil)
            let interrupted = try #require(session.codexHooksReview)
            await connection.invalidateCodexHooksReview()
            try await eventually { await MainActor.run { session.codexHooksReview !== interrupted && session.codexHooksReview?.presentation?.isBusy == false } }
            #expect(mock.sent.filter { $0.method == "_codex/hooks/list" }.count == 3)
            #expect(interrupted.continueWithoutTrusting() == nil)
            let active = try #require(session.codexHooksReview)
            active.continueWithoutTrusting(presentationID: active.presentation?.id)
            _ = try await prompt.value
            _ = try await concurrent.value
            let delivered = mock.sent.filter { $0.method == "session/prompt" }.count
            #expect(delivered == 3)
            #expect(session.queue.isEmpty)
        }
        await manager.detach(sessionId: session.id)
    }

    @Test(arguments: [-32603, 1001, -32044])
    @MainActor func ordinaryExecutionErrorsDoNotTriggerReviewReplay(code: Int) async throws {
        let mock = ACPMockClient()
        mock.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"agentInfo":{"name":"@alas-ide/codex-acp","version":"2.2.2-alas.4"},"_meta":{"codexHooks":{"version":1,"reviewToken":true}}}"#.utf8) }
        let connection = ACPConnection(client: mock)
        connection.codexHooksReviewEnabled = true
        try await connection.initialize()
        connection.reviewCodexHooks = { connection.codexHooksReviewToken = "reviewed" }
        mock.script(method: "session/prompt") { _ in
            throw ACPClientError.jsonrpc(JSONRPCError(code: code, message: "Post-dispatch failure", data: AnyCodable(["kind": "unknown", "restartable": true])))
        }
        await #expect(throws: ACPClientError.self) { try await connection.prompt(sessionId: "s", blocks: []) }
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
    }

    @Test @MainActor func cancelledReviewWaiterCannotDispatchAfterSharedContinuation() async throws {
        let mock = ACPMockClient()
        mock.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"agentInfo":{"name":"@alas-ide/codex-acp","version":"2.2.2-alas.4"},"_meta":{"codexHooks":{"version":1,"reviewToken":true}}}"#.utf8) }
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        let connection = ACPConnection(client: mock)
        connection.codexHooksReviewEnabled = true
        try await connection.initialize()
        let gate = ExecutionReviewGate()
        connection.reviewCodexHooks = { connection.codexHooksReviewToken = await gate.review() }
        let prompt = Task { try await connection.prompt(sessionId: "s", blocks: []) }
        var iterator = gate.entered.stream.makeAsyncIterator()
        await iterator.next()
        prompt.cancel()
        gate.release?.resume(returning: "reviewed")
        await #expect(throws: CancellationError.self) { try await prompt.value }
        #expect(mock.sent.allSatisfy { $0.method != "session/prompt" })
    }

    @MainActor private final class ExecutionReviewGate {
        let entered = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<String, Never>?
        func review() async -> String {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.continuation.yield(())
            }
        }
    }

    @Test @MainActor func oldBrokerMismatchBlocksLifecycleFallback() async throws {
        let mock = ACPMockClient()
        mock.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"agentInfo":{"name":"@alas-ide/codex-acp","version":"2.2.2-alas.4"},"_meta":{"codexHooks":{"version":1,"reviewToken":true}}}"#.utf8) }
        mock.script(method: "session/fork") { _ in
            throw RemoteHelperClientError.jsonrpc(.init(code: -32076, message: "broker state error: OperationKeyPayloadMismatch", data: nil))
        }
        mock.script(method: "session/new") { _ in Data(#"{"sessionId":"unsafe-fallback"}"#.utf8) }
        let connection = ACPConnection(client: mock)
        connection.codexHooksReviewEnabled = true
        try await connection.initialize()
        connection.reviewCodexHooks = { connection.codexHooksReviewToken = "fresh" }
        await #expect(throws: ACPCodexHooksBrokerMismatchError.self) {
            try await connection.forkSession(cwd: "/p", sessionId: "source", mcpServers: [], brokerOperationKey: "stable")
        }
        await #expect(throws: ACPCodexHooksBrokerMismatchError.self) { try await connection.newSession(cwd: "/p", mcpServers: []) }
        #expect(mock.sent.filter { $0.method == "session/fork" }.count == 1)
        #expect(mock.sent.allSatisfy { $0.method != "session/new" })
    }

    @Test(arguments: ["2.2.2-alas.4", "2.2.2-alas.14", "2.3.0-alas.1"])
    func verifiedRelease(version: String) {
        #expect(ACPCodexHooksCapability.supports(agentInfo: .init(name: "@alas-ide/codex-acp", version: version)))
    }

    @Test(arguments: ["2.2.2-alas.3", "2.2.2", "2.2.2-alas.4-extra", "2.2.2-alas.x"])
    func unsupportedRelease(version: String) {
        let supported = ACPCodexHooksCapability.supports(agentInfo: .init(name: "@alas-ide/codex-acp", version: version))
        #expect(supported == false)
    }

    @Test func malformedListCannotCertifyReview() throws {
        for json in ["{}", #"{"cwd":"/p","hooks":[],"warnings":[],"errors":[],"reviewToken":""}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ACPCodexHooksList.self, from: Data(json.utf8)) }
        }
    }

    @Test(arguments: [-32044, -32603, 1001])
    func onlyReservedErrorAllowsReplay(code: Int) {
        let error = JSONRPCError(code: code, message: "retained", data: AnyCodable(["kind": "codex_hook_changed", "restartable": true]))
        #expect((ACPCodexHookReviewError.classify(error) != nil) == (code == -32044))
    }

    @Test(arguments: ["unverified", "false", "throw"])
    @MainActor func selectedPairsRequireTrustedReadback(result: String) async throws {
        let initial = try snapshot()
        var received: [ACPCodexHookIdentity] = []
        let coordinator = ACPCodexHooksReviewCoordinator(context: .init(host: "SSH host", cwd: "/p"), list: { initial }, trust: { _, pairs in
            received = pairs
            if result == "throw" { throw JSONRPCError(code: -32603, message: "trust write failed", data: nil) }
            return result != "false"
        })
        await coordinator.refresh()
        #expect(coordinator.selection.isEmpty)
        coordinator.setSelected(initial.hooks[0].identity, selected: true)
        await coordinator.trustSelectedAndContinue()
        #expect(received == [initial.hooks[0].identity])
        #expect(coordinator.presentation?.error != nil)
        if result == "throw" { #expect(coordinator.presentation?.error?.contains("trust write failed") == true) }
        #expect(coordinator.reviewToken == "token")
    }

    @Test @MainActor func diagnosticsAllowContinueButUnknownDefinitionsRemainVisible() async throws {
        let initial = try snapshot(handler: "future")
        let coordinator = ACPCodexHooksReviewCoordinator(context: .init(host: "local", cwd: "/p"), list: { initial }, trust: { _, _ in false })
        await coordinator.refresh()
        #expect(coordinator.presentation != nil)
        coordinator.setSelected(initial.hooks[0].identity, selected: true)
        #expect(coordinator.selection.isEmpty)
        #expect(coordinator.continueWithoutTrusting() == "token")
        coordinator.invalidate()
        #expect(coordinator.presentation == nil)
        #expect(coordinator.reviewToken == nil)
        #expect(coordinator.continueWithoutTrusting() == nil)
    }

    @Test @MainActor func changedRefreshClearsSelectionsAndRejectsOldButtons() async throws {
        var current = try snapshot()
        let coordinator = ACPCodexHooksReviewCoordinator(context: .init(host: "local", cwd: "/p"), list: { current }, trust: { _, _ in true })
        await coordinator.refresh()
        let old = try #require(coordinator.presentation?.id)
        coordinator.setSelected(current.hooks[0].identity, selected: true)
        current = try snapshot(hash: "changed")
        await coordinator.refresh()
        #expect(coordinator.selection.isEmpty)
        #expect(coordinator.continueWithoutTrusting(presentationID: old) == nil)
        #expect(coordinator.presentation != nil)
    }

    @Test @MainActor func duplicateIdentitiesCannotBeSelected() async throws {
        let initial = try snapshot(duplicate: true)
        let coordinator = ACPCodexHooksReviewCoordinator(context: .init(host: "local", cwd: "/p"), list: { initial }, trust: { _, _ in true })
        await coordinator.refresh()
        coordinator.setSelected(initial.hooks[0].identity, selected: true)
        #expect(coordinator.selection.isEmpty)
    }

    @Test @MainActor func confirmedReadbackContinuesWithStableToken() async throws {
        var current = try snapshot()
        let coordinator = ACPCodexHooksReviewCoordinator(context: .init(host: "local", cwd: "/p"), list: { current }, trust: { _, pairs in
            #expect(pairs == [current.hooks[0].identity])
            current = try snapshot(status: "trusted")
            return true
        })
        await coordinator.refresh()
        coordinator.setSelected(current.hooks[0].identity, selected: true)
        await coordinator.trustSelectedAndContinue()
        #expect(coordinator.presentation == nil)
        #expect(coordinator.reviewToken == "token")
    }

    @Test(arguments: ["unknown hook", "diagnostic"])
    @MainActor func changedTrustReadbackWaitsForExplicitContinuation(change: String) async throws {
        var current = try snapshot(diagnostics: false)
        let coordinator = ACPCodexHooksReviewCoordinator(context: .init(host: "local", cwd: "/p"), list: { current }, trust: { _, _ in
            current = try snapshot(status: "trusted", token: "changed", diagnostics: change == "diagnostic", additionalUnknownHook: change == "unknown hook")
            return true
        })
        let updates = AsyncStream<Void>.makeStream()
        let subscription = coordinator.willChange.observe { updates.continuation.yield(()) }
        var completed = false
        let waiting = Task {
            let token = await coordinator.review()
            completed = true
            return token
        }
        var iterator = updates.stream.makeAsyncIterator()
        while coordinator.presentation?.isBusy != false { _ = await iterator.next() }
        let originalID = try #require(coordinator.presentation?.id)
        coordinator.setSelected(current.hooks[0].identity, selected: true, presentationID: originalID)
        await coordinator.trustSelectedAndContinue(presentationID: originalID)
        #expect(coordinator.presentation?.snapshot == current)
        #expect(coordinator.presentation?.id != originalID)
        #expect(coordinator.presentation?.error != nil)
        #expect(coordinator.selection.isEmpty)
        #expect(completed == false)
        #expect(coordinator.continueWithoutTrusting(presentationID: originalID) == nil)
        #expect(coordinator.continueWithoutTrusting() == "changed")
        #expect(await waiting.value == "changed")
        _ = subscription
    }

    @Test @MainActor func invalidationResolvesWaitBeforeLateListCompletes() async throws {
        let initial = try snapshot()
        let entered = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<ACPCodexHooksList, Never>?
        let coordinator = ACPCodexHooksReviewCoordinator(context: .init(host: "local", cwd: "/p"), list: {
            await withCheckedContinuation { continuation in release = continuation; entered.continuation.yield(()) }
        }, trust: { _, _ in true })
        let waiting = Task { await coordinator.review() }
        var iterator = entered.stream.makeAsyncIterator()
        await iterator.next()
        coordinator.invalidate()
        #expect(await waiting.value == nil)
        release?.resume(returning: initial)
        #expect(coordinator.presentation == nil)
        #expect(coordinator.reviewToken == nil)

        // Await the entire refresh operation to prove a late callback cannot restore state.
        let late = ACPCodexHooksReviewCoordinator(context: .init(host: "local", cwd: "/p"), list: {
            await withCheckedContinuation { continuation in release = continuation; entered.continuation.yield(()) }
        }, trust: { _, _ in true })
        let refreshing = Task { await late.refresh() }
        await iterator.next()
        late.invalidate()
        release?.resume(returning: initial)
        await refreshing.value
        #expect(late.presentation == nil)
        #expect(late.reviewToken == nil)
    }

    @Test @MainActor func lateTrustCannotRestoreInvalidatedPresentation() async throws {
        let initial = try snapshot()
        let entered = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Bool, Never>?
        let coordinator = ACPCodexHooksReviewCoordinator(context: .init(host: "local", cwd: "/p"), list: { initial }, trust: { _, _ in
            await withCheckedContinuation { continuation in release = continuation; entered.continuation.yield(()) }
        })
        await coordinator.refresh()
        coordinator.setSelected(initial.hooks[0].identity, selected: true)
        let trusting = Task { await coordinator.trustSelectedAndContinue() }
        var iterator = entered.stream.makeAsyncIterator()
        await iterator.next()
        coordinator.invalidate()
        release?.resume(returning: true)
        await trusting.value
        #expect(coordinator.presentation == nil)
        #expect(coordinator.reviewToken == nil)
    }

    @Test @MainActor func failedInspectionCannotContinue() async {
        let coordinator = ACPCodexHooksReviewCoordinator(context: .init(host: "remote", cwd: "/p"), list: { throw ACPClientError.decoding("broken list") }, trust: { _, _ in true })
        await coordinator.refresh()
        #expect(coordinator.presentation?.error?.contains("broken list") == true)
        #expect(coordinator.continueWithoutTrusting() == nil)
        #expect(coordinator.reviewToken == nil)
    }

    @Test @MainActor func emptyAndTrustedSnapshotsContinueAutomatically() async throws {
        for initial in [try snapshot(status: "trusted", diagnostics: false), try JSONDecoder().decode(ACPCodexHooksList.self, from: Data(#"{"cwd":"/p","hooks":[],"warnings":[],"errors":[],"reviewToken":"token"}"#.utf8))] {
            let coordinator = ACPCodexHooksReviewCoordinator(context: .init(host: "local", cwd: "/p"), list: { initial }, trust: { _, _ in false })
            #expect(await coordinator.review() == "token")
            #expect(coordinator.presentation == nil)
        }
    }

    @Test(arguments: ["codex_hook_review_required", "codex_hook_changed", "future", ""])
    func wrappedErrorsRetainExactReplayBoundary(kind: String) {
        let error = JSONRPCError(code: -32044, message: "original", data: AnyCodable(["kind": kind]))
        let expected = ACPCodexHookReviewError(rawValue: kind)
        #expect(ACPCodexHookReviewError.classify(ACPClientError.jsonrpc(error)) == expected)
        #expect(ACPCodexHookReviewError.classify(JSONRPCError(code: 1001, message: "original", data: AnyCodable(["kind": kind, "restartable": true]))) == nil)
    }

    private func snapshot(handler: String = "command", hash: String = "h", status: String = "untrusted", token: String = "token", duplicate: Bool = false, diagnostics: Bool = true, additionalUnknownHook: Bool = false) throws -> ACPCodexHooksList {
        let hook = """
        {"key":"k","currentHash":"\(hash)","eventName":"sessionStart","matcher":null,"timeoutSec":10,"statusMessage":null,"sourcePath":"/hooks.json","source":"sessionFlags","pluginId":null,"displayOrder":0,"enabled":true,"isManaged":false,"trustStatus":"\(status)","handlerType":"\(handler)","command":"true","async":false}
        """
        let unknown = hook.replacingOccurrences(of: #""key":"k""#, with: #""key":"new""#)
            .replacingOccurrences(of: #""handlerType":"command""#, with: #""handlerType":"future""#)
        return try JSONDecoder().decode(ACPCodexHooksList.self, from: Data("""
        {"cwd":"/p","hooks":[\(hook)\(duplicate ? "," + hook : "")\(additionalUnknownHook ? "," + unknown : "")],"warnings":\(diagnostics ? #"["warning"]"# : "[]"),"errors":\(diagnostics ? #"[{"path":"/bad","message":"bad"}]"# : "[]"),"reviewToken":"\(token)"}
        """.utf8))
    }
}
