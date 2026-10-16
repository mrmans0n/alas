import Darwin
import Foundation

/// Spawns and supervises `alas mcp --http` processes — one per http-transport
/// ACP session. Each process binds a localhost port and prints `PORT <n>`; we
/// capture it and hand back the endpoint the injection layer turns into an
/// http MCP wire entry. Main-actor: created/queried from AppState.
///
/// The endpoint (port and token) is remembered per session in
/// `BuiltInMCPSessionState`. An agent kept alive in its broker across an app
/// restart still holds that address, so the next launch respawns the server
/// on the same port with the same token instead of a fresh one the agent
/// would never hear about. Servers exit with the app (graceful quit or not)
/// because they watch a stdin pipe only the app holds open.
@MainActor
public final class AlasMCPHTTPSupervisor {
    private struct Running {
        let process: Process
        let port: Int
        let token: String
        /// The write end of the server's stdin. Closing it — explicitly or
        /// by the app dying — makes `--exit-with-parent` exit the server.
        let parentLink: Pipe
    }
    private var running: [String: Running] = [:]
    public let state: BuiltInMCPSessionState
    private var reapedOrphans = false

    public init(state: BuiltInMCPSessionState) {
        self.state = state
    }

    /// Parse the `PORT <n>` announcement the server prints on startup.
    public nonisolated static func parsePort(from line: String) -> Int? {
        let parts = line.split(separator: " ")
        guard parts.count == 2, parts[0] == "PORT", let port = Int(parts[1]) else { return nil }
        return port
    }

    /// Return a live endpoint for `sessionId`: the running process, a
    /// respawn at the session's remembered address, or a fresh address when
    /// that port is taken. Returns nil if spawning fails or no port is
    /// announced in time — the caller then falls back to stdio.
    public func endpoint(
        binaryPath: String,
        socketPath: String,
        worktreePath: String,
        sessionId: String,
        parentSessionId: String?,
        workspaceOnly: Bool = false
    ) async -> BuiltInAlasMCP.HTTPEndpoint? {
        if let existing = running[sessionId], existing.process.isRunning {
            return Self.endpoint(port: existing.port, token: existing.token)
        }
        running[sessionId] = nil
        reapOrphanedServersOnce(binaryPath: binaryPath)

        var attempts: [(port: Int?, token: String)] = []
        if let remembered = state.httpEndpoint(sessionId: sessionId) {
            attempts.append((remembered.port, remembered.token))
        }
        attempts.append((nil, UUID().uuidString))
        for attempt in attempts {
            let environment = Self.environment(
                base: ProcessInfo.processInfo.environment,
                socketPath: socketPath,
                worktreePath: worktreePath,
                sessionId: sessionId,
                token: attempt.token,
                parentSessionId: parentSessionId,
                workspaceOnly: workspaceOnly
            )
            guard let launched = await Self.launch(
                binaryPath: binaryPath,
                port: attempt.port,
                token: attempt.token,
                environment: environment
            ) else { continue }
            // A superseded call may have launched one meanwhile; keep one.
            if let existing = running[sessionId], existing.process.isRunning {
                launched.process.terminate()
                return Self.endpoint(port: existing.port, token: existing.token)
            }
            running[sessionId] = launched
            state.setHTTPEndpoint(.init(port: launched.port, token: launched.token), sessionId: sessionId)
            return Self.endpoint(port: launched.port, token: launched.token)
        }
        return nil
    }

    /// Stops the session's server. Its address stays remembered: an agent
    /// still running in its broker may reconnect to it on a later attach.
    public func end(sessionId: String) {
        if let running = running[sessionId] {
            running.process.terminate()
        }
        running[sessionId] = nil
    }

    public func shutdown() {
        for (_, r) in running { r.process.terminate() }
        running.removeAll()
    }

    private static func endpoint(port: Int, token: String) -> BuiltInAlasMCP.HTTPEndpoint {
        BuiltInAlasMCP.HTTPEndpoint(url: "http://localhost:\(port)/mcp", token: token)
    }

