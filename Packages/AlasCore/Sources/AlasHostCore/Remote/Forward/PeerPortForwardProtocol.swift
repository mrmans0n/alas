import Foundation

/// Forwarding a host run's loopback endpoint to a paired Mac: TCP streams
/// relayed over the peer connection. The Mac names a run by its
/// `RunRecord.id`, never a host or a port; the host resolves the port from
/// its own run store. Carried as `RemoteClientMessage.portForward` and
/// `RemoteServerMessage.portForward`, which older peers skip as unknown types.
///
/// Flow control is explicit both ways: each side may send at most `window`
/// unacknowledged bytes per stream, and returns `credit` as it writes the
/// bytes it received to its socket. A side with no window left stops reading
/// its socket; a side that sends beyond its window loses the stream.
public enum PeerPortForwardCapability: Sendable {
    /// Advertised in `hello` by hosts that forward run endpoints. v1 pins
    /// `PeerPortForwardLimits`' default `window` and `maxChunk` on both ends;
    /// changing either needs a new capability.
    public static let v1 = "host.runs.forward.v1"
}

/// `window` and `maxChunk` are part of `PeerPortForwardCapability.v1`: both
/// ends assume the defaults, so changing them needs a new capability.
public struct PeerPortForwardLimits: Equatable, Sendable {
    /// Unacknowledged bytes either side may send on one stream.
    public var window: Int
    /// Largest `data` payload.
    public var maxChunk: Int
    /// A browser opens several connections per origin, plus a hot-reload
    /// socket, so these sit above the console attachment caps.
    public var maxStreamsPerRun: Int
    public var maxStreamsPerConnection: Int
    public var maxStreamsTotal: Int

    public init(window: Int = 512 * 1024, maxChunk: Int = 64 * 1024, maxStreamsPerRun: Int = 16, maxStreamsPerConnection: Int = 32, maxStreamsTotal: Int = 64) {
        self.window = window
        self.maxChunk = maxChunk
        self.maxStreamsPerRun = maxStreamsPerRun
        self.maxStreamsPerConnection = maxStreamsPerConnection
        self.maxStreamsTotal = maxStreamsTotal
    }
}

/// Mac → host.
public enum PeerPortForwardRequest: Codable, Equatable, Sendable {
    /// Dials the loopback endpoint of `runID` (a `RunRecord.id`) on the host.
    /// The Mac sends nothing else on `stream` until `opened`.
    case open(stream: UUID, runID: String)
    case data(stream: UUID, bytes: Data)
    /// The Mac wrote `bytes` the host sent to its socket.
    case credit(stream: UUID, bytes: Int)
    case close(stream: UUID)
}

/// Host → Mac.
public enum PeerPortForwardEvent: Codable, Equatable, Sendable {
    case opened(stream: UUID)
    /// `open` failed; the message is shown to the user as is.
    case refused(stream: UUID, message: String)
    case data(stream: UUID, bytes: Data)
    /// The host wrote `bytes` the Mac sent to the run's socket.
    case credit(stream: UUID, bytes: Int)
    /// The run's socket ended, the run stopped, or the Mac broke the protocol.
    case closed(stream: UUID)
}

public enum PeerPortForwardEndpoint: Sendable {
    /// Whether a run's endpoint names this machine's loopback, so a peer may
    /// forward it. Deliberately narrower than `RunEndpointPolicy.isLoopback`:
    /// a wildcard address like `0.0.0.0` is not a place to dial.
    public static func isLoopback(_ url: URL) -> Bool {
        url.host.map(isLoopbackHost) ?? false
    }

    /// `localhost`, `127.0.0.1`, or `::1` with or without brackets.
    public static func isLoopbackHost(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(dialHost(host))
    }

    /// The host as `NWEndpoint.Host` takes it: lowercased, without IPv6 brackets.
    static func dialHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}
