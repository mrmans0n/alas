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
        let startedAt: String
    }

    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    /// Set by `start()`.
    private var process: SpawnedProcess?
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var decoder = JSONRPCFramer()
    private let lock = NSLock()
    private let refreshLock = NSLock()
    /// Serializes stderr reads, so the termination drain cannot overtake a
    /// readability callback that already read bytes but has not yielded them.
    /// Guards `stderrDrained`.
    private let stderrLock = NSLock()
    /// Set by the drain, which leaves the descriptor non-blocking: a callback
    /// that was already queued must not read it again.
    private var stderrDrained = false
    private var continuation: AsyncStream<Incoming>.Continuation?
    /// Set once the termination handler fires. We can't rely on
    /// `process.isRunning` after that — the OS may reuse the root pid
    /// for an unrelated process.
    private var rootHasExited = false
    /// `(pid, start time)` entries accumulated by the periodic descendant
    /// tracker while the root is alive. Needed because the
    /// termination handler runs after the kernel has reaped the root and
    /// reparented its children to init, so a fresh ppid walk from the root
    /// pid returns nothing. The start time lets us re-verify a cached PID
    /// still belongs to the same process before signaling it late.
    private var orphanedDescendants: Set<DescendantKey> = []
    private var descendantTracker: Task<Void, Never>?
    private var descendantForkSources: [pid_t: DispatchSourceProcess] = [:]

    let incoming: AsyncStream<Incoming>

    init(executable: URL, arguments: [String], environment: [String: String]?) {
        var cont: AsyncStream<Incoming>.Continuation!
        self.incoming = AsyncStream { c in cont = c }
        self.continuation = cont
        self.executable = executable
        self.arguments = arguments
        // Always inherit the parent environment, then overlay user values on
        // top — using the user's dict alone would wipe `PATH`, `HOME`,
        // developer-tool variables, etc., so a config that only sets one flag
        // would also stop `/usr/bin/env` from resolving Homebrew-installed
        // servers.
        self.environment = ProcessInfo.processInfo.environment.merging(environment ?? [:]) { $1 }
    }

    func start() throws {
        // A server can close stdin before its exit event reaches the client.
        // Keep EPIPE as a thrown write error, without changing process signals.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { return }
            self.lock.lock()
            self.decoder.append(data)
            let frames = self.decoder.drainFrames()
            let failed = self.decoder.hasFailed
            self.lock.unlock()
            if failed {
                self.continuation?.finish()
                self.terminate()
                return
            }
            for f in frames { self.continuation?.yield(.frame(f)) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.stderrLock.lock()
            defer { self.stderrLock.unlock() }
            guard !self.stderrDrained else { return }
            let data = handle.availableData
            if data.isEmpty { return }
            self.continuation?.yield(.stderr(data))
        }
        // The child leads its own process group from the spawn, so signals
        // from `terminate()` reach the whole tree via `kill(-pid, …)`.
        let process = try SpawnedProcess(
            executable: executable, arguments: arguments, environment: environment,
            stdin: stdin, stdout: stdout, stderr: stderr
        ) { [weak self] pid, termination in
            guard let self else { return }
            if pid > 0 {
                // Last chance to reach same-group descendants that were
                // spawned after the most recent tracker tick. Later shutdown
                // paths avoid group signaling once the root pid can be stale.
                _ = Darwin.kill(-pid, SIGTERM)
            }
            self.refreshLock.lock()
            self.lock.lock()
            let cachedTargets = self.orphanedDescendants
            self.rootHasExited = true
            self.lock.unlock()
            self.refreshLock.unlock()
            self.cancelDescendantForkObservers()
            for d in Self.currentlyMatching(cachedTargets) {
                _ = Darwin.kill(d.pid, SIGTERM)
            }
            self.drainStderr()
            self.continuation?.yield(.exited(termination.status))
            self.continuation?.finish()
        }
        self.process = process
        startDescendantForkObserver(for: process.pid)
        refreshOrphanSet()
        startDescendantTracker()
    }

    /// The readability callback is asynchronous to the exit: a message written
    /// just before the child died can still be sitting in the pipe when the
    /// exit is reported. Yield it first, so the client's stderr tail is
    /// complete when it records the exit. Reads only what is already buffered:
    /// a descendant may still hold the write end open, so waiting for EOF
    /// could block forever.
    private func drainStderr() {
        stderr.fileHandleForReading.readabilityHandler = nil
        stderrLock.lock()
        defer { stderrLock.unlock() }
        stderrDrained = true
        let drained = Self.drainBuffered(descriptor: stderr.fileHandleForReading.fileDescriptor)
        if !drained.isEmpty { continuation?.yield(.stderr(drained)) }
    }

    /// Reads what is buffered on `descriptor` and returns at once, even when
    /// another process still holds the write end open. Leaves the descriptor
    /// non-blocking. The client keeps only a short tail, so a flood from a
    /// surviving descendant is not worth reading past `limit`.
    static func drainBuffered(descriptor: Int32, limit: Int = 256 * 1024) -> Data {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return Data() }
        var drained = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while drained.count < limit {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count > 0 {
                drained.append(chunk, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        return drained
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
        cancelDescendantForkObservers()
        guard let process, process.pid > 0 else { return }
        let pid = process.pid
        refreshLock.lock()
        lock.lock()
        let rootAlive = !rootHasExited
        let targets = orphanedDescendants
        lock.unlock()
        refreshLock.unlock()

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
            for d in Self.currentlyMatching(cachedTargets.subtracting(liveDescendants)) {
                _ = Darwin.kill(d.pid, SIGTERM)
            }
        } else {
            // Root has already exited: the process group may have been
            // reused by an unrelated process, so we only signal cached
            // descendants whose process identity still matches.
            for d in Self.currentlyMatching(targets) {
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
                let shouldStop = self.lock.withLock { self.rootHasExited }
                if shouldStop { return }
                // Each refresh spawns `ps`; keep that off the cooperative pool.
                await BlockingWork.run { self.refreshOrphanSet() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func startDescendantForkObserver(for pid: pid_t) {
        guard pid > 0 else { return }
        lock.lock()
        let alreadyWatching = descendantForkSources[pid] != nil
        lock.unlock()
        if alreadyWatching { return }

        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .fork,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.refreshOrphanSet()
        }
        lock.lock()
        if descendantForkSources[pid] == nil, !rootHasExited {
            descendantForkSources[pid] = source
            lock.unlock()
            source.resume()
            return
        }
        lock.unlock()
        source.resume()
        source.cancel()
    }

    private func cancelDescendantForkObservers() {
        lock.lock()
        let sources = Array(descendantForkSources.values)
        descendantForkSources.removeAll()
        lock.unlock()
        for source in sources {
            source.cancel()
        }
    }

    private func pruneDescendantForkObservers(keeping pids: Set<pid_t>) {
        lock.lock()
        let stale = descendantForkSources.keys.filter { !pids.contains($0) }
        let sources = stale.compactMap { descendantForkSources.removeValue(forKey: $0) }
        lock.unlock()
        for source in sources {
            source.cancel()
        }
    }

    private func observeForks(from descendants: Set<DescendantKey>) {
        for pid in descendants.map(\.pid) {
            startDescendantForkObserver(for: pid)
        }
        let rootPid = process?.pid ?? 0
        var watched = Set(descendants.map(\.pid))
        if rootPid > 0 { watched.insert(rootPid) }
        pruneDescendantForkObservers(keeping: watched)
    }

    private func refreshOrphanSet() {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        lock.lock()
        let shouldStop = rootHasExited
        lock.unlock()
        guard !shouldStop, let process, process.isRunning else { return }

        let pid = process.pid
        guard pid > 0 else { return }
        let live = Set(Self.collectDescendants(of: pid))
        lock.lock()
        let cached = orphanedDescendants
        lock.unlock()
        let retained = Self.currentlyMatching(cached)
        let watched = retained.union(live)
        lock.lock()
        orphanedDescendants.subtract(cached.subtracting(retained))
        orphanedDescendants.formUnion(live)
        let shouldObserve = !rootHasExited
        lock.unlock()
        if shouldObserve {
            observeForks(from: watched)
        }
    }

    /// Walks the live process tree collecting every descendant of `root`.
    /// Returns the list immediately; once the root exits the kernel
    /// reparents children to init so they become unfindable via a ppid
    /// walk from the original root.
    private static func collectDescendants(of root: pid_t) -> [DescendantKey] {
        // `lstart` makes the cached PID identity stable across PID reuse
        // while still surviving exec, where `comm` can legitimately change.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "pid=,ppid=,lstart=", "-ax"]
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
        var childrenOf: [pid_t: [(pid: pid_t, startedAt: String)]] = [:]
        for line in s.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            let parts = trimmed.split(separator: " ", maxSplits: 6,
                                      omittingEmptySubsequences: true)
            guard parts.count >= 7,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            let startedAt = parts[2...6].joined(separator: " ")
            childrenOf[ppid, default: []].append((pid, startedAt))
        }
        var out: [DescendantKey] = []
        var queue: [pid_t] = [root]
        while let p = queue.popLast() {
            for c in childrenOf[p] ?? [] {
                out.append(DescendantKey(pid: c.pid, startedAt: c.startedAt))
                queue.append(c.pid)
            }
        }
        return out
    }

    private static func currentlyMatching(_ keys: Set<DescendantKey>) -> Set<DescendantKey> {
        guard !keys.isEmpty else { return [] }
        let pids = Set(keys.map(\.pid))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "pid=,lstart=", "-ax"]
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
        var current: Set<DescendantKey> = []
        for line in s.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            let parts = trimmed.split(separator: " ", maxSplits: 5,
                                      omittingEmptySubsequences: true)
            guard parts.count >= 6,
                  let pid = pid_t(parts[0]),
                  pids.contains(pid) else { continue }
            current.insert(DescendantKey(pid: pid,
                                         startedAt: parts[1...5].joined(separator: " ")))
        }
        return current.intersection(keys)
    }
}

extension LSPTransport: LSPTransporting {}
