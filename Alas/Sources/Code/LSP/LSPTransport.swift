import Foundation

/// Abstraction over the live `LSPTransport` so tests can inject a fake.
/// Marked `Sendable` because `LSPClient` (an actor) holds a reference and
/// calls into it across async boundaries; the concrete `LSPTransport` is
/// `@unchecked Sendable` because the actor is the sole owner that mutates it.
protocol LSPTransporting: AnyObject, Sendable {
    var incoming: AsyncStream<LSPTransport.Incoming> { get }
    func start() throws
    func send(_ data: Data) throws
    func terminate()
}

/// Owns a `Process` running an LSP server and exposes async send/receive.
/// `incoming` emits raw JSON Data per-frame; the client decodes them.
///
/// `@unchecked Sendable`: mutable internals (Process, Pipe, decoder buffer)
/// are not sent across threads concurrently — the owning `LSPClient` actor
/// serializes all access; readability handlers run on the pipe queue but only
/// touch `decoder` under `lock` and emit via the AsyncStream continuation.
final class LSPTransport: @unchecked Sendable {
    enum Incoming: Sendable {
        case frame(Data)
        case stderr(Data)
        case exited(Int32)
    }

    private struct DescendantKey: Hashable {
        let pid: pid_t
        let command: String
    }

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var decoder = JSONRPCFramer()
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

    init(executable: URL, arguments: [String], environment: [String: String]?) {
        var cont: AsyncStream<Incoming>.Continuation!
        self.incoming = AsyncStream { c in cont = c }
        self.continuation = cont
        process.executableURL = executable
        process.arguments = arguments
        // Always inherit the parent environment, then overlay user values on
        // top — assigning `process.environment` directly to the user's dict
        // wipes `PATH`, `HOME`, developer-tool variables, etc., so a config
        // that only sets one flag would also stop `/usr/bin/env` from
        // resolving Homebrew-installed servers.
        if let env = environment {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            process.environment = merged
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { return }
            self.lock.lock()
            self.decoder.append(data)
            let frames = self.decoder.drainFrames()
            self.lock.unlock()
            for f in frames { self.continuation?.yield(.frame(f)) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.continuation?.yield(.stderr(data))
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

    /// Writes a JSON-RPC body framed with `Content-Length`. Header and body
    /// must reach stdin contiguously; concurrent callers would interleave
    /// the two writes and corrupt the stream. This class does not lock —
    /// the only sender is `LSPClient` (an actor), which already serializes.
    func send(_ data: Data) throws {
        let framed = JSONRPCFramer.encode(data)
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
        // `comm=` is the executable name (no header). It's stable across
        // reads of the same process and changes when the PID is reused,
        // so it's a cheap identity marker for late validation.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "pid=,ppid=,comm=", "-ax"]
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
        var childrenOf: [pid_t: [(pid: pid_t, command: String)]] = [:]
        for line in s.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            let parts = trimmed.split(separator: " ", maxSplits: 2,
                                      omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            childrenOf[ppid, default: []].append((pid, String(parts[2])))
        }
        var out: [DescendantKey] = []
        var queue: [pid_t] = [root]
        while let p = queue.popLast() {
            for c in childrenOf[p] ?? [] {
                out.append(DescendantKey(pid: c.pid, command: c.command))
                queue.append(c.pid)
            }
        }
        return out
    }

    /// Returns true when the current command for `pid` matches the
    /// command captured when we recorded it. Used to skip stale cached
    /// PIDs whose original process has exited and whose PID may have
    /// been reused for an unrelated process.
    private static func pidStillMatches(_ key: DescendantKey) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(key.pid)", "-o", "comm="]
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
        let current = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !current.isEmpty && current == key.command
    }
}

extension LSPTransport: LSPTransporting {}
