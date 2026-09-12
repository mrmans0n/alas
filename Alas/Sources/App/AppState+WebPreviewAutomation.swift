import AppKit
import Foundation

extension AppState {
    func previewOwnerIsAvailable(_ owner: SessionOwnerID) -> Bool {
        switch owner {
        case .worktree(let id):
            projects.contains { project in
                projectsManager.visibleWorktrees(projectId: project.id).contains { $0.id == id }
            }
        case .workspaceCheckout(let id, let location):
            config.workspacesEnabled && workspacesManager.checkouts.contains {
                $0.id == id && $0.executionLocation.normalized == location.normalized && $0.archivedAt == nil
            }
        }
    }

    func cliPreview(_ command: WebPreviewCommand, owner: SessionOwnerID,
                    isAuthorized: @escaping @MainActor () -> Bool) async -> AlasCLIResponse {
        let service = WebPreviewAutomationService(
            tabs: tabs, owner: owner, isAuthorized: isAuthorized,
            resolveOpen: { [weak self] command in
                guard let self else { throw WebPreviewAutomationError.denied }
                return try await self.previewOpenTarget(command, owner: owner)
            },
            focus: { [weak self] tabID in
                guard let self else { return }
                switch owner {
                case .worktree(let id):
                    if let worktree = self.worktree(withId: id) {
                        self.focusGlobalWorktree(id: id, projectId: worktree.projectId)
                        self.activateWorktreeCenterTab(worktreeId: id, tabId: tabID)
                    }
                case .workspaceCheckout(let id, _):
                    self.selectWorkspaceCheckout(id: id)
                    self.tabs.activate(owner: owner, tabId: tabID)
                }
                NSApp?.activate(ignoringOtherApps: true)
            }
        )
        do {
            let payload = try await service.perform(command)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard data.count <= 12 * 1024 * 1024, let json = String(data: data, encoding: .utf8) else {
                return .error("preview_limit: The result exceeds the response limit. Capture a smaller region.")
            }
            return .text([json])
        } catch {
            return .error(error.localizedDescription)
        }
    }

    func previewOpenTarget(_ command: WebPreviewCommand, owner: SessionOwnerID) async throws -> WebPreviewOpenTarget {
        guard previewOwnerIsAvailable(owner) else { throw WebPreviewAutomationError.denied }
        let worktree = owner.worktreeID.flatMap { self.worktree(withId: $0) }
        let host = worktree.map { webPreviewRemoteHost(for: $0) } ?? owner.checkoutExecutionLocation?.sshHost
        if let raw = command.url, let url = RunEndpointPolicy.endpoint(from: raw) {
            return WebPreviewOpenTarget(url: url, remoteHost: host)
        }
        guard let worktree else {
            throw WebPreviewAutomationError.endpoint("Supply an explicit URL for this Workspace Checkout.")
        }
        let scripts = await RunScriptStore.scripts(worktreeRoot: worktree.path, remoteHost: host)
        let candidates = scripts.filter { script in
            script.endpoint != nil && (command.scriptKey == nil || script.key == command.scriptKey)
        }
        guard candidates.count == 1, let script = candidates.first, let endpoint = script.endpoint else {
            throw WebPreviewAutomationError.endpoint(candidates.isEmpty
                ? "No configured endpoint found. Supply url or a Run script_key with an endpoint."
                : "Multiple endpoints are configured. Supply url or script_key. Candidates: \(candidates.map(\.key).joined(separator: ", "))")
        }
        let record = runRecords.record(worktreeID: worktree.id, scriptKey: script.key)
        let target = record.flatMap { $0.status.isActive ? $0.target : nil }
            ?? runExecutionTarget(for: script, in: worktree)
        return WebPreviewOpenTarget(url: endpoint, remoteHost: target.host)
    }
}
