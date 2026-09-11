import Foundation

enum CheckpointRestoreError: Error, Equatable, Sendable {
    case blocked(CheckpointRestoreBlocker)
    case stalePreview
    case missingPreviewGroup(UUID)
    case missingCurrentPath(String)
    case missingDesiredPath(String)
    case invalidGitOutput
}

struct CheckpointRestorePreparation: Equatable, Sendable {
    let operationID: UUID
    let target: CheckpointWorktreeTarget
    let checkpointID: CheckpointID
    let recoveryCheckpointID: CheckpointID
    let selectedPaths: [String]
    let expectedFingerprint: String
    let expectedIndexChecksum: String
    let preparedIndex: URL
    let stagingRoot: URL
    let replacementsRoot: URL
    let backupsRoot: URL
}

enum CheckpointRestoreFaultPoint: Equatable, Sendable {
    case afterRecoveryPublication
    case afterJournalPrepared
    case afterFileMove(path: String)
    case beforeIndexInstall
    case afterIndexInstall
    case beforeVerification
    case duringRollback(path: String)
}

struct CheckpointRestoreFaultInjector: Sendable {
    let hit: @Sendable (CheckpointRestoreFaultPoint) throws -> Void

    static let none = Self(hit: { _ in })
}

struct CheckpointRestoreTransaction: Sendable {
    let store: WorktreeCheckpointStore
    let git: any CheckpointGitRunning
    let fileSystem: any CheckpointFileSystem
    let faultInjector: CheckpointRestoreFaultInjector

    init(store: WorktreeCheckpointStore, git: any CheckpointGitRunning,
         fileSystem: any CheckpointFileSystem, faultInjector: CheckpointRestoreFaultInjector = .none) {
        self.store = store
        self.git = git
        self.fileSystem = fileSystem
        self.faultInjector = faultInjector
    }

    func prepare(target: CheckpointWorktreeTarget, preview: CheckpointRestorePreview,
                 manifest: WorktreeCheckpointManifest, current: WorktreeStateSnapshot,
                 selectedPaths: [String], recoveryCheckpointID: CheckpointID) async throws -> CheckpointRestorePreparation {
        guard current.fingerprint == preview.currentFingerprint else { throw CheckpointRestoreError.stalePreview }
        let operationID = UUID()
        let stagingRoot = target.path.appendingPathComponent(".alas-checkpoint-restore-\(operationID.uuidString.lowercased())", isDirectory: true)
        let replacementsRoot = stagingRoot.appendingPathComponent("replacements", isDirectory: true)
        let backupsRoot = stagingRoot.appendingPathComponent("backups", isDirectory: true)
        let preparedIndex = stagingRoot.appendingPathComponent("index")
        var createdStaging = false
        var journalWritten = false

        do {
            try fileSystem.createDirectoryExclusively(stagingRoot, mode: 0o700)
            createdStaging = true
            try fileSystem.createDirectoryExclusively(replacementsRoot, mode: 0o700)
            try fileSystem.createDirectoryExclusively(backupsRoot, mode: 0o700)
            try await makePreparedIndex(at: preparedIndex, target: target, manifest: manifest, current: current,
                                        selectedPaths: selectedPaths)

            var stagingNames: [String: String] = [:]
            let saved = Dictionary(uniqueKeysWithValues: manifest.paths.map { ($0.relativePath, $0) })
            for path in selectedPaths {
                guard let now = current.paths[path] else { throw CheckpointRestoreError.missingCurrentPath(path) }
                let desired = saved[path] ?? .init(relativePath: path, head: now.head, index: now.head, worktree: now.head)
                let name = UUID().uuidString.lowercased()
                stagingNames[path] = name
                try await materialize(desired.worktree, at: replacementsRoot.appendingPathComponent(name), target: target)
            }

            let journal = CheckpointRestoreJournal(id: operationID, lineageID: target.lineageID,
                                                    checkpointID: manifest.id, recoveryCheckpointID: recoveryCheckpointID,
                                                    phase: .prepared, stagingRoot: stagingRoot.path, selectedPaths: selectedPaths,
                                                    expectedFingerprint: preview.currentFingerprint,
                                                    expectedIndexChecksum: current.indexChecksum,
                                                    stagingNames: stagingNames)
            try await store.writeJournal(journal)
            journalWritten = true
            guard try await store.journal(id: operationID, lineageID: target.lineageID) == journal else {
                throw CheckpointRestoreError.invalidGitOutput
            }
            try faultInjector.hit(.afterJournalPrepared)
            return .init(operationID: operationID, target: target, checkpointID: manifest.id,
                         recoveryCheckpointID: recoveryCheckpointID, selectedPaths: selectedPaths,
                         expectedFingerprint: preview.currentFingerprint, expectedIndexChecksum: current.indexChecksum,
                         preparedIndex: preparedIndex, stagingRoot: stagingRoot,
                         replacementsRoot: replacementsRoot, backupsRoot: backupsRoot)
        } catch {
            if journalWritten { try? await store.discardPreparedJournal(id: operationID, lineageID: target.lineageID) }
            if createdStaging { try? FileManager.default.removeItem(at: stagingRoot) }
            throw error
        }
    }

