import AppKit

/// The client side of paired Macs' host channels. Host messages from peers
/// go straight here, never through federation.
extension AppState {
    func makeNativePeerHosts() -> NativePeerHosts {
        let hosts = NativePeerHosts(
            send: { [weak self] serverId, message in self?.remotePeers.sendToPeer(.host(message), serverId: serverId) },
            supports: { [weak self] serverId, capability in
                self?.remotePeers.capabilities[serverId]?.contains(capability) == true
            },
            confirm: { [weak self] confirmation, peerName in
                self?.confirmPeerWorktreeRemoval(confirmation, peerName: peerName) ?? false
            },
            showError: { [weak self] title, message in self?.showFileActionError(title: title, message: message) },
            notice: { [weak self] serverId, notice in
                self?.harness.notifications.notifyPeerNotice(
                    body: notice.body, title: notice.title, agent: AgentKind(rawValue: notice.agent) ?? .codex,
                    serverId: serverId, sessionId: notice.sessionID
                )
            }
        )
        remotePeers.onHostMessage = { [weak hosts] serverId, message in
            hosts?.receive(serverId: serverId, message)
        }
        return hosts
    }

    /// The local delete and force alerts, naming the host Mac so they can't
    /// pass for a local delete, plus the host-only unsaved-edits one.
    func confirmPeerWorktreeRemoval(_ confirmation: PeerWorktreeRemoval.Confirmation, peerName: String) -> Bool {
        let title: String, text: String, button: String
        switch confirmation {
        case .delete(let branch, let keepBranch):
            let local = Self.deleteConfirmation(branch: branch, keepBranch: keepBranch)
            return confirmDeleteWorktree(WorktreeDeleteConfirmation(
                title: "Delete worktree '\(branch)' on \(peerName)?", message: local.message
            ))
        case .force(let branch):
            title = "'\(branch)' on \(peerName) \(Self.forceDeleteAlertTitleSuffix)"
            text = Self.forceDeleteAlertMessage
            button = "Force Delete"
        case .discardUnsavedEdits(let branch, let archiving):
            let action = archiving ? "Archive" : "Delete"
            title = "\(action) worktree '\(branch)'?"
            text = "An editor on \(peerName) has unsaved changes in this worktree. \(archiving ? "Archiving" : "Deleting") will discard them; save them on \(peerName) first to keep them."
            button = "Discard & \(action)"
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
