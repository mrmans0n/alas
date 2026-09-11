import AppKit
import Foundation

protocol WorktreeCheckpointServicing: Sendable {
    func summaries(target: CheckpointWorktreeTarget) async throws -> CheckpointCatalogSnapshot
    func nonterminalJournals(target: CheckpointWorktreeTarget) async throws -> [CheckpointRestoreJournal]
    func createManual(target: CheckpointWorktreeTarget, label: String) async throws -> WorktreeCheckpointSummary
    func manifest(target: CheckpointWorktreeTarget, id: CheckpointID) async throws -> WorktreeCheckpointManifest
    func delete(target: CheckpointWorktreeTarget, id: CheckpointID) async throws -> CheckpointCatalogSnapshot
    func restorePreview(target: CheckpointWorktreeTarget, id: CheckpointID, coordination: CheckpointCoordinationSnapshot,
                        selectedGroupIDs: Set<UUID>?) async throws -> CheckpointRestorePreview
    func diffContent(target: CheckpointWorktreeTarget, id: CheckpointID, path: String) async -> CheckpointDiffContent
    func restore(target: CheckpointWorktreeTarget, preview: CheckpointRestorePreview, selectedGroupIDs: Set<UUID>,
                 coordination: CheckpointCoordinationSnapshot) async throws -> CheckpointRestoreResult
    func recoverInterruptedRestore(target: CheckpointWorktreeTarget, operationID: UUID,
                                   coordination: CheckpointCoordinationSnapshot) async throws -> CheckpointRestoreResult
}

enum CheckpointCaptureError: Error, Equatable, Sendable {
    case unstableWorktree
    case missingSelectedPath(String)
}

struct CheckpointCaptureHooks: Sendable {
    let afterPayloadStaging: @Sendable (Int) async throws -> Void
    static let none = Self(afterPayloadStaging: { _ in })
}

