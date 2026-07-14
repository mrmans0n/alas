import Darwin
import Foundation

enum JSONRPCFraming {
    case contentLength   // LSP-style "Content-Length: N\r\n\r\n<body>"
    case newline         // ACP-style one-JSON-object-per-line
}

protocol JSONRPCStdioTransporting: AnyObject, Sendable {
    var incoming: AsyncStream<JSONRPCStdioTransport.Incoming> { get }
    var requestIDPrefix: String? { get }
    func start() throws
    func send(_ data: Data) throws
    func send(_ data: Data, onWritten: @escaping @Sendable () -> Void) throws
    func terminate()
}

extension JSONRPCStdioTransporting {
    var requestIDPrefix: String? { nil }

    func send(_ data: Data, onWritten: @escaping @Sendable () -> Void) throws {
        try send(data)
        onWritten()
    }
}

final class JSONRPCStdioTransport: @unchecked Sendable, JSONRPCStdioTransporting {
    enum Incoming: Sendable {
        case frame(Data, onConsumed: (@Sendable () -> Void)? = nil)
        case stderr(Data)
        case exited(Int32)
    }

    private struct DescendantKey: Hashable {
        let pid: pid_t
        let startedAt: ProcessStartTime
    }

    private struct ProcessStartTime: Hashable, Sendable {
        let seconds: Int64
        let microseconds: Int64
    }

    private struct ProcessIdentity: Sendable {
        let parentPid: pid_t
        let startedAt: ProcessStartTime
    }

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let framing: JSONRPCFraming
    private var contentLengthFramer = JSONRPCFramer()
    private var newlineFramer = JSONRPCNewlineFramer()
    private let lock = NSLock()
    private let refreshLock = NSLock()
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
            self.continuation?.yield(.exited(p.terminationStatus))
            self.continuation?.finish()
        }
        try process.run()
        // Move the child into its own process group so signals from
        // `terminate()` can be delivered to the whole tree via
        // `kill(-pid, …)`. Foundation's Process doesn't expose
        // POSIX_SPAWN_SETPGROUP, so we race the child via the parent —
        // either side may EACCES once exec completes, but at least one
        // of those two calls succeeds and the child ends up as group
        // leader. Same pattern as `ACPTerminal`.
        _ = setpgid(process.processIdentifier, process.processIdentifier)
        startDescendantForkObserver(for: process.processIdentifier)
        refreshLock.lock()
        let initialDescendants = Set(Self.collectChildDescendants(of: process.processIdentifier))
        mergeInitialOrphanSet(initialDescendants)
        refreshLock.unlock()
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
        cancelDescendantForkObservers()
        let pid = process.processIdentifier
        guard pid > 0 else { return }
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
        descendantTracker = Task.detached(priority: .utility) { [weak self] in
            // Walk the live process tree every second while the root is
            // alive, accumulating every descendant we observe. The last
            // pre-exit snapshot is what `terminate()` relies on after
            // the kernel reparents children to init.
            while !Task.isCancelled {
                guard let self else { return }
                self.lock.lock()
                let shouldStop = self.rootHasExited
                self.lock.unlock()
                if shouldStop { return }
                self.refreshOrphanSet()
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
        let rootPid = process.processIdentifier
        var watched = Set(descendants.map(\.pid))
        if rootPid > 0 { watched.insert(rootPid) }
        pruneDescendantForkObservers(keeping: watched)
    }

    private func mergeInitialOrphanSet(_ descendants: Set<DescendantKey>) {
        guard !descendants.isEmpty else { return }
        lock.lock()
        let shouldObserve = !rootHasExited
        if shouldObserve {
            orphanedDescendants.formUnion(descendants)
        }
        lock.unlock()
        if shouldObserve {
            observeForks(from: descendants)
        }
    }

    private func refreshOrphanSet() {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        lock.lock()
        let shouldStop = rootHasExited
        lock.unlock()
        guard !shouldStop, process.isRunning else { return }

        let pid = process.processIdentifier
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "pid=,ppid=", "-ax"]
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
        var childrenOf: [pid_t: [pid_t]] = [:]
        for line in s.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            let parts = trimmed.split(separator: " ", maxSplits: 1,
                                      omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            childrenOf[ppid, default: []].append(pid)
        }
        var out: [DescendantKey] = []
        var queue: [pid_t] = [root]
        while let p = queue.popLast() {
            for c in childrenOf[p] ?? [] {
                guard let identity = processIdentity(of: c),
                      identity.parentPid == p else { continue }
                out.append(DescendantKey(pid: c, startedAt: identity.startedAt))
                queue.append(c)
            }
        }
        return out
    }

    /// Lightweight startup snapshot. Unlike `collectDescendants`, this
    /// uses libproc's ppid index instead of spawning `/bin/ps -ax`, so
    /// `start()` can capture immediate descendants before returning
    /// without blocking the main actor on a subprocess process-table walk.
    private static func collectChildDescendants(of root: pid_t) -> [DescendantKey] {
        var out: [DescendantKey] = []
        var queue: [pid_t] = [root]
        while let parent = queue.popLast() {
            for child in childPids(of: parent) {
                guard let identity = processIdentity(of: child),
                      identity.parentPid == parent else { continue }
                out.append(DescendantKey(pid: child, startedAt: identity.startedAt))
                queue.append(child)
            }
        }
        return out
    }

    private static func childPids(of parent: pid_t) -> [pid_t] {
        var capacity = 16
        while capacity <= 4096 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let pidCount = pids.withUnsafeMutableBufferPointer { buffer in
                proc_listchildpids(parent, buffer.baseAddress,
                                   Int32(capacity * MemoryLayout<pid_t>.stride))
            }
            guard pidCount > 0 else { return [] }
            let count = min(capacity, Int(pidCount))
            if count < capacity {
                return Array(pids.prefix(count)).filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
    }

    private static func currentlyMatching(_ keys: Set<DescendantKey>) -> Set<DescendantKey> {
        guard !keys.isEmpty else { return [] }
        var current: Set<DescendantKey> = []
        for key in keys {
            guard processStartTime(of: key.pid) == key.startedAt else { continue }
            current.insert(key)
        }
        return current
    }

    private static func processStartTime(of pid: pid_t) -> ProcessStartTime? {
        processIdentity(of: pid)?.startedAt
    }

    /// Kernel process birth time, used as the stable half of cached
    /// descendant identity. Unlike `ps lstart`, this is raw timeval
    /// data rather than a locale/timezone-formatted, second-precision
    /// wall-clock string.
    private static func processIdentity(of pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: size) { rebound in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, rebound, Int32(size))
            }
        }
        guard result == Int32(size) else { return nil }
        return ProcessIdentity(
            parentPid: pid_t(info.pbi_ppid),
            startedAt: ProcessStartTime(seconds: Int64(info.pbi_start_tvsec),
                                        microseconds: Int64(info.pbi_start_tvusec))
        )
    }
}
