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
        let baseBranch = config.worktrees.baseBranch
        let comparisonMode = config.changes.comparisonMode
        let commitsAheadResolution = GitService.BaseResolution.forCommits(
            mode: comparisonMode,
            userOverrodeBaseBranch: false
        )
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
                try await GitService().commitsAhead(
                    at: worktree.path,
                    baseBranch: baseBranch,
                    resolution: commitsAheadResolution
                )
            },
            loadBranches: { worktree in
                try await GitService().branches(at: worktree.path)
            },
            resolveRevision: { worktree, ref in
                try await GitService().resolveRevision(at: worktree.path, ref: ref)
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
