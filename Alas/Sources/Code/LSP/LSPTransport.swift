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

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var decoder = JSONRPCFramer()
    private let lock = NSLock()
    private var continuation: AsyncStream<Incoming>.Continuation?
    /// True once the root process has exited so `terminate()` can skip
    /// signalling a stale pid the OS may have reused. Set synchronously
    /// in the termination handler.
    private var rootHasExited = false

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
        process.terminationHandler = { [weak self] proc in
            self?.rootHasExited = true
            self?.continuation?.yield(.exited(proc.terminationStatus))
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

    /// Writes a JSON-RPC body framed with `Content-Length`. Header and body
    /// must reach stdin contiguously; concurrent callers would interleave
    /// the two writes and corrupt the stream. This class does not lock —
    /// the only sender is `LSPClient` (an actor), which already serializes.
    func send(_ data: Data) throws {
        let framed = JSONRPCFramer.encode(data)
        try stdin.fileHandleForWriting.write(contentsOf: framed)
    }

    func terminate() {
        guard !rootHasExited else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        // Signal the whole process group so descendants receive the
        // signal even when the root doesn't forward it. Per-pid signal
        // as a fallback for the case where `setpgid` lost the race
        // against exec. Same pattern as `JSONRPCStdioTransport` and
        // `ACPTerminal`.
        _ = Darwin.kill(-pid, SIGTERM)
        if process.isRunning { process.terminate() }
    }
}

extension LSPTransport: LSPTransporting {}
