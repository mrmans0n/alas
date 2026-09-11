import CryptoKit
import Foundation

enum CheckpointStoreError: Error, Equatable, Sendable {
    case invalidLineageID
    case checkpointNotFound
    case blobNotFound
    case blobDoesNotMatchReference
    case byteLimitExceeded
    case operationReferencesCheckpoint
}

struct CheckpointPublication: Sendable {
    let manifest: WorktreeCheckpointManifest
    let blobs: [CheckpointBlobReference: Data]
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

    init(root: URL = Paths.checkpointsRoot, fileSystem: any CheckpointFileSystem = LiveCheckpointFileSystem(), limits: Limits = .init()) {
        self.root = root
        self.fileSystem = fileSystem
        self.limits = limits
    }

    func catalog(lineageID: String) throws -> CheckpointCatalogSnapshot {
        try validate(lineageID)
        try prepare(lineageID)
        let catalogURL = paths(lineageID).catalog
        guard exists(catalogURL) else { return try rebuildCatalog(lineageID: lineageID) }
        do {
            let catalog = try JSONDecoder.checkpoints.decode(CheckpointCatalogSnapshot.self, from: fileSystem.fileData(catalogURL))
            guard catalog.schemaVersion == CheckpointCatalogSnapshot.currentSchemaVersion, catalog.lineageID == lineageID else {
                throw CheckpointStoreError.invalidLineageID
            }
            let reconciliation = try validManifests(lineageID: lineageID)
            let unavailable = reconciliation.unavailable + catalog.summaries.filter { existing in
                existing.unavailableReason != nil && !reconciliation.unavailable.contains(where: { candidate in candidate.id == existing.id })
            }
            let rebuilt = snapshot(
                lineageID: lineageID,
                manifests: reconciliation.valid,
                unavailable: unavailable,
                byteCount: try byteCount(Set(reconciliation.valid.flatMap { references(in: $0) }), layout: paths(lineageID), incoming: [:])
            )
            if rebuilt != catalog { try writeCatalog(rebuilt, layout: paths(lineageID)) }
            return rebuilt
        } catch {
            try quarantine(catalogURL, in: paths(lineageID).quarantine, name: "catalog")
            return try rebuildCatalog(lineageID: lineageID)
        }
    }

    func publish(_ publication: CheckpointPublication) throws -> CheckpointCatalogSnapshot {
        let manifest = publication.manifest
        try validate(manifest.lineageID)
        try manifest.validate()
        try prepare(manifest.lineageID)
        let layout = paths(manifest.lineageID)
        let currentCatalog = try catalog(lineageID: manifest.lineageID)
        let manifestReferences = references(in: manifest)
        guard manifestReferences == Set(publication.blobs.keys) else { throw CheckpointStoreError.blobDoesNotMatchReference }
        for (reference, data) in publication.blobs {
            guard CheckpointBlobReference.make(for: data) == reference else { throw CheckpointStoreError.blobDoesNotMatchReference }
        }

        let existingManifests = try validManifests(lineageID: manifest.lineageID).valid
        var candidates = existingManifests + [manifest]
        let protected = try protectedIDs(lineageID: manifest.lineageID)
        let victims = retentionVictims(from: candidates, protected: protected)
        candidates.removeAll { candidate in victims.contains(where: { $0.id == candidate.id }) }
        let reachable = Set(candidates.flatMap { references(in: $0) })
        let bytes = try byteCount(reachable, layout: layout, incoming: publication.blobs)
        guard bytes <= limits.bytes else { throw CheckpointStoreError.byteLimitExceeded }

        for (reference, data) in publication.blobs where !exists(blobURL(reference, layout: layout)) {
            try fileSystem.writeDurable(data, to: blobURL(reference, layout: layout), mode: 0o600)
        }
        let entry = layout.entries.appendingPathComponent(manifest.id.uuidString.lowercased(), isDirectory: true)
        guard !exists(entry) else { throw CheckpointStoreError.checkpointNotFound }
        let temporary = layout.entries.appendingPathComponent(".\(manifest.id.uuidString.lowercased()).tmp", isDirectory: true)
        try fileSystem.createDirectoryExclusively(temporary, mode: 0o700)
        try fileSystem.writeDurable(JSONEncoder.checkpoints.encode(manifest), to: temporary.appendingPathComponent("manifest.json"), mode: 0o600)
        try fileSystem.synchronizeDirectory(temporary)
        try fileSystem.move(temporary, to: entry)

        let next = snapshot(lineageID: manifest.lineageID, manifests: candidates, unavailable: currentCatalog.summaries.filter { $0.unavailableReason != nil }, byteCount: bytes)
        try writeCatalog(next, layout: layout)
        for victim in victims { try removeEntry(victim.id, layout: layout) }
        try garbageCollect(layout: layout, manifests: candidates, journals: try activeJournals(lineageID: manifest.lineageID))
        return next
    }

