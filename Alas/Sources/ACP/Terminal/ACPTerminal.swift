import Darwin
import Foundation
import Combine

/// Wraps one agent-spawned subprocess. Owns the merged stdout+stderr
/// rolling buffer (capped at 1 MiB), captures the exit status, and
/// publishes a display-rate-limited terminal tail for the transcript UI.
@MainActor
final class ACPTerminal: ObservableObject {
    /// 1 MiB protocol-output cap. Independent from the agent-supplied
    /// `outputByteLimit`; the transcript UI keeps its own smaller tail.
    static let internalBufferCap = 1 << 20
    /// The transcript row is at most 300 points tall. Retaining a 64 KiB
    /// parsed display tail gives users ample scrollback without laying out
    /// the entire protocol buffer on every refresh.
    nonisolated static let displayByteLimit = 64 << 10
    nonisolated static let displayRefreshMinInterval: TimeInterval = 1.0 / 30.0

    enum DisplayRefreshAction: Equatable {
        case publishNow
        case scheduleDrain(after: TimeInterval)
        case drop
    }

    let id: String
    let createdAt: Date
    let outputByteLimit: Int
    private let normalizesCRLF: Bool

    @Published private(set) var cwd: String?
    /// Full protocol buffer. This is intentionally not `@Published`: raw pipe
    /// chunks must not invalidate SwiftUI. `displayRevision` below is the
    /// coalesced UI signal.
    var buffer: Data { Data(bufferStorage[bufferStart...]) }
    var retainedByteCount: Int { bufferStorage.count - bufferStart }
    private var bufferStorage = Data()
    private var bufferStart = 0
    private(set) var truncated: Bool = false
    @Published private(set) var exitStatus: ACPTerminalExitStatus?
    @Published private(set) var displayRevision: UInt64 = 0
    private(set) var displayRuns: [AttributedRun] = []
    private var displayTail: ANSITailBuffer
    private var lastDisplayPublish = -Double.greatestFiniteMagnitude
    private var displayDrain: Task<Void, Never>?
    /// Flipped by `release()`. The host uses this to reject further
    /// `terminal/*` protocol calls against this id while still letting
    /// the UI render the retained buffer.
    private(set) var released: Bool = false
    var onExit: (() -> Void)?
    var isProcessBacked: Bool { process != nil }
    var isMetadataBacked: Bool { process == nil }

    private let process: Process?
    private let pipe: Pipe?
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
    /// `(pid, start time)` pairs accumulated by the periodic tracker
    /// while the root is alive. Needed because `terminationHandler`
    /// runs after the kernel has already reaped the root and
    /// reparented its children to init — a fresh ppid walk from the
    /// root pid would then return nothing, so a later `kill()` could
    /// never reach a backgrounded child that holds the pipe open.
    /// The process start time lets us re-verify the PID still belongs
    /// to our terminal before signaling it late (PID reuse is rare on
    /// macOS over a few-second window but not impossible).
    private var orphanedDescendants: Set<DescendantKey> = []
    private var descendantTracker: Task<Void, Never>?

    struct DescendantKey: Hashable, Sendable {
        let pid: pid_t
        let startedAt: ProcessStartTime
    }

    struct ProcessStartTime: Hashable, Sendable {
        let seconds: Int64
        let microseconds: Int64
    }

    private struct ProcessIdentity {
        let parentPid: pid_t
        let startedAt: ProcessStartTime
    }