    private static func launch(
        binaryPath: String,
        port: Int?,
        token: String,
        environment: [String: String]
    ) async -> Running? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments(port: port)
        process.environment = environment

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // Close-on-exec on both ends before anything else can spawn, so no
        // other child (broker, agent, terminal) inherits the write end and
        // keeps the server alive after the app is gone. The child still gets
        // the read end as its stdin: dup2 clears the flag on fd 0.
        let parentLink = Pipe()
        _ = fcntl(parentLink.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(parentLink.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.standardInput = parentLink

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read the first line (the PORT announcement) off the pipe, bounded by a
        // short timeout so a wedged process can't hang the attach. On timeout the
        // reader is unblocked by terminating the process (see readPortLine). A
        // server that cannot bind a requested port exits without announcing.
        let announced = await readPortLine(from: stdoutPipe, process: process, timeout: .seconds(5))
        guard let announced, port == nil || announced == port else {
            process.terminate()
            return nil
        }
        return Running(process: process, port: announced, token: token, parentLink: parentLink)
    }

    nonisolated static func arguments(port: Int?) -> [String] {
        ["mcp", "--http", "--exit-with-parent"] + (port.map { ["--port", String($0)] } ?? [])
    }

    /// Servers left by app runs that predate `--exit-with-parent` were never
    /// told to stop. Reparented to launchd, they sit on localhost ports
    /// forever; a running app's own servers are never launchd's children.
    private func reapOrphanedServersOnce(binaryPath: String) {
        guard !reapedOrphans else { return }
        reapedOrphans = true
        Task.detached(priority: .utility) {
            for pid in Self.orphanedServerPIDs(binaryPath: binaryPath) {
                kill(pid, SIGTERM)
            }
        }
    }

    nonisolated private static func orphanedServerPIDs(binaryPath: String) -> [pid_t] {
        let executable = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path
        return childPIDs(of: 1).filter { pid in
            guard executablePath(of: pid) == executable,
                  let argv = arguments(of: pid)
            else { return false }
            return isHTTPServerInvocation(argv)
        }
    }

    /// `alas mcp --http …`, as opposed to the agent-owned stdio server or
    /// any other `alas` command.
    nonisolated static func isHTTPServerInvocation(_ argv: [String]) -> Bool {
        argv.count >= 3 && argv[1] == "mcp" && argv.dropFirst(2).contains("--http")
    }

    nonisolated private static func childPIDs(of parent: pid_t) -> [pid_t] {
        var capacity = 1024
        while capacity <= 65536 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBufferPointer { buffer in
                proc_listchildpids(parent, buffer.baseAddress, Int32(capacity * MemoryLayout<pid_t>.stride))
            }
            guard count > 0 else { return [] }
            if Int(count) < capacity {
                return pids.prefix(Int(count)).filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
    }

    nonisolated private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A process's argv from `KERN_PROCARGS2`: argc, the exec path, padding,
    /// then argc NUL-terminated strings.
    nonisolated private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var argv: [String] = []
        while argv.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            argv.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return argv
    }

    public nonisolated static func environment(
        base: [String: String],
        socketPath: String,
        worktreePath: String,
        sessionId: String,
        token: String,
        parentSessionId: String?,
        workspaceOnly: Bool = false
    ) -> [String: String] {
        var env = base
        env["ALAS_SOCKET_PATH"] = socketPath
        env["ALAS_WORKTREE_DIR"] = worktreePath
        env["ALAS_SESSION_ID"] = sessionId
        env["ALAS_MCP_HTTP_TOKEN"] = token
        if let parentSessionId { env["ALAS_PARENT_SESSION_ID"] = parentSessionId }
        if workspaceOnly { env["ALAS_MCP_WORKSPACE_ONLY"] = "1" }
        return env
    }

    /// Read lines from `pipe` until one parses as a PORT announcement, or the
    /// timeout elapses. Runs the blocking read off the main actor.
    ///
    /// `handle.availableData` ignores cooperative cancellation, so a plain
    /// `cancelAll()` cannot interrupt a wedged process that never prints `PORT`
    /// and never closes stdout. Instead, when the timeout fires we terminate the
    /// process and close the read handle: both force `availableData` to return
    /// empty (EOF), so the reader task finishes and the group returns promptly.
    nonisolated private static func readPortLine(
        from pipe: Pipe,
        process: Process,
        timeout: Duration
    ) async -> Int? {
        let handle = pipe.fileHandleForReading
        return await withTaskGroup(of: Int?.self) { group in
            group.addTask {
                // Blocking reads, so they run off the cooperative pool.
                await BlockingWork.run {
                    var buffer = Data()
                    while true {
                        let chunk = handle.availableData   // blocking read
                        if chunk.isEmpty { return nil }    // EOF
                        buffer.append(chunk)
                        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer[..<newlineIndex]
                            let line = String(decoding: lineData, as: UTF8.self)
                            return parsePort(from: line.trimmingCharacters(in: .whitespaces))
                        }
                    }
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Cancelled because the reader already got the port — the
                    // process is healthy; must NOT terminate it.
                    return nil
                }
                // Genuine timeout: a process that won't announce its port is
                // useless. Kill it and close the pipe so the blocking reader
                // unblocks via EOF.
                process.terminate()
                try? handle.close()
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
