import AlasRemoteKit
import Foundation
import Observation

/// One attachment to a host console: keeps its output in order for the view,
/// and turns what the view writes into `input` while this phone holds the
/// lease. Starts as a viewer, as on the Mac; typing needs `takeControl`.
@MainActor @Observable
final class TerminalConsole {
    enum Phase: Equatable {
        case attaching
        case live
        case ended(String)
    }

    let consoleId: String
    let title: String
    private(set) var phase = Phase.attaching
    private(set) var control = PeerConsoleControl(owner: .host, generation: 0, change: .current)
    /// The host's grid; the view fits it, since only a lease holder may resize.
    private(set) var rows = 24
    private(set) var columns = 80
    let canResize: Bool

    var isControlling: Bool { phase == .live && control.owner == .you }

    /// Hands output to the view: a snapshot first replaces the screen.
    @ObservationIgnored var write: ((Data, _ isSnapshot: Bool) -> Void)?

    @ObservationIgnored private let hub: HostHub
    @ObservationIgnored private let hostID: UUID
    @ObservationIgnored private let attachmentId = UUID().uuidString
    @ObservationIgnored private var listener: ListenerToken?
    /// The next output sequence; nil before a snapshot or while one is awaited after a gap.
    @ObservationIgnored private var expected: Int?
    @ObservationIgnored private var filter = PeerConsoleInputFilter()
    @ObservationIgnored private var inputSequence = 0
    @ObservationIgnored private var escapeToken = 0
    /// The lease the filter's held bytes began under; they never go out under another.
    @ObservationIgnored private var pendingLease: PeerConsoleControl?
    /// The view's grid, as SwiftTerm last reported it.
    @ObservationIgnored private var viewGrid: (rows: Int, columns: Int)?
    /// The host's grid changed under a snapshot laid out for it: ask for another once the view fits.
    @ObservationIgnored private var resyncWhenFitted = false
    @ObservationIgnored private var watchGeneration = 0
    /// The host's `onlineCount` the attachment was made under.
    @ObservationIgnored private var attachedOnline = 0

    init(hub: HostHub, hostID: UUID, console: PeerConsoleSummary) {
        self.hub = hub
        self.hostID = hostID
        consoleId = console.consoleId
        title = console.title
        rows = console.rows
        columns = console.columns
        canResize = hub.supports(PeerConsoleCapability.resizeV1, on: hostID)
    }

    func attach() {
        guard listener == nil else { return }
        listener = hub.addListener(hostID) { [weak self] message in
            guard case .console(let event) = message, event.attachmentId == self?.attachmentId else { return }
            self?.handle(event)
        }
        attachedOnline = hub.onlineCount(of: hostID)
        sendAttach()
        watchGeneration += 1
        watchHost(generation: watchGeneration)
    }

    private func sendAttach() {
        send(.attach(consoleId: consoleId, attachmentId: attachmentId, scrollbackRows: 1000))
    }

