import Foundation
import Darwin

/// Wraps `spctl --assess` for an LSP binary so we can pre-flight Gatekeeper
/// before spawning a subprocess from a GUI app. On macOS Tahoe a GUI app
/// spawning an ad-hoc-signed binary triggers a Gatekeeper popup the user
/// must dismiss from System Settings; checking spctl first lets us skip the
/// spawn and surface an in-app banner instead.
///
/// Caches results by (realPath, mtime, inode). The first lookup per binary
/// per session shells out to spctl (~150-300ms); later lookups are µs-fast
/// cache reads. Callers run on the main actor — see the spec for the
/// stutter trade-off.
@MainActor
final class GatekeeperAssessor {
    enum Result: Equatable { case allowed, rejected, unknown }

    static let shared = GatekeeperAssessor()

    /// Throwing closure that returns the assessment for `realPath`. The
    /// default runs `/usr/sbin/spctl --assess --type execute <path>` via
    /// `Process`. Injected for tests.
    typealias Runner = (_ realPath: String) throws -> Result

    private struct CacheEntry {
        let mtime: TimeInterval
        let inode: UInt64
        let result: Result
    }

    private let runner: Runner
    private var cache: [String: CacheEntry] = [:]

    init(runner: @escaping Runner = GatekeeperAssessor.defaultRunner) {
        self.runner = runner
    }

    /// Returns the cached assessment for `realPath`, or runs the assessor
    /// (blocking) on cache miss/stale. Never throws — assessment errors
    /// collapse to `.unknown`, which callers treat as `.allowed` so a
    /// broken check doesn't hide an LSP.
    ///
    /// Pass the symlink-resolved path. Use `URL.resolvingSymlinksInPath()` or
    /// equivalent before calling; otherwise cache keys may not match across
    /// different paths to the same binary.
    func assess(realPath: String) -> Result {
        let stat = currentStat(path: realPath)
        if let entry = cache[realPath],
           let stat,
           entry.mtime == stat.mtime,
           entry.inode == stat.inode {
            return entry.result
        }

        let result: Result
        do {
            result = try runner(realPath)
        } catch {
            return .unknown
        }

        if let stat {
            cache[realPath] = CacheEntry(mtime: stat.mtime, inode: stat.inode, result: result)
        }
        return result
    }

    func invalidate(realPath: String) {
        cache.removeValue(forKey: realPath)
    }

    func invalidateAll() {
        cache.removeAll(keepingCapacity: true)
    }

    private func currentStat(path: String) -> (mtime: TimeInterval, inode: UInt64)? {
        var buf = Darwin.stat()
        // Callers pass realPath (already symlink-resolved), so lstat and stat
        // are equivalent here; lstat also keeps the cache key stable if a caller
        // accidentally hands us an unresolved symlink.
        guard Darwin.lstat(path, &buf) == 0 else { return nil }
        let mtime = TimeInterval(buf.st_mtimespec.tv_sec) + TimeInterval(buf.st_mtimespec.tv_nsec) / 1_000_000_000
        return (mtime: mtime, inode: UInt64(buf.st_ino))
    }

    nonisolated static func defaultRunner(realPath: String) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        process.arguments = ["--assess", "--type", "execute", realPath]
        let null = Pipe()
        process.standardOutput = null
        process.standardError = null

        try process.run()
        // spctl normally completes in well under a second. We bound the wait
        // with a hard 2s ceiling so a wedged syspolicyd can't hang the UI.
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            sema.signal()
        }
        let timedOut = sema.wait(timeout: .now() + 2.0) == .timedOut
        if timedOut {
            process.terminate()
            return .unknown
        }
        return process.terminationStatus == 0 ? .allowed : .rejected
    }
}