    private func makePreparedIndex(at preparedIndex: URL, target: CheckpointWorktreeTarget,
                                   manifest: WorktreeCheckpointManifest, current: WorktreeStateSnapshot,
                                   selectedPaths: [String]) async throws {
        let indexPath = try await gitPath("index", target: target)
        if FileManager.default.fileExists(atPath: indexPath.path) {
            try fileSystem.writeDurable(try fileSystem.fileData(indexPath), to: preparedIndex, mode: 0o600)
        } else {
            let result = try await git.run(["read-tree", "--empty"], cwd: target.path,
                                           environment: ["GIT_INDEX_FILE": preparedIndex.path])
            guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        }
        let saved = Dictionary(uniqueKeysWithValues: manifest.paths.map { ($0.relativePath, $0) })
        for path in selectedPaths {
            guard let now = current.paths[path] else { throw CheckpointRestoreError.missingCurrentPath(path) }
            let state = saved[path]?.index ?? now.head
            if state.kind == .absent {
                try await runGit(["update-index", "--force-remove", "--", path], target: target, index: preparedIndex)
                continue
            }
            guard let blob = state.blob, let mode = state.mode else { throw CheckpointRestoreError.missingDesiredPath(path) }
            let bytes = try await store.readBlob(blob, lineageID: target.lineageID)
            let materialized = preparedIndex.deletingLastPathComponent().appendingPathComponent("index-\(UUID().uuidString.lowercased())")
            try fileSystem.writeDurable(bytes, to: materialized, mode: 0o600)
            defer { try? fileSystem.removeIfPresent(materialized) }
            let hash = try await git.run(["hash-object", "-w", materialized.path], cwd: target.path, environment: [:])
            guard hash.exitCode == 0 else { throw ProcessError.nonZeroExit(hash.exitCode, hash.stderr) }
            let oid = hash.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            try await runGit(["update-index", "--add", "--cacheinfo", mode, oid, path], target: target, index: preparedIndex)
        }
    }

    private func materialize(_ state: CheckpointFileState, at url: URL, target: CheckpointWorktreeTarget) async throws {
        guard state.kind != .absent else { return }
        guard let blob = state.blob else { throw CheckpointRestoreError.invalidGitOutput }
        let bytes = try await store.readBlob(blob, lineageID: target.lineageID)
        switch state.kind {
        case .regular:
            try fileSystem.writeDurable(bytes, to: url, mode: state.mode == "100755" ? 0o755 : 0o644)
        case .symlink:
            try fileSystem.createSymlink(target: bytes, at: url)
        case .absent:
            return
        }
        let actual = try fileSystem.readLeaf(root: url.deletingLastPathComponent(), relativePath: url.lastPathComponent)
        switch (state.kind, actual) {
        case (.regular, .regular(let data, let executable)):
            guard CheckpointBlobReference.make(for: data) == blob, executable == (state.mode == "100755") else { throw CheckpointRestoreError.invalidGitOutput }
        case (.symlink, .symlink(let data)):
            guard CheckpointBlobReference.make(for: data) == blob else { throw CheckpointRestoreError.invalidGitOutput }
        default:
            throw CheckpointRestoreError.invalidGitOutput
        }
    }

    private func gitPath(_ name: String, target: CheckpointWorktreeTarget) async throws -> URL {
        let result = try await git.run(["rev-parse", "--path-format=absolute", "--git-path", name], cwd: target.path, environment: [:])
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        return URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func runGit(_ args: [String], target: CheckpointWorktreeTarget, index: URL) async throws {
        let result = try await git.run(args, cwd: target.path, environment: ["GIT_INDEX_FILE": index.path])
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
    }
}
