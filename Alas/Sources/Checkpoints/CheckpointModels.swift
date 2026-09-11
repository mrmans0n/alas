import CryptoKit
import Foundation

typealias CheckpointID = UUID

struct CheckpointCoordinationSnapshot: Equatable, Sendable {
    let dirtyEditorPaths: Set<String>
    let activeTerminalCount: Int
    let activeACPCount: Int
    let otherGitMutationActive: Bool
    let scopeDescription: String

    static let clear = Self(dirtyEditorPaths: [], activeTerminalCount: 0, activeACPCount: 0,
                            otherGitMutationActive: false, scopeDescription: "This repository only")

    static func scopeDescription(repositoryName: String, workspaceName: String?) -> String {
        workspaceName == nil ? "This repository only" : "Only \(repositoryName)'s selected worktree is in scope"
    }
}

enum CheckpointRestoreBlocker: Int, Hashable, Sendable, CaseIterable {
    case remoteTarget
    case interruptedRestore
    case lineageMismatch
    case changedHEAD
    case gitOperation
    case indexLock
    case otherGitMutation
    case dirtyEditorBuffer
    case activeSession
    case corruptCheckpoint

    static func highestPriority(in blockers: Set<Self>) -> Self? {
        blockers.min { $0.rawValue < $1.rawValue }
    }

    var description: String {
        switch self {
        case .remoteTarget: "Checkpoints are not available for remote worktrees yet."
        case .interruptedRestore: "An interrupted checkpoint restore needs recovery."
        case .lineageMismatch: "The worktree identity no longer matches this checkpoint."
        case .changedHEAD: "HEAD has changed since this checkpoint was captured."
        case .gitOperation: "Finish the current Git operation before restoring."
        case .indexLock: "The Git index is locked."
        case .otherGitMutation: "Another Git mutation is active."
        case .dirtyEditorBuffer: "Save or discard unsaved edits in selected files before restoring."
        case .activeSession: "Stop active terminal and agent sessions before restoring."
        case .corruptCheckpoint: "The checkpoint is unavailable or has missing or corrupt data."
        }
    }
}

struct CheckpointRestoreEffect: Equatable, Sendable {
    enum Layer: Equatable, Sendable { case index, worktree }
    let relativePath: String
    let layer: Layer
    let head: CheckpointFileState
    let before: CheckpointFileState
    let after: CheckpointFileState
    let removesUntrackedFile: Bool

    var description: String {
        switch layer {
        case .index:
            guard before != after else { return "index: unchanged" }
            return "index: \(indexStatus(before)) -> \(indexStatus(after))"
        case .worktree:
            guard before != after else { return "working tree: unchanged" }
            if removesUntrackedFile { return "untracked file will be removed" }
            let current = before == head ? "clean" : before.kind == .absent ? "deleted" : "modified"
            let desired = after.kind == .absent ? "removed" : "checkpoint contents"
            return "working tree: \(current) -> \(desired)"
        }
    }

    private func indexStatus(_ state: CheckpointFileState) -> String {
        if state == head { return "clean" }
        if state.kind == .absent { return "staged deletion" }
        if head.kind == .absent { return "staged addition" }
        return "staged modification"
    }
}

struct CheckpointRestoreGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    let primaryPath: String
    let memberPaths: [String]
    let renameSource: String?
    let effects: [CheckpointRestoreEffect]
}

struct CheckpointRestorePreview: Identifiable, Equatable, Sendable {
    let id: UUID
    let checkpointID: CheckpointID
    let checkpointLabel: String
    let currentFingerprint: String
    let groups: [CheckpointRestoreGroup]
    let blocker: CheckpointRestoreBlocker?
    let scopeDescription: String
    let selectedGroupIDs: Set<UUID>

