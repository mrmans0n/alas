import Foundation

/// Materializes `git show <ref>:<path>` into a temp file so a historical
/// revision can be dragged out of Alas as a real file. Snapshots are memoized
/// per `(ref, path)` for the lifetime of the app session.
actor RevisionSnapshotCache {
    static let shared = RevisionSnapshotCache()

    /// Container holding one directory per app session, under the temp dir.
    static let rootDirectoryName = "alas-drag"

    /// This session's snapshot root. Immutable, so callers read it without
    /// hopping onto the actor.
    nonisolated let sessionDirectory: URL

    private var snapshots: [String: URL] = [:]
    private var didSweep = false

    init(sessionID: String = UUID().uuidString) {
        sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    /// Directory-safe form of a git ref. `stash@{0}^3` is not a usable path
    /// component, so every character outside `[A-Za-z0-9._-]` becomes `-`.
    /// Distinct refs stay distinct for everything Alas drags; a collision would
    /// at worst reuse a snapshot of the same path, never a different one.
    nonisolated static func refComponent(_ ref: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return String(ref.map { allowed.contains($0) ? $0 : "-" })
    }

    /// Where the blob at `ref:path` is written. The original relative path is
    /// preserved so the receiving app sees the real filename.
    nonisolated func snapshotURL(ref: String, path: String) -> URL {
        sessionDirectory
            .appendingPathComponent(Self.refComponent(ref), isDirectory: true)
            .appendingPathComponent(path)
    }

    /// Returns a local file holding the blob, or nil when the blob does not
    /// exist at that revision or cannot be written.
    func snapshot(worktreePath: URL, ref: String, path: String) async -> URL? {
        sweepStaleSessionsIfNeeded()

        let key = "\(ref)\u{0}\(path)"
        if let cached = snapshots[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let destination = snapshotURL(ref: ref, path: path)
        do {
            let result = try await Process.gitData(["show", "\(ref):\(path)"], cwd: worktreePath)
            guard result.exitCode == 0 else { return nil }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.stdout.write(to: destination, options: .atomic)
        } catch {
            return nil
        }

        snapshots[key] = destination
        return destination
    }

    func removeSessionDirectory() {
        try? FileManager.default.removeItem(at: sessionDirectory)
        snapshots.removeAll()
    }

    /// Removes session directories left behind by earlier runs. Done on first
    /// use rather than at launch so it never sits on the startup path, and so a
    /// crashed session still gets cleaned up by the next one.
    private func sweepStaleSessionsIfNeeded() {
        guard !didSweep else { return }
        didSweep = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries
        where entry.lastPathComponent != sessionDirectory.lastPathComponent {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
