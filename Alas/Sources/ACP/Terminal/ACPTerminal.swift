import Foundation
import Combine

/// Wraps one agent-spawned subprocess. Owns the merged stdout+stderr
/// rolling buffer (capped at 1 MiB), captures the exit status, and
/// publishes a "buffer changed" signal so UI subscribers can re-render
/// the live tail without polling.
@MainActor
final class ACPTerminal: ObservableObject {
    /// 1 MiB internal cap. Independent from the agent-supplied
    /// `outputByteLimit`, which only governs what we return via
    /// `terminal/output` — never how much we keep around for the UI.
    static let internalBufferCap = 1 << 20

    let id: String
    let createdAt: Date
    let outputByteLimit: Int

    @Published private(set) var buffer: Data = Data()
    @Published private(set) var truncated: Bool = false
    @Published private(set) var exitStatus: ACPTerminalExitStatus?
    /// Flipped by `release()`. The host uses this to reject further
    /// `terminal/*` protocol calls against this id while still letting
    /// the UI render the retained buffer.
    private(set) var released: Bool = false
    var onExit: (() -> Void)?

    private let process: Process
    private let pipe: Pipe
    private var exitWaiters: [CheckedContinuation<ACPTerminalExitStatus, Never>] = []
    /// True once the readability handler has observed an empty chunk —
    /// the canonical EOF signal. `handleExit` polls this before
    /// publishing `exitStatus` so a fast-exiting command's final bytes
    /// land in the buffer before `wait_for_exit` waiters resume.
    private var sawEOF: Bool = false
    /// Set as soon as `terminationHandler` fires. We can't trust
    /// `process.isRunning` after that — the OS may reuse the root pid
    /// for an unrelated process, and `isRunning` polls by pid. Used by
    /// `kill()` to decide whether it's still safe to signal the root.
    nonisolated(unsafe) private var rootHasExited: Bool = false
    /// `(pid, command)` pairs accumulated by the periodic tracker
    /// while the root is alive. Needed because `terminationHandler`
    /// runs after the kernel has already reaped the root and
    /// reparented its children to init — a fresh ppid walk from the
    /// root pid would then return nothing, so a later `kill()` could
    /// never reach a backgrounded child that holds the pipe open.
    /// The command name lets us re-verify the PID still belongs to
    /// our terminal before signaling it late (PID reuse is rare on
    /// macOS over a few-second window but not impossible).
    private var orphanedDescendants: Set<DescendantKey> = []
    private var descendantTracker: Task<Void, Never>?

    struct DescendantKey: Hashable {
        let pid: pid_t
        let command: String
    }

