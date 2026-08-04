import CryptoKit
import Foundation

/// Materializes `git show <ref>:<path>` into a temp file so a historical
/// revision can be dragged out of Alas as a real file. Snapshots are memoized
/// per `(ref, path)` for the lifetime of the app session.
actor RevisionSnapshotCache {
    static let shared = RevisionSnapshotCache()

    /// Container holding one directory per app session, under the temp dir.
    static let rootDirectoryName = "alas-drag"

    /// A session directory older than this is treated as abandoned by a
    /// crashed or exited process. The threshold must be generous: the user
    /// routinely runs multiple Alas instances at once, and a live instance's
    /// snapshots must never be deleted out from under an in-flight drag.
    static let staleSessionAge: TimeInterval = 24 * 60 * 60

    /// Characters that are safe to use verbatim in a path component.
    private static let allowedRefComponentCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )

    /// This session's snapshot root. Immutable, so callers read it without
    /// hopping onto the actor.
    nonisolated let sessionDirectory: URL

    private var snapshots: [String: URL] = [:]
    /// `(ref, path)` keys already known to have no blob, so a repeated failed
    /// lookup — e.g. dragging a deleted file's row — does not re-spawn `git
    /// show` for every gesture callback while the drag is held.
    private var missingSnapshots: Set<String> = []
    private var didSweep = false

    init(sessionID: String = UUID().uuidString) {
        sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    /// Directory-safe form of a git ref. `stash@{0}^3` is not a usable path
    /// component, so every character outside `[A-Za-z0-9._-]` is
    /// percent-encoded (`stash@{0}^3` becomes `stash%40%7B0%7D%5E3`).
    /// Percent-encoding is reversible and therefore injective, so distinct
    /// refs never collide on disk — unlike a lossy replacement scheme, which
    /// could map both `feature/foo` and a literal branch named `feature-foo`
    /// to the same path and silently overwrite one snapshot with the other's
    /// content. This directory name is internal and never shown to the user;
    /// the preserved relative *filename* is what the receiving app sees.
    nonisolated static func refComponent(_ ref: String) -> String {
        if let encoded = ref.addingPercentEncoding(withAllowedCharacters: allowedRefComponentCharacters) {
            return encoded
        }
        return String(ref.unicodeScalars.map { allowedRefComponentCharacters.contains($0) ? Character($0) : "-" })
    }

    /// Short, deterministic, filesystem-safe stand-in for a worktree's full
    /// path. The full path (e.g. `/Users/nacho/.alas/.worktrees/...`) is not
    /// usable as a single path component — it would blow past the 255-byte
    /// filename limit — so it is SHA256-hashed and truncated to 12 hex
    /// characters. Must not use `String.hashValue`: that hash is reseeded
    /// per process, so it would not even stay stable across two calls in the
    /// same run, let alone the same session.
    nonisolated static func worktreeComponent(_ worktreePath: URL) -> String {
        SHA256.hash(data: Data(worktreePath.path.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Where the blob at `ref:path` is written. The original relative path is
    /// preserved so the receiving app sees the real filename. Segmented by
    /// worktree first: `RevisionSnapshotCache.shared` is shared across every
    /// open worktree tab in the app, so without this segment two repos
    /// dragging the same `(ref, path)` (e.g. both have `stash@{0}` +
    /// `README.md`) would write to and read back the same on-disk file,
    /// silently handing one repo's bytes to the other's drag.
    nonisolated func snapshotURL(worktreePath: URL, ref: String, path: String) -> URL {
        sessionDirectory
            .appendingPathComponent(Self.worktreeComponent(worktreePath), isDirectory: true)
            .appendingPathComponent(Self.refComponent(ref), isDirectory: true)
            .appendingPathComponent(path)
    }

    /// Returns a local file holding the blob, or nil when the blob does not
    /// exist at that revision, the worktree is remote, or the blob cannot be
    /// written.
    ///
    /// The remote check belongs here rather than only in the caller: this
    /// method routes through `Process.gitData`, which follows
    /// `RemoteHostRegistry` for a remote worktree path and would otherwise
    /// silently `ssh` out to fetch a blob.
    func snapshot(worktreePath: URL, ref: String, path: String) async -> URL? {
        guard !worktreePath.isRemoteAlasPath else { return nil }

        sweepStaleSessionsIfNeeded()

        let key = "\(worktreePath.path)\u{0}\(ref)\u{0}\(path)"
        if let cached = snapshots[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        if missingSnapshots.contains(key) {
            return nil
        }

        let destination = snapshotURL(worktreePath: worktreePath, ref: ref, path: path)
        do {
            let result = try await Process.gitData(["show", "\(ref):\(path)"], cwd: worktreePath)
            guard result.exitCode == 0 else {
                if !Task.isCancelled {
                    missingSnapshots.insert(key)
                }
                return nil
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.stdout.write(to: destination, options: .atomic)
        } catch {
            // A thrown error here is either a cancellation (the task was
            // cancelled while `git show` was in flight, so `Process.runData`
            // tore the process down but returned normally with a non-zero
            // exit code above — that path is handled there) or a genuine
            // failure such as the 30s watchdog timeout. Neither means git
            // actually answered "this path is not in that tree", so the
            // miss must not be memoized: a retry could still succeed.
            return nil
        }

        snapshots[key] = destination
        return destination
    }

    func removeSessionDirectory() {
        try? FileManager.default.removeItem(at: sessionDirectory)
        snapshots.removeAll()
        missingSnapshots.removeAll()
    }

    /// Removes session directories left behind by earlier runs. Done on first
    /// use rather than at launch so it never sits on the startup path, and so a
    /// crashed session still gets cleaned up by the next one. Only entries
    /// older than `staleSessionAge` are removed: concurrent Alas instances
    /// must not delete each other's live snapshots, so anything that could
    /// plausibly belong to a still-running instance is left alone.
    private func sweepStaleSessionsIfNeeded() {
        guard !didSweep else { return }
        didSweep = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Self.staleSessionAge)
        for entry in entries
        where entry.lastPathComponent != sessionDirectory.lastPathComponent {
            guard
                let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey]),
                let modified = values.contentModificationDate,
                modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
