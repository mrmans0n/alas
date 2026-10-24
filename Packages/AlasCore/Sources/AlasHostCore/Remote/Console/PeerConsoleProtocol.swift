import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

/// Peer console traffic: viewing and controlling a host's existing
/// zmx-backed console from a paired Mac. Attachment-scoped and separate from
/// ACP sessions; routed to one verified peer, never fanned out through ACP
/// subscribers. Carried as `RemoteClientMessage.console` and
/// `RemoteServerMessage.console`, which older peers skip as unknown types.
public enum PeerConsoleCapability: Sendable {
    /// Advertised in `hello` by hosts that serve peer consoles.
    public static let v1 = "peerConsole.v1"
    /// Advertised by hosts that serve `PeerConsoleRequest.terminate`. Older
    /// hosts drop unknown console requests, so clients gate the control on it.
    public static let terminateV1 = "peerConsoleTerminate.v1"
    /// Advertised by hosts that serve `PeerConsoleRequest.open`.
    public static let openV1 = "peerConsoleOpen.v1"
    /// Advertised by hosts that apply `PeerConsoleRequest.resize`. A Mac
    /// running the app sizes its consoles from its own grid and omits it.
    public static let resizeV1 = "peerConsoleResize.v1"

    /// What a Mac running the app serves.
    public static let appHost = [v1, terminateV1, openV1]
    /// What a headless host with zmx serves.
    public static let headlessHost = [v1, terminateV1, openV1, resizeV1]
}

/// Why a host could not open a console for a peer. The message is shown to
/// the peer as is.
public struct PeerConsoleOpenError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public static let unsupported = Self("This Mac can't open terminals for a peer.")
    public static let worktreeUnavailable = Self("This worktree is no longer available on the host.")
    public static let worktreeBusy = Self("Wait for the current worktree operation to finish before opening a terminal.")
    public static let sshProject = Self("Terminals in SSH projects can't be opened from a peer.")
    public static let zmxMissing = Self(
        "zmx was not found next to alas-host or in /Applications/Alas.app, so this host can't open terminals."
    )
    public static let notStarted = Self("The terminal did not start.")
}

public struct PeerConsoleSummary: Codable, Equatable, Sendable {
    /// Opaque host-side console identifier. The host resolves it through its
    /// live terminal registry; it never names a socket, session, or command.
    public let consoleId: String
    public let title: String
    public let worktreeId: String?
    public let projectId: String?
    /// Display names; a peer may know nothing else about the worktree.
    public let projectName: String?
    public let worktreeName: String?
    public let rows: Int
    public let columns: Int
    /// Lets a peer's sidebar place a console-only worktree like a session's.
    /// Nil from an older host; rows then fall back to the display names.
    public var worktree: RemoteWorktreeSummary? = nil
    /// The position of the console's tab in its worktree's tab strip. Panes
    /// of one split tab share it and are listed in pane order. Nil from an
    /// older host.
    public var tabIndex: Int? = nil

    public init(consoleId: String, title: String, worktreeId: String?, projectId: String?, projectName: String?, worktreeName: String?, rows: Int, columns: Int, worktree: RemoteWorktreeSummary? = nil, tabIndex: Int? = nil) {
        self.consoleId = consoleId
        self.title = title
        self.worktreeId = worktreeId
        self.projectId = projectId
        self.projectName = projectName
        self.worktreeName = worktreeName
        self.rows = rows
        self.columns = columns
        self.worktree = worktree
        self.tabIndex = tabIndex
    }
}

public struct PeerConsoleControl: Codable, Equatable, Sendable {
    public enum Owner: String, Codable, Sendable {
        case host
        /// The peer this message is addressed to.
        case you
        case anotherPeer
    }

    public enum Change: String, Codable, Sendable {
        case current, granted, denied, released, reclaimed, revoked
    }

    public let owner: Owner
    /// Lease generation; input must carry the generation it was granted.
    public let generation: Int
    public let change: Change

    public init(owner: Owner, generation: Int, change: Change) {
        self.owner = owner
        self.generation = generation
        self.change = change
    }
}

public enum PeerConsoleSnapshotReason: String, Codable, Sendable {
    case initial
    /// The peer fell behind; pending output was discarded and replaced.
    case peerBackpressure
    /// The peer asked for one after a sequence gap.
    case requested
}

public enum PeerConsoleDetachReason: String, Codable, Sendable {
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
    /// A peer closed the console's tab, ending its process.
    case terminated
    case unknown

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// Peer → host.
public enum PeerConsoleRequest: Codable, Equatable, Sendable {
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
    /// Closes the console on the host as a local tab close would. Needs no
    /// attachment or lease. On success the host replies with a fresh `list`.
    case terminate(consoleId: String)
    /// Opens a new console in the host worktree `worktreeId` (`Worktree.id`).
    /// The host replies with a fresh `list`, then `opened`, or with
    /// `openFailed`. Gated on `PeerConsoleCapability.openV1`.
    case open(requestId: String, worktreeId: String)
    /// Asks the host to resize the console to the holder's grid. Accepted
    /// only from the current lease holder; viewers learn the result through
    /// `geometry`. Gated on `PeerConsoleCapability.resizeV1`.
    case resize(attachmentId: String, rows: Int, columns: Int)
}

/// Host → peer.
public enum PeerConsoleEvent: Codable, Equatable, Sendable {
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
    /// Answers `open`, after a `list` that includes the new console. Sent
    /// only to a peer that sent `open`, so older decoders never see it.
    case opened(requestId: String, consoleId: String)
    /// Answers `open` with the host's reason, shown to the user as is.
    case openFailed(requestId: String, message: String)
}

extension PeerConsoleEvent {
    /// Nil for `list`, `opened` and `openFailed`, which are not attachment
    /// scoped.
    public var attachmentId: String? {
        switch self {
        case .list, .opened, .openFailed: nil
        case .attached(let id, _, _, _), .snapshot(let id, _, _, _), .output(let id, _, _), .control(let id, _),
             .inputAck(let id, _, _), .geometry(let id, _, _), .detached(let id, _):
            id
        }
    }
}