    /// A dropped socket takes its attachments with it on the host, which says nothing about them:
    /// once the link is back, attach again and start over from a fresh snapshot, as a viewer.
    private func watchHost(generation: Int) {
        guard generation == watchGeneration, listener != nil else { return }
        let (online, count) = withObservationTracking {
            (hub.state(of: hostID) == .online, hub.onlineCount(of: hostID))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchHost(generation: generation) }
        }
        if !online, phase == .live {
            phase = .attaching
        } else if online, count != attachedOnline {
            attachedOnline = count
            expected = nil
            filter = PeerConsoleInputFilter()
            pendingLease = nil
            control = PeerConsoleControl(owner: .host, generation: 0, change: .current)
            phase = .attaching
            sendAttach()
        }
    }

    func detach() {
        // Listening means the host still holds the attachment; `detached` drops the listener.
        guard listener != nil else { return }
        send(.detach(attachmentId: attachmentId))
        listener = nil
        watchGeneration += 1
    }

    func takeControl() { send(.takeControl(attachmentId: attachmentId)) }
    func releaseControl() { send(.releaseControl(attachmentId: attachmentId)) }

    /// The holder's view changed size: the host lays its screen out for it, where it can.
    func viewResized(rows: Int, columns: Int) {
        viewGrid = (rows, columns)
        if resyncWhenFitted, rows == self.rows, columns == self.columns, phase == .live {
            // Bytes fed into the old grid lost what it couldn't hold; only a new snapshot restores it.
            resyncWhenFitted = false
            expected = nil
            send(.resync(attachmentId: attachmentId))
        }
        guard canResize, isControlling, rows > 0, columns > 0, rows != self.rows || columns != self.columns else { return }
        send(.resize(attachmentId: attachmentId, rows: rows, columns: columns))
    }

    /// Bytes the view wrote: keys, paste, and its own replies to queries, which the filter drops.
    /// A sequence begun under one lease (or while viewing) is dropped rather than finished under
    /// another, as the Mac's `PeerConsoleInputRelay` does.
    func viewWrote(_ data: Data) {
        let heldUnder = filter.hasPending ? pendingLease : nil
        let keys = filter.filter(data)
        let crossesLease = heldUnder.map { !Self.sameLease($0, control) } ?? false
        pendingLease = filter.hasPending ? (heldUnder ?? control) : nil
        if !crossesLease { forward(keys) }
        guard filter.hasAmbiguousPrefix else { return }
        // A lone ESC waits briefly for the rest of a sequence, then goes out as the Escape key.
        escapeToken += 1
        let token = escapeToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self, token == escapeToken else { return }
            let lease = pendingLease
            let keys = filter.flushAmbiguousPrefix()
            pendingLease = filter.hasPending ? lease : nil
            if let lease, Self.sameLease(lease, control) { forward(keys) }
        }
    }

    private static func sameLease(_ a: PeerConsoleControl, _ b: PeerConsoleControl) -> Bool {
        a.owner == b.owner && a.generation == b.generation
    }

    private func forward(_ keys: Data) {
        // Nothing typed while only viewing goes anywhere.
        guard !keys.isEmpty, isControlling else { return }
        inputSequence += 1
        send(.input(attachmentId: attachmentId, generation: control.generation, sequence: inputSequence, data: keys))
    }

    private func handle(_ event: PeerConsoleEvent) {
        switch event {
        case .attached(_, let rows, let columns, let control):
            gridChanged(rows: rows, columns: columns)
            self.control = control
            phase = .live
        case .snapshot(_, let sequence, _, let data):
            expected = sequence + 1
            write?(data, true)
        case .output(_, let sequence, let data):
            guard let expected else { return }
            guard sequence == expected else {
                // Bytes went missing: drop output until a fresh snapshot replaces the screen.
                self.expected = nil
                send(.resync(attachmentId: attachmentId))
                return
            }
            self.expected = expected + 1
            write?(data, false)
        case .control(_, let control):
            self.control = control
        case .geometry(_, let rows, let columns):
            gridChanged(rows: rows, columns: columns)
        case .detached(_, let reason):
            listener = nil
            watchGeneration += 1
            phase = .ended(Self.message(reason))
        case .inputAck, .list, .opened, .openFailed, .openNeedsRepoHookApproval:
            break
        }
    }

    /// The view lays the new grid out only after SwiftUI's next update, while the snapshot that
    /// follows is fed at once, so it is replaced once the view fits.
    private func gridChanged(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
        if viewGrid.map({ $0.rows != rows || $0.columns != columns }) ?? true { resyncWhenFitted = true }
    }

    private func send(_ request: PeerConsoleRequest) {
        hub.send(.console(request), to: hostID)
    }

    private static func message(_ reason: PeerConsoleDetachReason) -> String {
        switch reason {
        case .detached: "Detached."
        case .unavailable: "This terminal is no longer available."
        case .targetExited, .terminated: "The terminal ended."
        case .restartRequired: "Restart this terminal on the Mac to view it."
        case .unauthorized: "This Mac doesn't share terminals with this phone. Pair it again from the Mac."
        case .limitReached: "Too many terminals are open. Close one and try again."
        case .protocolError, .localOverflow, .unknown: "The connection to this terminal was lost."
        }
    }
}
