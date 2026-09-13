import Foundation

extension AppState {
    func runScriptWritingHelpAgent(in worktree: Worktree) throws -> String {
        guard !worktree.path.isRemoteAlasPath else { throw RunScriptWritingHelpError.remoteWorktree }
        guard let agentID = config.agents.worktreeAutoLaunch.agentId, agentID != "none" else {
            throw RunScriptWritingHelpError.noDefaultAgent
        }
        guard agentRegistry.enabled().contains(where: { $0.id == agentID }),
              ACPLaunchCatalog.specs.contains(where: { $0.agentID == agentID }) else {
            throw RunScriptWritingHelpError.unsupportedAgent
        }
        return agentID
    }

    func startRunScriptWritingHelp(scope: RunScriptScope, scriptURL: URL, in worktree: Worktree, request: String) throws {
        let agentID = try runScriptWritingHelpAgent(in: worktree)
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RunScriptWritingHelpError.emptyRequest
        }
        guard let currentWorktree = self.worktree(withId: worktree.id),
              currentWorktree.projectId == worktree.projectId,
              currentWorktree.path == worktree.path,
              let manager = acpManager(for: currentWorktree) else {
            throw RunScriptWritingHelpError.sessionUnavailable
        }
        let prompt = RunScriptWritingHelp.prompt(
            scope: scope, scriptURL: scriptURL, worktreeRoot: currentWorktree.path, request: request
        )
        guard let tab = openNewACPSession(agentID: agentID, owner: manager.owner, initialPrompt: prompt) else {
            throw RunScriptWritingHelpError.sessionUnavailable
        }
        focusGlobalWorktree(id: currentWorktree.id, projectId: currentWorktree.projectId)
        activateWorktreeCenterTab(worktreeId: currentWorktree.id, tabId: tab.id)
    }
}
