import Darwin
import Foundation

final class AgentHookSocketServer {
    private(set) var socketPath: String?
    private var listenTask: Task<Void, Never>?
    var onEvent: ((AgentHookEvent) -> Void)?
    var onCLIRequest: ((AlasCLIRequest) async -> AlasCLIResponse)?

    static let maxPayloadSize = 65_536

    init(socketPath: String) {
        unlink(socketPath)
        guard startListening(path: socketPath) else { return }
        self.socketPath = socketPath
    }

    convenience init(uid: uid_t = getuid(), pid: pid_t = ProcessInfo.processInfo.processIdentifier) {
        let directory = "/tmp/alas-\(uid)"
        guard Self.prepareSocketDirectory(directory, ownerUid: uid) else {
            self.init(socketPath: "/dev/null")
            return
        }
        Self.sweepStaleSockets(in: directory)
        let path = "\(directory)/pid-\(pid)"
        self.init(socketPath: path)
    }

    /// Ensures `path` is a real directory (no symlink) owned by `ownerUid`
    /// with mode `0700`. Refuses to use it otherwise: another local user
    /// could pre-create a world-writable `/tmp/alas-<uid>` for our predictable
    /// UID and then connect to our `pid-<pid>` socket to spoof hook events,
    /// driving false UI state and notifications.
    static func prepareSocketDirectory(_ path: String, ownerUid: uid_t) -> Bool {
        var st = Darwin.stat()
        if Darwin.lstat(path, &st) != 0 {
            guard mkdir(path, 0o700) == 0 else { return false }
            guard Darwin.lstat(path, &st) == 0 else { return false }
        }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let modeBits = st.st_mode & 0o777
        return isDir
            && st.st_uid == ownerUid
            && (modeBits & 0o077) == 0
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
                await self?.acceptAndHandle(socketFD: socketFD)
            }
        }
        return true
    }

    private func acceptAndHandle(socketFD: Int32) async {
        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else { return }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let data = Self.readPayload(from: clientFD) else {
            close(clientFD)
            return
        }

        if Self.payloadKind(data) == "cli" {
            guard let request = try? AlasCLIRequest.decode(from: data) else {
                Self.sendResponse(clientFD: clientFD, ok: false, error: "Malformed request.")
                return
            }
            let response: AlasCLIResponse
            if let handler = onCLIRequest {
                response = await handler(request)
            } else {
                response = .error("Alas CLI is not available.")
            }
            Self.sendResponse(clientFD: clientFD, response: response)
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

    private static func payloadKind(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["kind"] as? String
    }

    static func readPayload(from clientFD: Int32) -> Data? {
        // Read in chunks; after each chunk, try to parse what we have as
        // JSON. As soon as it parses, return — this avoids waiting for the
        // client to close (or the SO_RCVTIMEO to fire). macOS `nc` doesn't
        // half-close on stdin EOF without `-N` (which it doesn't support
        // anyway), so each hook would otherwise wait the full `-w1`
        // second per invocation, adding ~1s of latency to every Claude
        // prompt/tool/stop event.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxPayloadSize {
            let bytesRead = read(clientFD, &buffer, buffer.count)
            if bytesRead < 0 {
                guard errno == EINTR else { return nil }
                continue
            }
            if bytesRead == 0 { return data.isEmpty ? nil : data }
            data.append(contentsOf: buffer.prefix(bytesRead))
            // Cheap parse probe: if the bytes form a complete JSON object
            // already, we're done. Malformed bytes won't parse and we keep
            // reading.
            if !data.isEmpty, (try? JSONSerialization.jsonObject(with: data)) != nil {
                return data
            }
        }
        return nil
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

    private static func sendResponse(clientFD: Int32, response: AlasCLIResponse) {
        do {
            let data = try response.encode()
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                _ = Darwin.write(clientFD, base, data.count)
            }
        } catch {
            let fallback = #"{"ok":false,"error":"Malformed response."}"#.data(using: .utf8)!
            fallback.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                _ = Darwin.write(clientFD, base, fallback.count)
            }
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
        guard bindResult == 0 else { close(socketFD)
        return -1 }
        guard listen(socketFD, 8) == 0 else { close(socketFD)
        return -1 }
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
