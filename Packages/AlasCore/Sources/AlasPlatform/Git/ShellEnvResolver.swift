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
                if let path = try? await runShellAndGetPATH(shell: shell, interactive: interactive) {
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

    private static func runShellAndGetPATH(shell: String, interactive: Bool) async throws -> String {
        // An interactive shell's startup files may print, fail a command or
        // take seconds (nvm); the sentinels find PATH in whatever it prints,
        // whatever its exit status, and an empty stdin keeps it from waiting
        // for input.
        let result = try await Process.run(
            shell,
            args: (interactive ? ["-i", "-l", "-c"] : ["-l", "-c"]) + [
                #"printf '%s' "\#(sentinelStart)"; printenv PATH; printf '%s' "\#(sentinelEnd)""#
            ],
            stdin: "",
            timeout: interactive ? 10 : 2
        )
        let raw = result.stdout
        guard let start = raw.range(of: sentinelStart)?.upperBound,
              let end = raw.range(of: sentinelEnd, range: start..<raw.endIndex)?.lowerBound,
              start < end else { return "" }
        let path = raw[start..<end].trimmingCharacters(in: .newlines)
        return path
    }

    public init() {}
}
