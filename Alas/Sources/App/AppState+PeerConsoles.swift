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
            }
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

    func peerConsoleSummaries() -> [PeerConsoleSummary] {
        terminal.registry.all
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { session in
                guard let console = peerConsoleSocket(session) else { return nil }
                return PeerConsoleSummary(
                    consoleId: session.id,
                    title: tabs.terminalRuntimeTitles[session.id] ?? "Console",
                    worktreeId: session.worktreeId,
                    projectId: session.projectId,
                    rows: console.size.rows,
                    columns: console.size.columns
                )
            }
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
}
