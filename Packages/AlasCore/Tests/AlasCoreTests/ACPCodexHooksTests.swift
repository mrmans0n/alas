import Foundation
import Testing
import AlasCore

struct ACPCodexHooksTests {
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
