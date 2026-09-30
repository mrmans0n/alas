import Foundation
import os

/// Remote worktree ids moved from real paths to `RemotePath` virtual paths
/// (see `ProjectConfig.legacyWorktreeIDs`). Every store keyed by worktree id
/// follows them so existing remote worktrees keep their tabs, transcripts,
/// buffers, reviews, run history, schedules, attention, and selection.
///
/// Runs first thing in `AppState.init`, before the attention store and run
/// scheduler load their files, and before any tabs load, zmx orphan sweep,
/// or per-worktree ACP store open. The run-history database may already be
/// open (a default argument); SQLite serializes the second connection's write.
/// Idempotent: decode re-reports the map until projects.json is rewritten, so
/// a missing source is skipped, an existing destination never overwritten,
/// and already-virtual ids are left alone. Failures are logged and skipped;
/// nothing is deleted.
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
            return reroot(url, root)
        }
    }

    /// JSON stores whose identifier fields embed worktree ids.
    enum JSONStore: CaseIterable, Sendable {
        case reviewSessions, reviewDraftComments, runSchedules, attention

        var url: URL {
            switch self {
            case .reviewSessions: Paths.reviewSessionsFile
            case .reviewDraftComments: Paths.reviewDraftCommentsFile
            case .runSchedules: Paths.runSchedulesFile
            case .attention: Paths.attentionEventsFile
            }
        }

        func rewriter(_ idMap: [String: String]) -> LegacyIDRewriter {
            switch self {
            case .reviewSessions:
                .init(
                    idMap: idMap, idKeys: ["id", "worktreeID", "sessionID", "draftSessionID", "rawValue", "repositoryPath"],
                    keyedMaps: ["recordsByID", "replacementIDsByOldID"]
                )
            case .reviewDraftComments:
                .init(idMap: idMap, idKeys: ["sessionID", "rawValue"], keyedMaps: ["commentsBySessionID"])
            case .runSchedules:
                .init(idMap: idMap, idKeys: ["worktreeId", "worktreeID"])
            case .attention:
                // Owners without a lineage id are keyed by path, and source
                // keys (`rawValue`) embed the owner's storage key.
                .init(idMap: idMap, idKeys: ["legacyPath", "path", "rawValue", "sessionID"])
            }
        }
    }

    /// Every project's renamed ids, minus any a local project still uses: a
    /// local checkout at the same real path shared these stores before
    /// virtual paths existed, so it keeps them.
    static func legacyIDMap(projects: [ProjectConfig]) -> [String: String] {
        let localIDs = Set(projects.filter(\.legacyWorktreeIDs.isEmpty).flatMap {
            [$0.path] + $0.cachedWorktrees.map(\.id) + $0.worktreeOrder + $0.hiddenWorktreePaths
        })
        return projects.reduce(into: [:]) { map, project in
            map.merge(project.legacyWorktreeIDs.filter { !localIDs.contains($0.key) }) { a, _ in a }
        }
    }

    static func migrate(
        idMap: [String: String],
        root: URL = Paths.appSupportRoot,
        fileManager: FileManager = .default,
        defaults: UserDefaults? = nil
    ) {
        for (old, new) in idMap {
            for store in Store.allCases {
                let from = store.url(root: root, id: old)
                let to = store.url(root: root, id: new)
                switch store {
                case .tabs:
                    move(from, to, fileManager)
                case .acpSessions:
                    // Sidecars hold committed rows, so they move before the main
                    // file: an interrupted run leaves the main file at the old
                    // path and the next launch resumes. Skip only when both
                    // main files exist (never pair an old WAL with a new database).
                    let mainAtSource = fileManager.fileExists(atPath: from.path)
                    let mainAtDestination = fileManager.fileExists(atPath: to.path)
                    guard mainAtSource != mainAtDestination else { continue }
                    for sidecar in ["-wal", "-shm"] {
                        move(URL(fileURLWithPath: from.path + sidecar), URL(fileURLWithPath: to.path + sidecar), fileManager)
                    }
                    move(from, to, fileManager)
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
        movePendingReviews(idMap, in: reroot(Paths.pendingReviewsDir, root), fileManager)
        for store in JSONStore.allCases {
            rewriteJSONFile(reroot(store.url, root), store.rewriter(idMap))
        }
        updateSQLite(reroot(Paths.runHistoryDB, root), fileManager) { db in
            try renameColumns(db, table: "run_history", ["worktree_id", "conflict_worktree_id"], idMap)
        }
        updateSQLite(reroot(Paths.acpOrchestrationDB, root), fileManager) { db in
            try renameColumns(db, table: "delegations", ["parent_worktree_id", "child_worktree_id"], idMap)
            try rewriteWorktreeRequests(db, LegacyIDRewriter(idMap: idMap, idKeys: ["worktreeId", "destinationPath"]))
        }
        if let defaults { rekeyGGUndoMarkers(defaults, idMap) }
    }

    private static func reroot(_ url: URL, _ root: URL) -> URL {
        root.appendingPathComponent(String(url.path.dropFirst(Paths.appSupportRoot.path.count)))
    }

    /// Pending-review files are named `<pathHash>[-pr<N>].json`.
    private static func movePendingReviews(_ idMap: [String: String], in dir: URL, _ fileManager: FileManager) {
        let names = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        guard !names.isEmpty else { return }
        for (old, new) in idMap {
            let oldStem = String(PendingReview.pathHash(old))
            let newStem = String(PendingReview.pathHash(new))
            for name in names where name.hasPrefix(oldStem) {
                let suffix = name.dropFirst(oldStem.count)
                guard suffix == ".json" || suffix.hasPrefix("-pr") else { continue }
                move(dir.appendingPathComponent(name), dir.appendingPathComponent(newStem + suffix), fileManager)
            }
        }
    }

    private static func rewriteJSONFile(_ url: URL, _ rewriter: LegacyIDRewriter) {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            let rewritten = rewriter.rewrite(object)
            guard !(rewritten as AnyObject).isEqual(object) else { return }
            try JSONSerialization.data(withJSONObject: rewritten, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: url, options: .atomic)
        } catch {
            logger.error("Skipping \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens only an existing database (the wrapper would create one) and
    /// applies `work` in one transaction.
    private static func updateSQLite(_ url: URL, _ fileManager: FileManager, _ work: (SQLiteDatabase) throws -> Void) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.transaction { try work(db) }
        } catch {
            logger.error("Skipping \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Missing tables or columns (older schemas) are skipped.
    private static func renameColumns(
        _ db: SQLiteDatabase, table: String, _ columns: [String], _ idMap: [String: String]
    ) throws {
        let existing = Set(try db.query("SELECT name FROM pragma_table_info(?)", bindings: [table])
            .compactMap { $0["name"] as? String })
        for column in columns where existing.contains(column) {
            for (old, new) in idMap {
                try db.exec("UPDATE \(table) SET \(column) = ? WHERE \(column) = ?", bindings: [new, old])
            }
        }
    }

    /// `worktree_request` is a JSON blob naming the delegated worktree.
    private static func rewriteWorktreeRequests(_ db: SQLiteDatabase, _ rewriter: LegacyIDRewriter) throws {
        let columns = Set(try db.query("SELECT name FROM pragma_table_info('delegations')").compactMap { $0["name"] as? String })
        guard columns.isSuperset(of: ["child_session_id", "worktree_request"]) else { return }
        for row in try db.query("SELECT child_session_id, worktree_request FROM delegations") {
            guard let id = row["child_session_id"] as? String, let data = row["worktree_request"] as? Data,
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            let rewritten = rewriter.rewrite(object)
            guard !(rewritten as AnyObject).isEqual(object) else { continue }
            try db.exec(
                "UPDATE delegations SET worktree_request = ? WHERE child_session_id = ?",
                bindings: [try JSONSerialization.data(withJSONObject: rewritten), id]
            )
        }
    }

    private static func rekeyGGUndoMarkers(_ defaults: UserDefaults, _ idMap: [String: String]) {
        let key = GGUndoMarkerStore.defaultsKey
        func rekeyed(_ markers: [String: Any]) -> [String: Any]? {
            var out = markers
            for (old, value) in markers {
                guard let new = idMap[old], out[new] == nil else { continue }
                out[new] = value
                out[old] = nil
            }
            return out.keys == markers.keys ? nil : out
        }
        if let data = defaults.data(forKey: key) {
            guard let markers = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let out = rekeyed(markers),
                  let encoded = try? JSONSerialization.data(withJSONObject: out) else { return }
            defaults.set(encoded, forKey: key)
        } else if let markers = defaults.dictionary(forKey: key), let out = rekeyed(markers) {
            defaults.set(out, forKey: key)
        }
    }

    /// Rewrites recents and last selections, then saves whichever file
    /// changed. Saving here matters: projects.json can be re-saved with the
    /// virtual ids before any settings save, and the legacy map is then gone.
    /// `store` is nil in the test host, which shares the user's app support dir.
    static func rewrite(
        _ config: inout AppConfig,
        _ spaces: inout SpacesFile?,
        idMap: [String: String],
        saving store: (any PersistenceStoreProtocol)?
    ) {
        let (oldConfig, oldSpaces) = (config, spaces)
        config.recentWorktreeIdsByProject = config.recentWorktreeIdsByProject.mapValues { $0.map { idMap[$0] ?? $0 } }
        config.recentWorktreeRefs = config.recentWorktreeRefs.map {
            .init(projectId: $0.projectId, worktreeId: idMap[$0.worktreeId] ?? $0.worktreeId)
        }
        if var file = spaces {
            for i in file.spaces.indices {
                if let old = file.spaces[i].lastSelectedWorktreeId, let new = idMap[old] {
                    file.spaces[i].lastSelectedWorktreeId = new
                }
            }
            spaces = file
        }
        guard let store else { return }
        if config != oldConfig { save(config, to: Paths.appConfigFile, store) }
        if let spaces, spaces != oldSpaces { save(spaces, to: Paths.spacesFile, store) }
    }

    private static func save(_ value: some Encodable, to url: URL, _ store: any PersistenceStoreProtocol) {
        do {
            try store.write(value, to: url)
        } catch {
            logger.error("Saving \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
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

/// Rewrites legacy worktree ids inside the identifier fields of a decoded
/// JSON value. Only strings under `idKeys`, and the keys and string values of
/// dictionaries under `keyedMaps`, are touched, so free text never is. Within
/// such a string an id matches only as a whole field delimited by `:` or
/// U+001F (the separators every composite id here uses); a `file://` URL
/// matches by path. An id already inside its virtual form is skipped, which
/// keeps the rewrite idempotent. `skippedKeys` subtrees are left alone.
struct LegacyIDRewriter {
    let idMap: [String: String]
    var idKeys: Set<String> = []
    var keyedMaps: Set<String> = []
    var skippedKeys: Set<String> = []

    func rewrite(_ value: Any, key: String? = nil) -> Any {
        if let key, skippedKeys.contains(key) { return value }
        switch value {
        case let dict as [String: Any]:
            guard let key, keyedMaps.contains(key) else {
                return Dictionary(uniqueKeysWithValues: dict.map { ($0.key, rewrite($0.value, key: $0.key)) })
            }
            var out: [String: Any] = [:]
            for (entryKey, entry) in dict {
                let newKey = rewrite(id: entryKey)
                // Never overwrite an entry that already exists under the new key.
                let target = newKey != entryKey && dict[newKey] == nil ? newKey : entryKey
                if let string = entry as? String {
                    out[target] = rewrite(id: string)
                } else {
                    out[target] = rewrite(entry)
                }
            }
            return out
        case let array as [Any]:
            return array.map { rewrite($0, key: key) }
        case let string as String:
            guard let key, idKeys.contains(key) else { return string }
            return rewrite(id: string)
        default:
            return value
        }
    }

    func rewrite(id value: String) -> String {
        if value.hasPrefix("file://"), let path = URL(string: value)?.path, let new = idMap[path] {
            return URL(fileURLWithPath: new, isDirectory: value.hasSuffix("/")).absoluteString
        }
        return idMap.reduce(value) { replacingField($1.key, with: $1.value, in: $0) }
    }

    private func replacingField(_ old: String, with new: String, in text: String) -> String {
        let separators: Set<Character> = [":", "\u{1f}"]
        let virtualPrefix = new.hasSuffix(old) ? String(new.dropLast(old.count)) : ""
        var out = ""
        var cursor = text.startIndex
        var searchStart = text.startIndex
        while let range = text.range(of: old, range: searchStart ..< text.endIndex) {
            searchStart = range.upperBound
            let before = text[..<range.lowerBound]
            guard before.last.map(separators.contains) ?? true,
                  range.upperBound == text.endIndex || separators.contains(text[range.upperBound]),
                  virtualPrefix.isEmpty || !before.hasSuffix(virtualPrefix)
            else { continue }
            out += text[cursor ..< range.lowerBound] + new
            cursor = range.upperBound
        }
        return out + text[cursor...]
    }
}