    init(id: String,
         command: String,
         args: [String],
         env: [String: String],
         cwd: String,
         outputByteLimit: Int,
         normalizesCRLF: Bool = false) throws
    {
        self.id = id
        self.createdAt = Date()
        self.cwd = cwd
        self.normalizesCRLF = normalizesCRLF
        self.displayTail = ANSITailBuffer(byteLimit: Self.displayByteLimit)
        // Cap against the internal buffer so an agent can't ask us to
        // return more than we ever retain. Floor at 1 so callers that
        // pass 0 or negative don't trip divide-by-zero / nonsense math
        // downstream — but otherwise honor the requested limit, even
        // when it's very small (agents may deliberately request a tight
        // tail). Per ACP `outputByteLimit` contract.
        self.outputByteLimit = max(1, min(outputByteLimit, Self.internalBufferCap))

        let process = Process()
        let pipe = Pipe()
        self.process = process
        self.pipe = pipe
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
        installReadabilityHandler()
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

    init(metadataId id: String, cwd: String?, outputByteLimit: Int = 65_536) {
        self.id = id
        self.createdAt = Date()
        self.cwd = cwd
        self.outputByteLimit = max(1, min(outputByteLimit, Self.internalBufferCap))
        self.normalizesCRLF = false
        self.displayTail = ANSITailBuffer(byteLimit: Self.displayByteLimit)
        self.process = nil
        self.pipe = nil
    }

    func waitForExit() async -> ACPTerminalExitStatus {
        if let s = exitStatus { return s }
        return await withCheckedContinuation { cont in
            exitWaiters.append(cont)
        }
    }

    func kill() {
        guard let process else { return }
        let pid = process.processIdentifier
        // `pid > 0` guards against signalling pid 0 (our own group)
        // when the process never launched. We intentionally do NOT
        // gate on exitStatus — a release()/killAll() after the EOF
        // timeout fired still needs to reach orphan descendants we
        // captured in the tracker. signalTargets handles the stale-
        // rootPid risk via `rootHasExited` and stale-descendant risk
        // via per-PID start-time validation.
        guard pid > 0 else { return }
        // Union of: live ppid walk (works while root is alive) +
        // tracker-accumulated snapshot (catches descendants spawned
        // while the root was still alive but reparented after exit).
        let cached = orphanedDescendants
        let preKillDescendants = Set(Self.collectChildDescendants(of: pid))
        // Cheap root/process-group signal stays synchronous so a
        // just-about-to-exit root cannot reparent uncached children
        // before any cleanup signal is sent.
        let rootAliveAtKill = !rootHasExited
        if rootAliveAtKill {
            _ = Darwin.kill(-pid, SIGTERM)
            _ = Darwin.kill(pid, SIGTERM)
        }
        let strongSelf = StrongBox(self)
        Task.detached(priority: .utility) {
            var initial = preKillDescendants
            initial.formUnion(Self.collectDescendants(of: pid))
            if rootAliveAtKill {
                initial.formUnion(Self.collectGroupMembers(of: pid))
            }
            initial.formUnion(cached)
            let termRootAlive = await MainActor.run {
                !strongSelf.value.rootHasExited
            }
            Self.signalTargets(rootPid: pid, rootAlive: termRootAlive,
                               descendants: initial, signal: SIGTERM)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            var union = initial
            union.formUnion(Self.collectDescendants(of: pid))
            let latestCached = await MainActor.run {
                strongSelf.value.orphanedDescendants
            }
            union.formUnion(latestCached)
            let killRootAlive = await MainActor.run {
                !strongSelf.value.rootHasExited
            }
            Self.signalTargets(rootPid: pid, rootAlive: killRootAlive,
                               descendants: union, signal: SIGKILL)
        }
    }

    /// Sends `signal` to root + descendants when the root is still
    /// alive, or only to descendants when it has already exited. In
    /// the root-exited path, per-PID identity is re-checked via the
    /// captured start time so we don't signal an unrelated process
    /// that the OS has reused a descendant PID for.
    nonisolated private static func signalTargets(rootPid: pid_t, rootAlive: Bool,
                                                  descendants: Set<DescendantKey>, signal: Int32)
    {
        if rootAlive {
            // Root is alive → process group signal reaches the whole
            // tree, no identity check needed.
            _ = Darwin.kill(-rootPid, signal)
            _ = Darwin.kill(rootPid, signal)
            for d in descendants { _ = Darwin.kill(d.pid, signal) }
        } else {
            for d in Self.currentlyMatching(descendants) {
                _ = Darwin.kill(d.pid, signal)
            }
        }
    }

    private func startDescendantTracker() {
        guard let process else { return }
        let rootPid = process.processIdentifier
        let weakSelf = WeakBox(self)
        descendantTracker = Task.detached(priority: .utility) {
            // Walk the live process tree every second while the root is
            // alive, accumulating every descendant we observe. The last
            // pre-exit snapshot is what `kill()` relies on after
            // terminationHandler runs (children are reparented to init
            // by then and unfindable via a ppid walk from the root).
            while !Task.isCancelled {
                let shouldStop = await MainActor.run {
                    weakSelf.value?.rootHasExited ?? true
                }
                if shouldStop { return }
                let live = Set(Self.collectDescendants(of: rootPid))
                let cached = await MainActor.run {
                    weakSelf.value?.orphanedDescendants ?? []
                }
                let retained = Self.currentlyMatching(cached)
                await MainActor.run {
                    guard let terminal = weakSelf.value else { return }
                    terminal.mergeOrphanSet(cached: cached, retained: retained, live: live)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func mergeOrphanSet(cached: Set<DescendantKey>,
                                retained: Set<DescendantKey>,
                                live: Set<DescendantKey>)
    {
        orphanedDescendants.subtract(cached.subtracting(retained))
        orphanedDescendants.formUnion(live)
    }

    /// Sends `signal` to the root pid, its process group, and every
    /// supplied descendant pid. The group signal succeeds when the
    /// parent-side `setpgid` won the race against the child's `exec`
    /// (often loses on macOS, since Foundation's Process can't pass
    /// POSIX_SPAWN_SETPGROUP). The descendant list is the fallback.
    /// Per-pid kills are no-ops for already-dead/unrelated PIDs.

    nonisolated private static func collectDescendants(of root: pid_t) -> [DescendantKey] {
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
                if let startedAt = processStartTime(of: c) {
                    out.append(DescendantKey(pid: c, startedAt: startedAt))
                }
                queue.append(c)
            }
        }
        return out
    }

    /// Lightweight pre-kill fallback snapshot. Unlike `collectDescendants`,
    /// this uses libproc's ppid index instead of spawning `/bin/ps -ax`, so
    /// `kill()` can capture children before signaling a fast-exiting root
    /// without doing a full process-table scan on the main actor.
    nonisolated static func collectChildDescendants(of root: pid_t) -> [DescendantKey] {
        guard let root = processKey(of: root) else { return [] }
        return collectChildDescendants(of: root)
    }

    nonisolated static func collectChildDescendants(of root: DescendantKey) -> [DescendantKey] {
        var out: [DescendantKey] = []
        var queue: [DescendantKey] = [root]
        while let parent = queue.popLast() {
            guard processStartTime(of: parent.pid) == parent.startedAt else { continue }
            let children = childPids(of: parent.pid)
            guard processStartTime(of: parent.pid) == parent.startedAt else { continue }
            for child in children {
                guard let identity = processIdentity(of: child),
                      identity.parentPid == parent.pid,
                      processStartTime(of: parent.pid) == parent.startedAt else { continue }
                let child = DescendantKey(pid: child, startedAt: identity.startedAt)
                out.append(child)
                queue.append(child)
            }
        }
        return out
    }

    nonisolated static func processKey(of pid: pid_t) -> DescendantKey? {
        guard let startedAt = processStartTime(of: pid) else { return nil }
        return DescendantKey(pid: pid, startedAt: startedAt)
    }

    nonisolated static func childProcessKey(of pid: pid_t, parentPID: pid_t) -> DescendantKey? {
        guard let identity = processIdentity(of: pid),
              identity.parentPid == parentPID else { return nil }
        return DescendantKey(pid: pid, startedAt: identity.startedAt)
    }

    nonisolated private static func childPids(of parent: pid_t) -> [pid_t] {
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

    /// Captures members of the root's process group after the cheap
    /// synchronous group signal. This catches a TERM-trapping child
    /// even if the root exits before a descendant ppid walk runs; the
    /// returned PIDs are still validated by start time before late
    /// cleanup signals are delivered.
    nonisolated private static func collectGroupMembers(of pgid: pid_t) -> [DescendantKey] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "pid=,pgid=", "-ax"]
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
        var out: [DescendantKey] = []
        for line in s.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            let parts = trimmed.split(separator: " ", maxSplits: 1,
                                      omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let currentPgid = pid_t(parts[1]),
                  pid != pgid,
                  currentPgid == pgid,
                  let startedAt = processStartTime(of: pid) else { continue }
            out.append(DescendantKey(pid: pid, startedAt: startedAt))
        }
        return out
    }

    /// Returns the subset of cached descendant identities that still
    /// match the current process table. Used to skip stale cached PIDs
    /// whose original process has exited and whose PID may have been
    /// reused for an unrelated process.
    nonisolated static func currentlyMatching(_ keys: Set<DescendantKey>) -> Set<DescendantKey> {
        guard !keys.isEmpty else { return [] }
        var current: Set<DescendantKey> = []
        for key in keys {
            guard processStartTime(of: key.pid) == key.startedAt else { continue }
            current.insert(key)
        }
        return current
    }

    /// Kernel process birth time, used as the stable half of cached
    /// descendant identity. Unlike `ps lstart`, this is raw timeval
    /// data rather than a locale/timezone-formatted, second-precision
    /// wall-clock string.
    nonisolated private static func processStartTime(of pid: pid_t) -> ProcessStartTime? {
        processIdentity(of: pid)?.startedAt
    }

    nonisolated private static func processIdentity(of pid: pid_t) -> ProcessIdentity? {
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

    func updateMetadataCwd(_ cwd: String?) {
        guard !isProcessBacked else { return }
        self.cwd = cwd
    }

    func appendMetadataOutput(_ data: Data, replace: Bool) {
        guard !isProcessBacked else { return }
        if replace {
            bufferStorage.removeAll(keepingCapacity: true)
            bufferStart = 0
            displayTail.reset()
            truncated = false
        }
        appendChunk(data)
    }

    func finishMetadata(exitStatus status: ACPTerminalExitStatus) {
        guard !isProcessBacked else { return }
        if exitStatus != nil {
            exitStatus = status
            return
        }
        publishDisplayNow()
        exitStatus = status
        onExit?()
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for c in waiters { c.resume(returning: status) }
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
        let snapshot = ANSIPlainTextSnapshot.tail(
            from: buffer,
            byteLimit: limit,
            normalizesCRLF: normalizesCRLF
        )
        return (snapshot.text, truncated || snapshot.truncated)
    }

    /// Remote SSH terminals use a pty, which translates LF to CRLF. Preserve
    /// lone carriage returns because they carry progress-bar redraw semantics.
    nonisolated static func normalizeCRLF(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    // MARK: - Helpers

    private func installReadabilityHandler() {
        guard let pipe, exitStatus == nil, !sawEOF else { return }
        let weakSelf = WeakBox(self)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            handle.readabilityHandler = nil
            let chunk = handle.availableData
            Task { @MainActor in
                guard let terminal = weakSelf.value else { return }
                if chunk.isEmpty {
                    terminal.signalEOF()
                    return
                }
                terminal.appendChunk(chunk)
                terminal.installReadabilityHandler()
            }
        }
    }

    private func appendChunk(_ chunk: Data) {
        displayTail.feed(chunk)
        bufferStorage.append(chunk)
        if retainedByteCount > Self.internalBufferCap {
            let drop = retainedByteCount - Self.internalBufferCap
            bufferStart += drop
            // The bulk drop may have landed mid-codepoint. Advance the
            // start past any leading UTF-8 continuation bytes so the
            // buffer always begins on a valid character boundary —
            // snapshot/output paths can then trust the invariant even
            // when no further truncation is needed at read time.
            while bufferStart < bufferStorage.count,
                  (bufferStorage[bufferStart] & 0xC0) == 0x80 {
                bufferStart += 1
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
            if !truncated { truncated = true }

            // Advance a logical start for each chunk, then compact only after
            // a full cap's worth of discarded storage has accumulated. This
            // amortizes the 1 MiB copy instead of memmoving it per pipe chunk.
            if bufferStart >= Self.internalBufferCap {
                bufferStorage = Data(bufferStorage[bufferStart...])
                bufferStart = 0
            }
        }
        noteDisplayChange()
    }

    private func stripLeadingPartialSGR() {
        var n = 0
        while n < min(retainedByteCount, 16) {
            let b = bufferStorage[bufferStart + n]
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
        if n > 0 { bufferStart += n }
    }

    nonisolated static func displayRefreshAction(
        elapsedSincePublish: TimeInterval,
        hasPendingDrain: Bool,
        minInterval: TimeInterval = displayRefreshMinInterval
    ) -> DisplayRefreshAction {
        if hasPendingDrain { return .drop }
        if elapsedSincePublish >= minInterval { return .publishNow }
        return .scheduleDrain(after: minInterval - elapsedSincePublish)
    }

    private func noteDisplayChange() {
        let now = ProcessInfo.processInfo.systemUptime
        switch Self.displayRefreshAction(
            elapsedSincePublish: now - lastDisplayPublish,
            hasPendingDrain: displayDrain != nil
        ) {
        case .publishNow:
            publishDisplayNow(at: now)
        case .scheduleDrain(let delay):
            displayDrain = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.displayDrain = nil
                self.publishDisplayNow()
            }
        case .drop:
            break
        }
    }

    private func publishDisplayNow(
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        displayDrain?.cancel()
        displayDrain = nil
        lastDisplayPublish = now
        displayRuns = displayTail.runs
        displayRevision &+= 1
    }

    private func handleExit(status: ACPTerminalExitStatus) async {
        guard let pipe else { return }
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
        publishDisplayNow()
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

/// Strong indirection for detached cleanup tasks that must preserve
/// terminal state until their bounded signal escalation finishes.
private final class StrongBox<T: AnyObject>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
