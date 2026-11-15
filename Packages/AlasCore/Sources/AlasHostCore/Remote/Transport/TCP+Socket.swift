import Foundation
import AlasFoundation

/// A nonblocking socket and the dispatch sources watching it. Closes the
/// descriptor once no source still refers to it. Used only on `queue`.
private final class SocketHandle {
    let fd: Int32
    private var sources: [DispatchSourceProtocol] = []
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        NoSigPipe.socket(fd)
    }

    /// Runs `handler` each time the socket is readable (or writable), until
    /// the returned source is cancelled.
    func watch(_ kind: Kind, queue: DispatchQueue, handler: @escaping () -> Void) -> DispatchSourceProtocol {
        let source: DispatchSourceProtocol = switch kind {
        case .read: DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        case .write: DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        }
        sources.append(source)
        source.setEventHandler(handler: handler)
        let id = ObjectIdentifier(source as AnyObject)
        // Strong: the handle must outlive its sources to close the descriptor
        // after the last one lets go. Removing the source breaks the cycle.
        source.setCancelHandler { [self] in
            sources.removeAll { ObjectIdentifier($0 as AnyObject) == id }
            closeIfDone()
        }
        source.resume()
        return source
    }

    func close() {
        guard !closed else { return }
        closed = true
        if sources.isEmpty {
            Foundation.close(fd)
        } else {
            sources.forEach { $0.cancel() }
        }
    }

    private func closeIfDone() {
        if closed, sources.isEmpty { Foundation.close(fd) }
    }

    enum Kind {
        case read, write
    }
}

/// `TCPStream` over a socket: what platforms without Network.framework use.
/// Built everywhere so its tests run everywhere.
/// `@unchecked Sendable`: everything after `start` runs on `queue`.
final class SocketTCPStream: TCPStream, @unchecked Sendable {
    private enum Origin {
        case accepted(Int32)
        case dial(host: String, port: UInt16)
    }

    private struct PendingSend {
        var data: Data
        let completion: (@Sendable (Error?) -> Void)?
    }

    private let origin: Origin
    private var queue: DispatchQueue!
    private var onState: (@Sendable (TCPStreamState) -> Void)?
    private var handle: SocketHandle?
    private var reader: DispatchSourceProtocol?
    private var writer: DispatchSourceProtocol?
    private var sends: [PendingSend] = []
    private var finishing: (@Sendable () -> Void)?
    private var cancelled = false

    init(fd: Int32) {
        origin = .accepted(fd)
    }

    init(host: String, port: UInt16) {
        origin = .dial(host: host, port: port)
    }

    func start(queue: DispatchQueue, onState: @escaping @Sendable (TCPStreamState) -> Void) {
        self.queue = queue
        self.onState = onState
        queue.async { [self] in
            switch origin {
            case .accepted(let fd):
                handle = SocketHandle(fd: fd)
                onState(.ready)
            case .dial(let host, let port):
                dial(Self.addresses(host: host, port: port)[...])
            }
        }
    }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        queue.async { [self] in
            guard let handle, !cancelled, reader == nil else { return }
            reader = handle.watch(.read, queue: queue) { [weak self] in
                guard let self, let handle = self.handle else { return }
                var buffer = [UInt8](repeating: 0, count: max(1, maximumLength))
                let count = buffer.withUnsafeMutableBytes { Foundation.read(handle.fd, $0.baseAddress, $0.count) }
                if count < 0, errno == EAGAIN || errno == EINTR { return }
                reader?.cancel()
                reader = nil
                if count > 0 {
                    completion(Data(buffer[..<count]), false, nil)
                } else if count == 0 {
                    completion(nil, true, nil)
                } else {
                    completion(nil, true, POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                }
            }
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            guard !cancelled else { return }
            sends.append(PendingSend(data: data, completion: completion))
            flush()
        }
    }

    func finish(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !cancelled else { return completion() }
            finishing = completion
            flush()
        }
    }

    func cancel() {
        queue?.async { [self] in
            guard !cancelled else { return }
            cancelled = true
            sends.removeAll()
            handle?.close()
            handle = nil
            reader = nil
            writer = nil
            onState?(.cancelled)
        }
    }

    /// Writes queued sends in order; waits for writability when the socket is full.
    private func flush() {
        guard let handle, !cancelled else { return }
        while var next = sends.first {
            let written = next.data.withUnsafeBytes { Foundation.write(handle.fd, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EAGAIN || errno == EINTR {
                    if writer == nil {
                        writer = handle.watch(.write, queue: queue) { [weak self] in self?.flush() }
                    }
                    return
                }
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                let failed = sends
                sends.removeAll()
                failed.forEach { $0.completion?(error) }
                return
            }
            next.data.removeFirst(written)
            if next.data.isEmpty {
                sends.removeFirst()
                next.completion?(nil)
            } else {
                sends[0] = next
            }
        }
        writer?.cancel()
        writer = nil
        if let finishing {
            self.finishing = nil
            shutdown(handle.fd, Int32(SHUT_WR))
            finishing()
        }
    }

    // MARK: Connecting

    private func dial(_ addresses: ArraySlice<SocketAddress>) {
        guard !cancelled else { return }
        guard let address = addresses.first else {
            return onState?(.failed(POSIXError(.ECONNREFUSED))) ?? ()
        }
        let fd = socket(address.family, streamSocketType, 0)
        guard fd >= 0 else { return dial(addresses.dropFirst()) }
        let handle = SocketHandle(fd: fd)
        let result = address.withSockaddr { Foundation.connect(fd, $0, $1) }
        if result == 0 {
            return connected(handle)
        }
        guard errno == EINPROGRESS else {
            handle.close()
            return dial(addresses.dropFirst())
        }
        var waiting: DispatchSourceProtocol?
        waiting = handle.watch(.write, queue: queue) { [weak self] in
            waiting?.cancel()
            waiting = nil
            guard let self, !cancelled else { return handle.close() }
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
            if failure == 0 {
                connected(handle)
            } else {
                handle.close()
                dial(addresses.dropFirst())
            }
        }
    }

    private func connected(_ handle: SocketHandle) {
        guard !cancelled else { return handle.close() }
        self.handle = handle
        onState?(.ready)
        flush()
    }

    private static func addresses(host: String, port: UInt16) -> [SocketAddress] {
        var hints = addrinfo()
        hints.ai_socktype = streamSocketType
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(list) }
        return sequence(first: first, next: { $0.pointee.ai_next }).compactMap { SocketAddress($0.pointee) }
    }
}

