@_spi(AppHost) import AlasCore
import Foundation

/// Serving this Mac's consoles to paired peers (#1558).
extension AppState {
    var peerConsoleHost: PeerConsoleHost? {
        if let host = _peerConsoleHost { return host }
        let host = PeerConsoleHost(environment: .init(
            consoles: { [weak self] in self?.peerConsoleSummaries() ?? [] },
            resolve: { [weak self] in self?.peerConsoleTarget(consoleId: $0) },
            setLocalInputSuppressed: { [weak self] consoleId, suppressed in
                self?.terminal.registry.session(for: consoleId)?.surface.setReadOnly(suppressed)
            },
            terminate: { [weak self] in self?.closeTerminalPaneWithoutConfirmation(leafId: $0) },
            open: { [weak self] in
                guard let self else { throw PeerConsoleOpenError.unsupported }
                return try await self.openPeerConsole(worktreeId: $0, repoHook: $1)
            }
        ))
        _peerConsoleHost = host
        return host
    }

    /// Asks this Mac's user, on the usual approval sheet, about a hook a
    /// paired Mac holds work for.
    func decidePeerRepoHook(
        serverId: String, hook: PeerRepoHook, context: RepoHookApprovalContext
    ) async -> RepoHookApprovalDecision {
        let host = remotePeers.helloPeers.first { $0.serverId == serverId }?.name ?? serverId
        return await repoHookApprovalQueue.requestDecision(
            hook: hook.repoHook(fromHost: host), projectID: "peer:\(serverId)", context: context
        )
    }

    /// Opens a terminal for a peer as a hidden, non-activating tab, so the
    /// host user's selection and focus never move. The hidden flag isn't
    /// persisted, so the tab shows once this Mac relaunches. No `resize`:
    /// the app keeps sizing consoles from its own grid. The session-open
    /// hook is gated by `repoHook`, never on this Mac's sheet; throws
    /// `RepoHookApprovalRequired` when the peer must approve it first.
    func openPeerConsole(worktreeId: String, repoHook: RepoHookConsent?) async throws -> String {
        guard let (project, worktree) = projectAndWorktree(withWorktreeId: worktreeId),
              !projectsManager.isWorktreeHidden(projectId: project.id, path: worktree.path)
        else { throw PeerConsoleOpenError.worktreeUnavailable }
        guard project.host == nil else { throw PeerConsoleOpenError.sshProject }
        guard config.terminal.keepSessionsAlive, terminal.zmxClient.isAvailable else {
            throw PeerConsoleOpenError(
                "This Mac doesn't keep terminal sessions alive (Settings › Terminal › Keep sessions alive across app quit), so it can't share a new terminal."
            )
        }
        do {
            let gate = try await core.gateRepoHook(event: .sessionOpen, project: project, consent: repoHook) {
                await core.environment.repoHookLoader.load(event: .sessionOpen, worktreeRoot: worktree.path, host: project.host)
            }
            if case .needsApproval(let hook) = gate { throw RepoHookApprovalRequired(hook: hook) }
            // Reads the hook again and runs it only if approved; one changed
            // since the gate is skipped, not asked about here.
            let tab = try await openTerminalTabPreparingRemoteZmxIfNeeded(
                for: worktree, isHidden: true, activates: false, promptsForRepoHooks: false
            )
            if case .terminal(let state) = tab, let id = state.root.leaves().first?.id { return id }
        } catch let required as RepoHookApprovalRequired {
            throw required
        } catch {
            throw PeerConsoleOpenError((error as? LocalizedError)?.errorDescription ?? PeerConsoleOpenError.notStarted.message)
        }
        throw PeerConsoleOpenError.notStarted
    }

    /// Only live, host-local, zmx-backed consoles are eligible. SSH consoles
    /// keep their zmx daemon on the remote host; plain shells have none.
    private func peerConsoleSocket(_ session: TerminalSession) -> (path: String, size: AlasGhostty.SurfaceView.GridSize)? {
        guard session.remoteHost == nil,
              let name = session.zmxSessionName,
              let path = terminal.zmxClient.socketPath(forSession: name),
              let size = session.surface.gridSize
        else { return nil }
        return (path, size)
    }

