import Darwin
import Foundation
import os

private let hostSocketLogger = Logger(subsystem: "io.nlopez.alas", category: "HostSocket")

/// Serves the host protocol on a local Unix socket, one JSON message per
/// line. The socket sits in this user's owner-only runtime directory, is
/// itself owner-only, and refuses a peer running as anyone else; each
/// connection's caller is the user the socket reports for it.
///
/// `@unchecked Sendable`: the accept loop and each connection's reads run on
/// their own threads, every write on its connection's serial queue, and the
/// protocol itself on the main actor. The only state shared across them is
/// `isStopped`, under `lock`.
public final class HostSocketServer: @unchecked Sendable {
    public let path: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var isStopped = false
    private let server: HostProtocolServer
    /// A line longer than this ends the connection rather than growing a buffer.
    static let maxLineBytes = 1 << 20

    /// Where this profile's host socket lives.
    public static func defaultPath(uid: uid_t = getuid(), profile: AlasProfile = .current) -> String {
        (profile.runtimeDirectory?.path ?? "/tmp/alas-\(uid)") + "/host.sock"
    }

    /// Starts serving at `path`, or returns nil when it cannot: the directory
    /// is not this user's own, or another live host already serves the path.
    @MainActor
    public init?(path: String = HostSocketServer.defaultPath(), server: HostProtocolServer) {
        let directory = (path as NSString).deletingLastPathComponent
        guard AgentHookSocketServer.prepareSocketDirectory(directory, ownerUid: getuid()) else {
            hostSocketLogger.error("Host socket directory \(directory, privacy: .public) is not private to this user")
            return nil
        }
        if Self.connect(to: path) {
            hostSocketLogger.info("Another host already serves \(path, privacy: .public)")
            return nil
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, Self.withAddress(path, { bind(fd, $0, $1) }) == 0,
              chmod(path, 0o600) == 0, listen(fd, 16) == 0
        else {
            if fd >= 0 { close(fd) }
            hostSocketLogger.error("Could not listen on \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        self.path = path
        self.listenFD = fd
        self.server = server
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// Stops accepting and removes the socket file. Open connections end when
    /// their clients do.
    public func stop() {
        lock.withLock {
            guard !isStopped else { return }
            isStopped = true
            unlink(path)
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
        }
    }

    private var stopped: Bool { lock.withLock { isStopped } }

    private func acceptLoop() {
        while !stopped {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            var uid = uid_t(0)
            var gid = gid_t(0)
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let connection = HostSocketConnection(fd: client)
            Task { @MainActor [server] in
                connection.serve(server.connect(caller: .localUser(uid: uid), send: connection.write))
            }
        }
    }

    /// Whether something accepts connections at `path` now.
    static func connect(to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withAddress(path) { Darwin.connect(fd, $0, $1) } == 0
    }

    static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            errno = ENAMETOOLONG
            return -1
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

/// One client of the host socket: reads lines on its own thread and hands
/// each message to the protocol; writes one line per message, in order.
final class HostSocketConnection: @unchecked Sendable {
    private let fd: Int32
    private let writes = DispatchQueue(label: "io.nlopez.alas.host-socket-write")
    private let lock = NSLock()
    private var isClosed = false

    init(fd: Int32) {
        self.fd = fd
    }

    /// Reads until the client goes away, then ends `connection`.
    @MainActor
    func serve(_ connection: HostProtocolConnection) {
        Thread.detachNewThread { [self] in
            readLoop { message in
                Task { @MainActor in await connection.receive(message) }
            } onInvalid: { reason in
                Task { @MainActor in
                    await self.write(.response(id: 0, result: .failure(error: .invalidRequest(reason: reason))))
                }
            }
            Task { @MainActor in
                connection.close()
                self.closeSocket()
            }
        }
    }

    /// Returns once the line is written, or the client is gone.
    @MainActor
    func write(_ message: HostServerMessage) async {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(UInt8(ascii: "\n"))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            writes.async { [self] in
                defer { done.resume() }
                guard !lock.withLock({ isClosed }) else { return }
                data.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                        if written < 0 {
                            if errno == EINTR { continue }
                            return
                        }
                        offset += written
                    }
                }
            }
        }
    }

    private func readLoop(onMessage: (HostClientMessage) -> Void, onInvalid: (String) -> Void) {
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let decoder = JSONDecoder()
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: chunk[0 ..< count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex ..< newline]
                pending.removeSubrange(pending.startIndex ... newline)
                guard !line.isEmpty else { continue }
                do {
                    onMessage(try decoder.decode(HostClientMessage.self, from: line))
                } catch {
                    onInvalid("Not a host protocol message: \(error.localizedDescription)")
                }
            }
            if pending.count > HostSocketServer.maxLineBytes { return }
        }
    }

    private func closeSocket() {
        writes.async { [self] in
            lock.withLock { isClosed = true }
            close(fd)
        }
    }
}
