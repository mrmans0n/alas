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

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let framing: JSONRPCFraming
    private var contentLengthFramer = JSONRPCFramer()
    private var newlineFramer = JSONRPCNewlineFramer()
    private let lock = NSLock()
    private var continuation: AsyncStream<Incoming>.Continuation?
    /// True once the root process has exited so `terminate()` can skip
    /// signalling a stale pid the OS may have reused. Set synchronously
    /// in the termination handler.
    private var rootHasExited = false

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
            self?.rootHasExited = true
            self?.continuation?.yield(.exited(p.terminationStatus))
            self?.continuation?.finish()
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
        guard !rootHasExited else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        // Signal the whole process group first so descendants (node →
        // codex, node → claude, etc.) receive the signal even when the
        // root process doesn't forward it. Per-pid signal as a fallback
        // for the case where `setpgid` lost the race against exec and
        // the child never became a group leader. SIGTERM mirrors the
        // previous behaviour; SIGKILL is not used so a graceful exit
        // can flush buffered output.
        _ = Darwin.kill(-pid, SIGTERM)
        // Walk the process tree and signal any descendants the group
        // kill may have missed. On macOS, parent-side setpgid frequently
        // loses the exec race (Foundation's Process can't pass
        // POSIX_SPAWN_SETPGROUP), leaving no process group to target.
        for d in Self.collectDescendants(of: pid) {
            _ = Darwin.kill(d, SIGTERM)
        }
        if process.isRunning { process.terminate() }
    }

    /// Walks the live process tree collecting every descendant of `root`.
    /// Returns the list immediately; once the root exits the kernel
    /// reparents children to init so they become unfindable via a ppid
    /// walk from the original root.
    private static func collectDescendants(of root: pid_t) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "pid=,ppid=", "-ax"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        guard let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) else { return [] }
        var childrenOf: [pid_t: [pid_t]] = [:]
        for line in s.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1,
                                   omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            childrenOf[ppid, default: []].append(pid)
        }
        var out: [pid_t] = []
        var queue: [pid_t] = [root]
        while let p = queue.popLast() {
            for c in childrenOf[p] ?? [] {
                out.append(c)
                queue.append(c)
            }
        }
        return out
    }
}