    /// Tab order, then pane order within a split tab; consoles outside any
    /// tab follow in creation order.
    func peerConsoleSummaries() -> [PeerConsoleSummary] {
        terminal.registry.all
            .map { (session: $0, position: terminalTabPosition(of: $0)) }
            .sorted {
                ($0.position?.tab ?? .max, $0.position?.pane ?? 0, $0.session.createdAt)
                    < ($1.position?.tab ?? .max, $1.position?.pane ?? 0, $1.session.createdAt)
            }
            .compactMap { session, position in
                guard let console = peerConsoleSocket(session) else { return nil }
                let names = projectAndWorktree(withWorktreeId: session.worktreeId)
                return PeerConsoleSummary(
                    consoleId: session.id,
                    title: tabs.terminalRuntimeTitles[session.id] ?? "Console",
                    worktreeId: session.worktreeId,
                    projectId: session.projectId,
                    projectName: names?.project.name,
                    worktreeName: names?.worktree.name,
                    rows: console.size.rows,
                    columns: console.size.columns,
                    // No git metrics: this list is built synchronously on every poll.
                    worktree: names.map {
                        RemoteWorktreeSummaryBuilder.make(
                            projectName: $0.project.name,
                            worktree: $0.worktree,
                            isMain: projectsManager.isMain($0.worktree, in: $0.project),
                            isFolder: $0.project.isFolder,
                            metrics: .unavailable
                        )
                    },
                    tabIndex: position?.tab
                )
            }
    }

    private func terminalTabPosition(of session: TerminalSession) -> (tab: Int, pane: Int)? {
        for (index, tab) in tabs.tabs(forWorktree: session.worktreeId).enumerated() {
            if case .terminal(let state) = tab,
               let pane = state.root.leaves().firstIndex(where: { $0.id == session.id }) {
                return (index, pane)
            }
        }
        return nil
    }

    private func peerConsoleTarget(consoleId: String) -> PeerConsoleTarget? {
        guard let session = terminal.registry.session(for: consoleId),
              let console = peerConsoleSocket(session)
        else { return nil }
        session.surface.onGridSizeChange = { [weak self] rows, columns in
            self?._peerConsoleHost?.geometryChanged(consoleId: consoleId, rows: rows, columns: columns)
        }
        return PeerConsoleTarget(
            consoleId: consoleId,
            socketPath: console.path,
            rows: console.size.rows,
            columns: console.size.columns
        )
    }

    /// The client side: viewing paired Macs' consoles. Console events from
    /// peers go straight here, never through federation.
    func makeNativePeerConsoles() -> NativePeerConsoles {
        let consoles = NativePeerConsoles(
            send: { [weak self] serverId, message in self?.remotePeers.sendToPeer(message, serverId: serverId) },
            supportsConsoles: { [weak self] serverId in
                self?.remotePeers.capabilities[serverId]?.contains(PeerConsoleCapability.v1) == true
            },
            supportsTerminate: { [weak self] serverId in
                self?.remotePeers.capabilities[serverId]?.contains(PeerConsoleCapability.terminateV1) == true
            },
            supportsOpen: { [weak self] serverId in
                self?.remotePeers.capabilities[serverId]?.contains(PeerConsoleCapability.openV1) == true
            },
            supportsResize: { [weak self] serverId in
                self?.remotePeers.capabilities[serverId]?.contains(PeerConsoleCapability.resizeV1) == true
            },
            makeSurface: { [weak self] executable, args, onExit in
                guard let self else { throw CancellationError() }
                return try terminal.makeTransientSurface(
                    cfg: config.terminal,
                    theme: themeStore.current,
                    executable: executable,
                    args: args,
                    onExit: onExit
                )
            },
            showError: { [weak self] title, message in self?.showFileActionError(title: title, message: message) },
            supportsRepoHookApproval: { [weak self] serverId in
                self?.remotePeers.capabilities[serverId]?.contains(PeerConsoleCapability.repoHookApprovalV1) == true
            },
            decideRepoHook: { [weak self] serverId, hook, context in
                await self?.decidePeerRepoHook(serverId: serverId, hook: hook, context: context) ?? .cancel
            }
        )
        remotePeers.onConsoleEvent = { [weak consoles] serverId, event in
            consoles?.receive(serverId: serverId, event)
        }
        return consoles
    }
}
