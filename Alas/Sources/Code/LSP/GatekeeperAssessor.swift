import Foundation
import Darwin

/// Pre-flight Gatekeeper for an LSP binary by inspecting its
/// `com.apple.quarantine` xattr. Tahoe's GUI-spawn Gatekeeper block fires
/// for binaries the user "downloaded" (anything with quarantine on it),
/// not for arbitrary ad-hoc-signed executables: the previous
/// `spctl --assess --type execute` heuristic produced false positives
/// across the board (every Homebrew script, every cargo-installed Rust
/// binary, every node-script LSP comes back `rejected` even though the
/// system would happily spawn them). Quarantine presence is the narrow,
/// accurate signal — the same one the OS uses to decide whether to fire
/// the System Settings prompt.
///
/// Caches results by (realPath, mtime, inode); the xattr check itself is
/// already cheap, but caching keeps the cost off the main actor on the
/// hot path of editor open / tab switch.
@MainActor
final class GatekeeperAssessor {
    enum Result: Equatable { case allowed, rejected, unknown }

    static let shared = GatekeeperAssessor()

    /// Throwing closure that returns the assessment for `realPath`. The
    /// default reads `com.apple.quarantine` via `getxattr(2)`: present →
    /// `.rejected`, absent → `.allowed`. Injected for tests.
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
        // Probe size first. On ENOATTR the file simply isn't quarantined;
        // any other errno means inaccessible — return .unknown so the
        // availability layer falls open to .allowed rather than hiding a
        // runnable LSP behind a banner.
        let size = realPath.withCString { cpath in
            getxattr(cpath, "com.apple.quarantine", nil, 0, 0, 0)
        }
        if size < 0 { return errno == ENOATTR ? .allowed : .unknown }
        if size == 0 { return .unknown }

        var buffer = [UInt8](repeating: 0, count: size)
        let read = buffer.withUnsafeMutableBufferPointer { bufPtr -> Int in
            realPath.withCString { cpath in
                getxattr(cpath, "com.apple.quarantine", bufPtr.baseAddress, size, 0, 0)
            }
        }
        if read < 0 { return .unknown }
        guard let value = String(bytes: buffer[0..<read], encoding: .utf8) else { return .unknown }
        return interpretQuarantineValue(value)
    }

    /// Parse the `com.apple.quarantine` xattr value. Format is
    /// `flags;timestamp;agent;uuid` where `flags` is a hex bitfield.
    /// Bit `0x40` (`LSQuarantineUserApproved`) is set after the user
    /// approves the item via macOS Gatekeeper — the OS keeps the xattr
    /// in place and only flips the flag, so treating "attribute present"
    /// as a block would re-nudge after the user already approved.
    nonisolated static func interpretQuarantineValue(_ value: String) -> Result {
        let firstField = value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? value
        let trimmed = firstField.trimmingCharacters(in: .whitespaces)
        guard let flags = UInt32(trimmed, radix: 16) else { return .unknown }
        return (flags & 0x0040) != 0 ? .allowed : .rejected
    }
}
