import Foundation
import Testing
@testable import Alas

@MainActor
struct RepoHookApprovalQueueTests {
    @Test func presentsConcurrentRequestsInFIFOOrder() async {
        let queue = RepoHookApprovalQueue()
        let first = hook("first")
        let second = hook("second")
        let firstTask = Task {
            await queue.requestDecision(hook: first, projectID: "project", context: .sessionOpen)
        }
        let secondTask = Task {
            await queue.requestDecision(hook: second, projectID: "project", context: .worktreeCreate)
        }

        await Task.yield()
        #expect(queue.activeRequest?.hook == first)
        queue.decide(.approve)
        #expect(await firstTask.value == .approve)

        #expect(queue.activeRequest?.hook == second)
        queue.decide(.skip)
        #expect(await secondTask.value == .skip)
        #expect(queue.activeRequest == nil)
    }

    @Test func coalescesMatchingHookRequestsAndSharesDecision() async {
        let queue = RepoHookApprovalQueue()
        let sharedHook = hook("shared")
        let nextHook = hook("next")
        let firstTask = Task {
            await queue.requestDecision(hook: sharedHook, projectID: "project", context: .sessionOpen)
        }
        let duplicateTask = Task {
            await queue.requestDecision(hook: sharedHook, projectID: "project", context: .sessionOpen)
        }
        let nextTask = Task {
            await queue.requestDecision(hook: nextHook, projectID: "project", context: .sessionOpen)
        }

        await Task.yield()
        let activeID = queue.activeRequest?.id
        #expect(queue.activeRequest?.hook == sharedHook)
        #expect(queue.activeRuntimeRequest?.id == activeID)
        #expect(queue.activeProjectSettingsRequest == nil)

        queue.decide(.approve)
        #expect(await firstTask.value == .approve)
        #expect(await duplicateTask.value == .approve)
        #expect(queue.activeRequest?.hook == nextHook)
        #expect(queue.activeRequest?.id != activeID)

        queue.decide(.skip)
        #expect(await nextTask.value == .skip)
        #expect(queue.activeRequest == nil)
    }

    @Test func scopesCoalescingByProjectAndContext() async {
        let queue = RepoHookApprovalQueue()
        let sameHook = hook("same content")
        let firstTask = Task {
            await queue.requestDecision(hook: sameHook, projectID: "project-a", context: .sessionOpen)
        }
        let otherProjectTask = Task {
            await queue.requestDecision(hook: sameHook, projectID: "project-b", context: .sessionOpen)
        }
        let otherContextTask = Task {
            await queue.requestDecision(hook: sameHook, projectID: "project-a", context: .workspaceMember)
        }

        await Task.yield()
        let firstID = queue.activeRequest?.id
        #expect(queue.activeRequest?.context == .sessionOpen)
        queue.decide(.approve)
        #expect(await firstTask.value == .approve)

        #expect(queue.activeRequest?.id != firstID)
        #expect(queue.activeRequest?.context == .sessionOpen)
        queue.decide(.skip)
        #expect(await otherProjectTask.value == .skip)

        #expect(queue.activeRequest?.context == .workspaceMember)
        queue.decide(.approve)
        #expect(await otherContextTask.value == .approve)
        #expect(queue.activeRequest == nil)
    }

    @Test func routesProjectSettingsRequestsToNestedPresenter() async {
        let queue = RepoHookApprovalQueue()
        let task = Task {
            await queue.requestDecision(hook: hook("settings"), projectID: "project", context: .projectSettings)
        }

        await Task.yield()
        #expect(queue.activeProjectSettingsRequest?.id == queue.activeRequest?.id)
        #expect(queue.activeRuntimeRequest == nil)
        queue.decide(.approve)
        #expect(await task.value == .approve)
    }

    @Test func cancellingOneCoalescedWaiterLeavesSharedRequestActive() async {
        let queue = RepoHookApprovalQueue()
        let sharedHook = hook("shared")
        let firstTask = Task {
            await queue.requestDecision(hook: sharedHook, projectID: "project", context: .sessionOpen)
        }
        let duplicateTask = Task {
            await queue.requestDecision(hook: sharedHook, projectID: "project", context: .sessionOpen)
        }
        let nextTask = Task {
            await queue.requestDecision(hook: hook("next"), projectID: "project", context: .sessionOpen)
        }

        await Task.yield()
        duplicateTask.cancel()
        await Task.yield()
        #expect(await duplicateTask.value == .cancel)
        #expect(queue.activeRequest?.hook == sharedHook)

        queue.decide(.approve)
        #expect(await firstTask.value == .approve)
        #expect(queue.activeRequest?.hook == hook("next"))
        queue.decide(.skip)
        #expect(await nextTask.value == .skip)
    }

    @Test func supportsRetryAndContextSpecificCancelPolicy() async {
        let queue = RepoHookApprovalQueue()
        let task = Task {
            await queue.requestDecision(hook: hook("retry"), projectID: "project", context: .worktreeCreate)
        }

        await Task.yield()
        #expect(queue.activeRequest?.context.allowsCancel == false)
        #expect(queue.activeRequest?.context.skipTitle == "Finish without hook")
        queue.decide(.retry)
        #expect(await task.value == .retry)
    }

    @Test func cancelledWaitingRequestResolvesOnlyThatRequest() async {
        let queue = RepoHookApprovalQueue()
        let firstTask = Task {
            await queue.requestDecision(hook: hook("first"), projectID: "project", context: .sessionOpen)
        }
        let secondTask = Task {
            await queue.requestDecision(hook: hook("second"), projectID: "project", context: .workspaceMember)
        }

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
