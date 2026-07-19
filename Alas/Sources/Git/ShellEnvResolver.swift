import Foundation

final class ShellEnvResolver {
    static let shared = ShellEnvResolver()

    private let lock = NSLock()
    private var _resolvedPath: String?
    private var resolveTask: Task<Void, Never>?

    var resolvedPath: String? {
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

    func resolve() {
        let task = Task {
            let path = await Self.discoverShellPath()
            lock.lock()
            _resolvedPath = path
            lock.unlock()
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
    func waitUntilResolved() async {
        lock.lock()
        let task = resolveTask
        lock.unlock()
        await task?.value
    }

    private static func discoverShellPath() async -> String? {
        let candidates = shellCandidates()
        for shell in candidates {
            if let path = try? await runShellAndGetPATH(shell: shell) {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
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

    private static func runShellAndGetPATH(shell: String) async throws -> String {
        let result = try await Process.run(
            shell,
            args: [
                "-l", "-c",
                #"printf '%s' "\#(sentinelStart)"; printenv PATH; printf '%s' "\#(sentinelEnd)""#
            ],
            timeout: 2
        )
        guard result.exitCode == 0 else { return "" }
        let raw = result.stdout
        guard let start = raw.range(of: sentinelStart)?.upperBound,
              let end = raw.range(of: sentinelEnd, range: start..<raw.endIndex)?.lowerBound,
              start < end else { return "" }
        let path = raw[start..<end].trimmingCharacters(in: .newlines)
        return path
    }
}
