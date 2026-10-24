import Foundation
import Observation

/// Coalesces on-demand list requests per peer: one request in flight, and
/// any asks that arrive meanwhile collapse into a single follow-up, so a
/// burst of run events sends two lists at most.
struct PeerConsoleListCoalescer {
    private var inFlight: Set<String> = []
    private var stale: Set<String> = []

    /// Whether to send a list now. When false, the ask is replayed by `answered`.
    mutating func shouldSend(_ serverId: String) -> Bool {
        if inFlight.insert(serverId).inserted { return true }
        stale.insert(serverId)
        return false
    }

    /// The peer answered; whether to ask again because something changed since.
    mutating func answered(_ serverId: String) -> Bool {
        guard inFlight.remove(serverId) != nil, stale.remove(serverId) != nil else { return false }
        inFlight.insert(serverId)
        return true
    }

    /// Forgets `serverId`, or everything, so a lost reply can't wedge asks.
    mutating func reset(_ serverId: String? = nil) {
        guard let serverId else {
            inFlight = []
            stale = []
            return
        }
        inFlight.remove(serverId)
        stale.remove(serverId)
    }
}

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
    /// Fired when a peer reports a console list that differs from the last
    /// one, so the sidebar snapshot can fold it in.
    @ObservationIgnored var onListChanged: (() -> Void)?
    /// Fired when a peer opened the terminal this Mac asked for, so the
    /// view can select it.
    @ObservationIgnored var onOpened: ((_ serverId: String, _ consoleId: String) -> Void)?

    @ObservationIgnored private let send: @MainActor (_ serverId: String, RemoteClientMessage) -> Void
    @ObservationIgnored private let supportsConsoles: @MainActor (_ serverId: String) -> Bool
    @ObservationIgnored private let supportsTerminate: @MainActor (_ serverId: String) -> Bool
    @ObservationIgnored private let supportsOpen: @MainActor (_ serverId: String) -> Bool
    @ObservationIgnored private let supportsResize: @MainActor (_ serverId: String) -> Bool
    @ObservationIgnored private let makeSurface: PeerConsoleViewer.MakeSurface
    @ObservationIgnored private let showError: @MainActor (_ title: String, _ message: String) -> Void
    /// `open` requests awaiting a reply, by request id, to the peer asked.
    @ObservationIgnored private var pendingOpens: [String: String] = [:]
    /// A console this Mac just opened, whose viewer takes control once live.
    @ObservationIgnored private var controlOnOpen: (serverId: String, consoleId: String)?
    @ObservationIgnored private var onlinePeers: Set<String> = []
    @ObservationIgnored private var listRefresh: Task<Void, Never>?
    @ObservationIgnored private var coalescer = PeerConsoleListCoalescer()

    init(
        send: @escaping @MainActor (_ serverId: String, RemoteClientMessage) -> Void,
        supportsConsoles: @escaping @MainActor (_ serverId: String) -> Bool,
        supportsTerminate: @escaping @MainActor (_ serverId: String) -> Bool = { _ in false },
        supportsOpen: @escaping @MainActor (_ serverId: String) -> Bool = { _ in false },
        supportsResize: @escaping @MainActor (_ serverId: String) -> Bool = { _ in false },
        makeSurface: @escaping PeerConsoleViewer.MakeSurface,
        showError: @escaping @MainActor (_ title: String, _ message: String) -> Void = { _, _ in }
    ) {
        self.send = send
        self.supportsConsoles = supportsConsoles
        self.supportsTerminate = supportsTerminate
        self.supportsOpen = supportsOpen
        self.supportsResize = supportsResize
        self.makeSurface = makeSurface
        self.showError = showError
    }

    func start() {
        guard listRefresh == nil else { return }
        listRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.listRefreshInterval)
                guard let self else { return }
                coalescer.reset() // a reply lost to a dropped link must not block asks
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
        pendingOpens = [:]
        coalescer.reset()
    }

    /// Reconciles with the peers whose links currently carry sessions.
    func peersChanged(online: Set<String>) {
        let added = online.subtracting(onlinePeers)
        for gone in onlinePeers.subtracting(online) { coalescer.reset(gone) }
        onlinePeers = online
        consoles = consoles.filter { online.contains($0.key) }
        pendingOpens = pendingOpens.filter { online.contains($0.value) }
        if let viewer, !online.contains(viewer.serverId) { viewer.connectionLost() }
        requestLists(for: added)
    }

    func receive(serverId: String, _ event: PeerConsoleEvent) {
        if case .list(let list) = event {
            if coalescer.answered(serverId) { send(serverId, .console(.list)) }
            guard onlinePeers.contains(serverId), consoles[serverId] != list else { return }
            consoles[serverId] = list
            onListChanged?()
            return
        }
        // Only the peer asked answers an open, and only once.
        if case .opened(let requestId, let consoleId) = event {
            guard pendingOpens[requestId] == serverId else { return }
            pendingOpens[requestId] = nil
            controlOnOpen = (serverId, consoleId)
            onOpened?(serverId, consoleId)
            return
        }
        if case .openFailed(let requestId, let message) = event {
            guard pendingOpens[requestId] == serverId else { return }
            pendingOpens[requestId] = nil
            showError("New Terminal Failed", message)
            return
        }
        guard let viewer, viewer.serverId == serverId, event.attachmentId == viewer.attachmentId else { return }
        viewer.receive(event)
    }

    /// Asks `serverId` for its console list now instead of at the next poll,
    /// for when a run starts or ends and its console appears or goes. Bursts
    /// are coalesced.
    func refresh(serverId: String) {
        guard onlinePeers.contains(serverId), supportsConsoles(serverId),
              coalescer.shouldSend(serverId) else { return }
        send(serverId, .console(.list))
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

    /// Whether `serverId` can close its consoles for a peer; older hosts
    /// would drop the request.
    func canTerminate(serverId: String) -> Bool {
        onlinePeers.contains(serverId) && supportsTerminate(serverId)
    }

    /// Asks the host to close a console. The host replies with a fresh list,
    /// which drops the tab without waiting for the next poll.
    func terminate(serverId: String, consoleId: String) {
        guard canTerminate(serverId: serverId) else { return }
        send(serverId, .console(.terminate(consoleId: consoleId)))
    }

    /// Whether `serverId` opens terminals for a peer; older hosts would
    /// drop the request.
    func canOpen(serverId: String) -> Bool {
        onlinePeers.contains(serverId) && supportsOpen(serverId)
    }

    /// Asks the host for a new shell in `worktreeId`. Its `opened` reply
    /// selects the console and takes control of it.
    func openTerminal(serverId: String, worktreeId: String) {
        guard canOpen(serverId: serverId) else { return }
        let requestId = UUID().uuidString
        pendingOpens[requestId] = serverId
        send(serverId, .console(.open(requestId: requestId, worktreeId: worktreeId)))
    }

    private func open(serverId: String, consoleId: String) {
        viewer?.close()
        let takesControl = controlOnOpen.map { $0.serverId == serverId && $0.consoleId == consoleId } ?? false
        controlOnOpen = nil
        guard onlinePeers.contains(serverId) else { return }
        let title = consoles[serverId]?.first { $0.consoleId == consoleId }?.title ?? "Console"
        let send = self.send
        viewer = PeerConsoleViewer(
            serverId: serverId,
            consoleId: consoleId,
            title: title,
            scrollbackRows: Self.scrollbackRows,
            send: { send(serverId, .console($0)) },
            makeSurface: makeSurface,
            takesControlWhenLive: takesControl,
            supportsResize: supportsResize(serverId)
        )
    }

    private func requestLists(for peers: Set<String>) {
        for serverId in peers where supportsConsoles(serverId) {
            send(serverId, .console(.list))
        }
    }
}
