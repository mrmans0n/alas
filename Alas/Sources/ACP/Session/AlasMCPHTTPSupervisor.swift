import Foundation

/// Spawns and supervises `alas mcp --http` processes — one per http-transport
/// ACP session. Each process binds an ephemeral localhost port and prints
/// `PORT <n>`; we capture it and hand back the endpoint the injection layer
/// turns into an http MCP wire entry. Main-actor: created/queried from AppState.
@MainActor
final class AlasMCPHTTPSupervisor {
    struct Running {
        let process: Process
        let port: Int
        let token: String
    }
    private var running: [String: Running] = [:]

    /// Parse the `PORT <n>` announcement the server prints on startup.
    nonisolated static func parsePort(from line: String) -> Int? {
        let parts = line.split(separator: " ")
        guard parts.count == 2, parts[0] == "PORT", let port = Int(parts[1]) else { return nil }
        return port
    }

    /// Return a live endpoint for `sessionId`, spawning the process if needed.
    /// Returns nil if spawning fails or no port is announced in time — the
    /// caller then falls back to stdio.
    func endpoint(
        binaryPath: String,
        socketPath: String,
        worktreePath: String,
        sessionId: String,
        parentSessionId: String?,
        workspaceOnly: Bool = false
    ) async -> BuiltInAlasMCP.HTTPEndpoint? {
        if let existing = running[sessionId], existing.process.isRunning {
            return BuiltInAlasMCP.HTTPEndpoint(
                url: "http://localhost:\(existing.port)/mcp", token: existing.token)
        }
        running[sessionId] = nil

        let token = UUID().uuidString
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["mcp", "--http"]
        process.environment = Self.environment(
            base: ProcessInfo.processInfo.environment,
            socketPath: socketPath,
            worktreePath: worktreePath,
            sessionId: sessionId,
            token: token,
            parentSessionId: parentSessionId,
            workspaceOnly: workspaceOnly
        )

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read the first line (the PORT announcement) off the pipe, bounded by a
        // short timeout so a wedged process can't hang the attach. On timeout the
        // reader is unblocked by terminating the process (see readPortLine).
        let port = await Self.readPortLine(from: stdoutPipe, process: process, timeout: .seconds(5))
        guard let port else {
            process.terminate()
            return nil
        }
        running[sessionId] = Running(process: process, port: port, token: token)
        return BuiltInAlasMCP.HTTPEndpoint(url: "http://localhost:\(port)/mcp", token: token)
    }

    func end(sessionId: String) {
        if let running = running[sessionId] {
            running.process.terminate()
        }
        running[sessionId] = nil
    }

    func shutdown() {
        for (_, r) in running { r.process.terminate() }
        running.removeAll()
    }

    nonisolated static func environment(
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
