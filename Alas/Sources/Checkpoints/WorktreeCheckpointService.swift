import Foundation

protocol WorktreeCheckpointServicing: Sendable {
    func summaries(target: CheckpointWorktreeTarget) async throws -> CheckpointCatalogSnapshot
    func createManual(target: CheckpointWorktreeTarget, label: String) async throws -> WorktreeCheckpointSummary
    func manifest(target: CheckpointWorktreeTarget, id: CheckpointID) async throws -> WorktreeCheckpointManifest
    func delete(target: CheckpointWorktreeTarget, id: CheckpointID) async throws -> CheckpointCatalogSnapshot
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

    init(store: WorktreeCheckpointStore = .init(),
         snapshotter: WorktreeStateSnapshotter = .live,
         hooks: CheckpointCaptureHooks = .none) {
        self.store = store
        self.snapshotter = snapshotter
        self.hooks = hooks
    }

    func summaries(target: CheckpointWorktreeTarget) async throws -> CheckpointCatalogSnapshot {
        try await store.catalog(lineageID: target.lineageID)
    }

    func manifest(target: CheckpointWorktreeTarget, id: CheckpointID) async throws -> WorktreeCheckpointManifest {
        try await store.load(id: id, lineageID: target.lineageID)
    }

    func delete(target: CheckpointWorktreeTarget, id: CheckpointID) async throws -> CheckpointCatalogSnapshot {
        try await store.delete(id: id, lineageID: target.lineageID)
    }

    func createManual(target: CheckpointWorktreeTarget, label: String) async throws -> WorktreeCheckpointSummary {
        let label = try normalizedLabel(label)
        for number in 1...2 {
            do {
                let attempt = try await CheckpointCaptureAttempt(snapshot: snapshotter.snapshot(target: target), capturedAt: .now)
                try await hooks.afterPayloadStaging(number)
                let verification = try await snapshotter.snapshot(target: target)
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
                        selectedPaths: Set<String>) async throws -> WorktreeCheckpointSummary {
        guard current.lineageID == target.lineageID else { throw CheckpointSnapshotError.lineageChanged }
        return try await publish(target: target, attempt: .init(snapshot: current, capturedAt: .now),
                                 paths: selectedPaths, kind: .recovery, label: "Before checkpoint restore")
    }

    private func normalizedLabel(_ label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CheckpointModelError.invalidLabel }
        return String(trimmed.prefix(120))
    }

    private func publish(target: CheckpointWorktreeTarget, attempt: CheckpointCaptureAttempt,
                         paths selectedPaths: Set<String>, kind: CheckpointKind, label: String) async throws -> WorktreeCheckpointSummary {
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
        let catalog = try await store.publish(.init(manifest: manifest, blobs: blobs))
        guard let summary = catalog.summaries.first(where: { $0.id == manifest.id }) else {
            throw CheckpointStoreError.checkpointNotFound
        }
        return summary
    }
}
