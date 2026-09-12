import Darwin
import Foundation

enum CheckpointRestoreError: Error, Equatable, Sendable {
    case blocked(CheckpointRestoreBlocker)
    case stalePreview
    case missingPreviewGroup(UUID)
    case missingCurrentPath(String)
    case missingDesiredPath(String)
    case invalidGitOutput
    case emptySelection
    case invalidJournal
    case restoreFailedButRecovered
    case recoveryRequired(operationID: UUID, paths: [String], phase: CheckpointRestoreJournal.Phase)
}

struct CheckpointRestoreResult: Equatable, Sendable {
    let recoveryCheckpointID: CheckpointID
    let restoredPaths: [String]
}

struct CheckpointRestorePreparation: Equatable, Sendable {
    let operationID: UUID
    let target: CheckpointWorktreeTarget
    let checkpointID: CheckpointID
    let recoveryCheckpointID: CheckpointID
    let selectedPaths: [String]
    let expectedFingerprint: String
    let expectedIndexChecksum: String
    let preparedIndexChecksum: String
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
    case afterPartialIndexWrite
    case beforeIndexCandidateSync
    case afterIndexCandidatePublication
    case afterIndexLockIntentJournaled
    case afterIndexLockJournaled
    case afterIndexLockHandoff
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
            let initialJournal = CheckpointRestoreJournal(id: operationID, lineageID: target.lineageID,
                                                           checkpointID: manifest.id, recoveryCheckpointID: recoveryCheckpointID,
                                                           phase: .prepared, stagingRoot: stagingRoot.path, selectedPaths: selectedPaths,
                                                           expectedFingerprint: preview.currentFingerprint,
                                                           expectedIndexChecksum: current.indexChecksum)
            try await store.writeJournal(initialJournal)
            journalWritten = true
            let originalIndex = try await gitPath("index", target: target)
            let originalBytes = FileManager.default.fileExists(atPath: originalIndex.path) ? try fileSystem.fileData(originalIndex) : Data()
            guard digest(originalBytes) == current.indexChecksum else { throw CheckpointRestoreError.stalePreview }
            try fileSystem.writeDurable(originalBytes, to: stagingRoot.appendingPathComponent("original-index"), mode: 0o600)
            try await makePreparedIndex(at: preparedIndex, target: target, manifest: manifest, current: current,
                                        selectedPaths: selectedPaths)
            let preparedIndexChecksum = CheckpointBlobReference.make(for: try fileSystem.fileData(preparedIndex)).sha256

            var stagingNames: [String: String] = [:]
            let saved = Dictionary(uniqueKeysWithValues: manifest.paths.map { ($0.relativePath, $0) })
            for path in selectedPaths {
                let desired = try desiredState(for: path, saved: saved, current: current, selectedPaths: selectedPaths)
                let name = UUID().uuidString.lowercased()
                stagingNames[path] = name
                try await materialize(desired.worktree, at: replacementsRoot.appendingPathComponent(name), target: target)
            }