    static func make(manifest: WorktreeCheckpointManifest, current: WorktreeStateSnapshot,
                     coordination: CheckpointCoordinationSnapshot, selectedGroupIDs: Set<UUID>? = nil,
                     blockers: Set<CheckpointRestoreBlocker> = []) throws -> Self {
        let saved = Dictionary(uniqueKeysWithValues: manifest.paths.map { ($0.relativePath, $0) })
        let savedDirty = manifest.paths.filter { $0.index != $0.head || $0.worktree != $0.head }.map(\.relativePath)
        let currentDirty = current.paths.values.filter { $0.index != $0.head || $0.worktree != $0.head }.map(\.relativePath)
        var remaining = Set(savedDirty).union(currentDirty)
        let sourceGroups = manifest.groups + current.groups
        var groups: [CheckpointRestoreGroup] = []
        for path in remaining.sorted() where remaining.contains(path) {
            var members: Set<String> = [path]
            var previous: Set<String> = []
            while previous != members {
                previous = members
                for group in sourceGroups where !members.isDisjoint(with: group.memberPaths) {
                    members.formUnion(group.memberPaths)
                }
            }
            let savedGroup = manifest.groups.first { !members.isDisjoint(with: $0.memberPaths) }
            let rename = sourceGroups.first { $0.renameSource != nil && !members.isDisjoint(with: $0.memberPaths) }
            let primary = rename?.primaryPath ?? savedGroup?.primaryPath ?? path
            // Snapshot group UUIDs are ephemeral. Derive current-only identities
            // from the checkpoint and sorted paths so selection survives refresh.
            let identity = try JSONEncoder().encode([manifest.id.uuidString] + members.sorted())
            let hash = Array(SHA256.hash(data: identity))
            let stableID = UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7], hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
            let id = savedGroup?.id ?? stableID
            let selected = selectedGroupIDs?.contains(id) ?? true
            var effects: [CheckpointRestoreEffect] = []
            for member in members.sorted() {
                guard let now = current.paths[member] else { throw CheckpointCaptureError.missingSelectedPath(member) }
                let desired = saved[member] ?? .init(relativePath: member, head: now.head, index: now.head, worktree: now.head)
                effects.append(.init(relativePath: member, layer: .index, head: desired.head, before: now.index,
                                     after: selected ? desired.index : now.index, removesUntrackedFile: false))
                effects.append(.init(relativePath: member, layer: .worktree, head: desired.head, before: now.worktree,
                                     after: selected ? desired.worktree : now.worktree,
                                     removesUntrackedFile: now.head.kind == .absent && now.index.kind == .absent && desired.worktree.kind == .absent))
            }
            groups.append(.init(id: id, primaryPath: primary, memberPaths: members.sorted(), renameSource: rename?.renameSource, effects: effects))
            remaining.subtract(members)
        }
        let selected = selectedGroupIDs.map { $0.intersection(groups.map(\.id)) } ?? Set(groups.map(\.id))
        let selectedPaths = Set(groups.filter { selected.contains($0.id) }.flatMap(\.memberPaths))
        var blockers = blockers
        if manifest.lineageID != current.lineageID { blockers.insert(.lineageMismatch) }
        if manifest.headOID != current.headOID { blockers.insert(.changedHEAD) }
        if coordination.otherGitMutationActive { blockers.insert(.otherGitMutation) }
        if !coordination.dirtyEditorPaths.isDisjoint(with: selectedPaths) { blockers.insert(.dirtyEditorBuffer) }
        if coordination.activeTerminalCount > 0 || coordination.activeACPCount > 0 { blockers.insert(.activeSession) }
        return .init(id: UUID(), checkpointID: manifest.id, checkpointLabel: manifest.label, currentFingerprint: current.fingerprint,
                     groups: groups.sorted { $0.primaryPath < $1.primaryPath }, blocker: .highestPriority(in: blockers),
                     scopeDescription: coordination.scopeDescription, selectedGroupIDs: selected)
    }
}

// Each image is decoded for this result and then treated as immutable by the
// diff presentation. Existing AppKit image pair types do not declare Sendable.
enum CheckpointDiffContent: @unchecked Sendable {
    case text(ParsedDiff)
    case image(ImageDiffPair)
    case binary(beforeByteCount: Int64?, afterByteCount: Int64?)
    case unavailable(String)
}

enum CheckpointKind: String, Codable, Equatable, Sendable {
    case manual
    case recovery
}

enum CheckpointLeafKind: String, Codable, Equatable, Sendable {
    case absent
    case regular
    case symlink
}

enum CheckpointModelError: Error, Equatable, Sendable {
    case invalidFileState(kind: CheckpointLeafKind, mode: String?, hasBlob: Bool)
    case invalidBlobReference
    case invalidLabel
    case unsupportedSchemaVersion(Int)
}

struct CheckpointBlobReference: Codable, Equatable, Hashable, Sendable {
    let sha256: String
    let byteCount: Int64