    init(id: String,
         command: String,
         args: [String],
         env: [String: String],
         cwd: String,
         outputByteLimit: Int) throws
    {
        self.id = id
        self.createdAt = Date()
        // Cap against the internal buffer so an agent can't ask us to
        // return more than we ever retain. Floor at 1 so callers that
        // pass 0 or negative don't trip divide-by-zero / nonsense math
        // downstream — but otherwise honor the requested limit, even
        // when it's very small (agents may deliberately request a tight
        // tail). Per ACP `outputByteLimit` contract.
        self.outputByteLimit = max(1, min(outputByteLimit, Self.internalBufferCap))

        self.process = Process()
        self.pipe = Pipe()
        // Spawn via /usr/bin/env so bare commands (npm, cargo, etc.) are
        // resolved against PATH. Foundation's Process only looks at the
        // exact URL otherwise, which would fail every non-absolute command
        // the agent sends. `--` stops env's option parsing so a command
        // that looks like a flag still works.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["--", command] + args
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = pipe
        process.standardError = pipe
        // Detach from the controlling terminal's stdin so the child can't
        // try to read from our parent's stdin handle if Foundation defaults
        // to inheriting it.
        process.standardInput = FileHandle.nullDevice

        let weakSelf = WeakBox(self)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // Empty chunk = EOF on the read end (every writer fd
                // closed). Signal the exit path; further callbacks
                // won't fire after this.
                Task { @MainActor in
                    weakSelf.value?.signalEOF()
                }
                return
            }
            Task { @MainActor in
                weakSelf.value?.appendChunk(chunk)
            }
        }
        process.terminationHandler = { proc in
            // Mark the root as exited synchronously here so any kill()
            // call that races ahead of the @MainActor handleExit Task
            // already sees the flag and skips signaling rootPid.
            weakSelf.value?.rootHasExited = true
            let status: ACPTerminalExitStatus
            if proc.terminationReason == .uncaughtSignal {
                status = ACPTerminalExitStatus(exitCode: nil, signal: Self.signalName(proc.terminationStatus))
            } else {
                status = ACPTerminalExitStatus(exitCode: Int(proc.terminationStatus), signal: nil)
            }
            Task { @MainActor in
                await weakSelf.value?.handleExit(status: status)
            }
        }
        try process.run()
        startDescendantTracker()
        // Move the child into its own process group so signals from
        // `kill()` can be delivered to the whole tree via `kill(-pid, …)`.
        // Foundation's Process doesn't expose POSIX_SPAWN_SETPGROUP, so
        // we race the child via the parent — either side may EACCES once
        // exec completes, but at least one of those two calls succeeds
        // and the child ends up as group leader.
        _ = setpgid(process.processIdentifier, process.processIdentifier)
    }

    func waitForExit() async -> ACPTerminalExitStatus {
        if let s = exitStatus { return s }
        return await withCheckedContinuation { cont in
            exitWaiters.append(cont)
        }
    }

    func kill() {
        let pid = process.processIdentifier
        // `pid > 0` guards against signalling pid 0 (our own group)
        // when the process never launched. We intentionally do NOT
        // gate on exitStatus — a release()/killAll() after the EOF
        // timeout fired still needs to reach orphan descendants we
        // captured in the tracker. signalTargets handles the stale-
        // rootPid risk via `rootHasExited` and stale-descendant risk
        // via per-PID command-name validation.
        guard pid > 0 else { return }
        let rootAlive = !rootHasExited
        // Union of: live ppid walk (works while root is alive) +
        // tracker-accumulated snapshot (catches descendants spawned
        // while the root was still alive but reparented after exit).
        var initial = Set(Self.collectDescendants(of: pid))
        for d in orphanedDescendants { initial.insert(d) }
        signalTargets(rootPid: pid, rootAlive: rootAlive, descendants: initial, signal: SIGTERM)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            var union = initial
            for d in Self.collectDescendants(of: pid) { union.insert(d) }
            for d in self.orphanedDescendants { union.insert(d) }
            self.signalTargets(rootPid: pid, rootAlive: !self.rootHasExited,
                               descendants: union, signal: SIGKILL)
        }
    }

    /// Sends `signal` to root + descendants when the root is still
    /// alive, or only to descendants when it has already exited. In
    /// the root-exited path, per-PID identity is re-checked via the
    /// captured command name so we don't signal an unrelated process
    /// that the OS has reused a descendant PID for.
    private func signalTargets(rootPid: pid_t, rootAlive: Bool,
                               descendants: Set<DescendantKey>, signal: Int32)
    {
        if rootAlive {
            // Root is alive → process group signal reaches the whole
            // tree, no identity check needed.
            _ = Darwin.kill(-rootPid, signal)
            _ = Darwin.kill(rootPid, signal)
            for d in descendants { _ = Darwin.kill(d.pid, signal) }
        } else {
            for d in descendants where Self.pidStillMatches(d) {
                _ = Darwin.kill(d.pid, signal)
            }
        }
    }

    private func startDescendantTracker() {
        descendantTracker = Task { @MainActor [weak self] in
            // Walk the live process tree every second while the root is
            // alive, accumulating every descendant we observe. The last
            // pre-exit snapshot is what `kill()` relies on after
            // terminationHandler runs (children are reparented to init
            // by then and unfindable via a ppid walk from the root).
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshOrphanSet()
                if !self.process.isRunning { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func refreshOrphanSet() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        for d in Self.collectDescendants(of: pid) {
            orphanedDescendants.insert(d)
        }
    }

    /// Sends `signal` to the root pid, its process group, and every
    /// supplied descendant pid. The group signal succeeds when the
    /// parent-side `setpgid` won the race against the child's `exec`
    /// (often loses on macOS, since Foundation's Process can't pass
    /// POSIX_SPAWN_SETPGROUP). The descendant list is the fallback.
    /// Per-pid kills are no-ops for already-dead/unrelated PIDs.

    nonisolated private static func collectDescendants(of root: pid_t) -> [DescendantKey] {
        // `comm=` is the executable name (no header). It's stable
        // across reads of the same process and changes when the PID is
        // reused, so it's a cheap identity marker for late validation.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "pid=,ppid=,comm=", "-ax"]
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
        var childrenOf: [pid_t: [(pid: pid_t, command: String)]] = [:]
        for line in s.split(separator: "\n") {
            // pid, ppid, then command (which may contain spaces).
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
    nonisolated private static func pidStillMatches(_ key: DescendantKey) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(key.pid)", "-o", "comm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        guard let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) else { return false }
        let current = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !current.isEmpty && current == key.command
    }

    /// Marks the terminal as released. Per the ACP spec the id can no
    /// longer be used with `terminal/*` methods, but tool calls that
    /// already reference it MUST keep rendering the captured output —
    /// so the buffer is retained. The readability handler is left
    /// installed so the killed process's `handleExit` can still observe
    /// the EOF empty-chunk and publish `exitStatus`; otherwise the
    /// terminal would never finalize and would count as live against
    /// `maxLiveTerminals` indefinitely.
    func release() {
        released = true
        kill()
    }

    /// Returns the last `byteLimit` bytes of the buffer as ANSI-stripped
    /// text. The slice start is normalized to a parser-safe boundary:
    /// 1. Extended backwards through any unterminated ANSI escape in a
    ///    short lookback window so the parser doesn't treat the tail of
    ///    a cut `ESC[31m…` as plain text.
    /// 2. Then advanced past any leading UTF-8 continuation bytes so
    ///    multibyte codepoints aren't split mid-sequence.
    func snapshot(byteLimit: Int) -> (text: String, truncated: Bool) {
        let limit = max(1, min(byteLimit, Self.internalBufferCap))
        let didTruncate = buffer.count > limit
        let slice: Data
        if didTruncate {
            let all = [UInt8](buffer)
            var start = all.count - limit
            // Lookback for an unterminated CSI escape. CSI param bytes
            // are 0x30..0x3F; finals are 0x40..0x7E. If we find an ESC
            // within 16 bytes of the cut whose final hasn't yet been
            // seen, extend the slice start back to include it.
            let lookbackFloor = max(0, start - 16)
            var i = start - 1
            while i >= lookbackFloor {
                if all[i] == 0x1B {
                    var hasFinal = false
                    if i + 1 < start, all[i + 1] == 0x5B {
                        for k in (i + 2) ..< start where all[k] >= 0x40 && all[k] <= 0x7E {
                            hasFinal = true
                            break
                        }
                    } else {
                        hasFinal = true  // 2-char ESC (already complete) or OSC (handled by parser)
                    }
                    if !hasFinal { start = i }
                    break
                }
                i -= 1
            }
            // Skip leading UTF-8 continuation bytes (10xxxxxx).
            while start < all.count, (all[start] & 0xC0) == 0x80 {
                start += 1
            }
            slice = Data(all[start ..< all.count])
        } else {
            slice = buffer
        }
        // Strip ANSI for the JSON response (agents shouldn't see escape codes).
        var stream = ANSIStream()
        let runs = stream.feed(slice)
        let text = runs.map(\.text).joined()
        return (text, truncated || didTruncate)
    }

    // MARK: - Helpers

    private func appendChunk(_ chunk: Data) {
        buffer.append(chunk)
        if buffer.count > Self.internalBufferCap {
            let drop = buffer.count - Self.internalBufferCap
            buffer.removeFirst(drop)
            // The bulk drop may have landed mid-codepoint. Advance the
            // start past any leading UTF-8 continuation bytes so the
            // buffer always begins on a valid character boundary —
            // snapshot/output paths can then trust the invariant even
            // when no further truncation is needed at read time.
            while let first = buffer.first, (first & 0xC0) == 0x80 {
                buffer.removeFirst(1)
            }
            // The drop may have ALSO landed mid-ANSI-escape. Unlike
            // snapshot, we can't look backwards for the ESC byte (it
            // was just removed), so strip any leading partial CSI tail
            // heuristically: `[param-bytes]* m` is by far the common
            // case (SGR color codes). Conservative — only acts on a
            // leading run of digits/`;`/`:` followed by `m` within a
            // short window. Cursor-move finals are intentionally NOT
            // included to avoid eating bytes like `12A` in real text.
            stripLeadingPartialSGR()
            truncated = true
        }
    }

    private func stripLeadingPartialSGR() {
        var n = 0
        while n < min(buffer.count, 16) {
            let b = buffer[buffer.startIndex + n]
            if (b >= 0x30 && b <= 0x3F) {  // CSI param byte
                n += 1
                continue
            }
            if b == 0x6D, n > 0 {  // 'm' final after at least one param
                n += 1
                break
            }
            n = 0
            break
        }
        if n > 0 { buffer.removeFirst(n) }
    }

    private func handleExit(status: ACPTerminalExitStatus) async {
        descendantTracker?.cancel()
        // Close the parent-side write end so the read end can EOF after
        // the kernel buffer drains. `Pipe()` retains both ends; if we
        // leave the write end open, the readability handler's final
        // empty-chunk EOF never fires. The child's own write fd was
        // closed by the kernel when it exited.
        try? pipe.fileHandleForWriting.close()
        // Wait up to 5 s for the readability handler to deliver every
        // buffered byte and the empty-chunk EOF marker. The dispatch
        // source runs on a separate queue, so a `Task.yield()` isn't
        // enough — we have to actually wait for event delivery. Bound
        // the wait so a backgrounded descendant that inherited the
        // pipe and held it open indefinitely can't permanently leak
        // the terminal slot. The periodic descendant tracker is
        // best-effort and can't always catch children spawned in the
        // microseconds before the root exits.
        let deadline = ContinuousClock.now + .milliseconds(5000)
        while !sawEOF, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        exitStatus = status
        onExit?()
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for c in waiters { c.resume(returning: status) }
    }

    /// Called by the readability handler when an empty chunk arrives
    /// (every writer fd closed = EOF). The polling loop in `handleExit`
    /// observes this flag and proceeds to publish `exitStatus`.
    private func signalEOF() {
        sawEOF = true
    }

    nonisolated private static func signalName(_ raw: Int32) -> String {
        switch raw {
        case SIGTERM: return "SIGTERM"
        case SIGKILL: return "SIGKILL"
        case SIGINT: return "SIGINT"
        case SIGHUP: return "SIGHUP"
        case SIGSEGV: return "SIGSEGV"
        default: return "SIG\(raw)"
        }
    }
}

/// Weak indirection for the readability handler / termination
/// handler, which both fire on background queues and might outlive
/// the terminal briefly.
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
