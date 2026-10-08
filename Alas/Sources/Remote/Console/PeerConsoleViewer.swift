import Foundation
import Observation

/// Contiguity check for one attachment's output stream. A gap means bytes
/// are missing, so continuing from it would corrupt the screen: the viewer
/// asks for a fresh snapshot and ignores output until it arrives.
struct PeerConsoleStreamOrder {
    enum Decision: Equatable {
        case write
        case drop
        case resync
    }

    /// Next expected output sequence; nil before a snapshot or while one is
    /// awaited after a gap.
    private var expected: Int?

    mutating func snapshot(sequence: Int) {
        expected = sequence + 1
    }

    mutating func output(sequence: Int) -> Decision {
        guard let expected else { return .drop }
        guard sequence == expected else {
            self.expected = nil
            return .resync
        }
        self.expected = expected + 1
        return .write
    }
}

/// Holds VT bytes until the local surface is at least the host's grid.
///
/// The host lays its screen out for its own rows and columns. Writing that
/// into a smaller surface scrolls rows off the top and clamps cursor moves,
/// and the surface only reaches its final size once it has font metrics, so
/// bytes wait until the grid fits. A snapshot supersedes anything held.
struct PeerConsoleWriteGate {
    /// Held bytes beyond this are dropped and a fresh snapshot is needed.
    static let maxHeldBytes = 8 * 1024 * 1024

    enum Result: Equatable {
        case write(Data)
        case hold
        case resync
    }

    private var held: [Data] = []
    private var heldBytes = 0
    private var fits = false

    mutating func snapshot(_ data: Data) -> Result {
        held = []
        heldBytes = 0
        return output(data)
    }

    mutating func output(_ data: Data) -> Result {
        if fits { return .write(data) }
        held.append(data)
        heldBytes += data.count
        guard heldBytes <= Self.maxHeldBytes else {
            held = []
            heldBytes = 0
            return .resync
        }
        return .hold
    }

    /// The surface or host grid changed. Returns held bytes, in order, once
    /// the surface covers the host grid.
    mutating func gridChanged(surfaceFits: Bool) -> Data? {
        fits = surfaceFits
        guard fits, !held.isEmpty else { return nil }
        let data = held.reduce(Data(), +)
        held = []
        heldBytes = 0
        return data
    }
}

/// Turns bytes the viewer's surface wrote into `input` requests.
///
/// Nothing is forwarded unless this attachment holds the lease: view mode
/// sends no keys, paste, mouse, or terminal replies. While controlling,
/// terminal replies are filtered out, and every message carries the lease
/// generation so the host rejects input that outlives the grant.
struct PeerConsoleInputRelay {
    /// Largest `input` message; bigger pastes are split in order.
    static let maxChunk = 64 * 1024

    private var filter = PeerConsoleInputFilter()
    private var sequence = 0
    /// The lease in effect when the current lone ESC was held.
    private var escapeLease: PeerConsoleControl?

    /// A lone ESC is held until `flushEscape` decides it was the Escape key.
    var hasPendingEscape: Bool { filter.hasPendingEscape }

    /// Bytes always pass through the filter, even in view mode, so a reply
    /// that starts before control is granted is still recognized when it
    /// finishes after; only the holder's output is sent.
    mutating func relay(_ data: Data, attachmentId: String, control: PeerConsoleControl) -> [PeerConsoleRequest] {
        let keys = filter.filter(data)
        escapeLease = filter.hasPendingEscape ? control : nil
        guard control.owner == .you else { return [] }
        return requests(for: keys, attachmentId: attachmentId, control: control)
    }

    /// Releases a held ESC as the Escape key, but only under the lease it
    /// was held under: an ESC from view mode, or one that crossed a
    /// revoke and regrant, is discarded.
    mutating func flushEscape(attachmentId: String, control: PeerConsoleControl) -> [PeerConsoleRequest] {
        let keys = filter.flushEscape()
        let lease = escapeLease
        escapeLease = nil
        guard control.owner == .you, lease?.owner == .you, lease?.generation == control.generation else { return [] }
        return requests(for: keys, attachmentId: attachmentId, control: control)
    }

