import Foundation
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations
import AlasACP

private let headlessShepherdLogger = Logger(subsystem: "io.nlopez.alas", category: "ReviewShepherd")

/// The PR and stack shepherds' effects on a host without the app: sessions
/// through the host's session managers, gg through a coordinator of its own,
/// notices through the harness, and no panes to refresh.
extension AlasCoreContext {
    public func installDefaultShepherdEffects() {
        reviewShepherd.effects = ReviewShepherd.Effects(
            worktreeContext: { [weak self] worktreeID in
                guard let self, let resolved = shepherdWorktree(worktreeID) else { return nil }
                let project = resolved.project, worktree = resolved.worktree
                return ReviewShepherd.WorktreeContext(
                    worktreeID: worktree.id,
                    projectID: project.id,
                    path: worktree.path,
                    baseBranch: environment.configuration().worktrees.baseBranch,
                    isEligible: !project.isFolder
                )
            },
            sessionState: { [weak self] sessionID, worktreeID in
                await self?.headlessShepherdSessionState(sessionID: sessionID, worktreeID: worktreeID) ?? .missing
            },
            deliverPrompt: { [weak self] sessionID, worktreeID, prompt, isStillWanted in
                await self?.headlessDeliverShepherdPrompt(
                    sessionID: sessionID, worktreeID: worktreeID, prompt: prompt, isStillWanted: isStillWanted
                ) ?? .failed
            },
            rules: { [weak self] worktreeID in
                try await self?.headlessShepherdRules(worktreeID: worktreeID) ?? ShepherdRules.none
            },
            notify: { [weak self] event in
                guard let self else { return }
                let message = ShepherdNotification.review(for: event) { self.projectAndWorktree(withWorktreeId: $0.id.worktreeID)?.project.host }
                notifyShepherd(title: message.title, body: message.body, sessionID: message.record.sessionID,
                               owner: message.record.owner, worktreeID: message.record.id.worktreeID)
            },
            refreshPaneIfCached: { _ in },
            archiveWorktreeIfAllowed: { [weak self] worktreeID, sessionID, isStillWanted in
                await self?.headlessArchiveShepherdWorktreeIfAllowed(
                    worktreeID, sessionID: sessionID, isStillWanted: isStillWanted
                ) ?? .declined
            },
            servesWorktree: { [weak self] in self?.servesShepherdWorktree($0) ?? false }
        )
        stackShepherd.effects = StackShepherd.Effects(
            worktreeContext: { [weak self] worktreeID in
                guard let self, let resolved = shepherdWorktree(worktreeID) else { return nil }
                let project = resolved.project, worktree = resolved.worktree
                return StackShepherd.WorktreeContext(
                    worktreeID: worktree.id,
                    path: worktree.path,
                    stackName: project.isFolder ? nil : shepherdStackName(project: project, worktree: worktree),
                    isEligible: !project.isFolder
                )
            },
            loadStack: { path in
                // Older gg builds lack `--no-refresh`; they read remote state too.
                let localOnly = GGAvailability.shared.capabilities.localStackSnapshot
                return try await GGService().currentStack(worktreePath: path.path, refreshRemote: !localOnly)
            },
            syncStack: { [weak self] worktreeID, plan in
                guard let self else { throw GGMutationError.staleConfirmation }
                let request: GGMutationRequest
                if plan == .wholeStack {
                    request = .sync
                } else {
                    guard GGAvailability.shared.capabilities.syncUntilDraft else { throw GGMutationError.scopedSyncUnsupported }
                    request = .syncUntil(target: plan.shipThroughEntryID, draft: plan.opensDrafts)
                }
                let actionState = GGStackActionState()
                try await runShepherdGGMutation(request, confirmedAgainst: nil, worktreeID: worktreeID, actionState: actionState)
                if actionState.syncHasTerminalFailure {
                    throw GGMutationError.syncTerminalFailure(message: actionState.lastError ?? "GG sync failed.")
                }
            },
            rebaseStack: { [weak self] worktreeID, expected in
                guard let self else { throw GGMutationError.staleConfirmation }
                try await runShepherdGGMutation(
                    .rebase(target: nil), confirmedAgainst: expected, worktreeID: worktreeID, actionState: GGStackActionState()
                )
            },
            sessionState: { [weak self] sessionID, worktreeID in
                await self?.headlessShepherdSessionState(sessionID: sessionID, worktreeID: worktreeID) ?? .missing
            },
            deliverPrompt: { [weak self] sessionID, worktreeID, prompt, isStillWanted in
                await self?.headlessDeliverShepherdPrompt(
                    sessionID: sessionID, worktreeID: worktreeID, prompt: prompt, isStillWanted: isStillWanted
                ) ?? .failed
            },
            rules: { [weak self] worktreeID in
                try await self?.headlessShepherdRules(worktreeID: worktreeID) ?? ShepherdRules.none
            },
            notify: { [weak self] event in
                guard let self else { return }
                let message = ShepherdNotification.stack(for: event) { self.projectAndWorktree(withWorktreeId: $0.id.worktreeID)?.project.host }
                notifyShepherd(title: message.title, body: message.body, sessionID: message.record.sessionID,
                               owner: message.record.owner, worktreeID: message.record.id.worktreeID)
            },
            archiveWorktreeIfAllowed: { [weak self] worktreeID, sessionID, isStillWanted in
                await self?.headlessArchiveShepherdWorktreeIfAllowed(
                    worktreeID, sessionID: sessionID, isStillWanted: isStillWanted
                ) ?? .declined
            },
            servesWorktree: { [weak self] in self?.servesShepherdWorktree($0) ?? false }
        )
    }

