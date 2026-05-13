import Darwin
import Foundation

final class AgentHookSocketServer {
    private(set) var socketPath: String?
    private var listenTask: Task<Void, Never>?
    var onEvent: ((AgentHookEvent) -> Void)?

    static let maxPayloadSize = 65_536

    init(socketPath: String) {
        unlink(socketPath)
        guard startListening(path: socketPath) else { return }
        self.socketPath = socketPath
    }

    convenience init(uid: uid_t = getuid(), pid: pid_t = ProcessInfo.processInfo.processIdentifier) {
        let directory = "/tmp/alas-\(uid)"
        let created = (try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )) != nil || FileManager.default.fileExists(atPath: directory)
        guard created else {
            self.init(socketPath: "/dev/null")
            return
        }
        Self.sweepStaleSockets(in: directory)
        let path = "\(directory)/pid-\(pid)"
        self.init(socketPath: path)
    }

    static func sweepStaleSockets(in directory: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries {
            guard entry.hasPrefix("pid-"),
                  let pid = Int32(entry.dropFirst(4)) else { continue }
            guard kill(pid, 0) != 0 else { continue }
            unlink("\(directory)/\(entry)")
        }
    }

    deinit {
        listenTask?.cancel()
        if let socketPath { unlink(socketPath) }
    }

    func shutdown() {
        listenTask?.cancel()
        listenTask = nil
        if let socketPath { unlink(socketPath) }
        socketPath = nil
    }

    private func startListening(path: String) -> Bool {
        let socketFD = Self.createSocket(path: path)
        guard socketFD >= 0 else { return false }

        listenTask = Task.detached { [weak self] in
            defer { close(socketFD) }
            while !Task.isCancelled {
                var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollFD, 1, 200)
                if ready < 0 {
                    guard errno == EINTR else { break }
                    continue
                }
                guard ready > 0 else { continue }
                self?.acceptAndHandle(socketFD: socketFD)
            }
        }
        return true
    }

    private func acceptAndHandle(socketFD: Int32) {
        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else { return }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let data = Self.readPayload(from: clientFD) else {
            close(clientFD)
            return
        }

        do {
            let event = try AgentHookEvent.decode(from: data)
            Self.sendResponse(clientFD: clientFD, ok: true)
            let handler = onEvent
            DispatchQueue.main.async { handler?(event) }
        } catch is AgentHookEventError where (try? AgentHookEvent.isUnknownEvent(data)) == true {
            Self.sendResponse(clientFD: clientFD, ok: true)
        } catch {
            Self.sendResponse(clientFD: clientFD, ok: false, error: "Malformed request.")
        }
    }

    static func readPayload(from clientFD: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(clientFD, &buffer, buffer.count)
            if bytesRead < 0 {
                guard errno == EINTR else { return nil }
                continue
            }
            if bytesRead == 0 { return data }
            data.append(contentsOf: buffer.prefix(bytesRead))
            if data.count > maxPayloadSize { return nil }
        }
    }

    private static func sendResponse(clientFD: Int32, ok: Bool, error: String? = nil) {
        var json: [String: Any] = ["ok": ok]
        if let error { json["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            close(clientFD)
            return
        }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(clientFD, base, data.count)
        }
        close(clientFD)
    }

    // Serialises chdir-based socket binding to prevent races when multiple
    // sockets are created concurrently (e.g. during parallel tests).
    private static let bindLock = NSLock()

    private static func createSocket(path: String) -> Int32 {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return -1 }

        let bindResult = Self.bindSocket(socketFD, toPath: path)
        guard bindResult == 0 else { close(socketFD); return -1 }
        guard listen(socketFD, 8) == 0 else { close(socketFD); return -1 }
        return socketFD
    }

    /// Calls `bind()` on `socketFD`, handling paths that exceed `sun_path` capacity
    /// by temporarily chdiring to the directory (serialised with `bindLock`).
    private static func bindSocket(_ socketFD: Int32, toPath path: String) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = path.utf8CString

        func doBind(_ bytes: ContiguousArray<CChar>) -> Int32 {
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                bytes.withUnsafeBufferPointer { buf in
                    memcpy(sunPath, buf.baseAddress!, buf.count)
                }
            }
            let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
            return withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                    bind(socketFD, p, addrLen)
                }
            }
        }

        if pathBytes.count <= sunPathSize {
            return doBind(pathBytes)
        }

        // Path too long for sun_path: chdir into the directory and bind by filename.
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        let filenameBytes = url.lastPathComponent.utf8CString
        guard filenameBytes.count <= sunPathSize else { return -1 }

        bindLock.lock()
        defer { bindLock.unlock() }
        let savedCWD = FileManager.default.currentDirectoryPath
        guard FileManager.default.changeCurrentDirectoryPath(dir) else { return -1 }
        let result = doBind(filenameBytes)
        FileManager.default.changeCurrentDirectoryPath(savedCWD)
        return result
    }
}

extension AgentHookEvent {
    static func isUnknownEvent(_ data: Data) throws -> Bool {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventStr = json["event"] as? String,
              ActivityEvent(rawValue: eventStr) == nil else { return false }
        return true
    }
}