    private mutating func requests(
        for keys: Data,
        attachmentId: String,
        control: PeerConsoleControl
    ) -> [PeerConsoleRequest] {
        var requests: [PeerConsoleRequest] = []
        var offset = 0
        while offset < keys.count {
            let end = min(offset + Self.maxChunk, keys.count)
            sequence += 1
            requests.append(.input(
                attachmentId: attachmentId,
                generation: control.generation,
                sequence: sequence,
                data: keys.subdata(in: offset..<end)
            ))
            offset = end
        }
        return requests
    }
}

/// One remote console shown on this Mac: a local Ghostty surface fed through
/// a `PeerConsoleBridge`, plus the attachment's control state.
///
/// Views start passive with the surface read-only, so nothing the user does
/// is written anywhere and terminal replies from the surface are discarded.
/// Only while the host grants this attachment the lease does PTY input from
/// the surface pass `PeerConsoleInputFilter` and go out as `input`, stamped
/// with the lease generation. Ending the view never replays input.
@MainActor
@Observable
final class PeerConsoleViewer {
    enum Phase: Equatable {
        case connecting
        case live
        case ended(String)
    }

    typealias MakeSurface = @MainActor (
        _ executable: String, _ args: [String], _ onExit: @escaping () -> Void
    ) throws -> AlasGhostty.SurfaceView

    /// Clears the surface and its scrollback before a snapshot replaces it.
    static let resetBeforeSnapshot = Data("\u{1B}c\u{1B}[3J".utf8)

    let serverId: String
    let consoleId: String
    let title: String
    let attachmentId = UUID().uuidString
    private(set) var phase = Phase.connecting
    /// The host's grid; the host owns it and the view only presents it.
    private(set) var rows: Int?
    private(set) var columns: Int?
    private(set) var control = PeerConsoleControl(owner: .host, generation: 0, change: .current)

    @ObservationIgnored private(set) var surface: AlasGhostty.SurfaceView?
    @ObservationIgnored private var bridge: PeerConsoleBridge?
    @ObservationIgnored private let send: @MainActor (PeerConsoleRequest) -> Void
    @ObservationIgnored private var order = PeerConsoleStreamOrder()
    @ObservationIgnored private var relay = PeerConsoleInputRelay()
    /// Only the newest Escape timer may release a held ESC.
    @ObservationIgnored private var escapeTimerToken = 0
    @ObservationIgnored private var writeGate = PeerConsoleWriteGate()

    var isControlling: Bool { phase == .live && control.owner == .you }

