import Foundation
import os

private let autoNameLogger = Logger(subsystem: "io.nlopez.alas", category: "WorktreeAutoName")

/// The worktree has an operation in flight, such as a pending delete.
private struct WorktreeBusyError: LocalizedError {
    var errorDescription: String? { "The worktree is busy with another operation." }
}

extension AppState {
    /// True while `worktree` still sits on the temporary branch it was created
    /// on and waits for a chat prompt to name it.
    func isBranchNamePending(_ worktree: Worktree) -> Bool {
        projectsManager.pendingAutoBranchName(projectId: worktree.projectId, worktreeId: worktree.id) == worktree.branch
    }

    /// Names a worktree created without a name from the first user prompt
    /// that carries a request. A prompt with nothing to name it after leaves
    /// it pending for the next one. Only an unpublished branch still on its
    /// temporary name is renamed; anything else means the user already took
    /// over, so the pending entry is dropped.
    func autoNameBranchIfPending(worktreeId: String, prompt: String) {
        guard !autoNamingWorktreeIds.contains(worktreeId),
              let resolved = projectAndWorktree(withWorktreeId: worktreeId),
              let placeholder = projectsManager.pendingAutoBranchName(
                  projectId: resolved.project.id,
                  worktreeId: worktreeId
              )
        else { return }
        let (project, worktree) = resolved
        guard worktree.branch == placeholder else {
            dropPendingAutoBranchName(projectId: project.id, worktreeId: worktreeId)
            return
        }
        guard let source = WorktreeAutoBranchName.source(fromPrompt: prompt) else { return }

        autoNamingWorktreeIds.insert(worktreeId)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.autoNamingWorktreeIds.remove(worktreeId) }
            guard let name = await self.suggestedBranchName(source: source, worktree: worktree),
                  self.projectsManager.pendingAutoBranchName(projectId: project.id, worktreeId: worktreeId) == placeholder
            else { return }
            do {
                let renamed = try await self.renameBranchWhileIdle(
                    worktree,
                    from: placeholder,
                    to: self.composedBranchName(name, project: project),
                    requireUnpublished: true
                )
                self.dropPendingAutoBranchName(projectId: project.id, worktreeId: worktreeId)
                self.handleProjectHeadUpdates(projectId: project.id, branchByWorktreePath: [worktree.path: renamed])
            } catch is WorktreeService.BranchRenameError {
                self.dropPendingAutoBranchName(projectId: project.id, worktreeId: worktreeId)
            } catch {
                autoNameLogger.warning("Naming branch \(placeholder, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Renames the branch of `worktree` to exactly `branch` (or a numbered
    /// variant when taken). Returns an error message for the rename sheet.
    func renameWorktreeBranch(_ worktree: Worktree, to branch: String) async -> String? {
        do {
            let renamed = try await renameBranchWhileIdle(
                worktree,
                from: worktree.branch,
                to: branch,
                requireUnpublished: false
            )
            dropPendingAutoBranchName(projectId: worktree.projectId, worktreeId: worktree.id)
            handleProjectHeadUpdates(projectId: worktree.projectId, branchByWorktreePath: [worktree.path: renamed])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// A branch name for `worktree` inferred from the work already on it:
    /// commits only this branch has, else the files it changed.
    func suggestBranchName(for worktree: Worktree) async -> String? {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else { return nil }
        let log = try? await Process.git(
            ["log", "--no-merges", "--format=%s", "-n", "8", "HEAD", "--not",
             "--exclude=\(worktree.branch)", "--branches", "--remotes"],
            cwd: worktree.path
        )
        var source = log?.exitCode == 0 ? log?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        if source.isEmpty {
            let status = try? await Process.git(["status", "--porcelain", "--untracked-files=all"], cwd: worktree.path)
            let files = status?.stdout.split(whereSeparator: \.isNewline).prefix(20).map { String($0.dropFirst(3)) } ?? []
            if !files.isEmpty { source = "Changed files:\n" + files.joined(separator: "\n") }
        }
        guard !source.isEmpty, let name = await suggestedBranchName(source: source, worktree: worktree) else { return nil }
        return composedBranchName(name, project: project)
    }

    /// The on-device model's name when one can run, else the AI tool chosen
    /// in Changes settings, else the request's first meaningful words.
    private func suggestedBranchName(source: String, worktree: Worktree) async -> String? {
        if issueWorktreeNameSuggestionAvailable,
           let name = await makeIssueWorktreeNameSuggester().suggestName(forRequest: source) {
            return name
        }
        if let name = await providerBranchName(source: source, worktree: worktree) {
            return name
        }
        return WorktreeAutoBranchName.fallbackName(source: source)
    }

    /// Runs the Changes AI tool headless, as commit message generation does.
    /// Nil when none is selected or available, or when it fails or answers
    /// with anything but a name.
    private func providerBranchName(source: String, worktree: Worktree) async -> String? {
        guard config.changes.aiToolId != "none" else { return nil }
        await loadAgentAvailability(for: worktree)
        guard let agent = RepositoryAgentSelectionPolicy.selection(
            selectedID: config.changes.aiToolId,
            availability: agentAvailability(for: worktree)
        ).agent else { return nil }
        do {
            let output = try await AgentRunner.runPromptRaw(
                agent: agent,
                input: WorktreeAutoBranchName.providerInput(source: source),
                prompt: WorktreeAutoBranchName.providerPrompt,
                target: agentExecutionTarget(for: worktree),
                workingDirectory: worktree.path.path,
                timeout: 60
            )
            return WorktreeAutoBranchName.parseProviderOutput(output)
        } catch {
            autoNameLogger.warning("Naming a branch with \(agent.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Serialized with the project's creates and deletes. A worktree with an
    /// operation in flight keeps its branch: a delete has already captured it.
    private func renameBranchWhileIdle(
        _ worktree: Worktree,
        from: String,
        to: String,
        requireUnpublished: Bool
    ) async throws -> String {
        try await ProjectMutationGate.shared.withMutation(projectID: worktree.projectId) { [self] in
            let isIdle = await MainActor.run {
                projectsManager.operationState(forWorktreeId: worktree.id, projectId: worktree.projectId) == nil
            }
            guard isIdle else { throw WorktreeBusyError() }
            return try await WorktreeService().renameBranch(
                worktreePath: worktree.path,
                from: from,
                to: to,
                requireUnpublished: requireUnpublished
            )
        }
    }

    private func composedBranchName(_ name: String, project: ProjectConfig) -> String {
        WorktreeBranchName.compose(
            name: name,
            prefix: config.worktrees.branchPrefix,
            globalTemplate: config.worktrees.branchTemplate,
            projectTemplate: project.worktreeBranchTemplate
        )
    }

    private func dropPendingAutoBranchName(projectId: String, worktreeId: String) {
        guard projectsManager.pendingAutoBranchName(projectId: projectId, worktreeId: worktreeId) != nil else { return }
        projectsManager.removePendingAutoBranchName(projectId: projectId, worktreeId: worktreeId)
        saveProjects()
    }
}
