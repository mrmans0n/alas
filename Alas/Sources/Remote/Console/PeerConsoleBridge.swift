import Darwin
import Foundation

/// Local byte pipe between Alas and the Ghostty surface that renders a
/// remote console.
///
/// Ghostty only renders bytes produced by a child process on its PTY, so the
/// surface runs `nc -U` against a single-use Unix socket in a private
/// directory. Bytes written here appear on the surface; bytes Ghostty writes
/// to its PTY (keys, paste, terminal replies) come back through `onInput`.
/// The command never starts a shell or a zmx session.
final class PeerConsoleBridge: @unchecked Sendable {
    let socketPath: String
    private let directory: String
    private let listener: Int32
    private let writes = DispatchQueue(label: "io.nlopez.alas.peer-console.bridge")
    private let lock = NSLock()
    private var connection: Int32 = -1
    private var queued: [Data] = []
    private var isClosed = false

    /// The command line the surface runs. The socket path is passed as `$0`
    /// so it never needs quoting inside the script.
    var command: (executable: String, args: [String]) {
        ("/bin/sh", ["-c", "stty raw -echo && exec /usr/bin/nc -U \"$0\"", socketPath])
    }

    /// `onInput` runs on a background thread with bytes the surface wrote.
    init(onInput: @escaping @Sendable (Data) -> Void) throws {
        var template = Array("/tmp/alas-pc.XXXXXX".utf8CString)
        guard let dir = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directory = String(cString: dir)
        let path = directory + "/s"
        self.directory = directory
        socketPath = path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard fd >= 0, bound == 0, listen(fd, 1) == 0 else {
            let code = errno
            if fd >= 0 { Darwin.close(fd) }
            try? FileManager.default.removeItem(atPath: directory)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        listener = fd
        let thread = Thread { [self] in acceptAndRead(onInput: onInput) }
        thread.name = "peer-console-bridge"
        thread.start()
    }

    /// Queues bytes for the surface, in order. Bytes written before `nc`
    /// connects are delivered once it does.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writes.async { [self] in
            lock.lock()
            let fd = connection
            if fd < 0, !isClosed { queued.append(data) }
            lock.unlock()
            if fd >= 0 { Self.writeAll(fd, data) }
        }
    }

    /// Ends the surface's `nc` and removes the socket directory.
    func close() {
        lock.lock()
        let first = !isClosed
        isClosed = true
        let fd = connection
        lock.unlock()
        guard first else { return }
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func acceptAndRead(onInput: @Sendable (Data) -> Void) {
        let fd = accept(listener, nil, nil)
        // Single use: nothing else may connect once the surface has.
        unlink(socketPath)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        writes.sync {
            lock.lock()
            let closed = isClosed
            if !closed { connection = fd }
            let backlog = queued
            queued = []
            lock.unlock()
            if !closed { backlog.forEach { Self.writeAll(fd, $0) } }
        }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                onInput(Data(buffer[0..<n]))
            } else if n < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        writes.sync {
            lock.withLock { connection = -1 }
            Darwin.close(fd)
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { return }
            }
        }
    }

    deinit { close() }
}