    init(
        serverId: String,
        consoleId: String,
        title: String,
        scrollbackRows: Int,
        send: @escaping @MainActor (PeerConsoleRequest) -> Void,
        makeSurface: MakeSurface
    ) {
        self.serverId = serverId
        self.consoleId = consoleId
        self.title = title
        self.send = send
        do {
            let bridge = try PeerConsoleBridge { [weak self] data in
                Task { @MainActor in self?.surfaceWrote(data) }
            }
            self.bridge = bridge
            surface = try makeSurface(bridge.command.executable, bridge.command.args) { [weak self] in
                Task { @MainActor in self?.end("The local terminal closed.", notifyHost: true) }
            }
        } catch {
            bridge?.close()
            bridge = nil
        }
        guard bridge != nil, let surface else {
            phase = .ended("Could not open a local terminal.")
            return
        }
        surface.setReadOnly(true)
        surface.onGridSizeChange = { [weak self] _, _ in self?.gridChanged() }
        // Fallback for a surface that never reports a resize (hidden view):
        // show the bytes rather than nothing.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let data = writeGate.gridChanged(surfaceFits: true) else { return }
            bridge?.write(data)
        }
        send(.attach(consoleId: consoleId, attachmentId: attachmentId, scrollbackRows: scrollbackRows))
    }

    func receive(_ event: PeerConsoleEvent) {
        guard !isEnded else { return }
        switch event {
        case .attached(_, let rows, let columns, let control):
            self.rows = rows
            self.columns = columns
            apply(control)
            gridChanged()
        case .snapshot(_, let sequence, _, let data):
            order.snapshot(sequence: sequence)
            deliver(writeGate.snapshot(Self.resetBeforeSnapshot + data))
            phase = .live
        case .output(_, let sequence, let data):
            switch order.output(sequence: sequence) {
            case .write: deliver(writeGate.output(data))
            case .drop: break
            case .resync: send(.resync(attachmentId: attachmentId))
            }
        case .control(_, let control):
            apply(control)
        case .geometry(_, let rows, let columns):
            self.rows = rows
            self.columns = columns
            gridChanged()
        case .detached(_, let reason):
            end(Self.message(for: reason), notifyHost: false)
        case .inputAck, .list:
            break
        }
    }

    func takeControl() {
        guard phase == .live else { return }
        send(.takeControl(attachmentId: attachmentId))
    }

    func releaseControl() {
        guard isControlling else { return }
        send(.releaseControl(attachmentId: attachmentId))
    }

    /// The peer went offline or revoked this Mac; the host already dropped
    /// the attachment with the connection.
    func connectionLost() {
        end("The connection to this Mac was lost.", notifyHost: false)
    }

    /// Closing the view detaches only this attachment; the console keeps running.
    func close() {
        end("Closed.", notifyHost: true)
        bridge?.close()
    }

    var isEnded: Bool {
        if case .ended = phase { true } else { false }
    }

    private func deliver(_ result: PeerConsoleWriteGate.Result) {
        switch result {
        case .write(let data): bridge?.write(data)
        case .hold: break
        case .resync:
            order = PeerConsoleStreamOrder()
            send(.resync(attachmentId: attachmentId))
        }
    }

    private func gridChanged() {
        guard let rows, let columns, let grid = surface?.gridSize else { return }
        let fits = grid.rows >= rows && grid.columns >= columns
        if let data = writeGate.gridChanged(surfaceFits: fits) { bridge?.write(data) }
    }

    private func apply(_ control: PeerConsoleControl) {
        self.control = control
        surface?.setReadOnly(control.owner != .you)
    }

    /// How long a lone ESC may wait for the rest of a sequence before it is
    /// sent as the Escape key.
    static let escapeTimeout: Duration = .milliseconds(30)

    private func surfaceWrote(_ data: Data) {
        let owner = phase == .live ? control : PeerConsoleControl(owner: .host, generation: 0, change: .current)
        relay.relay(data, attachmentId: attachmentId, control: owner).forEach(send)
        guard relay.hasPendingEscape else { return }
        escapeTimerToken += 1
        let token = escapeTimerToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.escapeTimeout)
            guard let self, token == escapeTimerToken else { return }
            let owner = phase == .live ? control : PeerConsoleControl(owner: .host, generation: 0, change: .current)
            relay.flushEscape(attachmentId: attachmentId, control: owner).forEach(send)
        }
    }

    private func end(_ message: String, notifyHost: Bool) {
        guard !isEnded else { return }
        // An attach was only sent if the local surface came up.
        if notifyHost, surface != nil {
            send(.detach(attachmentId: attachmentId))
        }
        phase = .ended(message)
        apply(PeerConsoleControl(owner: .host, generation: control.generation, change: .revoked))
    }

    static func message(for reason: PeerConsoleDetachReason) -> String {
        switch reason {
        case .detached: "Detached."
        case .unavailable: "This console is no longer available."
        case .targetExited: "The console's process exited."
        case .restartRequired:
            "This console runs on an older terminal daemon. Restart the console on the host Mac to share it."
        case .unauthorized: "This Mac does not share consoles with you."
        case .protocolError: "The console stream failed."
        case .localOverflow: "The console produced more output than could be relayed."
        case .unknown: "The console ended."
        }
    }
}
