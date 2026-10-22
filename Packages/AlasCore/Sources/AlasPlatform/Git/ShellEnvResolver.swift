import Foundation
import AlasFoundation
import AlasModel

/// All mutable state (`_resolvedPath`, `resolveTask`) is guarded by `lock` on
/// every access path, so concurrent use is safe.
public final class ShellEnvResolver: @unchecked Sendable {
    public static let shared = ShellEnvResolver()

    private let lock = NSLock()
    private var _resolvedPath: String?
    private var resolveTask: Task<Void, Never>?

    public var resolvedPath: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _resolvedPath
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _resolvedPath = newValue
        }
    }

    public func resolve() {
        let task = Task {
            let path = await Self.discoverShellPath()
            lock.withLock { _resolvedPath = path }
        }
        lock.lock()
        resolveTask = task
        lock.unlock()
    }

    /// Awaits the in-flight PATH resolution started by `resolve()`, if any.
    /// Returns immediately when resolution already finished or never started.
    /// Callers that need the login-shell PATH before probing an external CLI
    /// (e.g. `gg`) should await this instead of racing `resolve()`'s
    /// fire-and-forget Task.
    public func waitUntilResolved() async {
        let task = lock.withLock { resolveTask }
        await task?.value
    }

    /// The PATH of the user's shell: interactive and login first, since nvm,
    /// fnm and mise are set up in `.zshrc`, which zsh reads only for an
    /// interactive shell; a plain login shell when that yields nothing.
    static func discoverShellPath(candidates: [String] = shellCandidates()) async -> String? {
        for shell in candidates {
            for interactive in [true, false] {
                if let path = await runShellAndGetPATH(shell: shell, interactive: interactive) {
                    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
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

    private static let sentinelStart = "___ALAS_PATH___"
    private static let sentinelEnd = "___ALAS_END___"

    /// Runs the shell in a session of its own, without a terminal: an
    /// interactive shell's startup files could otherwise read from or take
    /// over the terminal this process runs in (`alas-host setup` over SSH)
    /// and stall. They may still print, fail a command or take seconds (nvm);
    /// the sentinels find PATH in whatever the shell prints, whatever its exit
    /// status, and the shell's whole process group is killed past `timeout`.
    private static func runShellAndGetPATH(shell: String, interactive: Bool) async -> String? {
        let output = Pipe()
        let errors = Pipe()
        let script = #"printf '%s' "\#(sentinelStart)"; printenv PATH; printf '%s' "\#(sentinelEnd)""#
        guard let child = try? SpawnedProcess(
            executable: URL(fileURLWithPath: shell),
            arguments: (interactive ? ["-i", "-l", "-c"] : ["-l", "-c"]) + [script],
            environment: ProcessInfo.processInfo.environment,
            newSession: true, stdin: nil, stdout: output, stderr: errors,
            onExit: { _, _ in }
        ) else { return nil }
        let read = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let drain = Task.detached { _ = errors.fileHandleForReading.readDataToEndOfFile() }
        let timeout = Task.detached {
            try await Task.sleep(for: .seconds(interactive ? 10 : 2))
            // The session leader's pid is its group's id.
            if child.isRunning { kill(-child.pid, SIGKILL) }
        }
        let raw = String(decoding: await read.value, as: UTF8.self)
        timeout.cancel()
        drain.cancel()
        guard let start = raw.range(of: sentinelStart)?.upperBound,
              let end = raw.range(of: sentinelEnd, range: start..<raw.endIndex)?.lowerBound,
              start < end else { return "" }
        return raw[start..<end].trimmingCharacters(in: .newlines)
    }

    public init() {}
}