    /// A turn of a session this host runs ended: the shepherds and scheduled
    /// turns waiting on it, and a delegating parent, hear of it, as in the app.
    public func turnCompleted(_ completion: ACPTurnCompletion) async {
        scheduledAgentTurns.deliver(completion)
        reviewShepherd.turnCompleted(sessionID: completion.sessionId)
        stackShepherd.turnCompleted(sessionID: completion.sessionId)
        await orchestration.childTurnCompleted(completion)
    }

    // MARK: - Worktrees

    /// Local worktrees the host lists. An SSH project's agents run on its own
    /// host, which only the app reaches; an id the host does not list may be
    /// one of those, so it is left to the app too.
    private func servesShepherdWorktree(_ worktreeID: String) -> Bool {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeID) else { return false }
        return resolved.project.host == nil
    }

    /// Nil when the worktree is gone or archived.
    // ponytail: Workspace checkout members aren't excluded on the host; add a store lookup if one gets shepherded
    private func shepherdWorktree(_ worktreeID: String) -> (project: ProjectConfig, worktree: Worktree)? {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeID),
              !projects.isWorktreeHidden(projectId: resolved.project.id, path: resolved.worktree.path)
        else { return nil }
        return resolved
    }

    /// The gg stack the stacked-diffs settings put `worktree` on, as the app
    /// resolves it; nil outside gg mode.
    private func shepherdStackName(project: ProjectConfig, worktree: Worktree) -> String? {
        let context = GGWorktreeContextResolver.resolve(
            masterEnabled: environment.configuration().changes.stackedDiffsEnabled,
            ggInstalled: GGAvailability.shared.isInstalled,
            isRemoteProject: project.host != nil || project.isFolder,
            projectMode: project.ggMode,
            worktreeOverride: projects.ggWorktreeMode(projectId: project.id, worktreeId: worktree.id),
            isMainWorktree: projects.isMain(worktree, in: project),
            repoHasGGConfig: GGStackGate.repoHasGGConfig(repoPath: project.path),
            branchUsername: GGConfigReader.branchUsername(repoPath: project.path),
            branch: worktree.branch
        )
        guard case .active(let name) = context else { return nil }
        return name
    }

    private func headlessShepherdRules(worktreeID: String) async throws -> ShepherdRules {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeID) else { return ShepherdRules.none }
        return try await ShepherdRulesResolver.load(worktreePath: resolved.worktree.path, projectSettings: resolved.project.shepherd)
    }

    // MARK: - Sessions

    private func shepherdSessionManager(worktreeID: String) -> ACPSessionManager? {
        guard let worktree = projectAndWorktree(withWorktreeId: worktreeID)?.worktree else { return nil }
        return try? environment.sessionManager(for: worktree, in: self)
    }

    private func headlessShepherdSessionState(sessionID: String, worktreeID: String) async -> ShepherdSessionState {
        guard let manager = shepherdSessionManager(worktreeID: worktreeID) else { return .missing }
        return await shepherdSessionState(sessionID: sessionID, in: manager)
    }

    private func headlessDeliverShepherdPrompt(
        sessionID: String,
        worktreeID: String,
        prompt: ShepherdPrompt,
        isStillWanted: @MainActor () -> Bool
    ) async -> ReviewShepherd.Delivery {
        guard let manager = shepherdSessionManager(worktreeID: worktreeID) else { return .failed }
        return await deliverShepherdPrompt(
            sessionID: sessionID, worktreeID: worktreeID, prompt: prompt, isStillWanted: isStillWanted, in: manager
        )
    }

    // MARK: - Notices

    /// Through the harness, which hands it to whoever shows the host's notices.
    private func notifyShepherd(title: String, body: String, sessionID: String, owner: SessionOwnerID, worktreeID: String) {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeID) else { return }
        let manager = sessionManagers[.worktree(worktreeID)]
        let agentID = manager?.liveSession(for: sessionID)?.agentId ?? manager?.cachedPersistedSessionRow(id: sessionID)?.agentId
        harness.notifications.notifyAlas(
            body: body,
            title: title,
            agent: agentID.map { AgentKind(acpAgentID: $0) } ?? .codex,
            projectId: resolved.project.id,
            worktreeId: resolved.worktree.id,
            sessionId: sessionID,
            owner: owner
        )
    }

    // MARK: - Archive and gg

    /// Settings > Changes > "Archive worktree after its PR merges", checked
    /// as the app does. A host has no editors, so no unsaved edits hold it.
    private func headlessArchiveShepherdWorktreeIfAllowed(
        _ worktreeID: String,
        sessionID: String,
        isStillWanted: @MainActor () -> Bool
    ) async -> ReviewShepherd.ArchiveResult {
        guard environment.configuration().changes.shepherd.archiveAfterMerge,
              let resolved = projectAndWorktree(withWorktreeId: worktreeID),
              !projects.isMain(resolved.worktree, in: resolved.project),
              !projects.isWorktreeHidden(projectId: resolved.project.id, path: resolved.worktree.path)
        else { return .declined }
        let worktree = resolved.worktree
        // Archiving hides the worktree, and the shepherd then drops every record
        // in it, including one still watching another open request.
        if hasActiveShepherdRecord(worktreeID: worktreeID) {
            headlessShepherdLogger.notice("Kept \(worktree.branch, privacy: .private): another pull request in it is still shepherded")
            return .declined
        }
        if await headlessShepherdSessionState(sessionID: sessionID, worktreeID: worktreeID) == .busy {
            return .deferredBusy
        }
        // The session state read suspends: the record, the setting or the
        // worktree may have changed meanwhile.
        guard isStillWanted(),
              environment.configuration().changes.shepherd.archiveAfterMerge,
              !projects.isWorktreeHidden(projectId: resolved.project.id, path: worktree.path),
              !hasActiveShepherdRecord(worktreeID: worktreeID)
        else { return .declined }
        do {
            try await WorktreesAPI(core: self).archive(worktree, caller: .cli)
        } catch {
            headlessShepherdLogger.error("Could not archive \(worktree.branch, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return .declined
        }
        return .archived
    }

    private func hasActiveShepherdRecord(worktreeID: String) -> Bool {
        reviewShepherd.records.values.contains { $0.id.worktreeID == worktreeID && !$0.phase.isTerminal }
            || stackShepherd.records.values.contains { $0.id.worktreeID == worktreeID && !$0.isFinished }
    }

    /// `request` through a gg mutation coordinator, as the stack drawer runs
    /// it, minus the drawer's refreshes. Refused while a checkpoint restore
    /// is pending recovery.
    // ponytail: one coordinator per call; stack_ship already serializes per worktree
    private func runShepherdGGMutation(
        _ request: GGMutationRequest,
        confirmedAgainst expected: GGStackIdentity?,
        worktreeID: String,
        actionState: GGStackActionState
    ) async throws {
        guard let worktree = projectAndWorktree(withWorktreeId: worktreeID)?.worktree else { throw GGMutationError.staleConfirmation }
        if await hasPendingCheckpointRecovery(worktree) { throw GGMutationError.staleConfirmation }
        let gg = GGService()
        let git = GitService()
        let path = worktree.path
        let coordinator = GGMutationCoordinator(
            worktreeId: worktree.id,
            worktreePath: path.path,
            service: gg,
            actionState: actionState,
            context: GGMutationContext(
                loadFreshStack: { try await gg.currentStackSnapshot(worktreePath: path.path) },
                loadCurrentBranch: { try await git.currentBranch(worktreePath: path) },
                loadCurrentHead: { try await git.revParseHEAD(worktreePath: path) },
                refreshStack: {},
                refreshGitChanges: {},
                refreshProviderReviews: {},
                refreshProjectTopology: {},
                finishPendingStaging: { true },
                worktreeExists: { FileManager.default.fileExists(atPath: path.path) },
                invalidateInbox: {},
                selectWorktreeAtPath: { _ in },
                currentBranch: { nil },
                publishLandEvent: { _ in false }
            )
        )
        guard let operation = coordinator.startApplying(request, confirmedAgainst: expected) else {
            throw GGMutationError.operationInFlight
        }
        try await operation.value
    }
}