actor WorktreeCheckpointService: WorktreeCheckpointServicing {
    private let store: WorktreeCheckpointStore
    private let snapshotter: WorktreeStateSnapshotter
    private let hooks: CheckpointCaptureHooks
    private let restoreFaultInjector: CheckpointRestoreFaultInjector
    private var cachedCatalogs: [String: CheckpointCatalogSnapshot] = [:]

    init(store: WorktreeCheckpointStore = .init(),
         snapshotter: WorktreeStateSnapshotter = .live,
         hooks: CheckpointCaptureHooks = .none, restoreFaultInjector: CheckpointRestoreFaultInjector = .none) {
        self.store = store
        self.snapshotter = snapshotter
        self.hooks = hooks
        self.restoreFaultInjector = restoreFaultInjector
    }

    func summaries(target: CheckpointWorktreeTarget) async throws -> CheckpointCatalogSnapshot {
        try validateLineage(target)
        _ = try await store.recoverableJournals(lineageID: target.lineageID)
        if let cached = cachedCatalogs[target.lineageID] { return cached }
        let catalog = try await store.catalog(lineageID: target.lineageID)
        cachedCatalogs[target.lineageID] = catalog
        return catalog
    }

    func nonterminalJournals(target: CheckpointWorktreeTarget) async throws -> [CheckpointRestoreJournal] {
        try validateLineage(target)
        return try await store.recoverableJournals(lineageID: target.lineageID)
    }

    func manifest(target: CheckpointWorktreeTarget, id: CheckpointID) async throws -> WorktreeCheckpointManifest {
        try await store.load(id: id, lineageID: target.lineageID)
    }

    func delete(target: CheckpointWorktreeTarget, id: CheckpointID) async throws -> CheckpointCatalogSnapshot {
        try validateLineage(target)
        let catalog = try await store.delete(id: id, lineageID: target.lineageID)
        cachedCatalogs[target.lineageID] = catalog
        return catalog
    }

    func restorePreview(target: CheckpointWorktreeTarget, id: CheckpointID,
                        coordination: CheckpointCoordinationSnapshot, selectedGroupIDs: Set<UUID>? = nil) async throws -> CheckpointRestorePreview {
        func blocked(_ blocker: CheckpointRestoreBlocker, label: String = "Checkpoint") -> CheckpointRestorePreview {
            .init(id: UUID(), checkpointID: id, checkpointLabel: label, currentFingerprint: "", groups: [],
                  blocker: blocker, scopeDescription: coordination.scopeDescription, selectedGroupIDs: [])
        }
        guard !target.path.isRemoteAlasPath else { return blocked(.remoteTarget) }
        if try await !store.recoverableJournals(lineageID: target.lineageID).isEmpty { return blocked(.interruptedRestore) }
        guard WorktreeService.existingLocalLineageID(forWorktreeAt: target.path) == target.lineageID else {
            return blocked(.lineageMismatch)
        }
        let saved: WorktreeCheckpointManifest?
        do { saved = try await store.loadMetadata(id: id, lineageID: target.lineageID) }
        catch { saved = nil }
        let head = try await previewHeadOID(target: target)
        if let saved, saved.headOID != head {
            return blocked(.changedHEAD, label: saved.label)
        }
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"] {
            let path = try await previewGit(["rev-parse", "--path-format=absolute", "--git-path", marker], target: target)
            if FileManager.default.fileExists(atPath: path.trimmingCharacters(in: .newlines)) {
                return blocked(.gitOperation, label: saved?.label ?? "Checkpoint")
            }
        }
        if try await !previewGit(["ls-files", "--unmerged", "-z"], target: target).isEmpty {
            return blocked(.gitOperation, label: saved?.label ?? "Checkpoint")
        }
        let lockPath = try await previewGit(["rev-parse", "--path-format=absolute", "--git-path", "index.lock"], target: target)
        if FileManager.default.fileExists(atPath: lockPath.trimmingCharacters(in: .newlines)) {
            return blocked(.indexLock, label: saved?.label ?? "Checkpoint")
        }
        guard let saved else {
            var blockers: Set<CheckpointRestoreBlocker> = [.corruptCheckpoint]
            if coordination.otherGitMutationActive { blockers.insert(.otherGitMutation) }
            if coordination.activeTerminalCount > 0 || coordination.activeACPCount > 0 { blockers.insert(.activeSession) }
            return blocked(CheckpointRestoreBlocker.highestPriority(in: blockers) ?? .corruptCheckpoint)
        }
        var blockers: Set<CheckpointRestoreBlocker> = []
        do { _ = try await store.load(id: id, lineageID: target.lineageID) }
        catch { blockers.insert(.corruptCheckpoint) }
        let current = try await snapshotter.snapshot(target: target, includingPaths: Set(saved.paths.map(\.relativePath)),
                                                     retainingPayloads: false)
        return try .make(manifest: saved, current: current, coordination: coordination, selectedGroupIDs: selectedGroupIDs, blockers: blockers)
    }

    func diffContent(target: CheckpointWorktreeTarget, id: CheckpointID, path: String) async -> CheckpointDiffContent {
        do {
            guard !target.path.isRemoteAlasPath else { return .unavailable(CheckpointRestoreBlocker.remoteTarget.description) }
            guard WorktreeService.existingLocalLineageID(forWorktreeAt: target.path) == target.lineageID else {
                return .unavailable(CheckpointRestoreBlocker.lineageMismatch.description)
            }
            let saved = try await store.load(id: id, lineageID: target.lineageID)
            _ = try snapshotter.fileSystem.validateRelativePath(path, under: target.path)
            let before: Data?
            if let state = saved.paths.first(where: { $0.relativePath == path })?.worktree {
                if let blob = state.blob { before = try await store.readBlob(blob, lineageID: target.lineageID) }
                else { before = nil }
            } else {
                let current = try await snapshotter.snapshot(target: target, includingPaths: [path])
                guard current.headOID == saved.headOID, let state = current.paths[path] else {
                    return .unavailable("The checkpoint baseline is unavailable for this path.")
                }
                before = try current.payload(state.head)
            }
            let after: Data?
            if try snapshotter.fileSystem.metadata(root: target.path, relativePath: path) == nil { after = nil }
            else {
                switch try snapshotter.fileSystem.readLeaf(root: target.path, relativePath: path) {
                case .regular(let data, _), .symlink(let data): after = data
                }
            }
            if ImageFileType.isSupported(relativePath: path) {
                func side(_ data: Data?) -> ImageDiffSide {
                    guard let data else { return .missing }
                    guard let image = NSImage(data: data) else { return .failed(.init(message: "Image could not be decoded.")) }
                    return GitService.imageSide(forDecodedImage: image)
                }
                return .image(.init(before: side(before), after: side(after), oldPath: nil,
                                    kind: before == nil ? .added : after == nil ? .deleted : .modified))
            }
            let binary = [before, after].compactMap { $0 }.contains { $0.contains(0) || String(data: $0, encoding: .utf8) == nil }
            if binary { return .binary(beforeByteCount: before.map { Int64($0.count) }, afterByteCount: after.map { Int64($0.count) }) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-diff-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            if let before {
                try before.write(to: directory.appendingPathComponent("before"))
            }
            if let after {
                try after.write(to: directory.appendingPathComponent("after"))
            }
            let beforePath = before == nil ? "/dev/null" : "before"
            let afterPath = after == nil ? "/dev/null" : "after"
            let result = try await snapshotter.git.run(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color",
                                                       "--src-prefix=checkpoint/", "--dst-prefix=current/", "--", beforePath, afterPath],
                                                      cwd: directory, environment: [:])
            guard result.exitCode == 0 || result.exitCode == 1 else {
                throw ProcessError.nonZeroExit(result.exitCode, result.stderr)
            }
            var diff = DiffParser.parse(result.stdout)
            if diff.hunks.isEmpty, diff.metadataSummary == nil, before == nil || after == nil {
                diff.metadataSummary = before == nil ? "Empty file added." : "Empty file deleted."
            }
            if diff.isBinary { return .binary(beforeByteCount: before.map { Int64($0.count) }, afterByteCount: after.map { Int64($0.count) }) }
            return .text(diff)
        } catch {
            return .unavailable("The checkpoint diff could not be loaded.")
        }
    }

    private func previewGit(_ args: [String], target: CheckpointWorktreeTarget) async throws -> String {
        let result = try await snapshotter.git.run(args, cwd: target.path, environment: [:])
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        return result.stdout
    }

    func createManual(target: CheckpointWorktreeTarget, label: String) async throws -> WorktreeCheckpointSummary {
        let label = try normalizedLabel(label)
        for number in 1...2 {
            do {
                let attempt = try await CheckpointCaptureAttempt(snapshot: snapshotter.snapshot(target: target), capturedAt: .now)
                try await hooks.afterPayloadStaging(number)
                let verification = try await snapshotter.snapshot(target: target, retainingPayloads: false)
                guard attempt.snapshot.fingerprint == verification.fingerprint else { continue }
                return try await publish(target: target, attempt: attempt, paths: Set(attempt.snapshot.paths.keys),
                                         kind: .manual, label: label)
            } catch CheckpointSnapshotError.stateChanged {
                continue
            }
        }
        throw CheckpointCaptureError.unstableWorktree
    }

    // Restore preflight supplies the selected current states, including clean
    // and absent paths which a dirty-worktree snapshot may not contain.
    func createRecovery(target: CheckpointWorktreeTarget, current: WorktreeStateSnapshot,
                        selectedPaths: Set<String>, protecting checkpointID: CheckpointID? = nil) async throws -> WorktreeCheckpointSummary {
        guard current.lineageID == target.lineageID else { throw CheckpointSnapshotError.lineageChanged }
        return try await publish(target: target, attempt: .init(snapshot: current, capturedAt: .now),
                                 paths: selectedPaths, kind: .recovery, label: "Before checkpoint restore",
                                 protecting: checkpointID.map { [$0] } ?? [])
    }

    func prepareRestore(target: CheckpointWorktreeTarget, preview: CheckpointRestorePreview,
                        selectedGroupIDs: Set<UUID>, coordination: CheckpointCoordinationSnapshot,
                        faultInjector: CheckpointRestoreFaultInjector = .none) async throws -> CheckpointRestorePreparation {
        let refreshed = try await restorePreview(target: target, id: preview.checkpointID, coordination: coordination,
                                                 selectedGroupIDs: selectedGroupIDs)
        if let blocker = refreshed.blocker { throw CheckpointRestoreError.blocked(blocker) }
        guard refreshed.currentFingerprint == preview.currentFingerprint else { throw CheckpointRestoreError.stalePreview }
        let manifest = try await store.load(id: refreshed.checkpointID, lineageID: target.lineageID)
        let selected = selectedGroupIDs.isEmpty ? preview.selectedGroupIDs : selectedGroupIDs
        let groups = Dictionary(uniqueKeysWithValues: refreshed.groups.map { ($0.id, $0) })
        for id in selected where groups[id] == nil { throw CheckpointRestoreError.missingPreviewGroup(id) }
        let selectedPaths = Set(selected.compactMap { groups[$0] }.flatMap(\.memberPaths))
        let current = try await snapshotter.snapshot(target: target, includingPaths: Set(manifest.paths.map(\.relativePath)))
        guard current.fingerprint == preview.currentFingerprint else { throw CheckpointRestoreError.stalePreview }
        let recovery = try await createRecovery(target: target, current: current, selectedPaths: selectedPaths,
                                                protecting: manifest.id)
        _ = try await store.load(id: recovery.id, lineageID: target.lineageID)
        try faultInjector.hit(.afterRecoveryPublication)
        return try await CheckpointRestoreTransaction(store: store, git: snapshotter.git, fileSystem: snapshotter.fileSystem,
                                                       faultInjector: faultInjector)
            .prepare(target: target, preview: preview, manifest: manifest, current: current,
                     selectedPaths: selectedPaths.sorted(by: restoreApplicationOrder), recoveryCheckpointID: recovery.id)
    }

    func restore(target: CheckpointWorktreeTarget, preview: CheckpointRestorePreview, selectedGroupIDs: Set<UUID>,
                 coordination: CheckpointCoordinationSnapshot) async throws -> CheckpointRestoreResult {
        guard !selectedGroupIDs.isEmpty else { throw CheckpointRestoreError.emptySelection }
        let preparation = try await prepareRestore(target: target, preview: preview, selectedGroupIDs: selectedGroupIDs,
                                                    coordination: coordination, faultInjector: restoreFaultInjector)
        return try await restoreTransaction.apply(preparation)
    }

    func recoverInterruptedRestore(target: CheckpointWorktreeTarget, operationID: UUID,
                                   coordination: CheckpointCoordinationSnapshot) async throws -> CheckpointRestoreResult {
        try await restoreTransaction.recover(target: target, operationID: operationID, coordination: coordination)
    }

    private var restoreTransaction: CheckpointRestoreTransaction {
        .init(store: store, git: snapshotter.git, fileSystem: snapshotter.fileSystem, faultInjector: restoreFaultInjector)
    }

    private func validateLineage(_ target: CheckpointWorktreeTarget) throws {
        guard WorktreeService.existingLocalLineageID(forWorktreeAt: target.path) == target.lineageID else {
            throw CheckpointSnapshotError.lineageChanged
        }
    }

    private func restoreApplicationOrder(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDepth = lhs.split(separator: "/").count
        let rhsDepth = rhs.split(separator: "/").count
        if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
        return lhs < rhs
    }

    private func previewHeadOID(target: CheckpointWorktreeTarget) async throws -> String {
        let result = try await LiveCheckpointGitRunner().run(["rev-parse", "--verify", "HEAD"], cwd: target.path, environment: [:])
        if result.exitCode == 0 { return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        let unborn = try await LiveCheckpointGitRunner().run(["rev-parse", "--verify", "--quiet", "HEAD"], cwd: target.path, environment: [:])
        guard unborn.exitCode == 1 else { throw CheckpointRestoreError.invalidGitOutput }
        let empty = try await LiveCheckpointGitRunner().run(["hash-object", "-t", "tree", "/dev/null"], cwd: target.path, environment: [:])
        guard empty.exitCode == 0 else { throw CheckpointRestoreError.invalidGitOutput }
        return empty.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedLabel(_ label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CheckpointModelError.invalidLabel }
        return String(trimmed.prefix(120))
    }

    private func publish(target: CheckpointWorktreeTarget, attempt: CheckpointCaptureAttempt,
                         paths selectedPaths: Set<String>, kind: CheckpointKind, label: String,
                         protecting: Set<CheckpointID> = []) async throws -> WorktreeCheckpointSummary {
        let snapshot = attempt.snapshot
        let paths = try selectedPaths.sorted().map { path in
            guard let state = snapshot.paths[path] else { throw CheckpointCaptureError.missingSelectedPath(path) }
            return state
        }
        var blobs: [CheckpointBlobReference: Data] = [:]
        for state in paths.flatMap({ [$0.head, $0.index, $0.worktree] }) {
            if let bytes = try snapshot.payload(state) {
                blobs[CheckpointBlobReference.make(for: bytes)] = bytes
            }
        }
        let groups = snapshot.groups.compactMap { group -> CheckpointFileGroup? in
            let members = group.memberPaths.filter { selectedPaths.contains($0) }
            guard let first = members.first else { return nil }
            return .init(id: group.id, primaryPath: members.contains(group.primaryPath) ? group.primaryPath : first,
                         renameSource: group.renameSource.flatMap { members.contains($0) ? $0 : nil }, memberPaths: members)
        }
        let manifest = try WorktreeCheckpointManifest(
            // The persisted ISO-8601 format stores whole seconds. Use that
            // precision for the returned summary as well as the saved manifest.
            kind: kind, label: label, createdAt: Date(timeIntervalSince1970: attempt.capturedAt.timeIntervalSince1970.rounded(.down)),
            byteCount: blobs.keys.reduce(0) { $0 + $1.byteCount }, lineageID: target.lineageID,
            capturedPath: target.path.path, repositoryName: target.repositoryName,
            branch: snapshot.branch, headOID: snapshot.headOID,
            exclusions: kind == .manual ? snapshot.exclusions : [], groups: groups, paths: paths
        )
        let catalog = try await store.publish(.init(manifest: manifest, blobs: blobs), protecting: protecting)
        cachedCatalogs[target.lineageID] = catalog
        guard let summary = catalog.summaries.first(where: { $0.id == manifest.id }) else {
            throw CheckpointStoreError.checkpointNotFound
        }
        return summary
    }
}
