import Foundation
import Testing
@testable import Alas

struct GGCommitMenuModelTests {
    @Test func unstackSubmissionUsesGGServiceUserMessage() {
        let error = GGServiceError.commandFailed(stderr: "Resolve the paused operation first.")

        #expect(GGErrorPresentation.message(for: error) == "Resolve the paused operation first.")
    }

    @Test func unstackSheetLocksDismissalAndRepeatSubmissionWhileSubmitting() {
        let idle = GGUnstackSheetPresentationState(isSubmitting: false)
        #expect(idle.canCancel)
        #expect(!idle.preventsInteractiveDismissal)
        #expect(idle.canSubmit(isValid: true))
        #expect(!idle.canSubmit(isValid: false))

        let submitting = GGUnstackSheetPresentationState(isSubmitting: true)
        #expect(!submitting.canCancel)
        #expect(submitting.preventsInteractiveDismissal)
        #expect(!submitting.canSubmit(isValid: true))
    }

    private func entry(
        position: Int = 2,
        title: String = "Add provider review routing",
        prNumber: Int? = 42,
        prState: GGPRState? = .open,
        approved: Bool = true,
        ciStatus: GGCIStatus? = .success,
        isCurrent: Bool = false
    ) -> GGStackEntry {
        GGStackEntry(
            position: position,
            sha: "sha-\(position)",
            title: title,
            ggId: "change-\(position)",
            prNumber: prNumber,
            prState: prState,
            approved: approved,
            ciStatus: ciStatus,
            isCurrent: isCurrent
        )
    }

    private func stack(target: GGStackEntry, count: Int = 4) -> GGStack {
        let entries = (1...count).map { position in
            position == target.position
                ? target
                : entry(position: position, prNumber: nil, prState: nil, approved: false, ciStatus: nil)
        }
        return GGStack(
            name: "feature",
            base: "main",
            totalCommits: entries.count,
            syncedCommits: 0,
            currentPosition: entries.last?.position,
            behindBase: 0,
            entries: entries
        )
    }

    private func context(
        target: GGStackEntry? = nil,
        provider: CodeHostKind? = .github,
        capabilities: GGCapabilities = .init(structuredSplit: true, keepCurrentUnstack: true),
        inFlightAction: GGStackActionKind? = nil,
        pausedOperation: GGPausedOperation? = nil,
        hasBlockingGitOperation: Bool = false,
        selectionIsStale: Bool = false,
        canOpenSplitCommit: Bool = true,
        reviewURL: URL? = URL(string: "https://github.com/owner/repository/pull/42")!
    ) -> GGCommitMenuContext {
        let target = target ?? entry()
        return GGCommitMenuContext(
            entry: target,
            stack: stack(target: target),
            provider: provider,
            capabilities: capabilities,
            inFlightAction: inFlightAction,
            pausedOperation: pausedOperation,
            hasBlockingGitOperation: hasBlockingGitOperation,
            selectionIsStale: selectionIsStale,
            canOpenSplitCommit: canOpenSplitCommit,
            providerReviewURL: reviewURL
        )
    }

    private func unstackModel(
        target: GGStackEntry,
        stack: GGStack,
        supportsKeepCurrent: Bool
    ) -> GGUnstackModel {
        let name = GGUnstackModel.derivedStackName(from: target.title)
        let prepared = GGPreparedMutation(
            request: .unstack(target: target.id, name: name, createWorktree: true),
            snapshot: GGStackIdentity(
                stackName: stack.name,
                base: stack.base,
                headSHA: stack.entries.last?.sha ?? target.sha,
                operationID: nil
            ),
            confirmation: .unstack(
                target: target.id,
                targetTitle: target.title,
                movedCommits: stack.entries.filter { $0.position >= target.position }.count,
                lowerStack: stack.name,
                newStack: name
            )
        )
        return try! GGUnstackModel(
            prepared: prepared,
            supportsKeepCurrent: supportsKeepCurrent
        )
    }

