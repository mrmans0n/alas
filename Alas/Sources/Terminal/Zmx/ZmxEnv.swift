// Alas/Sources/Terminal/Zmx/ZmxEnv.swift
import Foundation

/// Resolved once at app boot. Carries the location of the bundled `zmx`
/// binary (if present and executable) and a sun_path-safe, user-private
/// `ZMX_DIR` to use for the daemon's sockets and state.
struct ZmxEnv: Sendable {
    let binaryURL: URL?
    /// nil → no secure directory available, meaning we couldn't fit the
    /// canonical path within sun_path AND the /tmp fallback already exists
    /// with the wrong owner/perms. Treated as zmx-unavailable by callers.
    let zmxDir: URL?

    var isAvailable: Bool { binaryURL != nil && zmxDir != nil }

    /// Probe order:
    /// 1. `bundle.resourceURL/zmx/zmx` for the binary (must exist + be
    ///    executable). Missing or non-executable → `binaryURL = nil`.
    /// 2. Canonical `zmxDir = ~/Library/Caches/io.nlopez.alas/zmx`. The
    ///    user's Caches dir is always user-private, so if it fits within
    ///    `sun_path` we use it as-is.
    /// 3. Otherwise fall back to `/tmp/alas-zmx-<uid>`. Validate ownership
    ///    and mode 0o700 — if a pre-existing dir at that path is owned by
    ///    another user or world-permissive, refuse it (`zmxDir = nil`) so
    ///    zmx is marked unavailable rather than silently using an
    ///    attacker-controlled directory.
    static func resolve(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo
    ) -> ZmxEnv {
        let binaryURL = resolveBinaryURL(bundle: bundle, fileManager: fileManager)
        let zmxDir = resolveZmxDir(fileManager: fileManager, processInfo: processInfo)
        return ZmxEnv(binaryURL: binaryURL, zmxDir: zmxDir)
    }

    private static func resolveBinaryURL(bundle: Bundle, fileManager: FileManager) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent("zmx/zmx")
        guard fileManager.isExecutableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    private static func resolveZmxDir(fileManager: FileManager, processInfo: ProcessInfo) -> URL? {
        let canonical = canonicalZmxDir(fileManager: fileManager)
        // The user's Caches dir lives under ~/Library, which is private to
        // the current user by macOS convention — no ownership probe needed.
        // Still verify the path is actually a directory after creation:
        // if a regular file already exists at that path (or createDirectory
        // failed for any reason), returning it would have zmx fail at
        // `bind(2)` time while `isAvailable` claims success.
        if ZmxSunPathBudget.fits(dir: canonical.path) {
            try? fileManager.createDirectory(at: canonical, withIntermediateDirectories: true, attributes: [
                .posixPermissions: NSNumber(value: 0o700),
            ])
            if isDirectory(at: canonical, fileManager: fileManager) {
                return canonical
            }
            return nil
        }
        // Fallback lives in world-writable /tmp, so it MUST pass an
        // ownership + mode check before we hand it back to zmx.
        let tmpDir = fallbackTmpZmxDir(processInfo: processInfo)
        return secureFallback(at: tmpDir, fileManager: fileManager)
    }

    private static func isDirectory(at url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// Returns the URL only if we successfully made (or verified) a private
    /// `0o700`-owned-by-us directory there. Otherwise returns nil so the
    /// caller surfaces "no usable ZMX_DIR" → zmx unavailable. Fail closed:
    /// using an attacker-controlled directory for sockets/logs is worse
    /// than disabling cross-launch persistence.
    private static func secureFallback(at url: URL, fileManager: FileManager) -> URL? {
        let path = url.path
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [
            .posixPermissions: NSNumber(value: 0o700),
        ])
        // The path must exist as a directory before we even look at attrs.
        // A regular file at that path would make `attributesOfItem` succeed
        // but zmx couldn't bind sockets inside it.
        guard isDirectory(at: url, fileManager: fileManager) else { return nil }
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return nil }

        let ownerOK: Bool = {
            guard let owner = attrs[.ownerAccountID] as? NSNumber else { return false }
            return owner.uint32Value == getuid()
        }()
        guard ownerOK else { return nil }

        if let perms = attrs[.posixPermissions] as? NSNumber, perms.int32Value != 0o700 {
            // Try to lock it down; if we can't, refuse.
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: path
                )
            } catch {
                return nil
            }
        }
        return url
    }

    private static func canonicalZmxDir(fileManager: FileManager) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("io.nlopez.alas/zmx", isDirectory: true)
    }

    private static func fallbackTmpZmxDir(processInfo: ProcessInfo) -> URL {
        let uid = getuid()
        return URL(fileURLWithPath: "/tmp/alas-zmx-\(uid)", isDirectory: true)
    }
}
