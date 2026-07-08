import Foundation

enum JSONRPCFraming {
    case contentLength   // LSP-style "Content-Length: N\r\n\r\n<body>"
    case newline         // ACP-style one-JSON-object-per-line
}

protocol JSONRPCStdioTransporting: AnyObject, Sendable {
    var incoming: AsyncStream<JSONRPCStdioTransport.Incoming> { get }
    func start() throws
    func send(_ data: Data) throws
    func terminate()
}

final class JSONRPCStdioTransport: @unchecked Sendable, JSONRPCStdioTransporting {
    enum Incoming: Sendable {
        case frame(Data)
        case stderr(Data)
        case exited(Int32)
    }

    private struct DescendantKey: Hashable {
        let pid: pid_t
        let pgid: pid_t
        let startedAt: String
        let command: String
    }

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let framing: JSONRPCFraming
    private var contentLengthFramer = JSONRPCFramer()
    private var newlineFramer = JSONRPCNewlineFramer()
    private let lock = NSLock()
    private var continuation: AsyncStream<Incoming>.Continuation?
    /// Set once the termination handler fires. We can't rely on
    /// `process.isRunning` after that — the OS may reuse the root pid
    /// for an unrelated process.
    private var rootHasExited = false
    /// `(pid, command)` pairs accumulated by the periodic descendant
    /// tracker while the root is alive. Needed because the termination
    /// handler runs after the kernel has reaped the root and reparented
    /// its children to init, so a fresh ppid walk from the root pid
    /// returns nothing. The command name lets us re-verify a cached PID
    /// still belongs to our process before signaling it late.
    private var orphanedDescendants: Set<DescendantKey> = []
    private var descendantTracker: Task<Void, Never>?
    private var descendantForkSource: DispatchSourceProcess?

