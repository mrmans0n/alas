import Foundation
import AlasFoundation
import AlasModel

/// The environment of the user's login shell. Alas starts from launchd, whose
/// environment lacks what startup files set up: PATH entries for Homebrew,
/// nvm or rbenv, and variables such as ANDROID_HOME that tools Alas runs
/// (gg's lint hooks, git hooks) need. All mutable state
/// (`_resolvedEnvironment`, `resolveTask`) is guarded by `lock` on every
/// access path, so concurrent use is safe.
public final class ShellEnvResolver: @unchecked Sendable {
    public static let shared = ShellEnvResolver()

    private let lock = NSLock()
    private var _resolvedEnvironment: [String: String]?
    private var resolveTask: Task<Void, Never>?

    /// The login shell's environment, nil until it has resolved or when no
    /// shell gave one.
    public var resolvedEnvironment: [String: String]? {
        get { lock.withLock { _resolvedEnvironment } }
        set { lock.withLock { _resolvedEnvironment = newValue } }
    }

    /// The login shell's PATH, nil until it has resolved.
    public var resolvedPath: String? { resolvedEnvironment?["PATH"] }

    public func resolve() {
        let task = Task {
            let environment = await Self.discoverShellEnvironment()
            lock.withLock { _resolvedEnvironment = environment }
        }
        lock.lock()
        resolveTask = task
        lock.unlock()
    }

    /// Awaits the in-flight resolution started by `resolve()`, if any.
    /// Returns immediately when resolution already finished or never started.
    /// Callers that need the login-shell environment before probing an
    /// external CLI (e.g. `gg`) should await this instead of racing
    /// `resolve()`'s fire-and-forget Task.
    public func waitUntilResolved() async {
        let task = lock.withLock { resolveTask }
        await task?.value
    }

    /// Variables that describe the shell process itself, not the user's
    /// setup. A child started elsewhere must not inherit the shell's working
    /// directory as `PWD`.
    static let shellProcessKeys: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]

    /// The environment of the user's shell: interactive and login first,
    /// since nvm, fnm, rbenv and mise are set up in `.zshrc`, which zsh reads
    /// only for an interactive shell; a plain login shell when that yields
    /// no PATH.
    static func discoverShellEnvironment(candidates: [String] = shellCandidates()) async -> [String: String]? {
        for shell in candidates {
            for interactive in [true, false] {
                guard var environment = await runShellAndGetEnvironment(shell: shell, interactive: interactive) else { continue }
                let path = environment["PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !path.isEmpty else { continue }
                environment["PATH"] = path
                for key in shellProcessKeys { environment[key] = nil }
                return environment
            }
        }
        return nil
    }

    private static func shellCandidates() -> [String] {
        var list: [String] = []
        if let shell = ProcessInfo.processInfo.environment["SHELL"] { list.append(shell) }
        list.append("/bin/zsh")
        list.append("/bin/sh")
        return list
    }

    private static let sentinelStart = "___ALAS_ENV___"
    private static let sentinelEnd = "___ALAS_END___"

    /// Runs the shell in a session of its own, without a terminal: an
    /// interactive shell's startup files could otherwise read from or take
    /// over the terminal this process runs in (`alas-host setup` over SSH)
    /// and stall. They may still print, fail a command, take seconds (nvm) or
    /// leave a helper behind that holds the output open; the read ends at the
    /// end sentinel, whatever the shell's exit status, or past `timeout`, and
    /// then everything left in the shell's session is killed.
    private static func runShellAndGetEnvironment(shell: String, interactive: Bool) async -> [String: String]? {
        let output = Pipe()
        let errors = Pipe()
        // NUL-separated, so values may contain newlines.
        let script = #"printf '%s' "\#(sentinelStart)"; /usr/bin/env -0; printf '%s' "\#(sentinelEnd)""#
        guard let child = try? SpawnedProcess(
            executable: URL(fileURLWithPath: shell),
            arguments: (interactive ? ["-i", "-l", "-c"] : ["-l", "-c"]) + [script],
            environment: ProcessInfo.processInfo.environment,
            newSession: true, stdin: nil, stdout: output, stderr: errors,
            onExit: { _, _ in }
        ) else { return nil }
        let read = ShellOutput(endMarker: Data(sentinelEnd.utf8))
        errors.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        let raw = await withCheckedContinuation { continuation in
            read.onFinish = { continuation.resume(returning: $0) }
            output.fileHandleForReading.readabilityHandler = { read.append($0.availableData) }
            Task.detached {
                try? await Task.sleep(for: .seconds(interactive ? 10 : 2))
                read.finish()
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        // Whatever the shell left behind, a stalled shell itself or helpers
        // its startup files started, is in its session: end all of it.
        killSession(child.pid)
        guard let start = raw.range(of: Data(sentinelStart.utf8))?.upperBound,
              let end = raw.range(of: Data(sentinelEnd.utf8), in: start..<raw.endIndex)?.lowerBound,
              start < end else { return nil }
        var environment: [String: String] = [:]
        for entry in raw[start..<end].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return environment
    }

    /// Kills every process in session `id`. A shell's background jobs get
    /// process groups of their own, but stay in its session.
    private static func killSession(_ id: pid_t) {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        for pid in pids.prefix(max(0, count)) where pid > 0 && getsid(pid) == id {
            kill(pid, SIGKILL)
        }
    }

    public init() {}
}

/// What a shell printed, until the end marker, end of file or a timeout.
private final class ShellOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let endMarker: Data
    private var data = Data()
    private var finished = false
    var onFinish: ((Data) -> Void)?

    init(endMarker: Data) {
        self.endMarker = endMarker
    }

    /// Adds a chunk; an empty one is end of file. Finishes at the end marker.
    func append(_ chunk: Data) {
        lock.lock()
        if !chunk.isEmpty { data.append(chunk) }
        let done = chunk.isEmpty || data.range(of: endMarker) != nil
        lock.unlock()
        if done { finish() }
    }

    /// Finishes once; later calls do nothing.
    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let result = data
        let callback = onFinish
        lock.unlock()
        callback?(result)
    }
}
