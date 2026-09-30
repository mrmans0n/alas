import Foundation
import os

/// Remote worktree ids moved from real paths to `RemotePath` virtual paths
/// (see `ProjectConfig.legacyWorktreeIDs`). Stores keyed by worktree id
/// follow them so existing remote worktrees keep their tabs, transcripts,
/// buffers, recents, and last selection.
///
/// Runs from `AppState.init`, before any tabs load, zmx orphan sweep, or ACP
/// store open (all later instance calls), so nothing moved here is open.
/// Idempotent: decode re-reports the map until projects.json is rewritten, so
/// a missing source is skipped and an existing destination never overwritten.
/// Failures are logged and skipped; nothing is deleted.
///
/// ACP image attachments are deliberately not moved: transcripts reference
/// them by absolute file URL, and nothing reads the directory by id.
enum RemotePathMigration {
    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "remote-path-migration")

    enum Store: CaseIterable, Sendable {
        case tabs, acpSessions, buffers

        /// The `Paths` helper's location, re-rooted under `root`.
        func url(root: URL, id: String) -> URL {
            let url: URL = switch self {
            case .tabs: Paths.tabsFile(forWorktreeId: id)
            case .acpSessions: Paths.acpSessionsDB(forWorktreeId: id)
            case .buffers: Paths.buffersDir(forWorktreeId: id)
            }
            return root.appendingPathComponent(String(url.path.dropFirst(Paths.appSupportRoot.path.count)))
        }
    }

    static func migrate(idMap: [String: String], root: URL = Paths.appSupportRoot, fileManager: FileManager = .default) {
        for (old, new) in idMap {
            for store in Store.allCases {
                let from = store.url(root: root, id: old)
                let to = store.url(root: root, id: new)
                switch store {
                case .tabs:
                    move(from, to, fileManager)
                case .acpSessions:
                    guard move(from, to, fileManager) else { continue }
                    for sidecar in ["-wal", "-shm"] {
                        move(URL(fileURLWithPath: from.path + sidecar), URL(fileURLWithPath: to.path + sidecar), fileManager)
                    }
                case .buffers:
                    // Files only: a subdirectory is another worktree's
                    // buffers nested under this path, migrated on its own.
                    let children = (try? fileManager.contentsOfDirectory(
                        at: from, includingPropertiesForKeys: [.isDirectoryKey]
                    )) ?? []
                    for child in children
                    where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                        move(child, to.appendingPathComponent(child.lastPathComponent), fileManager)
                    }
                }
            }
        }
    }

    static func rewrite(_ config: inout AppConfig, idMap: [String: String]) {
        config.recentWorktreeIdsByProject = config.recentWorktreeIdsByProject.mapValues { $0.map { idMap[$0] ?? $0 } }
        config.recentWorktreeRefs = config.recentWorktreeRefs.map {
            .init(projectId: $0.projectId, worktreeId: idMap[$0.worktreeId] ?? $0.worktreeId)
        }
    }

    static func rewrite(_ spaces: inout SpacesFile, idMap: [String: String]) {
        for i in spaces.spaces.indices {
            if let old = spaces.spaces[i].lastSelectedWorktreeId, let new = idMap[old] {
                spaces.spaces[i].lastSelectedWorktreeId = new
            }
        }
    }

    @discardableResult
    private static func move(_ from: URL, _ to: URL, _ fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: from.path), !fileManager.fileExists(atPath: to.path) else { return false }
        do {
            try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: from, to: to)
            return true
        } catch {
            logger.error("Skipping \(from.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
