import AppKit
import Foundation

extension AppState {
    @MainActor
    func openReviewPaletteOverlay(prefill worktree: Worktree? = nil) {
        search.close()
        isSearchOpen = false
        repoSelector.close()
        isRepoSelectorOpen = false
        agentLauncher.reset()
        isAgentLauncherOpen = false
        runScriptPalette.reset()
        isRunScriptPaletteOpen = false
        if let worktree {
            reviewPalette.open(prefill: worktree)
        } else {
            reviewPalette.open()
        }
        isReviewPaletteOpen = true
    }

    @MainActor
    func closeReviewPaletteOverlay() {
        reviewPalette.close()
        isReviewPaletteOpen = false
    }

    /// Live environment for the review target palette: worktrees of the
    /// active project, git reads scoped per-worktree, and a launcher that
    /// switches the app to the picked worktree (the session tab lives in
    /// that worktree's tab set).
    ///
    /// `loadCommitsAhead` is invoked concurrently — once per worktree — from
    /// non-MainActor child tasks inside `ReviewTargetPaletteModel
    /// .loadWorktreeMetrics`'s `withTaskGroup`. Reading `self.config...`
    /// synchronously from inside that closure would race against MainActor
    /// mutations of `AppState.config` elsewhere in the app, so the two
    /// config values it needs are snapshotted into plain `let`s right here
    /// (this function itself is MainActor-isolated) and the closure only
    /// captures the already-resolved values, never `self.config`.
    @MainActor
    func reviewTargetPaletteEnvironment() -> ReviewTargetPaletteEnvironment {
        let defaultBaseBranch = config.worktrees.baseBranch
        let defaultComparisonMode = config.changes.comparisonMode
        let defaultResolution = GitService.BaseResolution.forCommits(
            mode: defaultComparisonMode,
            userOverrodeBaseBranch: false
        )

        // Per-worktree base-branch override snapshotted from any
        // already-loaded `RightPaneState` (e.g. the user picked a
        // non-default base for that worktree in the right pane) — read now,
        // on MainActor, since `loadCommitsAhead` below runs concurrently
        // off-MainActor and must never touch `self.rightPaneStore` from its
        // body. A worktree with no loaded right pane (never activated)
        // falls back to the global default above.
        let projectId = selectedWorktreeId
            .flatMap { self.worktree(withId: $0)?.projectId }
            ?? projects.first?.id
        var perWorktreeResolution: [String: (baseBranch: String, resolution: GitService.BaseResolution)] = [:]
        if let projectId {
            for worktree in projectsManager.visibleWorktrees(projectId: projectId) {
                guard let state = rightPaneStore.activeState(worktreeId: worktree.id) else { continue }
                perWorktreeResolution[worktree.id] = (
                    state.baseBranch,
                    GitService.BaseResolution.forCommits(
                        mode: state.comparisonMode,
                        userOverrodeBaseBranch: state.userOverrodeBaseBranch
                    )
                )
            }
        }

        return ReviewTargetPaletteEnvironment(
            worktrees: { [weak self] in
                guard let self else { return [] }
                let projectId = self.selectedWorktreeId
                    .flatMap { self.worktree(withId: $0)?.projectId }
                    ?? self.projects.first?.id
                guard let projectId else { return [] }
                return self.projectsManager.visibleWorktrees(projectId: projectId)
            },
            currentWorktreeId: { [weak self] in
                self?.selectedWorktreeId
            },
            loadCommitsAhead: { worktree in
                let override = perWorktreeResolution[worktree.id]
                return try await GitService().commitsAhead(
                    at: worktree.path,
                    baseBranch: override?.baseBranch ?? defaultBaseBranch,
                    resolution: override?.resolution ?? defaultResolution
                )
            },
            loadBranches: { worktree in
                try await GitService().branches(at: worktree.path)
            },
            resolveRevision: { worktree, ref in
                try await GitService().resolveRevision(at: worktree.path, ref: ref)
            },
            currentBranch: { worktree in
                try await GitService().currentBranch(worktreePath: worktree.path)
            },
            resolveTrackedRevision: { worktree, expression in
                try await TrackedRevisionResolver.live.resolve(at: worktree.path, expression: expression)
            },
            headSHA: { worktree in
                try await GitService().headSHA(at: worktree.path)
            },
            openTarget: { [weak self] target, worktree in
                guard let self else { return }
                let store = ReviewSessionStore()
                ReviewSessionLauncher.openOrFocus(
                    target: target,
                    findActive: { try store.findActive(targetID: $0) },
                    save: { try store.save($0) },
                    open: { record in
                        self.focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
                        _ = self.tabs.openOrFocusReviewSession(worktreeId: worktree.id, record: record)
                        self.closeReviewPaletteOverlay()
                    },
                    onFailure: { error in
                        self.reviewPalette.presentLaunchError(error.localizedDescription)
                    }
                )
            }
        )
    }
}
