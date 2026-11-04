import Foundation
import Observation

/// Project icons for rendering, answered from memory.
///
/// `AppState.effectiveIcon(for:)` is exact, and pays for it with about a
/// hundred file-system calls per project. The sidebar asks while SwiftUI lays
/// out a scroll frame, once per local header and once per same-named peer repo,
/// so on a busy disk those calls stall the main thread. This cache keeps the
/// sidebar away from the disk: a project is resolved when first seen, and from
/// then on its repo files are re-checked off the main actor, at most once per
/// `recheckInterval`. A changed file re-resolves and re-renders whoever read
/// the icon, so an edit to `.alas/icon.png` shows up within that interval.
@MainActor
@Observable
final class RepoIconRenderCache {
    /// Identifies one revision of a file, or its absence. The inode catches an
    /// atomic replace by a same-sized file within the same second.
    struct FileStamp: Equatable, Sendable {
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let size: Int64
        let inode: UInt64

        /// `stat(2)` directly: `URL.resourceValues` caches per URL instance and
        /// would hide the change this exists to notice.
        nonisolated static func read(_ path: String) -> FileStamp? {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return FileStamp(
                modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                size: info.st_size, inode: info.st_ino
            )
        }
    }

    private struct Entry {
        var project: ProjectConfig
        var icon: ProjectIcon
        var watched: [String]
        var stamps: [FileStamp?]
        var checkedAt: Date
    }

    /// Bumped when a re-check changes an icon, which is what re-renders readers.
    private(set) var revision = 0
    @ObservationIgnored var recheckInterval: TimeInterval = 3
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var recheck: Task<Void, Never>?

    /// - Parameters:
    ///   - watched: The files that can supply the project's icon, present or not.
    ///   - resolve: The exact answer, used on first sight and after a change.
    func icon(
        for project: ProjectConfig,
        watched: @escaping (ProjectConfig) -> [String],
        resolve: @escaping (ProjectConfig) -> ProjectIcon
    ) -> ProjectIcon {
        _ = revision
        if let entry = entries[project.id], entry.project.icon == project.icon, entry.project.path == project.path {
            if Date().timeIntervalSince(entry.checkedAt) >= recheckInterval {
                scheduleRecheck(watched: watched, resolve: resolve)
            }
            return entry.icon
        }
        let paths = watched(project)
        // Stamped before resolving, so an edit landing mid-resolve re-resolves.
        let stamps = paths.map(FileStamp.read)
        let icon = resolve(project)
        entries[project.id] = Entry(project: project, icon: icon, watched: paths, stamps: stamps, checkedAt: Date())
        return icon
    }

    /// Waits for a re-check in flight, for tests.
    func waitForRecheck() async {
        await recheck?.value
    }

    private func scheduleRecheck(
        watched: @escaping (ProjectConfig) -> [String],
        resolve: @escaping (ProjectConfig) -> ProjectIcon
    ) {
        guard recheck == nil else { return }
        let now = Date()
        let due = entries.filter { now.timeIntervalSince($0.value.checkedAt) >= recheckInterval }
            .mapValues(\.watched)
        recheck = Task { [weak self] in
            let fresh = await Task.detached(priority: .utility) {
                due.mapValues { $0.map(FileStamp.read) }
            }.value
            self?.apply(fresh, watched: watched, resolve: resolve)
            self?.recheck = nil
        }
    }

    private func apply(
        _ fresh: [String: [FileStamp?]],
        watched: (ProjectConfig) -> [String],
        resolve: (ProjectConfig) -> ProjectIcon
    ) {
        var changed = false
        for (id, stamps) in fresh {
            guard var entry = entries[id] else { continue }
            entry.checkedAt = Date()
            if stamps != entry.stamps {
                // The change can be a config naming a different image to watch.
                entry.watched = watched(entry.project)
                entry.stamps = entry.watched.map(FileStamp.read)
                let icon = resolve(entry.project)
                changed = changed || icon != entry.icon
                entry.icon = icon
            }
            entries[id] = entry
        }
        if changed { revision += 1 }
    }
}