            let journal = CheckpointRestoreJournal(id: operationID, lineageID: target.lineageID,
                                                    checkpointID: manifest.id, recoveryCheckpointID: recoveryCheckpointID,
                                                    phase: .prepared, stagingRoot: stagingRoot.path, selectedPaths: selectedPaths,
                                                    expectedFingerprint: preview.currentFingerprint,
                                                    expectedIndexChecksum: current.indexChecksum,
                                                    preparedIndexChecksum: preparedIndexChecksum,
                                                    stagingNames: stagingNames)
            try await store.writeJournal(journal)
            guard try await store.journal(id: operationID, lineageID: target.lineageID) == journal else {
                throw CheckpointRestoreError.invalidGitOutput
            }
            try faultInjector.hit(.afterJournalPrepared)
            return .init(operationID: operationID, target: target, checkpointID: manifest.id,
                         recoveryCheckpointID: recoveryCheckpointID, selectedPaths: selectedPaths,
                         expectedFingerprint: preview.currentFingerprint, expectedIndexChecksum: current.indexChecksum,
                         preparedIndexChecksum: preparedIndexChecksum,
                         preparedIndex: preparedIndex, stagingRoot: stagingRoot,
                         replacementsRoot: replacementsRoot, backupsRoot: backupsRoot)
        } catch {
            if journalWritten { try? await store.discardPreparedJournal(id: operationID, lineageID: target.lineageID) }
            if createdStaging { try? FileManager.default.removeItem(at: stagingRoot) }
            throw error
        }
    }

    func apply(_ preparation: CheckpointRestorePreparation) async throws -> CheckpointRestoreResult {
        let target = preparation.target
        guard var journal = try await store.journal(id: preparation.operationID, lineageID: target.lineageID),
              journal.id == preparation.operationID else {
            throw CheckpointRestoreError.invalidJournal
        }
        var beganWrites = false
        do {
            try await validateJournal(journal, target: target)
            try await acquireLock(journal: &journal, target: target)
            let desired = try await store.load(id: journal.checkpointID, lineageID: target.lineageID)
            let recovery = try await store.load(id: journal.recoveryCheckpointID, lineageID: target.lineageID)
            let current = try await snapshot(target, journal: journal, including: Set(desired.paths.map(\.relativePath)))
            guard current.fingerprint == journal.expectedFingerprint,
                  current.indexChecksum == journal.expectedIndexChecksum,
                  current.headOID == desired.headOID else { throw CheckpointRestoreError.stalePreview }
            for state in recovery.paths {
                guard current.paths[state.relativePath] == state else { throw CheckpointRestoreError.stalePreview }
            }
            for path in journal.selectedPaths {
                try validateLock(journal)
                let before = try requiredState(path, in: recovery)
                guard try leafState(path, root: target.path) == before.worktree else { throw CheckpointRestoreError.stalePreview }
                let destination = try ensureParent(path, root: target.path)
                let name = try stagingName(path, journal: journal)
                journal.phase = .applyingFiles
                journal.pendingPath = path
                try await store.writeJournal(journal)
                beganWrites = true
                if before.worktree.kind != .absent {
                    try moveLeaf(destination, to: preparation.backupsRoot.appendingPathComponent(name))
                    guard try leafState(name, root: preparation.backupsRoot) == before.worktree else {
                        throw CheckpointRestoreError.stalePreview
                    }
                    try faultInjector.hit(.afterFileMove(path: path))
                }
                let replacement = preparation.replacementsRoot.appendingPathComponent(name)
                if try fileSystem.metadata(root: preparation.replacementsRoot, relativePath: name) != nil {
                    if before.worktree.kind == .absent {
                        try removeEmptyDirectoryIfPresent(destination)
                    }
                    try moveLeaf(replacement, to: destination)
                }
                journal.completedPaths.append(path)
                journal.pendingPath = nil
                try await store.writeJournal(journal)
                try faultInjector.hit(.afterFileMove(path: path))
            }
            try faultInjector.hit(.beforeIndexInstall)
            try await revalidateIndexAndHead(journal, target: target, head: desired.headOID,
                                            allowedChecksums: [journal.expectedIndexChecksum])
            let bytes = try fileSystem.fileData(preparation.preparedIndex)
            guard digest(bytes) == journal.preparedIndexChecksum else { throw CheckpointRestoreError.invalidJournal }
            try await installIndex(bytes, journal: &journal, target: target)
            try faultInjector.hit(.afterIndexInstall)
            journal.phase = .verifying
            try await store.writeJournal(journal)
            try faultInjector.hit(.beforeVerification)
            let after = try await snapshot(target, journal: journal, including: Set(journal.selectedPaths))
            guard after.headOID == desired.headOID else { throw CheckpointRestoreError.stalePreview }
            let saved = Dictionary(uniqueKeysWithValues: desired.paths.map { ($0.relativePath, $0) })
            for path in journal.selectedPaths {
                let expected = try desiredState(for: path, saved: saved, current: current, selectedPaths: journal.selectedPaths)
                guard let actual = after.paths[path],
                      actual.index == expected.index,
                      actual.worktree == expected.worktree else { throw CheckpointRestoreError.invalidGitOutput }
            }
            try await finish(&journal, target: target, phase: .completed)
            return .init(recoveryCheckpointID: journal.recoveryCheckpointID, restoredPaths: journal.selectedPaths)
        } catch {
            let originalError = error
            if beganWrites {
                do { try await rollback(&journal, target: target) }
                catch { throw recoveryRequired(journal) }
                throw CheckpointRestoreError.restoreFailedButRecovered
            }
            do {
                try removeOwnedLock(journal)
                try await finish(&journal, target: target, phase: .recovered)
            } catch { throw recoveryRequired(journal) }
            throw originalError
        }
    }

    func recover(target: CheckpointWorktreeTarget, operationID: UUID,
                 coordination: CheckpointCoordinationSnapshot) async throws -> CheckpointRestoreResult {
        guard !target.path.isRemoteAlasPath else { throw CheckpointRestoreError.blocked(.remoteTarget) }
        guard WorktreeService.existingLocalLineageID(forWorktreeAt: target.path) == target.lineageID else {
            throw CheckpointRestoreError.blocked(.lineageMismatch)
        }
        guard var journal = try await store.journal(id: operationID, lineageID: target.lineageID),
              journal.id == operationID, !journal.phase.isTerminal else {
            throw CheckpointRestoreError.invalidJournal
        }
        try await validateJournal(journal, target: target)
        if coordination.otherGitMutationActive { throw CheckpointRestoreError.blocked(.otherGitMutation) }
        if coordination.activeTerminalCount > 0 || coordination.activeACPCount > 0 { throw CheckpointRestoreError.blocked(.activeSession) }
        if !coordination.dirtyEditorPaths.isDisjoint(with: journal.selectedPaths) { throw CheckpointRestoreError.blocked(.dirtyEditorBuffer) }
        if journal.preparedIndexChecksum == nil && journal.stagingNames.isEmpty && journal.phase == .prepared
            && journal.completedPaths.isEmpty && journal.pendingPath == nil && journal.ownedIndexLockPath == nil
            && journal.pendingIndexLock == nil {
            try await finish(&journal, target: target, phase: .recovered)
            return .init(recoveryCheckpointID: journal.recoveryCheckpointID, restoredPaths: journal.selectedPaths)
        }
        do { try await rollback(&journal, target: target) }
        catch { throw recoveryRequired(journal) }
        return .init(recoveryCheckpointID: journal.recoveryCheckpointID, restoredPaths: journal.selectedPaths)
    }

    private func rollback(_ journal: inout CheckpointRestoreJournal, target: CheckpointWorktreeTarget) async throws {
        try await validateJournal(journal, target: target)
        let recovery = try await store.load(id: journal.recoveryCheckpointID, lineageID: target.lineageID)
        let desired = try await store.load(id: journal.checkpointID, lineageID: target.lineageID)
        guard recovery.kind == .recovery, recovery.headOID == desired.headOID,
              Set(recovery.paths.map(\.relativePath)) == Set(journal.selectedPaths) else { throw CheckpointRestoreError.invalidJournal }
        let index = try await gitPath("index", target: target)
        let lock = try await gitPath("index.lock", target: target)
        if try exists(lock) { try validateLock(journal) }
        else { try await acquireLock(journal: &journal, target: target) }
        let indexBytes = try exists(index) ? try fileSystem.fileData(index) : Data()
        guard [journal.expectedIndexChecksum, journal.preparedIndexChecksum].contains(digest(indexBytes)) else {
            throw CheckpointRestoreError.stalePreview
        }
        let current = try await selectedSnapshot(target, journal: journal)
        guard current.headOID == recovery.headOID else { throw CheckpointRestoreError.blocked(.changedHEAD) }
        let root = URL(fileURLWithPath: journal.stagingRoot)
        let originalIndex = try fileSystem.fileData(root.appendingPathComponent("original-index"))
        guard digest(originalIndex) == journal.expectedIndexChecksum else { throw CheckpointRestoreError.invalidJournal }
        journal.phase = .rollingBack
        try await store.writeJournal(journal)
        var touched = journal.completedPaths
        if let pending = journal.pendingPath, !touched.contains(pending) { touched.append(pending) }
        // Backups are retained until every path and the index have verified.
        // Repeated recovery therefore remains possible after another interruption.
        for path in touched.reversed() {
            try faultInjector.hit(.duringRollback(path: path))
            try validateLock(journal)
            let before = try requiredState(path, in: recovery)
            let saved = Dictionary(uniqueKeysWithValues: desired.paths.map { ($0.relativePath, $0) })
            let expected = try desiredState(for: path, saved: saved, current: current, selectedPaths: journal.selectedPaths).worktree
            let actual = try leafState(path, root: target.path)
            if actual == before.worktree { continue }
            let name = try stagingName(path, journal: journal)
            let backupRoot = root.appendingPathComponent("backups")
            let backup = try leafState(name, root: backupRoot)
            guard actual == expected || (actual.kind == .absent && backup == before.worktree) else {
                throw CheckpointRestoreError.stalePreview
            }
            if before.worktree.kind != .absent {
                guard backup == before.worktree else { throw CheckpointRestoreError.invalidJournal }
            }
            let destination = try ensureParent(path, root: target.path)
            let replacement = root.appendingPathComponent("rollback-\(UUID().uuidString.lowercased())")
            try await materialize(before.worktree, at: replacement, target: target)
            if actual.kind != .absent {
                let displaced = root.appendingPathComponent("displaced-\(UUID().uuidString.lowercased())")
                try moveLeaf(destination, to: displaced)
                guard try leafState(displaced.lastPathComponent, root: root) == actual else { throw CheckpointRestoreError.stalePreview }
            }
            if before.worktree.kind != .absent {
                if actual.kind == .absent {
                    try removeEmptyDirectoryIfPresent(destination)
                }
                try moveLeaf(replacement, to: destination)
            }
            try await store.writeJournal(journal)
        }
        try await revalidateIndexAndHead(journal, target: target, head: recovery.headOID,
                                        allowedChecksums: [digest(indexBytes)])
        // Preserve the exact original index bytes, including extensions and stat
        // entries. The recovery manifest independently verifies its selected states.
        try await installIndex(originalIndex, journal: &journal, target: target)
        let after = try await selectedSnapshot(target, journal: journal)
        for state in recovery.paths {
            guard after.paths[state.relativePath] == state else { throw CheckpointRestoreError.invalidGitOutput }
        }
        guard after.indexChecksum == journal.expectedIndexChecksum,
              after.headOID == recovery.headOID else { throw CheckpointRestoreError.stalePreview }
        try await finish(&journal, target: target, phase: .recovered)
    }

    private func validateJournal(_ journal: CheckpointRestoreJournal, target: CheckpointWorktreeTarget) async throws {
        guard journal.lineageID == target.lineageID, !journal.phase.isTerminal,
              WorktreeService.existingLocalLineageID(forWorktreeAt: target.path) == target.lineageID,
              journal.stagingRoot == target.path.appendingPathComponent(".alas-checkpoint-restore-\(journal.id.uuidString.lowercased())").path,
              Set(journal.selectedPaths).count == journal.selectedPaths.count,
              Set(journal.completedPaths).isSubset(of: Set(journal.selectedPaths)),
              journal.pendingPath.map({ journal.selectedPaths.contains($0) }) ?? true else { throw CheckpointRestoreError.invalidJournal }
        let root = URL(fileURLWithPath: journal.stagingRoot)
        _ = try fileSystem.list(root)
        _ = try fileSystem.list(root.appendingPathComponent("backups"))
        _ = try fileSystem.list(root.appendingPathComponent("replacements"))
        let preparationIsComplete = journal.preparedIndexChecksum != nil
        if preparationIsComplete {
            guard Set(journal.stagingNames.values).count == journal.selectedPaths.count else { throw CheckpointRestoreError.invalidJournal }
        } else {
            guard journal.phase == .prepared, journal.stagingNames.isEmpty, journal.completedPaths.isEmpty,
                  journal.pendingPath == nil, journal.ownedIndexLockPath == nil, journal.pendingIndexLock == nil else {
                throw CheckpointRestoreError.invalidJournal
            }
        }
        for path in journal.selectedPaths {
            try validateRestorePath(path, selectedPaths: journal.selectedPaths, under: target.path)
            guard !path.split(separator: "/").contains(".git"), !path.hasPrefix(".alas-checkpoint-restore-") else {
                throw CheckpointRestoreError.invalidJournal
            }
            if preparationIsComplete {
                _ = try stagingName(path, journal: journal)
            }
        }
        if let lock = journal.ownedIndexLockPath {
            guard lock == (try await gitPath("index.lock", target: target)).path else { throw CheckpointRestoreError.invalidJournal }
        }
        if let pending = journal.pendingIndexLock {
            let candidate = URL(fileURLWithPath: pending.path)
            let index = try await gitPath("index", target: target)
            let prefixes = [
                ".alas-checkpoint-index-\(journal.id.uuidString.lowercased())-",
                ".alas-checkpoint-index-lock-\(journal.id.uuidString.lowercased())-",
            ]
            let suffix = prefixes.first { candidate.lastPathComponent.hasPrefix($0) }.map { prefix in
                String(candidate.lastPathComponent.dropFirst(prefix.count))
            }
            guard candidate.deletingLastPathComponent().path == index.deletingLastPathComponent().path,
                  suffix.flatMap(UUID.init(uuidString:)) != nil else {
                throw CheckpointRestoreError.invalidJournal
            }
        }
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"] {
            let path = try await gitPath(marker, target: target)
            if FileManager.default.fileExists(atPath: path.path) { throw CheckpointRestoreError.blocked(.gitOperation) }
        }
    }

    private func snapshot(_ target: CheckpointWorktreeTarget, journal: CheckpointRestoreJournal,
                          including paths: Set<String>) async throws -> WorktreeStateSnapshot {
        try await WorktreeStateSnapshotter(git: git, fileSystem: fileSystem)
            .snapshot(target: target, includingPaths: paths, ignoringRestoreOperation: journal.id)
    }

    private func selectedSnapshot(_ target: CheckpointWorktreeTarget, journal: CheckpointRestoreJournal) async throws -> WorktreeStateSnapshot {
        try await WorktreeStateSnapshotter(git: git, fileSystem: fileSystem)
            .snapshot(target: target, includingPaths: Set(journal.selectedPaths), onlyIncludedPaths: true)
    }

    private func revalidateIndexAndHead(_ journal: CheckpointRestoreJournal, target: CheckpointWorktreeTarget,
                                       head: String, allowedChecksums: Set<String>) async throws {
        try validateLock(journal)
        guard WorktreeService.existingLocalLineageID(forWorktreeAt: target.path) == target.lineageID else {
            throw CheckpointRestoreError.blocked(.lineageMismatch)
        }
        let currentHead = try await headOID(target)
        guard currentHead == head else {
            throw CheckpointRestoreError.blocked(.changedHEAD)
        }
        let index = try await gitPath("index", target: target)
        let bytes = try exists(index) ? try fileSystem.fileData(index) : Data()
        guard allowedChecksums.contains(digest(bytes)) else { throw CheckpointRestoreError.stalePreview }
    }

    private func acquireLock(journal: inout CheckpointRestoreJournal, target: CheckpointWorktreeTarget) async throws {
        let index = try await gitPath("index", target: target)
        let lock = try await gitPath("index.lock", target: target)
        _ = try fileSystem.list(lock.deletingLastPathComponent())
        let candidate = try makeEmptyIndexLockCandidate(index: index, operationID: journal.id)
        journal.ownedIndexLockPath = lock.path
        journal.ownedIndexLockChecksum = candidate.checksum
        journal.ownedIndexLockDevice = candidate.device
        journal.ownedIndexLockInode = candidate.inode
        journal.pendingIndexLock = candidate
        try await store.writeJournal(journal)
        try faultInjector.hit(.afterIndexLockIntentJournaled)
        guard Darwin.link(candidate.path, lock.path) == 0 else {
            try? fileSystem.removeIfPresent(URL(fileURLWithPath: candidate.path))
            journal.ownedIndexLockPath = nil
            journal.ownedIndexLockChecksum = nil
            journal.ownedIndexLockDevice = nil
            journal.ownedIndexLockInode = nil
            journal.pendingIndexLock = nil
            try await store.writeJournal(journal)
            throw CheckpointRestoreError.blocked(.indexLock)
        }
        try fileSystem.removeIfPresent(URL(fileURLWithPath: candidate.path))
        try fileSystem.synchronizeDirectory(lock.deletingLastPathComponent())
        journal.pendingIndexLock = nil
        try await store.writeJournal(journal)
        try faultInjector.hit(.afterIndexLockJournaled)
        try validateLock(journal)
    }

    private func validateLock(_ journal: CheckpointRestoreJournal) throws {
        guard let path = journal.ownedIndexLockPath, let checksum = journal.ownedIndexLockChecksum,
              let device = journal.ownedIndexLockDevice, let inode = journal.ownedIndexLockInode else {
            throw CheckpointRestoreError.blocked(.indexLock)
        }
        let actual = try indexIdentity(at: URL(fileURLWithPath: path))
        let originalMatches = actual.device == device && actual.inode == inode && actual.checksum == checksum
        let pendingMatches = journal.pendingIndexLock.map { sameIdentity(actual, $0) } ?? false
        guard originalMatches || pendingMatches else {
            throw CheckpointRestoreError.blocked(.indexLock)
        }
    }

    private func installIndex(_ bytes: Data, journal: inout CheckpointRestoreJournal, target: CheckpointWorktreeTarget) async throws {
        try validateLock(journal)
        let index = try await gitPath("index", target: target)
        guard let path = journal.ownedIndexLockPath else { throw CheckpointRestoreError.invalidJournal }
        let lock = URL(fileURLWithPath: path)
        // A previous handoff may have completed before ownership promotion was
        // journaled. Record the exact accepted identity before another attempt.
        let currentLock = try indexIdentity(at: lock)
        if let previous = journal.pendingIndexLock, try exists(URL(fileURLWithPath: previous.path)) {
            guard sameIdentity(try indexIdentity(at: URL(fileURLWithPath: previous.path)), previous) else {
                throw CheckpointRestoreError.invalidJournal
            }
            try fileSystem.removeIfPresent(URL(fileURLWithPath: previous.path))
        }
        journal.ownedIndexLockChecksum = currentLock.checksum
        journal.ownedIndexLockDevice = currentLock.device
        journal.ownedIndexLockInode = currentLock.inode
        journal.pendingIndexLock = nil
        try await store.writeJournal(journal)

        // Never truncate index.lock. An incomplete candidate cannot invalidate
        // the durable identity of the lock that still protects the live index.
        let candidate = try makeIndexCandidate(bytes, index: index, operationID: journal.id)
        journal.pendingIndexLock = candidate
        if journal.phase != .rollingBack { journal.phase = .installingIndex }
        try await store.writeJournal(journal)
        try faultInjector.hit(.afterIndexCandidatePublication)
        try validateLock(journal)
        guard sameIdentity(try indexIdentity(at: URL(fileURLWithPath: candidate.path)), candidate) else {
            throw CheckpointRestoreError.invalidJournal
        }
        try fileSystem.move(URL(fileURLWithPath: candidate.path), to: lock)
        try faultInjector.hit(.afterIndexLockHandoff)
        try validateLock(journal)
        journal.ownedIndexLockChecksum = candidate.checksum
        journal.ownedIndexLockDevice = candidate.device
        journal.ownedIndexLockInode = candidate.inode
        journal.pendingIndexLock = nil
        try await store.writeJournal(journal)
        try validateLock(journal)
        if bytes.isEmpty {
            try fileSystem.removeIfPresent(index)
            try removeOwnedLock(journal)
        } else {
            try fileSystem.move(lock, to: index)
        }
    }

    private func makeIndexCandidate(_ bytes: Data, index: URL, operationID: UUID) throws -> CheckpointRestoreJournal.IndexLockCandidate {
        let name = ".alas-checkpoint-index-\(operationID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        let candidate = index.deletingLastPathComponent().appendingPathComponent(name)
        _ = try fileSystem.list(candidate.deletingLastPathComponent())
        let descriptor = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posix("create index candidate") }
        defer { _ = Darwin.close(descriptor) }
        do {
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                let chunkSize = max(1, buffer.count / 2)
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), min(chunkSize, buffer.count - offset))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw posix("write index candidate") }
                    let firstWrite = offset == 0
                    offset += count
                    if firstWrite { try faultInjector.hit(.afterPartialIndexWrite) }
                }
            }
            try faultInjector.hit(.beforeIndexCandidateSync)
            guard Darwin.fsync(descriptor) == 0 else { throw posix("fsync index candidate") }
            try fileSystem.synchronizeDirectory(candidate.deletingLastPathComponent())
            let identity = try indexIdentity(at: candidate)
            guard identity.checksum == digest(bytes) else { throw CheckpointRestoreError.invalidJournal }
            return identity
        } catch {
            try? fileSystem.removeIfPresent(candidate)
            throw error
        }
    }

    private func makeEmptyIndexLockCandidate(index: URL, operationID: UUID) throws -> CheckpointRestoreJournal.IndexLockCandidate {
        let name = ".alas-checkpoint-index-lock-\(operationID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        let candidate = index.deletingLastPathComponent().appendingPathComponent(name)
        _ = try fileSystem.list(candidate.deletingLastPathComponent())
        let descriptor = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posix("create index lock candidate") }
        defer { _ = Darwin.close(descriptor) }
        do {
            guard Darwin.fsync(descriptor) == 0 else { throw posix("fsync index lock candidate") }
            try fileSystem.synchronizeDirectory(candidate.deletingLastPathComponent())
            let identity = try indexIdentity(at: candidate)
            guard identity.checksum == digest(Data()) else { throw CheckpointRestoreError.invalidJournal }
            return identity
        } catch {
            try? fileSystem.removeIfPresent(candidate)
            throw error
        }
    }

    private func indexIdentity(at url: URL) throws -> CheckpointRestoreJournal.IndexLockCandidate {
        var attributes = stat()
        guard Darwin.lstat(url.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            throw CheckpointRestoreError.blocked(.indexLock)
        }
        return .init(path: url.path, checksum: digest(try fileSystem.fileData(url)),
                     device: UInt64(attributes.st_dev), inode: UInt64(attributes.st_ino))
    }

    private func sameIdentity(_ lhs: CheckpointRestoreJournal.IndexLockCandidate, _ rhs: CheckpointRestoreJournal.IndexLockCandidate) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.checksum == rhs.checksum
    }

    private func removeOwnedLock(_ journal: CheckpointRestoreJournal) throws {
        if let pending = journal.pendingIndexLock, try exists(URL(fileURLWithPath: pending.path)) {
            guard sameIdentity(try indexIdentity(at: URL(fileURLWithPath: pending.path)), pending) else {
                throw CheckpointRestoreError.invalidJournal
            }
            try fileSystem.removeIfPresent(URL(fileURLWithPath: pending.path))
        }
        guard let path = journal.ownedIndexLockPath, try exists(URL(fileURLWithPath: path)) else { return }
        try validateLock(journal)
        try fileSystem.removeIfPresent(URL(fileURLWithPath: path))
    }

    private func finish(_ journal: inout CheckpointRestoreJournal, target: CheckpointWorktreeTarget,
                        phase: CheckpointRestoreJournal.Phase) async throws {
        try removeOwnedLock(journal)
        var terminal = journal
        terminal.phase = phase
        try await store.writeJournal(terminal)
        journal = terminal
        // Verification and the durable terminal record make the transaction
        // complete. A cleanup failure must not attempt another restore.
        do {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: journal.stagingRoot))
            try fileSystem.synchronizeDirectory(target.path)
            try await store.finishJournal(id: journal.id, lineageID: target.lineageID)
        } catch { return }
    }

    private func leafState(_ path: String, root: URL) throws -> CheckpointFileState {
        do {
            guard try fileSystem.metadata(root: root, relativePath: path) != nil else { return .absent }
            switch try fileSystem.readLeaf(root: root, relativePath: path) {
            case .regular(let bytes, let executable): return .regular(blob: .make(for: bytes), executable: executable)
            case .symlink(let bytes): return .symlink(blob: .make(for: bytes))
            }
        } catch CheckpointFileSystemError.unsupportedLeaf {
            let url = try fileSystem.validateRelativePath(path, under: root)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return .absent
            }
            throw CheckpointFileSystemError.unsupportedLeaf
        }
    }

    private func ensureParent(_ path: String, root: URL) throws -> URL {
        _ = try fileSystem.validateRelativePath(path, under: root)
        // Foundation can standardize /private/tmp to its /tmp symlink alias.
        // Keep the validated root spelling for strict no-symlink filesystem I/O.
        let destination = root.appendingPathComponent(path, isDirectory: false)
        var parent = root
        for component in path.split(separator: "/").dropLast() {
            parent.appendPathComponent(String(component))
            if !FileManager.default.fileExists(atPath: parent.path) { try fileSystem.createDirectoryExclusively(parent, mode: 0o755) }
        }
        _ = try fileSystem.validateRelativePath(path, under: root)
        return destination
    }

    private func moveLeaf(_ source: URL, to destination: URL) throws {
        _ = try fileSystem.list(source.deletingLastPathComponent())
        _ = try fileSystem.list(destination.deletingLastPathComponent())
        // Exclusive rename also refuses a new file that appeared after the last
        // fingerprint check. Both leaves remain recoverable on failure.
        guard Darwin.renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw posix("rename leaf") }
        try fileSystem.synchronizeDirectory(source.deletingLastPathComponent())
        try fileSystem.synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private func removeEmptyDirectoryIfPresent(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        guard Darwin.rmdir(url.path) == 0 else { throw posix("rmdir empty restore directory") }
        try fileSystem.synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func stagingName(_ path: String, journal: CheckpointRestoreJournal) throws -> String {
        guard let name = journal.stagingNames[path], UUID(uuidString: name) != nil, !name.contains("/") else {
            throw CheckpointRestoreError.invalidJournal
        }
        return name
    }

    private func requiredState(_ path: String, in manifest: WorktreeCheckpointManifest) throws -> CheckpointPathState {
        guard let state = manifest.paths.first(where: { $0.relativePath == path }) else { throw CheckpointRestoreError.invalidJournal }
        return state
    }

    private func validateRestorePath(_ path: String, selectedPaths: [String], under root: URL) throws {
        do {
            _ = try fileSystem.validateRelativePath(path, under: root)
        } catch CheckpointFileSystemError.unsafePath {
            guard let ancestor = selectedPaths
                .filter({ path.hasPrefix($0 + "/") })
                .max(by: { $0.count < $1.count }) else {
                throw CheckpointFileSystemError.unsafePath
            }
            _ = try fileSystem.validateRelativePath(ancestor, under: root)
        }
    }

    private func desiredState(for path: String,
                              saved: [String: CheckpointPathState],
                              current: WorktreeStateSnapshot,
                              selectedPaths: [String]) throws -> CheckpointPathState {
        if let state = saved[path] { return state }
        guard let now = current.paths[path] else { throw CheckpointRestoreError.missingCurrentPath(path) }
        let isSyntheticAncestor = selectedPaths.contains { $0.hasPrefix(path + "/") }
            && now.index == now.head
            && now.worktree == now.head
        return .init(relativePath: path, head: now.head, index: now.head,
                     worktree: isSyntheticAncestor ? .absent : now.head)
    }

    private func exists(_ url: URL) throws -> Bool {
        var attributes = stat()
        if Darwin.lstat(url.path, &attributes) == 0 { return true }
        if errno == ENOENT { return false }
        throw posix("lstat")
    }

    private func digest(_ bytes: Data) -> String { CheckpointBlobReference.make(for: bytes).sha256 }
    private func posix(_ operation: String) -> CheckpointFileSystemError { .posix(operation: operation, code: errno) }
    private func recoveryRequired(_ journal: CheckpointRestoreJournal) -> CheckpointRestoreError {
        .recoveryRequired(operationID: journal.id, paths: journal.selectedPaths, phase: journal.phase)
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

    private func headOID(_ target: CheckpointWorktreeTarget) async throws -> String {
        let result = try await git.run(["rev-parse", "--verify", "HEAD"], cwd: target.path, environment: [:])
        if result.exitCode == 0 { return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        let unborn = try await git.run(["rev-parse", "--verify", "--quiet", "HEAD"], cwd: target.path, environment: [:])
        guard unborn.exitCode == 1 else { throw CheckpointRestoreError.invalidGitOutput }
        let empty = try await git.run(["hash-object", "-t", "tree", "/dev/null"], cwd: target.path, environment: [:])
        guard empty.exitCode == 0 else { throw CheckpointRestoreError.invalidGitOutput }
        return empty.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGit(_ args: [String], target: CheckpointWorktreeTarget, index: URL) async throws {
        let result = try await git.run(args, cwd: target.path, environment: ["GIT_INDEX_FILE": index.path])
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
    }
}