    init(sha256: String, byteCount: Int64) {
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    static func make(for data: Data) -> Self {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Self(sha256: hash, byteCount: Int64(data.count))
    }

    func validate() throws {
        guard byteCount >= 0,
              sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw CheckpointModelError.invalidBlobReference
        }
    }
}

struct CheckpointFileState: Codable, Equatable, Sendable {
    let kind: CheckpointLeafKind
    let mode: String?
    let blob: CheckpointBlobReference?

    init(kind: CheckpointLeafKind, mode: String?, blob: CheckpointBlobReference?) {
        self.kind = kind
        self.mode = mode
        self.blob = blob
    }

    static let absent = Self(kind: .absent, mode: nil, blob: nil)

    static func regular(blob: CheckpointBlobReference, executable: Bool) -> Self {
        Self(kind: .regular, mode: executable ? "100755" : "100644", blob: blob)
    }

    static func symlink(blob: CheckpointBlobReference) -> Self {
        Self(kind: .symlink, mode: "120000", blob: blob)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(CheckpointLeafKind.self, forKey: .kind)
        self.mode = try container.decodeIfPresent(String.self, forKey: .mode)
        self.blob = try container.decodeIfPresent(CheckpointBlobReference.self, forKey: .blob)
        try validate()
    }

    func validate() throws {
        switch kind {
        case .absent:
            guard mode == nil, blob == nil else {
                throw CheckpointModelError.invalidFileState(kind: kind, mode: mode, hasBlob: blob != nil)
            }
        case .regular:
            guard mode == "100644" || mode == "100755", let blob else {
                throw CheckpointModelError.invalidFileState(kind: kind, mode: mode, hasBlob: blob != nil)
            }
            try blob.validate()
        case .symlink:
            guard mode == "120000", let blob else {
                throw CheckpointModelError.invalidFileState(kind: kind, mode: mode, hasBlob: blob != nil)
            }
            try blob.validate()
        }
    }
}

struct CheckpointWorktreeTarget: Equatable, Sendable {
    let worktreeID: String
    let projectID: String
    let path: URL
    let lineageID: String
    let branch: String
    let repositoryName: String
    let workspaceName: String?
}

struct CheckpointPathState: Codable, Equatable, Sendable {
    let relativePath: String
    let head: CheckpointFileState
    let index: CheckpointFileState
    let worktree: CheckpointFileState
}

struct CheckpointFileGroup: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let primaryPath: String
    let renameSource: String?
    let memberPaths: [String]
}

enum CheckpointExclusionReason: String, Codable, Equatable, Sendable {
    case ignoredByPolicy
    case likelySecret
    case tooLarge
    case specialFile
    case unsafePath
    case internalRestoreDirectory
}

struct CheckpointExclusion: Codable, Equatable, Sendable {
    let relativePath: String
    let reason: CheckpointExclusionReason
}

struct WorktreeCheckpointManifest: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 1
    static let currentCapturePolicyVersion = 1

    let schemaVersion: Int
    let id: CheckpointID
    let kind: CheckpointKind
    let label: String
    let createdAt: Date
    let byteCount: Int64
    let lineageID: String
    let capturedPath: String
    let repositoryName: String
    let branch: String
    let headOID: String
    let capturePolicyVersion: Int
    let exclusions: [CheckpointExclusion]
    let groups: [CheckpointFileGroup]
    let paths: [CheckpointPathState]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: CheckpointID = UUID(),
        kind: CheckpointKind,
        label: String,
        createdAt: Date = .now,
        byteCount: Int64,
        lineageID: String,
        capturedPath: String,
        repositoryName: String,
        branch: String,
        headOID: String,
        capturePolicyVersion: Int = Self.currentCapturePolicyVersion,
        exclusions: [CheckpointExclusion],
        groups: [CheckpointFileGroup],
        paths: [CheckpointPathState]
    ) throws {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else { throw CheckpointModelError.invalidLabel }

        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.label = String(normalizedLabel.prefix(120))
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.lineageID = lineageID
        self.capturedPath = capturedPath
        self.repositoryName = repositoryName
        self.branch = branch
        self.headOID = headOID
        self.capturePolicyVersion = capturePolicyVersion
        self.exclusions = exclusions
        self.groups = groups
        self.paths = paths
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            id: container.decode(CheckpointID.self, forKey: .id),
            kind: container.decode(CheckpointKind.self, forKey: .kind),
            label: container.decode(String.self, forKey: .label),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            byteCount: container.decode(Int64.self, forKey: .byteCount),
            lineageID: container.decode(String.self, forKey: .lineageID),
            capturedPath: container.decode(String.self, forKey: .capturedPath),
            repositoryName: container.decode(String.self, forKey: .repositoryName),
            branch: container.decode(String.self, forKey: .branch),
            headOID: container.decode(String.self, forKey: .headOID),
            capturePolicyVersion: container.decode(Int.self, forKey: .capturePolicyVersion),
            exclusions: container.decode([CheckpointExclusion].self, forKey: .exclusions),
            groups: container.decode([CheckpointFileGroup].self, forKey: .groups),
            paths: container.decode([CheckpointPathState].self, forKey: .paths)
        )
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CheckpointModelError.unsupportedSchemaVersion(schemaVersion)
        }
        guard capturePolicyVersion == Self.currentCapturePolicyVersion,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.count <= 120,
              byteCount >= 0,
              Set(paths.map(\.relativePath)).count == paths.count,
              Set(groups.map(\.id)).count == groups.count
        else { throw CheckpointModelError.invalidLabel }
        try paths.forEach { path in
            try path.head.validate()
            try path.index.validate()
            try path.worktree.validate()
        }
    }
}

