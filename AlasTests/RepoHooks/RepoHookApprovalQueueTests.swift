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
        #expect(queue.activeDialogRequest == nil)

        queue.decide(.approve)
        #expect(await firstTask.value == .approve)
        #expect(await duplicateTask.value == .approve)
        #expect(queue.activeRequest?.hook == nextHook)
        #expect(queue.activeRequest?.id != activeID)

        queue.decide(.skip)
        #expect(await nextTask.value == .skip)
        #expect(queue.activeRequest == nil)
    }

    @Test func coalescesWorktreeApprovalAcrossRuntimeContexts() async {
        let queue = RepoHookApprovalQueue()
        let sharedHook = hook("shared worktree hook", event: .worktreeCreate)
        let createTask = Task {
            await queue.requestDecision(hook: sharedHook, projectID: "project", context: .worktreeCreate)
        }

        await Task.yield()
        let activeRequestID = queue.activeRequest?.id
        #expect(queue.activeRequest?.context == .worktreeCreate)

        let memberTask = Task {
            await queue.requestDecision(hook: sharedHook, projectID: "project", context: .workspaceMember)
        }
        await Task.yield()
        #expect(queue.activeRequest?.id == activeRequestID)

        queue.decide(.approve)
        #expect(await createTask.value == .approve)
        let duplicatePromptWasQueued = queue.activeRequest != nil
        #expect(!duplicatePromptWasQueued)
        if duplicatePromptWasQueued {
            queue.decide(.skip)
        }
        #expect(await memberTask.value == .approve)
        #expect(queue.activeRequest == nil)
    }

    @Test func nonApprovalDecisionsResolveOneCoalescedWaiterAtATime() async {
        let queue = RepoHookApprovalQueue()
        let worktreeHook = hook("shared worktree hook", event: .worktreeCreate)
        let createTask = Task {
            await queue.requestDecision(hook: worktreeHook, projectID: "project", context: .worktreeCreate)
        }
        await Task.yield()
        let memberTask = Task {
            await queue.requestDecision(hook: worktreeHook, projectID: "project", context: .workspaceMember)
        }
        await Task.yield()

        let createRequestID = queue.activeRequest?.id
        queue.decide(.skip)
        #expect(await createTask.value == .skip)
        #expect(queue.activeRequest?.id != createRequestID)
        #expect(queue.activeRequest?.context == .workspaceMember)

        queue.decide(.skip)
        #expect(await memberTask.value == .skip)
        #expect(queue.activeRequest == nil)

        let firstSessionTask = Task {
            await queue.requestDecision(hook: hook("same session hook"), projectID: "project", context: .sessionOpen)
        }
        await Task.yield()
        let duplicateSessionTask = Task {
            await queue.requestDecision(hook: hook("same session hook"), projectID: "project", context: .sessionOpen)
        }
        await Task.yield()

        let sessionRequestID = queue.activeRequest?.id
        queue.decide(.cancel)
        #expect(await firstSessionTask.value == .cancel)
        #expect(queue.activeRequest?.id != sessionRequestID)

        queue.decide(.cancel)
        #expect(await duplicateSessionTask.value == .cancel)
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
        let settingsTask = Task {
            await queue.requestDecision(hook: sameHook, projectID: "project-a", context: .projectSettings)
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

        #expect(queue.activeRequest?.context == .projectSettings)
        queue.decide(.approve)
        #expect(await settingsTask.value == .approve)
        #expect(queue.activeRequest == nil)
    }

    @Test func routesProjectSettingsRequestsToNestedPresenter() async {
        let queue = RepoHookApprovalQueue()
        let presenterID = UUID()
        queue.registerDialogPresenter(id: presenterID)
        let task = Task {
            await queue.requestDecision(hook: hook("settings"), projectID: "project", context: .projectSettings)
        }

        await Task.yield()
        #expect(queue.activeDialogRequest?.id == queue.activeRequest?.id)
        #expect(queue.activeRuntimeRequest == nil)
        queue.decide(.approve)
        #expect(await task.value == .approve)
        queue.unregisterDialogPresenter(id: presenterID)
    }

    @Test func routesRuntimeRequestsThroughOpenProjectDialogAndBackToRoot() async {
        let queue = RepoHookApprovalQueue()
        let presenterID = UUID()
        queue.registerDialogPresenter(id: presenterID)
        let task = Task {
            await queue.requestDecision(hook: hook("runtime"), projectID: "project", context: .sessionOpen)
        }

        await Task.yield()
        let activeID = queue.activeRequest?.id
        #expect(queue.activeDialogRequest?.id == activeID)
        #expect(queue.activeRuntimeRequest == nil)

        queue.activeRuntimeRequest = nil
        #expect(queue.activeRequest?.id == activeID)

        queue.unregisterDialogPresenter(id: presenterID)
        #expect(queue.activeDialogRequest == nil)
        #expect(queue.activeRuntimeRequest?.id == activeID)
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

    @Test func cancellationBeforeWaiterRegistrationDoesNotLeaveRequestQueued() async {
        let queue = RepoHookApprovalQueue()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await queue.requestDecision(
                hook: hook("cancelled before registration"),
                projectID: "project",
                context: .sessionOpen
            )
        }

        await Task.yield()
        let pendingRequest = queue.activeRequest
        if pendingRequest != nil {
            queue.decide(.skip)
        }

        #expect(pendingRequest == nil)
        #expect(await task.value == .cancel)
        #expect(queue.activeRequest == nil)
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

    @Test func presentsApprovedHookReviewReadOnlyInProjectDialogFIFO() async {
        let queue = RepoHookApprovalQueue()
        let presenterID = UUID()
        queue.registerDialogPresenter(id: presenterID)
        let reviewedHook = hook("approved")
        let reviewTask = Task {
            await queue.requestReview(hook: reviewedHook)
        }

        await Task.yield()
        #expect(queue.activeDialogRequest?.isReadOnlyReview == true)
        #expect(queue.activeDialogRequest?.hook == reviewedHook)

        let approvalTask = Task {
            await queue.requestDecision(hook: hook("next"), projectID: "project", context: .projectSettings)
        }
        await Task.yield()
        queue.decide(.cancel)
        await reviewTask.value

        #expect(queue.activeDialogRequest?.isReadOnlyReview == false)
        #expect(queue.activeDialogRequest?.hook == hook("next"))
        queue.decide(.approve)
        #expect(await approvalTask.value == .approve)
        queue.unregisterDialogPresenter(id: presenterID)
    }

    private func hook(_ text: String, event: RepoHookEvent = .sessionOpen) -> RepoHook {
        let bytes = Data(text.utf8)
        return .init(
            event: event,
            source: .local,
            bytes: bytes,
            text: text,
            hash: RepoHookTrust.hash(event: event, bytes: bytes)
        )
    }
}