    @Test func mappedPullRequestCommitGetsStrictGGSubmenuOrder() {
        let model = GGCommitMenuModel.make(context: context())

        #expect(model.items.map(\.action) == [
            .reviewProviderRequest(
                number: 42,
                url: URL(string: "https://github.com/owner/repository/pull/42")!
            ),
            .openProviderRequest(number: 42),
            nil,
            .checkout,
            .splitCommit,
            nil,
            .dropCommit,
            .unstackHere,
            .landThrough,
        ])
        #expect(model.items.map(\.title) == [
            "Review PR in Alas...",
            "Open PR in Browser",
            nil,
            "Checkout Commit",
            "Split Commit...",
            nil,
            "Drop Commit...",
            "Split Stack Here...",
            "Land Through Here...",
        ])
        #expect(model.visibleItems.count == model.items.count)
    }

    @Test func reviewActionCarriesTheSelectedRemoteReviewURL() {
        let reviewURL = URL(string: "https://github.example/acme/alas/pull/42")!
        let model = GGCommitMenuModel.make(context: context(reviewURL: reviewURL))

        #expect(model.item(for: .reviewProviderRequest(number: 42, url: reviewURL))?.isEnabled == true)
    }

    @Test func mergeRequestCommitUsesMRLabels() {
        let model = GGCommitMenuModel.make(context: context(provider: .gitlab))

        #expect(model.items[0].title == "Review MR in Alas...")
        #expect(model.items[1].title == "Open MR in Browser")
    }

    @Test func remoteItemsAndTheirSeparatorAreHiddenWithoutMappedProviderReview() {
        let target = entry(prNumber: nil)
        let model = GGCommitMenuModel.make(context: context(target: target, provider: nil))

        #expect(!model.items[0].isVisible)
        #expect(!model.items[1].isVisible)
        #expect(!model.items[2].isVisible)
        #expect(model.visibleItems.first?.action == .checkout)
    }

    @Test func checkoutIsHiddenForCurrentCommit() {
        let model = GGCommitMenuModel.make(context: context(target: entry(isCurrent: true)))

        let checkout = try? #require(model.item(for: .checkout))
        #expect(checkout?.isVisible == false)
    }

    @Test func immutableCommitDisablesRewriteActionsWithReason() {
        let model = GGCommitMenuModel.make(context: context(target: entry(prState: .merged)))

        for action in [GGCommitAction.splitCommit, .dropCommit, .unstackHere] {
            let item = try? #require(model.item(for: action))
            #expect(item?.isEnabled == false)
            #expect(item?.disabledReason == "Merged commits cannot be rewritten.")
        }
        #expect(model.item(for: .checkout)?.isEnabled == true)
    }

    @Test func inFlightMutationDisablesLocalActionsWithConciseReason() {
        let model = GGCommitMenuModel.make(context: context(inFlightAction: .sync))

        for action in [
            GGCommitAction.checkout, .splitCommit, .dropCommit, .unstackHere, .landThrough,
        ] {
            let item = try? #require(model.item(for: action))
            #expect(item?.isEnabled == false)
            #expect(item?.disabledReason == "Another GG operation is running.")
        }
        #expect(model.item(for: .reviewProviderRequest(
            number: 42,
            url: URL(string: "https://github.com/owner/repository/pull/42")!
        ))?.isEnabled == true)
        #expect(model.item(for: .openProviderRequest(number: 42))?.isEnabled == true)
    }

    @Test func staleSelectionDisablesLocalActionsWithRefreshReason() {
        let model = GGCommitMenuModel.make(context: context(selectionIsStale: true))

        #expect(model.item(for: .checkout)?.disabledReason == "The stack changed. Refresh and try again.")
        #expect(model.item(for: .landThrough)?.isEnabled == false)
    }

    @Test func pausedOperationDisablesLocalActionsWithRecoveryReason() {
        let model = GGCommitMenuModel.make(context: context(
            pausedOperation: GGPausedOperation(pausedBy: .restack)
        ))

        #expect(model.item(for: .checkout)?.disabledReason == "Continue or abort the paused GG operation first.")
        #expect(model.item(for: .dropCommit)?.isEnabled == false)
    }

    @Test func landReadinessExplainsTargetAndLowerCommitFailures() {
        let blockedTarget = GGCommitMenuModel.make(context: context(
            target: entry(approved: false)
        ))
        #expect(blockedTarget.item(for: .landThrough)?.disabledReason == "This commit is not ready to land.")

        let target = entry(position: 2)
        let blockedLower = GGStackEntry(
            position: 1,
            sha: "sha-1",
            title: "Blocked lower",
            ggId: "change-1",
            prNumber: 41,
            prState: .open,
            approved: false,
            ciStatus: .success
        )
        let stack = GGStack(
            name: "feature",
            base: "main",
            totalCommits: 2,
            syncedCommits: 0,
            currentPosition: 2,
            behindBase: 0,
            entries: [blockedLower, target]
        )
        let model = GGCommitMenuModel.make(context: GGCommitMenuContext(
            entry: target,
            stack: stack,
            provider: .github,
            capabilities: .init(structuredSplit: true, keepCurrentUnstack: true),
            inFlightAction: nil,
            pausedOperation: nil,
            hasBlockingGitOperation: false,
            selectionIsStale: false
        ))
        #expect(model.item(for: .landThrough)?.disabledReason == "A lower commit is not ready to land.")
    }

    @Test func unavailableStructuredSplitHasUpdateReason() {
        let capabilities = GGCapabilities(structuredSplit: false, keepCurrentUnstack: true)
        let model = GGCommitMenuModel.make(context: context(capabilities: capabilities))

        #expect(model.item(for: .splitCommit)?.isEnabled == false)
        #expect(model.item(for: .splitCommit)?.disabledReason == "Update GG to split commits in Alas.")
    }

    @Test func splitCommitStaysDisabledUntilItsEditorHandlerIsWired() {
        let model = GGCommitMenuModel.make(context: context(canOpenSplitCommit: false))

        #expect(model.item(for: .splitCommit)?.isEnabled == false)
        #expect(model.item(for: .splitCommit)?.disabledReason == "Native Split Commit is unavailable.")
    }

    @Test func blockingGitOperationKeepsLocalGGActionsDisabled() {
        let model = GGCommitMenuModel.make(context: context(hasBlockingGitOperation: true))

        #expect(model.item(for: .checkout)?.disabledReason == "Finish the current Git operation first.")
        #expect(model.item(for: .dropCommit)?.isEnabled == false)
    }

    @Test func unstackDerivesNormalizedNameAndExactMovedCount() {
        let target = entry(position: 3, title: "feat(auth): Add OAuth 2.0 callbacks!")
        let model = unstackModel(
            target: target,
            stack: stack(target: target, count: 5),
            supportsKeepCurrent: true
        )

        #expect(model.stackName == "add-oauth-2-0-callbacks")
        #expect(model.movedCommitCount == 3)
        #expect(model.lowerStackName == "feature")
        #expect(model.createWorktree)
        #expect(model.confirmationMessage == "Split at \u{201C}feat(auth): Add OAuth 2.0 callbacks!\u{201D}. Move 3 commits from feature to add-oauth-2-0-callbacks.")
    }

    @Test func oldGGKeepsDefaultWorktreeToggleOnAndLocked() {
        var model = unstackModel(
            target: entry(position: 3),
            stack: stack(target: entry(position: 3), count: 5),
            supportsKeepCurrent: false
        )

        model.setCreateWorktree(false)

        #expect(model.createWorktree)
        #expect(!model.isCreateWorktreeToggleEnabled)
        #expect(model.createWorktreeDisabledReason == "Update GG to create a stack without a worktree")
    }

    @Test func editedStackNameNormalizesSpacesInDisplayedAndSubmittedValue() {
        var model = unstackModel(
            target: entry(position: 3),
            stack: stack(target: entry(position: 3), count: 5),
            supportsKeepCurrent: true
        )

        model.setStackName("oauth callbacks v2")

        #expect(model.stackName == "oauth-callbacks-v2")
        #expect(model.validatedStackName == "oauth-callbacks-v2")
        #expect(model.validationMessage == nil)
    }

    @Test func editedStackNameRejectsGGInvalidNames() {
        let cases = [
            ("auth/api", "Stack name cannot contain '/'."),
            ("auth--api", "Stack name cannot contain '--'."),
            ("auth~api", "Stack name cannot contain '~'."),
            ("auth^api", "Stack name cannot contain '^'."),
            ("auth:api", "Stack name cannot contain ':'."),
            ("auth?api", "Stack name cannot contain '?'."),
            ("auth*api", "Stack name cannot contain '*'."),
            ("auth[api", "Stack name cannot contain '['."),
            (#"auth\api"#, "Stack name cannot contain '\\'."),
            ("auth@api", "Stack name cannot contain '@'."),
            ("auth\napi", "Stack name cannot contain control characters."),
            ("auth..api", "Stack name cannot contain '..'."),
            (".auth", "Stack name cannot start or end with '.'."),
            ("auth.", "Stack name cannot start or end with '.'."),
            ("auth.lock", "Stack name cannot end with '.lock'."),
            ("", "Stack name cannot be empty."),
            ("---", "Stack name cannot contain '--'."),
        ]

        for (name, reason) in cases {
            var model = unstackModel(
                target: entry(position: 3),
                stack: stack(target: entry(position: 3), count: 5),
                supportsKeepCurrent: true
            )
            model.setStackName(name)
            #expect(model.validationMessage == reason, "\(name) should use GG's validation reason")
            #expect(model.validatedStackName == nil)
        }
    }
}
