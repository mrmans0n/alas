import Foundation

/// What the remote server and port forwarding need from TCP, so they run on
/// Apple's Network framework where it exists and on plain sockets elsewhere.
/// Every callback arrives on the queue the stream or listener was started on.

public enum TCPHost: Sendable, Equatable {
    /// Every interface, IPv4 and IPv6.
    case any
    case loopbackV4
    case loopbackV6
}

public enum TCPStreamState: Sendable {
    case ready
    /// Couldn't connect, or the connection broke.
    case failed(Error)
    case cancelled
}

public protocol TCPStream: AnyObject, Sendable {
    func start(queue: DispatchQueue, onState: @escaping @Sendable (TCPStreamState) -> Void)
    /// Up to `maximumLength` bytes once some arrive. `isComplete` means the
    /// peer finished sending.
    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, _ isComplete: Bool, Error?) -> Void)
    /// Called once `data` is written, in order with other sends.
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    /// Ends this side of the stream after the pending sends.
    func finish(completion: @escaping @Sendable () -> Void)
    func cancel()
}

public enum TCPListenerState: Sendable {
    case ready(port: UInt16)
    case failed(Error)
    case cancelled
}

public protocol TCPListener: AnyObject, Sendable {
    func start(
        queue: DispatchQueue,
        onState: @escaping @Sendable (TCPListenerState) -> Void,
        onConnection: @escaping @Sendable (any TCPStream) -> Void
    )
    func cancel()
}

public enum TCP {
    /// Listens on `port` of `host`; 0 lets the system choose. Binding
    /// problems arrive as `.failed`.
    public static func listener(host: TCPHost, port: UInt16) throws -> any TCPListener {
        #if canImport(Network)
        try NetworkTCPListener(host: host, port: port)
        #else
        SocketTCPListener(host: host, port: port)
        #endif
    }

    /// A stream to `host`, a name or an address, tried at each of its
    /// addresses in turn.
    public static func connect(host: String, port: UInt16) -> any TCPStream {
        #if canImport(Network)
        NetworkTCPStream(host: host, port: port)
        #else
        SocketTCPStream(host: host, port: port)
        #endif
    }
}
