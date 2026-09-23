import Foundation
import Testing
@testable import Alas

@MainActor
struct RepoHookApprovalQueueTests {
    @Test func presentsConcurrentRequestsInFIFOOrder() async {
        let queue = RepoHookApprovalQueue()
        let first = hook("first")
        let second = hook("second")
        let firstTask = Task { await queue.requestDecision(hook: first, context: .sessionOpen) }
        let secondTask = Task { await queue.requestDecision(hook: second, context: .worktreeCreate) }

        await Task.yield()
        #expect(queue.activeRequest?.hook == first)
        queue.decide(.approve)
        #expect(await firstTask.value == .approve)

        #expect(queue.activeRequest?.hook == second)
        queue.decide(.skip)
        #expect(await secondTask.value == .skip)
        #expect(queue.activeRequest == nil)
    }

    @Test func supportsRetryAndContextSpecificCancelPolicy() async {
        let queue = RepoHookApprovalQueue()
        let task = Task { await queue.requestDecision(hook: hook("retry"), context: .worktreeCreate) }

        await Task.yield()
        #expect(queue.activeRequest?.context.allowsCancel == false)
        #expect(queue.activeRequest?.context.skipTitle == "Finish without hook")
        queue.decide(.retry)
        #expect(await task.value == .retry)
    }

    @Test func cancelledWaitingRequestResolvesOnlyThatRequest() async {
        let queue = RepoHookApprovalQueue()
        let firstTask = Task { await queue.requestDecision(hook: hook("first"), context: .sessionOpen) }
        let secondTask = Task { await queue.requestDecision(hook: hook("second"), context: .workspaceMember) }

        await Task.yield()
        secondTask.cancel()
        await Task.yield()
        #expect(queue.activeRequest?.hook == hook("first"))
        #expect(await secondTask.value == .cancel)

        queue.decide(.approve)
        #expect(await firstTask.value == .approve)
        #expect(queue.activeRequest == nil)
    }

    @Test func unreadableHookOffersRetryAndContinueWithoutHook() async {
        let queue = RepoHookApprovalQueue()
        let failure = RepoHookFailure(event: .worktreeCreate, source: .local, message: "invalid UTF-8")
        let retryTask = Task {
            await queue.requestFailureDecision(failure: failure, context: .workspaceMember)
        }

        await Task.yield()
        #expect(queue.activeRequest?.failure == failure)
        #expect(queue.activeRequest?.context.skipTitle == "Finish member without hook")
        queue.decide(.retry)
        #expect(await retryTask.value == .retry)

        let continueTask = Task {
            await queue.requestFailureDecision(failure: failure, context: .workspaceMember)
        }
        await Task.yield()
        #expect(queue.activeRequest?.failure == failure)
        queue.decide(.skip)
        #expect(await continueTask.value == .skip)
    }

    private func hook(_ text: String) -> RepoHook {
        let bytes = Data(text.utf8)
        return .init(
            event: .sessionOpen,
            source: .local,
            bytes: bytes,
            text: text,
            hash: RepoHookTrust.hash(event: .sessionOpen, bytes: bytes)
        )
    }
}