/// `TCPListener` over a socket: what platforms without Network.framework use.
final class SocketTCPListener: TCPListener, @unchecked Sendable {
    private let host: TCPHost
    private let port: UInt16
    private var queue: DispatchQueue?
    private var handle: SocketHandle?
    private var cancelled = false
    private var onState: (@Sendable (TCPListenerState) -> Void)?

    init(host: TCPHost, port: UInt16) {
        self.host = host
        self.port = port
    }

    func start(
        queue: DispatchQueue,
        onState: @escaping @Sendable (TCPListenerState) -> Void,
        onConnection: @escaping @Sendable (any TCPStream) -> Void
    ) {
        self.queue = queue
        self.onState = onState
        queue.async { [self] in
            guard !cancelled else { return }
            let bound: (SocketHandle, UInt16)
            do {
                bound = try bind()
            } catch {
                return onState(.failed(error))
            }
            handle = bound.0
            _ = bound.0.watch(.read, queue: queue) { [weak self] in
                guard let self, let handle = self.handle else { return }
                while true {
                    let client = accept(handle.fd, nil, nil)
                    guard client >= 0 else { return }
                    onConnection(SocketTCPStream(fd: client))
                }
            }
            onState(.ready(port: bound.1))
        }
    }

    func cancel() {
        queue?.async { [self] in
            guard !cancelled else { return }
            cancelled = true
            handle?.close()
            handle = nil
            onState?(.cancelled)
        }
    }

    private func bind() throws -> (SocketHandle, UInt16) {
        let address: SocketAddress = switch host {
        case .any: .ipv6Any(port: port)
        case .loopbackV4: .ipv4Loopback(port: port)
        case .loopbackV6: .ipv6Loopback(port: port)
        }
        let fd = socket(address.family, streamSocketType, 0)
        guard fd >= 0 else { throw Self.posixError() }
        let handle = SocketHandle(fd: fd)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        if address.family == AF_INET6 {
            // `::` takes IPv4 too; `::1` stays IPv6 so `127.0.0.1` can share its port.
            var v6Only: Int32 = host == .any ? 0 : 1
            setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
        }
        guard address.withSockaddr({ Foundation.bind(fd, $0, $1) }) == 0, listen(fd, 128) == 0 else {
            let error = Self.posixError()
            handle.close()
            throw error
        }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (handle, SocketAddress(storage: storage)?.port ?? port)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// An IPv4 or IPv6 socket address.
private enum SocketAddress {
    case v4(sockaddr_in)
    case v6(sockaddr_in6)

    var family: Int32 {
        switch self {
        case .v4: AF_INET
        case .v6: AF_INET6
        }
    }

    var port: UInt16 {
        switch self {
        case .v4(let address): UInt16(bigEndian: address.sin_port)
        case .v6(let address): UInt16(bigEndian: address.sin6_port)
        }
    }

    static func ipv4Loopback(port: UInt16) -> SocketAddress {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        return .v4(address)
    }

    static func ipv6Any(port: UInt16) -> SocketAddress {
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        return .v6(address)
    }

    static func ipv6Loopback(port: UInt16) -> SocketAddress {
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_loopback
        return .v6(address)
    }

    init?(_ info: addrinfo) {
        guard let raw = info.ai_addr else { return nil }
        switch info.ai_family {
        case AF_INET: self = .v4(UnsafeRawPointer(raw).loadUnaligned(as: sockaddr_in.self))
        case AF_INET6: self = .v6(UnsafeRawPointer(raw).loadUnaligned(as: sockaddr_in6.self))
        default: return nil
        }
    }

    init?(storage: sockaddr_storage) {
        var storage = storage
        switch Int32(storage.ss_family) {
        case AF_INET: self = .v4(withUnsafeBytes(of: &storage) { $0.loadUnaligned(as: sockaddr_in.self) })
        case AF_INET6: self = .v6(withUnsafeBytes(of: &storage) { $0.loadUnaligned(as: sockaddr_in6.self) })
        default: return nil
        }
    }

    func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        switch self {
        case .v4(var address):
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        case .v6(var address):
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
    }
}
