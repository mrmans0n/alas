import Foundation

struct ACPAdapterVersionChecker: Sendable {
    typealias Runner = @Sendable (_ command: String, _ args: [String]) async throws -> (status: Int32, stdout: String)

    let timeout: TimeInterval
    let runner: Runner

    init(timeout: TimeInterval = 5, runner: @escaping Runner = ACPAdapterVersionChecker.defaultRunner) {
        self.timeout = timeout
        self.runner = runner
    }

    func check(packageName: String) async -> AdapterUpdateState {
        let result: (status: Int32, stdout: String)?
        do {
            result = try await withTimeout(timeout) {
                try await runner("npm", ["outdated", "-g", packageName, "--json"])
            }
        } catch {
            return .unknown
        }
        guard let r = result else { return .unknown }
        return Self.parse(packageName: packageName, status: r.status, stdout: r.stdout)
    }

    /// Pure parser exposed for tests and reuse.
    static func parse(packageName: String, status: Int32, stdout: String) -> AdapterUpdateState {
        // `npm outdated` exits 0 when up to date and 1 when something is
        // outdated. Anything else is treated as a tool failure.
        guard status == 0 || status == 1 else { return .unknown }

        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .upToDate }

        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }

        // `npm outdated --json` returns `{}` when the requested package is up
        // to date. Any other shape that doesn't include our package key (e.g.
        // `{"error": ...}` on a registry/auth failure) is a tool failure, not
        // a green light — keep it as `.unknown` so the failure TTL applies.
        if root.isEmpty { return .upToDate }
        guard let entry = root[packageName] as? [String: Any]
        else { return .unknown }

        guard let current = entry["current"] as? String
        else { return .upToDate }
        guard let latest = entry["latest"] as? String
        else { return .unknown }

        if isPrerelease(latest) { return .upToDate }
        if current == latest    { return .upToDate }
        if compareSemver(current, latest) == .orderedDescending { return .upToDate }
        return .available(current: current, latest: latest)
    }

    /// Treat any version containing a `-` segment as a prerelease (covers
    /// `1.2.0-beta.1`, `1.0.0-rc.0`, `2.0.0-next.5`, etc.).
    private static func isPrerelease(_ version: String) -> Bool {
        version.contains("-")
    }

    /// Lexicographic per-component numeric compare. Good enough for
    /// detecting `current > latest` (the only case we use it for); we do
    /// not need full semver precedence here.
    private static func compareSemver(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lparts = lhs.split(separator: ".").compactMap { Int($0) }
        let rparts = rhs.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(lparts.count, rparts.count) {
            let l = i < lparts.count ? lparts[i] : 0
            let r = i < rparts.count ? rparts[i] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    static let defaultRunner: Runner = { cmd, args in
        // Wired through withTaskCancellationHandler so that timeout-driven
        // task cancellation actually terminates the npm process; otherwise
        // a stuck registry call would pin the per-agent in-flight slot in
        // the store until npm exited on its own.
        nonisolated(unsafe) let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [cmd] + args
        proc.environment = ACPProcessEnvironment.augmented()
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(status: Int32, stdout: String), Error>) in
                proc.terminationHandler = { p in
                    let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                    let stdout = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(returning: (p.terminationStatus, stdout))
                }
                do {
                    try proc.run()
                } catch {
                    proc.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            proc.terminate()
        }
    }
}

/// Race an async operation against a timeout. The operation task is
/// cancelled on timeout; throwing rethrows to the caller. Used by the
/// version checker to bound npm calls.
private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        guard let result = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return result
    }
}

private struct TimeoutError: Error {}