struct WorktreeCheckpointSummary: Codable, Equatable, Sendable, Identifiable {
    let id: CheckpointID
    let kind: CheckpointKind
    let label: String
    let createdAt: Date
    let byteCount: Int64
    let stagedFileCount: Int
    let unstagedFileCount: Int
    let untrackedFileCount: Int
    let unavailableReason: String?
}

struct CheckpointCatalogSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let lineageID: String
    let summaries: [WorktreeCheckpointSummary]
    let byteCount: Int64

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        lineageID: String,
        summaries: [WorktreeCheckpointSummary],
        byteCount: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.lineageID = lineageID
        self.summaries = summaries
        self.byteCount = byteCount
    }
}

struct CheckpointRestoreJournal: Codable, Equatable, Sendable, Identifiable {
    struct IndexLockCandidate: Codable, Equatable, Sendable {
        let path: String
        let checksum: String
        let device: UInt64
        let inode: UInt64
    }

    enum Phase: String, Codable, Equatable, Sendable {
        case prepared
        case applyingFiles
        case installingIndex
        case verifying
        case rollingBack
        case completed
        case recovered

        var isTerminal: Bool {
            self == .completed || self == .recovered
        }
    }

    let id: UUID
    let lineageID: String
    let checkpointID: CheckpointID
    let recoveryCheckpointID: CheckpointID
    var phase: Phase
    let stagingRoot: String
    let selectedPaths: [String]
    var completedPaths: [String]
    var pendingPath: String?
    let expectedFingerprint: String
    let expectedIndexChecksum: String
    let preparedIndexChecksum: String?
    var ownedIndexLockPath: String?
    var ownedIndexLockChecksum: String?
    var ownedIndexLockDevice: UInt64?
    var ownedIndexLockInode: UInt64?
    var pendingIndexLock: IndexLockCandidate?
    let stagingNames: [String: String]

    init(
        id: UUID = UUID(),
        lineageID: String,
        checkpointID: CheckpointID,
        recoveryCheckpointID: CheckpointID,
        phase: Phase,
        stagingRoot: String,
        selectedPaths: [String],
        completedPaths: [String] = [],
        expectedFingerprint: String,
        expectedIndexChecksum: String,
        preparedIndexChecksum: String? = nil,
        ownedIndexLockPath: String? = nil,
        ownedIndexLockChecksum: String? = nil,
        stagingNames: [String: String] = [:]
    ) {
        self.id = id
        self.lineageID = lineageID
        self.checkpointID = checkpointID
        self.recoveryCheckpointID = recoveryCheckpointID
        self.phase = phase
        self.stagingRoot = stagingRoot
        self.selectedPaths = selectedPaths
        self.completedPaths = completedPaths
        self.expectedFingerprint = expectedFingerprint
        self.expectedIndexChecksum = expectedIndexChecksum
        self.preparedIndexChecksum = preparedIndexChecksum
        self.ownedIndexLockPath = ownedIndexLockPath
        self.ownedIndexLockChecksum = ownedIndexLockChecksum
        self.stagingNames = stagingNames
    }
}

extension JSONEncoder {
    static var checkpoints: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var checkpoints: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