    func load(id: CheckpointID, lineageID: String) throws -> WorktreeCheckpointManifest {
        try validate(lineageID)
        try prepare(lineageID)
        let manifest = try readManifest(id: id, lineageID: lineageID)
        try validate(manifest: manifest, layout: paths(lineageID))
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

    func delete(id: CheckpointID, lineageID: String) throws -> CheckpointCatalogSnapshot {
        try validate(lineageID)
        try prepare(lineageID)
        guard !(try protectedIDs(lineageID: lineageID).contains(id)) else { throw CheckpointStoreError.operationReferencesCheckpoint }
        let manifests = try validManifests(lineageID: lineageID).valid
        guard manifests.contains(where: { $0.id == id }) else { throw CheckpointStoreError.checkpointNotFound }
        let remaining = manifests.filter { $0.id != id }
        let layout = paths(lineageID)
        let next = snapshot(lineageID: lineageID, manifests: remaining, unavailable: (try catalog(lineageID: lineageID)).summaries.filter { $0.unavailableReason != nil }, byteCount: try byteCount(Set(remaining.flatMap { references(in: $0) }), layout: layout, incoming: [:]))
        try writeCatalog(next, layout: layout)
        try removeEntry(id, layout: layout)
        try garbageCollect(layout: layout, manifests: remaining, journals: try activeJournals(lineageID: lineageID))
        return next
    }

    func writeJournal(_ journal: CheckpointRestoreJournal) throws {
        try validate(journal.lineageID)
        try prepare(journal.lineageID)
        let layout = paths(journal.lineageID)
        try fileSystem.writeDurable(JSONEncoder.checkpoints.encode(journal), to: layout.journals.appendingPathComponent("\(journal.id.uuidString.lowercased()).json"), mode: 0o600)
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
        try activeJournals(lineageID: lineageID)
    }

    func finishJournal(id: UUID, lineageID: String) throws {
        guard let value = try journal(id: id, lineageID: lineageID), value.phase.isTerminal else { return }
        try fileSystem.removeIfPresent(paths(lineageID).journals.appendingPathComponent("\(id.uuidString.lowercased()).json"))
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
        if !exists(root) { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        for directory in [layout.root, layout.blobs, layout.entries, layout.journals, layout.quarantine] where !exists(directory) {
            try fileSystem.createDirectoryExclusively(directory, mode: 0o700)
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func blobURL(_ reference: CheckpointBlobReference, layout: Layout) -> URL { layout.blobs.appendingPathComponent(reference.sha256) }
    private func references(in manifest: WorktreeCheckpointManifest) -> Set<CheckpointBlobReference> {
        Set(manifest.paths.flatMap { [$0.head.blob, $0.index.blob, $0.worktree.blob].compactMap { $0 } })
    }

    private func validate(manifest: WorktreeCheckpointManifest, layout: Layout) throws {
        try manifest.validate()
        for path in manifest.paths { _ = try fileSystem.validateRelativePath(path.relativePath, under: layout.root) }
        for reference in references(in: manifest) { _ = try readBlob(reference, lineageID: manifest.lineageID) }
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

    private func validManifests(lineageID: String) throws -> ManifestReconciliation {
        try prepare(lineageID)
        let layout = paths(lineageID)
        var result = ManifestReconciliation(valid: [], unavailable: [])
        for entry in try fileSystem.list(layout.entries) where !entry.lastPathComponent.hasPrefix(".") {
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
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
                try quarantine(entry, in: layout.quarantine, name: id.uuidString.lowercased())
            }
        }
        return result
    }

    private func rebuildCatalog(lineageID: String) throws -> CheckpointCatalogSnapshot {
        let manifests = try validManifests(lineageID: lineageID)
        let layout = paths(lineageID)
        let next = snapshot(lineageID: lineageID, manifests: manifests.valid, unavailable: manifests.unavailable, byteCount: try byteCount(Set(manifests.valid.flatMap { references(in: $0) }), layout: layout, incoming: [:]))
        try writeCatalog(next, layout: layout)
        return next
    }

    private func snapshot(lineageID: String, manifests: [WorktreeCheckpointManifest], unavailable: [WorktreeCheckpointSummary] = [], byteCount: Int64) -> CheckpointCatalogSnapshot {
        let summaries = (manifests.sorted { $0.createdAt > $1.createdAt }.map { manifest in
            WorktreeCheckpointSummary(id: manifest.id, kind: manifest.kind, label: manifest.label, createdAt: manifest.createdAt, byteCount: manifest.byteCount, stagedFileCount: manifest.paths.filter { $0.index != $0.head }.count, unstagedFileCount: manifest.paths.filter { $0.worktree != $0.index }.count, untrackedFileCount: manifest.paths.filter { $0.head.kind == .absent && $0.worktree.kind != .absent }.count, unavailableReason: nil)
        } + unavailable).sorted { $0.createdAt > $1.createdAt }
        return .init(lineageID: lineageID, summaries: summaries, byteCount: byteCount)
    }

    private func unavailableSummary(for manifest: WorktreeCheckpointManifest, error: Error) -> WorktreeCheckpointSummary {
        WorktreeCheckpointSummary(id: manifest.id, kind: manifest.kind, label: manifest.label, createdAt: manifest.createdAt, byteCount: manifest.byteCount, stagedFileCount: 0, unstagedFileCount: 0, untrackedFileCount: 0, unavailableReason: String(describing: error))
    }

    private func writeCatalog(_ catalog: CheckpointCatalogSnapshot, layout: Layout) throws {
        try fileSystem.writeDurable(JSONEncoder.checkpoints.encode(catalog), to: layout.catalog, mode: 0o600)
        try fileSystem.synchronizeDirectory(layout.root)
    }

    private func byteCount(_ references: Set<CheckpointBlobReference>, layout: Layout, incoming: [CheckpointBlobReference: Data]) throws -> Int64 {
        try references.reduce(into: Int64(0)) { total, reference in
            if let data = incoming[reference] { total += Int64(data.count) }
            else { total += Int64(try fileSystem.fileData(blobURL(reference, layout: layout)).count) }
        }
    }

    private func retentionVictims(from manifests: [WorktreeCheckpointManifest], protected: Set<CheckpointID>) -> [WorktreeCheckpointManifest] {
        var victims: [WorktreeCheckpointManifest] = []
        for kind in [CheckpointKind.recovery, .manual] {
            let limit = kind == .recovery ? limits.recoveryCount : limits.manualCount
            let ordered = manifests.filter { $0.kind == kind }.sorted { $0.createdAt < $1.createdAt }
            var excess = max(0, ordered.count - limit)
            for manifest in ordered where excess > 0 && !protected.contains(manifest.id) {
                victims.append(manifest)
                excess -= 1
            }
        }
        return victims
    }

    private func activeJournals(lineageID: String) throws -> [CheckpointRestoreJournal] {
        try validate(lineageID)
        try prepare(lineageID)
        return try fileSystem.list(paths(lineageID).journals).compactMap { url in
            guard let value = try? JSONDecoder.checkpoints.decode(CheckpointRestoreJournal.self, from: fileSystem.fileData(url)), value.lineageID == lineageID, !value.phase.isTerminal else { return nil }
            return value
        }
    }

    private func protectedIDs(lineageID: String) throws -> Set<CheckpointID> {
        Set(try activeJournals(lineageID: lineageID).flatMap { [$0.checkpointID, $0.recoveryCheckpointID] })
    }

    private func garbageCollect(layout: Layout, manifests: [WorktreeCheckpointManifest], journals: [CheckpointRestoreJournal]) throws {
        let protected = Set(manifests.flatMap { references(in: $0) })
        for url in try fileSystem.list(layout.blobs) where !protected.contains(where: { $0.sha256 == url.lastPathComponent }) { try fileSystem.removeIfPresent(url) }
    }

    private func removeEntry(_ id: CheckpointID, layout: Layout) throws {
        let entry = layout.entries.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        for file in try fileSystem.list(entry) { try fileSystem.removeIfPresent(file) }
        try fileSystem.removeIfPresent(entry)
    }

    private func quarantine(_ source: URL, in directory: URL, name: String) throws {
        guard exists(source) else { return }
        try fileSystem.move(source, to: directory.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970))"))
    }
}
