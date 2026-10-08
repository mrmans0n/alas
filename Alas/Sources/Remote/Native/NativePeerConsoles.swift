import Foundation
import Observation

/// Paired Macs' consoles in the native peer UI, and the one being viewed.
///
/// Console traffic goes straight to one peer by `serverId`; it never passes
/// through federation's ACP routing. Lists are re-requested periodically
/// because a host opening or closing a tab has no push notification.
@MainActor
@Observable
final class NativePeerConsoles {
    static let scrollbackRows = 2000
    static let listRefreshInterval: Duration = .seconds(10)

    /// Eligible consoles per peer `serverId`, as the peer last reported them.
    private(set) var consoles: [String: [PeerConsoleSummary]] = [:]
    private(set) var viewer: PeerConsoleViewer?

    @ObservationIgnored private let send: @MainActor (_ serverId: String, RemoteClientMessage) -> Void
    @ObservationIgnored private let supportsConsoles: @MainActor (_ serverId: String) -> Bool
    @ObservationIgnored private let makeSurface: PeerConsoleViewer.MakeSurface
    @ObservationIgnored private var onlinePeers: Set<String> = []
    @ObservationIgnored private var listRefresh: Task<Void, Never>?

    init(
        send: @escaping @MainActor (_ serverId: String, RemoteClientMessage) -> Void,
        supportsConsoles: @escaping @MainActor (_ serverId: String) -> Bool,
        makeSurface: @escaping PeerConsoleViewer.MakeSurface
    ) {
        self.send = send
        self.supportsConsoles = supportsConsoles
        self.makeSurface = makeSurface
    }

    func start() {
        guard listRefresh == nil else { return }
        listRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.listRefreshInterval)
                guard let self else { return }
                requestLists(for: onlinePeers)
            }
        }
    }

    func stop() {
        listRefresh?.cancel()
        listRefresh = nil
        clearSelection()
        consoles = [:]
        onlinePeers = []
    }

    /// Reconciles with the peers whose links currently carry sessions.
    func peersChanged(online: Set<String>) {
        let added = online.subtracting(onlinePeers)
        onlinePeers = online
        consoles = consoles.filter { online.contains($0.key) }
        if let viewer, !online.contains(viewer.serverId) { viewer.connectionLost() }
        requestLists(for: added)
    }

    func receive(serverId: String, _ event: PeerConsoleEvent) {
        if case .list(let list) = event {
            guard onlinePeers.contains(serverId) else { return }
            consoles[serverId] = list
            return
        }
        guard let viewer, viewer.serverId == serverId, event.attachmentId == viewer.attachmentId else { return }
        viewer.receive(event)
    }

    func select(serverId: String, consoleId: String) {
        if let viewer, viewer.serverId == serverId, viewer.consoleId == consoleId, !viewer.isEnded { return }
        open(serverId: serverId, consoleId: consoleId)
    }

    /// A fresh attachment and snapshot for the current console; nothing from
    /// the previous attachment is replayed.
    func reconnect() {
        guard let viewer else { return }
        open(serverId: viewer.serverId, consoleId: viewer.consoleId)
    }

    func clearSelection() {
        viewer?.close()
        viewer = nil
    }

    private func open(serverId: String, consoleId: String) {
        viewer?.close()
        guard onlinePeers.contains(serverId) else { return }
        let title = consoles[serverId]?.first { $0.consoleId == consoleId }?.title ?? "Console"
        let send = self.send
        viewer = PeerConsoleViewer(
            serverId: serverId,
            consoleId: consoleId,
            title: title,
            scrollbackRows: Self.scrollbackRows,
            send: { send(serverId, .console($0)) },
            makeSurface: makeSurface
        )
    }

    private func requestLists(for peers: Set<String>) {
        for serverId in peers where supportsConsoles(serverId) {
            send(serverId, .console(.list))
        }
    }
}
