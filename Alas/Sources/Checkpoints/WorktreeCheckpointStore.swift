import CryptoKit
import Darwin
import Foundation

enum CheckpointStoreError: Error, Equatable, Sendable {
    case invalidLineageID
    case checkpointNotFound
    case blobNotFound
    case blobDoesNotMatchReference
    case byteLimitExceeded
    case operationReferencesCheckpoint
    case lineageLockUnavailable
}

struct CheckpointPublication: Sendable {
    let manifest: WorktreeCheckpointManifest
    let blobs: [CheckpointBlobReference: Data]
}

private struct CheckpointStoreLockOwner: Codable {
    let pid: Int32
    let createdAt: Date
}

actor WorktreeCheckpointStore {
    struct Limits: Equatable, Sendable {
        var manualCount = 20
        var recoveryCount = 5
        var bytes: Int64 = 2 * 1024 * 1024 * 1024
    }

    private let root: URL
    private let fileSystem: any CheckpointFileSystem
    private let limits: Limits
    private let lockStaleAge: TimeInterval = 120

    init(root: URL = Paths.checkpointsRoot, fileSystem: any CheckpointFileSystem = LiveCheckpointFileSystem(), limits: Limits = .init()) {
        self.root = root
        self.fileSystem = fileSystem
        self.limits = limits
    }

    func catalog(lineageID: String) throws -> CheckpointCatalogSnapshot {
        try validate(lineageID)
        try prepare(lineageID)
        return try withLineageLock(lineageID: lineageID) {
            try catalogUnlocked(lineageID: lineageID)
        }
    }

    private func catalogUnlocked(lineageID: String) throws -> CheckpointCatalogSnapshot {
        let catalogURL = paths(lineageID).catalog
        guard exists(catalogURL) else { return try rebuildCatalog(lineageID: lineageID) }
        do {
            let catalog = try JSONDecoder.checkpoints.decode(CheckpointCatalogSnapshot.self, from: fileSystem.fileData(catalogURL))
            guard catalog.schemaVersion == CheckpointCatalogSnapshot.currentSchemaVersion, catalog.lineageID == lineageID else {
                throw CheckpointStoreError.invalidLineageID
            }
            let catalogIDs = Set(catalog.summaries.map(\.id))
            let reconciliation = try validManifests(lineageID: lineageID, previousSummaries: catalog.summaries,
                                                    allowedIDs: catalogIDs)
            let unavailable = reconciliation.unavailable + catalog.summaries.filter { existing in
                existing.unavailableReason != nil && !reconciliation.unavailable.contains(where: { candidate in candidate.id == existing.id })
            }
            let rebuilt = snapshot(
                lineageID: lineageID,
                manifests: reconciliation.valid,
                unavailable: unavailable,
                byteCount: try storageByteCount(manifests: reconciliation.valid, layout: paths(lineageID), incoming: [:])
            )
            if rebuilt != catalog { try writeCatalog(rebuilt, layout: paths(lineageID)) }
            try garbageCollect(layout: paths(lineageID), manifests: reconciliation.valid, journals: try activeJournalsUnlocked(lineageID: lineageID))
            return rebuilt
        } catch {
            try quarantine(catalogURL, in: paths(lineageID).quarantine, name: "catalog")
            return try rebuildCatalog(lineageID: lineageID)
        }
    }

    func publish(_ publication: CheckpointPublication, protecting additionalProtectedIDs: Set<CheckpointID> = []) throws -> CheckpointCatalogSnapshot {
        let manifest = publication.manifest
        try validate(manifest.lineageID)
        try manifest.validate()
        try prepare(manifest.lineageID)
        return try withLineageLock(lineageID: manifest.lineageID) {
            try publishUnlocked(publication, protecting: additionalProtectedIDs)
        }
    }

    private func publishUnlocked(_ publication: CheckpointPublication, protecting additionalProtectedIDs: Set<CheckpointID>) throws -> CheckpointCatalogSnapshot {
        let manifest = publication.manifest
        let layout = paths(manifest.lineageID)
        let currentCatalog = try catalogUnlocked(lineageID: manifest.lineageID)
        let manifestReferences = references(in: manifest)
        guard manifestReferences == Set(publication.blobs.keys) else { throw CheckpointStoreError.blobDoesNotMatchReference }
        for (reference, data) in publication.blobs {
            guard CheckpointBlobReference.make(for: data) == reference else { throw CheckpointStoreError.blobDoesNotMatchReference }
        }

        let currentCatalogIDs = Set(currentCatalog.summaries.map(\.id))
        let existingManifests = try validManifests(lineageID: manifest.lineageID, previousSummaries: currentCatalog.summaries,
                                                   allowedIDs: currentCatalogIDs).valid
        var candidates = existingManifests + [manifest]
        let protected = try protectedIDsUnlocked(lineageID: manifest.lineageID).union(additionalProtectedIDs)
        var victims = retentionVictims(from: candidates, protected: protected, incomingID: manifest.id)
        candidates.removeAll { candidate in victims.contains(where: { $0.id == candidate.id }) }
        let incomingByteCount = try storageByteCount(manifests: [manifest], layout: layout, incoming: publication.blobs)
        guard incomingByteCount <= limits.bytes else { throw CheckpointStoreError.byteLimitExceeded }
        var reachable = Set(candidates.flatMap { references(in: $0) })
        var bytes = try storageByteCount(manifests: candidates, reachable: reachable, layout: layout, incoming: publication.blobs)
        if bytes > limits.bytes {
            for victim in byteLimitVictims(from: candidates, protected: protected, incomingID: manifest.id) {
                victims.append(victim)
                candidates.removeAll { $0.id == victim.id }
                reachable = Set(candidates.flatMap { references(in: $0) })
                bytes = try storageByteCount(manifests: candidates, reachable: reachable, layout: layout, incoming: publication.blobs)
                if bytes <= limits.bytes { break }
            }
        }
        guard bytes <= limits.bytes else { throw CheckpointStoreError.byteLimitExceeded }

        for (reference, data) in publication.blobs {
            let blob = blobURL(reference, layout: layout)
            if exists(blob) {
                if try blobMatchesReference(reference, layout: layout) {
                    continue
                }
                try fileSystem.removeIfPresent(blob)
            }
            let temporaryBlob = layout.blobs.appendingPathComponent(".\(reference.sha256).tmp")
            try fileSystem.writeDurable(data, to: temporaryBlob, mode: 0o600)
            do {
                try fileSystem.moveExclusively(temporaryBlob, to: blob)
            } catch CheckpointFileSystemError.posix(operation: "link", code: EEXIST) {
                try fileSystem.removeIfPresent(temporaryBlob)
            }
        }
        let entry = layout.entries.appendingPathComponent(manifest.id.uuidString.lowercased(), isDirectory: true)
        guard !exists(entry) else { throw CheckpointStoreError.checkpointNotFound }
        let temporary = layout.entries.appendingPathComponent(".\(manifest.id.uuidString.lowercased()).tmp", isDirectory: true)
        try fileSystem.createDirectoryExclusively(temporary, mode: 0o700)
        try fileSystem.writeDurable(JSONEncoder.checkpoints.encode(manifest), to: temporary.appendingPathComponent("manifest.json"), mode: 0o600)
        try fileSystem.synchronizeDirectory(temporary)
        try fileSystem.move(temporary, to: entry)

        let next = snapshot(lineageID: manifest.lineageID, manifests: candidates, unavailable: currentCatalog.summaries.filter { $0.unavailableReason != nil }, byteCount: bytes)
        do {
            try writeCatalog(next, layout: layout)
        } catch {
            try? removeEntry(manifest.id, layout: layout)
            try? garbageCollect(layout: layout, manifests: existingManifests, journals: activeJournalsUnlocked(lineageID: manifest.lineageID))
            throw error
        }
        for victim in victims { try? removeEntry(victim.id, layout: layout) }
        try? garbageCollect(layout: layout, manifests: candidates, journals: (try? activeJournalsUnlocked(lineageID: manifest.lineageID)) ?? [])
        return next
    }

    func load(id: CheckpointID, lineageID: String) throws -> WorktreeCheckpointManifest {
        try validate(lineageID)
        try prepare(lineageID)
        let manifest = try readManifest(id: id, lineageID: lineageID)
        try validate(manifest: manifest, layout: paths(lineageID))
        return manifest
    }

    // Preview can display states and higher-priority blockers even when a
    // payload is unavailable. Mutation and diff callers must use load instead.
    func loadMetadata(id: CheckpointID, lineageID: String) throws -> WorktreeCheckpointManifest {
        try validate(lineageID)
        try prepare(lineageID)
        let manifest = try readManifest(id: id, lineageID: lineageID)
        try validate(manifest: manifest, layout: paths(lineageID), verifyBlobs: false)
        return manifest
    }

    func readBlob(_ reference: CheckpointBlobReference, lineageID: String) throws -> Data {
        try validate(lineageID)
        try reference.validate()
        let url = blobURL(reference, layout: paths(lineageID))
        guard exists(url) else { throw CheckpointStoreError.blobNotFound }
        let data = try fileSystem.fileData(url)
        guard CheckpointBlobReference.make(for: data) == reference else { throw CheckpointStoreError.blobDoesNotMatchReference }
        return data
    }

    func materializeBlob(_ reference: CheckpointBlobReference, lineageID: String, to destination: URL, mode: mode_t) throws {
        try validate(lineageID)
        try reference.validate()
        let source = blobURL(reference, layout: paths(lineageID))
        guard exists(source) else { throw CheckpointStoreError.blobNotFound }
        guard try blobFileSize(reference, layout: paths(lineageID)) == reference.byteCount else {
            throw CheckpointStoreError.blobDoesNotMatchReference
        }
        try copyBlob(source, reference: reference, to: destination, mode: mode)
    }

    func delete(id: CheckpointID, lineageID: String) throws -> CheckpointCatalogSnapshot {
        try validate(lineageID)
        try prepare(lineageID)
        return try withLineageLock(lineageID: lineageID) {
            try deleteUnlocked(id: id, lineageID: lineageID)
        }
    }

    private func deleteUnlocked(id: CheckpointID, lineageID: String) throws -> CheckpointCatalogSnapshot {
        guard !(try protectedIDsUnlocked(lineageID: lineageID).contains(id)) else { throw CheckpointStoreError.operationReferencesCheckpoint }
        let currentCatalog = try catalogUnlocked(lineageID: lineageID)
        let manifests = try validManifests(lineageID: lineageID).valid
        let unavailable = currentCatalog.summaries.filter { $0.unavailableReason != nil }
        guard manifests.contains(where: { $0.id == id }) || unavailable.contains(where: { $0.id == id }) else { throw CheckpointStoreError.checkpointNotFound }
        let remaining = manifests.filter { $0.id != id }
        let layout = paths(lineageID)
        let remainingUnavailable = unavailable.filter { $0.id != id }
        let next = snapshot(lineageID: lineageID, manifests: remaining, unavailable: remainingUnavailable, byteCount: try storageByteCount(manifests: remaining, layout: layout, incoming: [:]))
        try writeCatalog(next, layout: layout)
        try removeEntry(id, layout: layout)
        try removeQuarantinedEntry(id, layout: layout)
        try garbageCollect(layout: layout, manifests: remaining, journals: try activeJournalsUnlocked(lineageID: lineageID))
        return next
    }

    func writeJournal(_ journal: CheckpointRestoreJournal) throws {
        try validate(journal.lineageID)
        try prepare(journal.lineageID)
        try withLineageLock(lineageID: journal.lineageID) {
            let layout = paths(journal.lineageID)
            try fileSystem.writeDurable(JSONEncoder.checkpoints.encode(journal), to: layout.journals.appendingPathComponent("\(journal.id.uuidString.lowercased()).json"), mode: 0o600)
        }
    }

    func journal(id: UUID, lineageID: String) throws -> CheckpointRestoreJournal? {
        try validate(lineageID)
        try prepare(lineageID)
        let url = paths(lineageID).journals.appendingPathComponent("\(id.uuidString.lowercased()).json")
        guard exists(url) else { return nil }
        let value = try JSONDecoder.checkpoints.decode(CheckpointRestoreJournal.self, from: fileSystem.fileData(url))
        return value.lineageID == lineageID ? value : nil
    }

    func recoverableJournals(lineageID: String) throws -> [CheckpointRestoreJournal] {
        try validate(lineageID)
        try prepare(lineageID)
        return try withLineageLock(lineageID: lineageID) {
            try activeJournalsUnlocked(lineageID: lineageID)
        }
    }

    func finishJournal(id: UUID, lineageID: String) throws {
        try validate(lineageID)
        try prepare(lineageID)
        try withLineageLock(lineageID: lineageID) {
            guard let value = try journal(id: id, lineageID: lineageID), value.phase.isTerminal else { return }
            try fileSystem.removeIfPresent(paths(lineageID).journals.appendingPathComponent("\(id.uuidString.lowercased()).json"))
        }
    }

    func discardPreparedJournal(id: UUID, lineageID: String) throws {
        try validate(lineageID)
        try prepare(lineageID)
        try withLineageLock(lineageID: lineageID) {
            guard let value = try journal(id: id, lineageID: lineageID), value.phase == .prepared else { return }
            try fileSystem.removeIfPresent(paths(lineageID).journals.appendingPathComponent("\(id.uuidString.lowercased()).json"))
        }
    }

    private struct Layout {
        let root: URL
        let blobs: URL
        let entries: URL
        let journals: URL
        let quarantine: URL
        let catalog: URL
    }

    private func paths(_ lineageID: String) -> Layout {
        let directory = root.appendingPathComponent(lineageID, isDirectory: true)
        return .init(root: directory, blobs: directory.appendingPathComponent("blobs", isDirectory: true), entries: directory.appendingPathComponent("entries", isDirectory: true), journals: directory.appendingPathComponent("journals", isDirectory: true), quarantine: directory.appendingPathComponent("quarantine", isDirectory: true), catalog: directory.appendingPathComponent("catalog.json"))
    }

    private func validate(_ lineageID: String) throws {
        guard UUID(uuidString: lineageID)?.uuidString.lowercased() == lineageID else { throw CheckpointStoreError.invalidLineageID }
    }

    private func prepare(_ lineageID: String) throws {
        let layout = paths(lineageID)
        if !exists(root) { try createDirectoryIfNeeded(root, mode: 0o700) }
        for directory in [layout.root, layout.blobs, layout.entries, layout.journals, layout.quarantine] where !exists(directory) {
            try createDirectoryIfNeeded(directory, mode: 0o700)
        }
    }

    private func createDirectoryIfNeeded(_ url: URL, mode: mode_t) throws {
        do {
            try fileSystem.createDirectoryExclusively(url, mode: mode)
        } catch CheckpointFileSystemError.posix(operation: "mkdir", code: EEXIST) {
            return
        }
    }

    private func withLineageLock<T>(lineageID: String, _ body: () throws -> T) throws -> T {
        let layout = paths(lineageID)
        let lock = try acquireLineageLock(layout: layout)
        defer { try? removeDirectoryTreeIfPresent(lock) }
        try removeAbandonedBlobTemporaries(layout: layout)
        return try body()
    }

    private func acquireLineageLock(layout: Layout) throws -> URL {
        let lock = layout.root.appendingPathComponent(".store.lock", isDirectory: true)
        let deadline = Date().addingTimeInterval(30)
        while true {
            do {
                try fileSystem.createDirectoryExclusively(lock, mode: 0o700)
                do {
                    let owner = CheckpointStoreLockOwner(pid: getpid(), createdAt: Date())
                    try fileSystem.writeDurable(JSONEncoder.checkpoints.encode(owner), to: lock.appendingPathComponent("owner.json"), mode: 0o600)
                    try fileSystem.synchronizeDirectory(lock)
                } catch {
                    try? fileSystem.removeIfPresent(lock.appendingPathComponent("owner.json"))
                    try? fileSystem.removeIfPresent(lock)
                    throw error
                }
                return lock
            } catch CheckpointFileSystemError.posix(operation: "mkdir", code: EEXIST) {
                if try reclaimAbandonedLineageLock(lock) { continue }
                guard Date() < deadline else { throw CheckpointStoreError.lineageLockUnavailable }
                usleep(10_000)
            }
        }
    }

    private func reclaimAbandonedLineageLock(_ lock: URL) throws -> Bool {
        let ownerURL = lock.appendingPathComponent("owner.json")
        if let owner = try? JSONDecoder.checkpoints.decode(CheckpointStoreLockOwner.self, from: fileSystem.fileData(ownerURL)) {
            guard !processMatchesOwner(owner) else { return false }
            try removeDirectoryTreeIfPresent(lock)
            return true
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: lock.path)
        let modifiedAt = attributes?[.modificationDate] as? Date
        guard let modifiedAt, Date().timeIntervalSince(modifiedAt) > lockStaleAge else { return false }
        try removeDirectoryTreeIfPresent(lock)
        return true
    }

    private func processMatchesOwner(_ owner: CheckpointStoreLockOwner) -> Bool {
        guard processIsAlive(owner.pid) else { return false }
        guard let startedAt = processStartTime(pid: owner.pid) else { return true }
        return startedAt <= owner.createdAt.addingTimeInterval(1)
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func processStartTime(pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), &info, &size, nil, 0)
        }
        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let startTime = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(startTime.tv_sec) + TimeInterval(startTime.tv_usec) / 1_000_000)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func blobURL(_ reference: CheckpointBlobReference, layout: Layout) -> URL { layout.blobs.appendingPathComponent(reference.sha256) }
    private func references(in manifest: WorktreeCheckpointManifest) -> Set<CheckpointBlobReference> {
        Set(manifest.paths.flatMap { [$0.head.blob, $0.index.blob, $0.worktree.blob].compactMap { $0 } })
    }

    private func validate(manifest: WorktreeCheckpointManifest, layout: Layout, verifyBlobs: Bool = true) throws {
        try manifest.validate()
        for path in manifest.paths { _ = try fileSystem.validateRelativePath(path.relativePath, under: layout.root) }
        for exclusion in manifest.exclusions { _ = try fileSystem.validateRelativePath(exclusion.relativePath, under: layout.root) }
        for group in manifest.groups {
            _ = try fileSystem.validateRelativePath(group.primaryPath, under: layout.root)
            if let renameSource = group.renameSource { _ = try fileSystem.validateRelativePath(renameSource, under: layout.root) }
            for memberPath in group.memberPaths { _ = try fileSystem.validateRelativePath(memberPath, under: layout.root) }
        }
        if verifyBlobs {
            for reference in references(in: manifest) {
                guard try blobMatchesReference(reference, layout: layout) else { throw CheckpointStoreError.blobDoesNotMatchReference }
            }
        }
    }

    private func readManifest(id: CheckpointID, lineageID: String) throws -> WorktreeCheckpointManifest {
        let url = paths(lineageID).entries.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true).appendingPathComponent("manifest.json")
        guard exists(url) else { throw CheckpointStoreError.checkpointNotFound }
        let manifest = try JSONDecoder.checkpoints.decode(WorktreeCheckpointManifest.self, from: fileSystem.fileData(url))
        guard manifest.id == id, manifest.lineageID == lineageID else { throw CheckpointStoreError.checkpointNotFound }
        return manifest
    }

    private struct ManifestReconciliation {
        var valid: [WorktreeCheckpointManifest]
        var unavailable: [WorktreeCheckpointSummary]
    }

    private func validManifests(lineageID: String, previousSummaries: [WorktreeCheckpointSummary] = [],
                                allowedIDs: Set<CheckpointID>? = nil) throws -> ManifestReconciliation {
        try prepare(lineageID)
        let layout = paths(lineageID)
        var result = ManifestReconciliation(valid: [], unavailable: [])
        for entry in try fileSystem.list(layout.entries) where !entry.lastPathComponent.hasPrefix(".") {
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            if let allowedIDs, !allowedIDs.contains(id) { continue }
            do {
                let manifest = try readManifest(id: id, lineageID: lineageID)
                do {
                    try validate(manifest: manifest, layout: layout)
                    result.valid.append(manifest)
                } catch {
                    result.unavailable.append(unavailableSummary(for: manifest, error: error))
                    try quarantine(entry, in: layout.quarantine, name: id.uuidString.lowercased())
                }
            } catch {
                if let previous = previousSummaries.first(where: { $0.id == id }) {
                    result.unavailable.append(unavailableSummary(from: previous, error: error))
                }
                try quarantine(entry, in: layout.quarantine, name: id.uuidString.lowercased())
            }
        }
        return result
    }

    private func rebuildCatalog(lineageID: String) throws -> CheckpointCatalogSnapshot {
        let manifests = try validManifests(lineageID: lineageID)
        let layout = paths(lineageID)
        let next = snapshot(lineageID: lineageID, manifests: manifests.valid, unavailable: manifests.unavailable, byteCount: try storageByteCount(manifests: manifests.valid, layout: layout, incoming: [:]))
        try writeCatalog(next, layout: layout)
        try garbageCollect(layout: layout, manifests: manifests.valid, journals: try activeJournalsUnlocked(lineageID: lineageID))
        return next
    }

    private func snapshot(lineageID: String, manifests: [WorktreeCheckpointManifest], unavailable: [WorktreeCheckpointSummary] = [], byteCount: Int64) -> CheckpointCatalogSnapshot {
        let summaries = (manifests.sorted { $0.createdAt > $1.createdAt }.map { manifest in
            WorktreeCheckpointSummary(id: manifest.id, kind: manifest.kind, label: manifest.label, createdAt: manifest.createdAt, byteCount: manifest.byteCount, stagedFileCount: manifest.paths.filter { $0.index != $0.head }.count, unstagedFileCount: manifest.paths.filter { $0.worktree != $0.index && !($0.head.kind == .absent && $0.index.kind == .absent) }.count, untrackedFileCount: manifest.paths.filter { $0.head.kind == .absent && $0.index.kind == .absent && $0.worktree.kind != .absent }.count, unavailableReason: nil)
        } + unavailable).sorted { $0.createdAt > $1.createdAt }
        return .init(lineageID: lineageID, summaries: summaries, byteCount: byteCount)
    }

    private func unavailableSummary(for manifest: WorktreeCheckpointManifest, error: Error) -> WorktreeCheckpointSummary {
        WorktreeCheckpointSummary(id: manifest.id, kind: manifest.kind, label: manifest.label, createdAt: manifest.createdAt, byteCount: manifest.byteCount, stagedFileCount: 0, unstagedFileCount: 0, untrackedFileCount: 0, unavailableReason: String(describing: error))
    }

    private func unavailableSummary(from summary: WorktreeCheckpointSummary, error: Error) -> WorktreeCheckpointSummary {
        WorktreeCheckpointSummary(
            id: summary.id,
            kind: summary.kind,
            label: summary.label,
            createdAt: summary.createdAt,
            byteCount: summary.byteCount,
            stagedFileCount: summary.stagedFileCount,
            unstagedFileCount: summary.unstagedFileCount,
            untrackedFileCount: summary.untrackedFileCount,
            unavailableReason: String(describing: error)
        )
    }

    private func writeCatalog(_ catalog: CheckpointCatalogSnapshot, layout: Layout) throws {
        try fileSystem.writeDurable(JSONEncoder.checkpoints.encode(catalog), to: layout.catalog, mode: 0o600)
        try fileSystem.synchronizeDirectory(layout.root)
    }

    private func storageByteCount(manifests: [WorktreeCheckpointManifest], layout: Layout, incoming: [CheckpointBlobReference: Data]) throws -> Int64 {
        try storageByteCount(manifests: manifests, reachable: Set(manifests.flatMap { references(in: $0) }), layout: layout, incoming: incoming)
    }

    private func storageByteCount(manifests: [WorktreeCheckpointManifest], reachable: Set<CheckpointBlobReference>, layout: Layout, incoming: [CheckpointBlobReference: Data]) throws -> Int64 {
        try blobByteCount(reachable, layout: layout, incoming: incoming) + manifestByteCount(manifests)
    }

    private func blobByteCount(_ references: Set<CheckpointBlobReference>, layout: Layout, incoming: [CheckpointBlobReference: Data]) throws -> Int64 {
        try references.reduce(into: Int64(0)) { total, reference in
            if let data = incoming[reference] {
                total += Int64(data.count)
            } else {
                total += try blobFileSize(reference, layout: layout)
            }
        }
    }

    private func manifestByteCount(_ manifests: [WorktreeCheckpointManifest]) throws -> Int64 {
        try manifests.reduce(into: Int64(0)) { total, manifest in
            total += Int64(try JSONEncoder.checkpoints.encode(manifest).count)
        }
    }

    private func blobFileSize(_ reference: CheckpointBlobReference, layout: Layout) throws -> Int64 {
        let blob = blobURL(reference, layout: layout)
        guard exists(blob) else { throw CheckpointStoreError.blobNotFound }
        let attributes = try FileManager.default.attributesOfItem(atPath: blob.path)
        guard let size = attributes[.size] as? NSNumber else { throw CheckpointStoreError.blobNotFound }
        return size.int64Value
    }

    private func blobMatchesReference(_ reference: CheckpointBlobReference, layout: Layout) throws -> Bool {
        let blob = blobURL(reference, layout: layout)
        guard try blobFileSize(reference, layout: layout) == reference.byteCount else { return false }
        let handle = try FileHandle(forReadingFrom: blob)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return hash == reference.sha256
    }

    private func copyBlob(_ source: URL, reference: CheckpointBlobReference, to destination: URL, mode: mode_t) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".alas-checkpoint-\(UUID().uuidString)")
        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard descriptor >= 0 else { throw CheckpointFileSystemError.posix(operation: "open", code: errno) }
        var descriptorIsOpen = true

        do {
            var hasher = SHA256()
            var byteCount: Int64 = 0
            while true {
                let chunk = try sourceHandle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                byteCount += Int64(chunk.count)
                hasher.update(data: chunk)
                try writeAll(chunk, descriptor: descriptor)
            }
            let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard byteCount == reference.byteCount, hash == reference.sha256 else {
                throw CheckpointStoreError.blobDoesNotMatchReference
            }
            guard Darwin.fchmod(descriptor, mode) == 0 else { throw CheckpointFileSystemError.posix(operation: "fchmod", code: errno) }
            guard Darwin.fsync(descriptor) == 0 else { throw CheckpointFileSystemError.posix(operation: "fsync", code: errno) }
            guard Darwin.close(descriptor) == 0 else { throw CheckpointFileSystemError.posix(operation: "close", code: errno) }
            descriptorIsOpen = false
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw CheckpointFileSystemError.posix(operation: "rename", code: errno) }
            try fileSystem.synchronizeDirectory(parent)
        } catch {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            _ = Darwin.unlink(temporary.path)
            throw error
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            var remaining = raw.count
            var pointer = raw.baseAddress
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else { throw CheckpointFileSystemError.posix(operation: "write", code: errno) }
                remaining -= written
                pointer = pointer?.advanced(by: written)
            }
        }
    }

    private func retentionVictims(from manifests: [WorktreeCheckpointManifest], protected: Set<CheckpointID>, incomingID: CheckpointID) -> [WorktreeCheckpointManifest] {
        var victims: [WorktreeCheckpointManifest] = []
        for kind in [CheckpointKind.recovery, .manual] {
            let limit = kind == .recovery ? limits.recoveryCount : limits.manualCount
            let count = manifests.filter { $0.kind == kind }.count
            let ordered = manifests
                .filter { $0.kind == kind && $0.id != incomingID }
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            var excess = max(0, count - limit)
            for manifest in ordered where excess > 0 && !protected.contains(manifest.id) {
                victims.append(manifest)
                excess -= 1
            }
        }
        return victims
    }

    private func byteLimitVictims(from manifests: [WorktreeCheckpointManifest], protected: Set<CheckpointID>, incomingID: CheckpointID) -> [WorktreeCheckpointManifest] {
        [CheckpointKind.recovery, .manual].flatMap { kind in
            manifests
                .filter { $0.kind == kind && $0.id != incomingID && !protected.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    private func activeJournals(lineageID: String) throws -> [CheckpointRestoreJournal] {
        try validate(lineageID)
        try prepare(lineageID)
        return try withLineageLock(lineageID: lineageID) {
            try activeJournalsUnlocked(lineageID: lineageID)
        }
    }

    private func activeJournalsUnlocked(lineageID: String) throws -> [CheckpointRestoreJournal] {
        let layout = paths(lineageID)
        return try fileSystem.list(layout.journals).compactMap { url in
            guard let value = try? JSONDecoder.checkpoints.decode(CheckpointRestoreJournal.self, from: fileSystem.fileData(url)), value.lineageID == lineageID else { return nil }
            if value.phase.isTerminal {
                try cleanupTerminalJournal(value, url: url)
                return nil
            }
            return value
        }
    }

    private func protectedIDs(lineageID: String) throws -> Set<CheckpointID> {
        Set(try activeJournals(lineageID: lineageID).flatMap { [$0.checkpointID, $0.recoveryCheckpointID] })
    }

    private func protectedIDsUnlocked(lineageID: String) throws -> Set<CheckpointID> {
        Set(try activeJournalsUnlocked(lineageID: lineageID).flatMap { [$0.checkpointID, $0.recoveryCheckpointID] })
    }

    private func garbageCollect(layout: Layout, manifests: [WorktreeCheckpointManifest], journals: [CheckpointRestoreJournal]) throws {
        let journalManifests = journals.flatMap { journal in
            [journal.checkpointID, journal.recoveryCheckpointID].compactMap { try? readManifest(id: $0, lineageID: journal.lineageID) }
        }
        let protectedManifests = manifests + journalManifests
        let protectedIDs = Set(protectedManifests.map(\.id))
        for url in try fileSystem.list(layout.entries) {
            guard let id = UUID(uuidString: url.lastPathComponent), !protectedIDs.contains(id) else { continue }
            try removeEntry(id, layout: layout)
        }
        let protectedBlobs = Set(protectedManifests.flatMap { references(in: $0) })
        for url in try fileSystem.list(layout.blobs) where shouldRemoveBlob(url, protected: protectedBlobs) { try fileSystem.removeIfPresent(url) }
    }

    private func removeAbandonedBlobTemporaries(layout: Layout) throws {
        for url in try fileSystem.list(layout.blobs) where isBlobTemporary(url.lastPathComponent) {
            try fileSystem.removeIfPresent(url)
        }
    }

    private func shouldRemoveBlob(_ url: URL, protected: Set<CheckpointBlobReference>) -> Bool {
        isBlobTemporary(url.lastPathComponent) || (isBlobName(url.lastPathComponent) && !protected.contains { $0.sha256 == url.lastPathComponent })
    }

    private func isBlobName(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy { character in
            character.isNumber || ("a" ... "f").contains(character)
        }
    }

    private func isBlobTemporary(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        let digest = name.dropFirst().dropLast(4)
        return digest.count == 64 && digest.allSatisfy { character in
            character.isNumber || ("a" ... "f").contains(character)
        }
    }

    private func removeEntry(_ id: CheckpointID, layout: Layout) throws {
        let entry = layout.entries.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        guard exists(entry) else { return }
        for file in try fileSystem.list(entry) { try fileSystem.removeIfPresent(file) }
        try fileSystem.removeIfPresent(entry)
    }

    private func removeQuarantinedEntry(_ id: CheckpointID, layout: Layout) throws {
        let prefix = id.uuidString.lowercased()
        for url in try fileSystem.list(layout.quarantine) where url.lastPathComponent.hasPrefix(prefix) {
            for file in (try? fileSystem.list(url)) ?? [] { try fileSystem.removeIfPresent(file) }
            try fileSystem.removeIfPresent(url)
        }
    }

    private func cleanupTerminalJournal(_ journal: CheckpointRestoreJournal, url: URL) throws {
        let staging = URL(fileURLWithPath: journal.stagingRoot, isDirectory: true)
        try removeDirectoryTreeIfPresent(staging)
        try fileSystem.removeIfPresent(url)
    }

    private func removeDirectoryTreeIfPresent(_ url: URL) throws {
        guard exists(url) else { return }
        for child in try fileSystem.list(url) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue {
                try removeDirectoryTreeIfPresent(child)
            } else {
                try fileSystem.removeIfPresent(child)
            }
        }
        try fileSystem.removeIfPresent(url)
    }

    private func quarantine(_ source: URL, in directory: URL, name: String) throws {
        guard exists(source) else { return }
        try fileSystem.move(source, to: directory.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970))"))
    }
}
