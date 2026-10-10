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
            terminate: { [weak self] in self?.closeTerminalPaneWithoutConfirmation(leafId: $0) }
        ))
        _peerConsoleHost = host
        return host
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
            makeSurface: { [weak self] executable, args, onExit in
                guard let self else { throw CancellationError() }
                return try terminal.makeTransientSurface(
                    cfg: config.terminal,
                    theme: themeStore.current,
                    executable: executable,
                    args: args,
                    onExit: onExit
                )
            }
        )
        remotePeers.onConsoleEvent = { [weak consoles] serverId, event in
            consoles?.receive(serverId: serverId, event)
        }
        return consoles
    }
}
