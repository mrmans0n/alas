import Foundation

/// Peer console traffic: viewing and controlling a host's existing
/// zmx-backed console from a paired Mac. Attachment-scoped and separate from
/// ACP sessions; routed to one verified peer, never fanned out through ACP
/// subscribers. Carried as `RemoteClientMessage.console` and
/// `RemoteServerMessage.console`, which older peers skip as unknown types.
enum PeerConsoleCapability {
    /// Advertised in `hello` by hosts that serve peer consoles.
    static let v1 = "peerConsole.v1"
}

struct PeerConsoleSummary: Codable, Equatable, Sendable {
    /// Opaque host-side console identifier. The host resolves it through its
    /// live terminal registry; it never names a socket, session, or command.
    let consoleId: String
    let title: String
    let worktreeId: String?
    let projectId: String?
    /// Display names; a peer may know nothing else about the worktree.
    let projectName: String?
    let worktreeName: String?
    let rows: Int
    let columns: Int
    /// Lets a peer's sidebar place a console-only worktree like a session's.
    /// Nil from an older host; rows then fall back to the display names.
    var worktree: RemoteWorktreeSummary? = nil
    /// The position of the console's tab in its worktree's tab strip. Panes
    /// of one split tab share it and are listed in pane order. Nil from an
    /// older host.
    var tabIndex: Int? = nil
}

struct PeerConsoleControl: Codable, Equatable, Sendable {
    enum Owner: String, Codable, Sendable {
        case host
        /// The peer this message is addressed to.
        case you
        case anotherPeer
    }

    enum Change: String, Codable, Sendable {
        case current, granted, denied, released, reclaimed, revoked
    }

    let owner: Owner
    /// Lease generation; input must carry the generation it was granted.
    let generation: Int
    let change: Change
}

enum PeerConsoleSnapshotReason: String, Codable, Sendable {
    case initial
    /// The peer fell behind; pending output was discarded and replaced.
    case peerBackpressure
    /// The peer asked for one after a sequence gap.
    case requested
}

enum PeerConsoleDetachReason: String, Codable, Sendable {
    /// The viewer detached.
    case detached
    /// Missing, exited, ineligible, or unknown console.
    case unavailable
    /// The console's process or zmx session ended while attached.
    case targetExited
    /// The running zmx daemon predates `Capture`; restarting the console fixes it.
    case restartRequired
    /// This host does not serve peer consoles to this connection.
    case unauthorized
    /// Too many attachments are open from this connection or in total.
    case limitReached
    case protocolError
    case localOverflow
    case unknown

    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// Peer → host.
enum PeerConsoleRequest: Codable, Equatable, Sendable {
    case list
    case attach(consoleId: String, attachmentId: String, scrollbackRows: Int)
    case takeControl(attachmentId: String)
    case releaseControl(attachmentId: String)
    /// Raw bytes for the console's PTY, accepted only from the current lease
    /// holder at the current generation. `sequence` is echoed in `inputAck`.
    case input(attachmentId: String, generation: Int, sequence: Int, data: Data)
    /// Sent after a sequence gap: the host replaces the stream with a snapshot.
    case resync(attachmentId: String)
    case detach(attachmentId: String)
}

/// Host → peer.
enum PeerConsoleEvent: Codable, Equatable, Sendable {
    case list(consoles: [PeerConsoleSummary])
    /// The host owns `rows` × `columns`; the viewer fits, crops, or scrolls.
    case attached(attachmentId: String, rows: Int, columns: Int, control: PeerConsoleControl)
    /// Replaces all prior screen state. Following output continues at
    /// `sequence + 1`.
    case snapshot(attachmentId: String, sequence: Int, reason: PeerConsoleSnapshotReason, data: Data)
    case output(attachmentId: String, sequence: Int, data: Data)
    case control(attachmentId: String, control: PeerConsoleControl)
    /// Accepted means relayed to the console, not executed by it.
    case inputAck(attachmentId: String, sequence: Int, accepted: Bool)
    case geometry(attachmentId: String, rows: Int, columns: Int)
    case detached(attachmentId: String, reason: PeerConsoleDetachReason)
}

extension PeerConsoleEvent {
    /// Nil for `list`, which is not attachment scoped.
    var attachmentId: String? {
        switch self {
        case .list: nil
        case .attached(let id, _, _, _), .snapshot(let id, _, _, _), .output(let id, _, _), .control(let id, _),
             .inputAck(let id, _, _), .geometry(let id, _, _), .detached(let id, _):
            id
        }
    }
}