    let incoming: AsyncStream<Incoming>

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        framing: JSONRPCFraming = .contentLength,
        replaceEnv: Bool = false
    ) {
        self.framing = framing
        var cont: AsyncStream<Incoming>.Continuation!
        self.incoming = AsyncStream { c in cont = c }
        self.continuation = cont
        process.executableURL = executable
        process.arguments = arguments
        if let env = environment {
            if replaceEnv {
                // Use exactly what the caller provided — used by ACP where
                // we explicitly need to *remove* env vars (CLAUDECODE etc.)
                // that the parent would otherwise inherit.
                process.environment = env
            } else {
                var merged = ProcessInfo.processInfo.environment
                for (k, v) in env { merged[k] = v }
                process.environment = merged
            }
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.lock.lock()
            let frames: [Data]
            switch self.framing {
            case .contentLength:
                self.contentLengthFramer.append(d)
                frames = self.contentLengthFramer.drainFrames()
            case .newline:
                self.newlineFramer.append(d)
                frames = self.newlineFramer.drainFrames()
            }
            self.lock.unlock()
            for f in frames { self.continuation?.yield(.frame(f)) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            self?.continuation?.yield(.stderr(d))
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            let pid = p.processIdentifier
            if pid > 0 {
                // Last chance to reach same-group descendants that were
                // spawned after the most recent tracker tick. Later shutdown
                // paths avoid group signaling once the root pid can be stale.
                _ = Darwin.kill(-pid, SIGTERM)
            }
            self.descendantForkSource?.cancel()
            self.lock.lock()
            let cachedTargets = self.orphanedDescendants
            self.rootHasExited = true
            self.lock.unlock()
            for d in cachedTargets where Self.pidStillMatches(d) {
                _ = Darwin.kill(d.pid, SIGTERM)
            }
            self.continuation?.yield(.exited(p.terminationStatus))
            self.continuation?.finish()
        }
        try process.run()
        startDescendantForkObserver()
        refreshOrphanSet()
        // Move the child into its own process group so signals from
        // `terminate()` can be delivered to the whole tree via
        // `kill(-pid, …)`. Foundation's Process doesn't expose
        // POSIX_SPAWN_SETPGROUP, so we race the child via the parent —
        // either side may EACCES once exec completes, but at least one
        // of those two calls succeeds and the child ends up as group
        // leader. Same pattern as `ACPTerminal`.
        _ = setpgid(process.processIdentifier, process.processIdentifier)
        startDescendantTracker()
    }

    func send(_ data: Data) throws {
        let framed: Data
        switch framing {
        case .contentLength: framed = JSONRPCFramer.encode(data)
        case .newline:       framed = JSONRPCNewlineFramer.encode(data)
        }
        try stdin.fileHandleForWriting.write(contentsOf: framed)
    }

    func terminate() {
        descendantTracker?.cancel()
        descendantForkSource?.cancel()
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        lock.lock()
        let rootAlive = !rootHasExited
        let targets = orphanedDescendants
        lock.unlock()

        if rootAlive {
            // Root is still alive: a process-group signal reaches the
            // whole tree. Take the fallback ppid snapshot before
            // signaling, while descendants are still parented to root.
            let cachedTargets = targets
            let liveDescendants = Set(Self.collectDescendants(of: pid))
            _ = Darwin.kill(-pid, SIGTERM)
            _ = Darwin.kill(pid, SIGTERM)
            for d in liveDescendants {
                _ = Darwin.kill(d.pid, SIGTERM)
            }
            for d in cachedTargets where !liveDescendants.contains(d) && Self.pidStillMatches(d) {
                _ = Darwin.kill(d.pid, SIGTERM)
            }
        } else {
            // Root has already exited: the process group may have been
            // reused by an unrelated process, so we only signal cached
            // descendants whose command name still matches.
            for d in targets where Self.pidStillMatches(d) {
                _ = Darwin.kill(d.pid, SIGTERM)
            }
        }

        if process.isRunning {
            process.terminate()
        }
    }

    private func startDescendantTracker() {
        descendantTracker = Task { [weak self] in
            // Walk the live process tree every second while the root is
            // alive, accumulating every descendant we observe. The last
            // pre-exit snapshot is what `terminate()` relies on after
            // the kernel reparents children to init.
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshOrphanSet()
                self.lock.lock()
                let shouldStop = self.rootHasExited
                self.lock.unlock()
                if shouldStop { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func startDescendantForkObserver() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .fork,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.refreshOrphanSet()
        }
        descendantForkSource = source
        source.resume()
    }

    private func refreshOrphanSet() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let keys = Self.collectDescendants(of: pid)
        lock.lock()
        for k in keys { orphanedDescendants.insert(k) }
        lock.unlock()
    }

    /// Walks the live process tree collecting every descendant of `root`.
    /// Returns the list immediately; once the root exits the kernel
    /// reparents children to init so they become unfindable via a ppid
    /// walk from the original root.
    private static func collectDescendants(of root: pid_t) -> [DescendantKey] {
        // `lstart` and `pgid` make the cached PID identity stable across
        // PID reuse, including common executable names like node or sh.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "pid=,ppid=,pgid=,lstart=,comm=", "-ax"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        let data: Data
        do {
            try proc.run()
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
        } catch {
            return []
        }
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        var childrenOf: [pid_t: [(pid: pid_t, pgid: pid_t, startedAt: String, command: String)]] = [:]
        for line in s.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            let parts = trimmed.split(separator: " ", maxSplits: 8,
                                      omittingEmptySubsequences: true)
            guard parts.count >= 9,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]),
                  let pgid = pid_t(parts[2]) else { continue }
            let startedAt = parts[3...7].joined(separator: " ")
            let command = String(parts[8])
            childrenOf[ppid, default: []].append((pid, pgid, startedAt, command))
        }
        var out: [DescendantKey] = []
        var queue: [pid_t] = [root]
        while let p = queue.popLast() {
            for c in childrenOf[p] ?? [] {
                out.append(DescendantKey(pid: c.pid, pgid: c.pgid,
                                         startedAt: c.startedAt, command: c.command))
                queue.append(c.pid)
            }
        }
        return out
    }

    /// Returns true when the current process identity for `pid` matches
    /// what we captured earlier. Used to skip stale cached PIDs whose
    /// original process has exited and whose PID may have been reused
    /// for an unrelated process.
    private static func pidStillMatches(_ key: DescendantKey) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(key.pid)", "-o", "pgid=,lstart=,comm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        let data: Data
        do {
            try proc.run()
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
        } catch {
            return false
        }
        guard let s = String(data: data, encoding: .utf8) else { return false }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 6,
                                  omittingEmptySubsequences: true)
        guard parts.count >= 7,
              let pgid = pid_t(parts[0]) else { return false }
        let current = (
            pgid: pgid,
            startedAt: parts[1...5].joined(separator: " "),
            command: String(parts[6])
        )
        return current.pgid == key.pgid &&
            current.startedAt == key.startedAt &&
            current.command == key.command
    }
}
