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
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    init(runner: @escaping Runner = GatekeeperAssessor.defaultRunner) {
        self.runner = runner
    }

    /// Returns the cached assessment for `realPath`, or runs the assessor
    /// (blocking) on cache miss/stale. Never throws — assessment errors
    /// collapse to `.unknown`, which callers treat as `.allowed` so a
    /// broken check doesn't hide an LSP.
    func assess(realPath: String) -> Result {
        let stat = currentStat(path: realPath)
        lock.lock()
        if let entry = cache[realPath],
           let stat,
           entry.mtime == stat.mtime,
           entry.inode == stat.inode {
            lock.unlock()
            return entry.result
        }
        lock.unlock()

        let result: Result
        do {
            result = try runner(realPath)
        } catch {
            return .unknown
        }

        if let stat {
            lock.lock()
            cache[realPath] = CacheEntry(mtime: stat.mtime, inode: stat.inode, result: result)
            lock.unlock()
        }
        return result
    }

    func invalidate(realPath: String) {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: realPath)
    }

    func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll(keepingCapacity: true)
    }

    private func currentStat(path: String) -> (mtime: TimeInterval, inode: UInt64)? {
        var buf = Darwin.stat()
        guard Darwin.lstat(path, &buf) == 0 else { return nil }
        let mtime = TimeInterval(buf.st_mtimespec.tv_sec) + TimeInterval(buf.st_mtimespec.tv_nsec) / 1_000_000_000
        return (mtime: mtime, inode: UInt64(buf.st_ino))
    }

    static func defaultRunner(realPath: String) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        process.arguments = ["--assess", "--type", "execute", realPath]
        let null = Pipe()
        process.standardOutput = null
        process.standardError = null

        try process.run()
        // spctl normally completes in well under a second. We bound the wait
        // with a hard 2s ceiling so a wedged syspolicyd can't hang the UI.
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                return .unknown
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return process.terminationStatus == 0 ? .allowed : .rejected
    }
}
