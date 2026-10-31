import CryptoKit
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public typealias CheckpointID = UUID

public enum AutomaticCheckpointLabel: Sendable {
    private static let excerptLimit = 80

    public static func make(prompt: String, hasAttachments: Bool) -> String {
        let normalized = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else {
            return hasAttachments ? "Before request with attachments" : "Before request"
        }
        guard normalized.count > excerptLimit else { return "Before: \(normalized)" }
        let excerpt = String(normalized.prefix(excerptLimit - 1))
            .trimmingCharacters(in: .whitespaces)
        return "Before: \(excerpt)…"
    }
}

public struct CheckpointCoordinationSnapshot: Equatable, Sendable {
    public let dirtyEditorPaths: Set<String>
    public let activeTerminalCount: Int
    public let activeACPCount: Int
    public let otherGitMutationActive: Bool
    public let scopeDescription: String

    public static let clear = Self(dirtyEditorPaths: [], activeTerminalCount: 0, activeACPCount: 0,
                            otherGitMutationActive: false, scopeDescription: "This repository only")

    public static func scopeDescription(repositoryName: String, workspaceName: String?) -> String {
        guard let workspaceName else { return "This repository only" }
        return "Only \(repositoryName)'s selected worktree in \(workspaceName) is in scope"
    }

    public func dirtyPathsOverlapping(_ selectedPaths: Set<String>) -> Set<String> {
        Self.overlappingPaths(dirtyPaths: dirtyEditorPaths, selectedPaths: selectedPaths)
    }

    public static func overlappingPaths(dirtyPaths: Set<String>, selectedPaths: Set<String>) -> Set<String> {
        Set(dirtyPaths.filter { dirtyPath in
            selectedPaths.contains { pathsOverlap(dirtyPath, $0) }
        })
    }

    public static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = normalizedRelativePath(lhs)
        let rhs = normalizedRelativePath(rhs)
        guard !lhs.isEmpty, !rhs.isEmpty else { return lhs == rhs }
        return lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    private static func normalizedRelativePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    public init(dirtyEditorPaths: Set<String>, activeTerminalCount: Int, activeACPCount: Int, otherGitMutationActive: Bool, scopeDescription: String) {
        self.dirtyEditorPaths = dirtyEditorPaths
        self.activeTerminalCount = activeTerminalCount
        self.activeACPCount = activeACPCount
        self.otherGitMutationActive = otherGitMutationActive
        self.scopeDescription = scopeDescription
    }
}

public enum CheckpointRestoreBlocker: Int, Codable, Hashable, Sendable, CaseIterable {
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

    public static func highestPriority(in blockers: Set<Self>) -> Self? {
        blockers.min { $0.rawValue < $1.rawValue }
    }

    /// On the wire by case name: the raw value is a priority, which a new
    /// blocker shifts. A name this side does not know is a corrupt
    /// checkpoint, which still refuses the restore.
    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        self = Self.allCases.first { $0.wireName == name } ?? .corruptCheckpoint
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireName)
    }

    private var wireName: String {
        switch self {
        case .remoteTarget: "remoteTarget"
        case .interruptedRestore: "interruptedRestore"
        case .lineageMismatch: "lineageMismatch"
        case .changedHEAD: "changedHEAD"
        case .gitOperation: "gitOperation"
        case .indexLock: "indexLock"
        case .otherGitMutation: "otherGitMutation"
        case .dirtyEditorBuffer: "dirtyEditorBuffer"
        case .activeSession: "activeSession"
        case .corruptCheckpoint: "corruptCheckpoint"
        }
    }

    public var description: String {
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

public struct CheckpointRestoreEffect: Codable, Equatable, Sendable {
    public enum Layer: Codable, Equatable, Sendable { case index, worktree }
    public let relativePath: String
    public let layer: Layer
    public let head: CheckpointFileState
    public let before: CheckpointFileState
    public let after: CheckpointFileState
    public let removesUntrackedFile: Bool

    public var description: String {
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

    public init(relativePath: String, layer: Layer, head: CheckpointFileState, before: CheckpointFileState, after: CheckpointFileState, removesUntrackedFile: Bool) {
        self.relativePath = relativePath
        self.layer = layer
        self.head = head
        self.before = before
        self.after = after
        self.removesUntrackedFile = removesUntrackedFile
    }
}

public struct CheckpointRestoreGroup: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let primaryPath: String
    public let memberPaths: [String]
    public let renameSource: String?
    public let effects: [CheckpointRestoreEffect]

    public init(id: UUID, primaryPath: String, memberPaths: [String], renameSource: String?, effects: [CheckpointRestoreEffect]) {
        self.id = id
        self.primaryPath = primaryPath
        self.memberPaths = memberPaths
        self.renameSource = renameSource
        self.effects = effects
    }
}

public struct CheckpointRestorePreview: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let checkpointID: CheckpointID
    public let checkpointLabel: String
    public let currentFingerprint: String
    public let groups: [CheckpointRestoreGroup]
    public let blocker: CheckpointRestoreBlocker?
    public let scopeDescription: String
    public let selectedGroupIDs: Set<UUID>

    public static func make(manifest: WorktreeCheckpointManifest, current: WorktreeStateSnapshot,
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
                members = structuralRestoreMembers(for: members, current: current, saved: saved)
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
            var effects: [CheckpointRestoreEffect] = []
            for member in members.sorted() {
                guard let now = current.paths[member] else { throw CheckpointCaptureError.missingSelectedPath(member) }
                let desired = desiredState(for: member, members: members, saved: saved, current: current)
                effects.append(.init(relativePath: member, layer: .index, head: desired.head, before: now.index,
                                     after: desired.index, removesUntrackedFile: false))
                effects.append(.init(relativePath: member, layer: .worktree, head: desired.head, before: now.worktree,
                                     after: desired.worktree,
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
        if !coordination.dirtyPathsOverlapping(selectedPaths).isEmpty { blockers.insert(.dirtyEditorBuffer) }
        if coordination.activeTerminalCount > 0 || coordination.activeACPCount > 0 { blockers.insert(.activeSession) }
        return .init(id: UUID(), checkpointID: manifest.id, checkpointLabel: manifest.label, currentFingerprint: current.fingerprint,
                     groups: groups.sorted { $0.primaryPath < $1.primaryPath }, blocker: .highestPriority(in: blockers),
                     scopeDescription: coordination.scopeDescription, selectedGroupIDs: selected)
    }

    private static func structuralRestoreMembers(for members: Set<String>,
                                                 current: WorktreeStateSnapshot,
                                                 saved: [String: CheckpointPathState]) -> Set<String> {
        var result = members
        let availablePaths = Set(current.paths.keys).union(saved.keys)
        for path in members {
            result.formUnion(availablePaths.filter { $0.hasPrefix(path + "/") })
            var components = path.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                let ancestor = components.joined(separator: "/")
                if current.paths[ancestor] != nil || saved[ancestor] != nil {
                    result.insert(ancestor)
                }
            }
        }
        return result
    }

    private static func desiredState(for path: String,
                                     members: Set<String>,
                                     saved: [String: CheckpointPathState],
                                     current: WorktreeStateSnapshot) -> CheckpointPathState {
        if let state = saved[path] { return state }
        guard let now = current.paths[path] else {
            return .init(relativePath: path, head: .absent, index: .absent, worktree: .absent)
        }
        let isSyntheticAncestor = members.contains { $0.hasPrefix(path + "/") }
            && now.index == now.head
            && now.worktree == now.head
        return .init(relativePath: path, head: now.head, index: now.head,
                     worktree: isSyntheticAncestor ? .absent : now.head)
    }

    public init(id: UUID, checkpointID: CheckpointID, checkpointLabel: String, currentFingerprint: String, groups: [CheckpointRestoreGroup], blocker: CheckpointRestoreBlocker?, scopeDescription: String, selectedGroupIDs: Set<UUID>) {
        self.id = id
        self.checkpointID = checkpointID
        self.checkpointLabel = checkpointLabel
        self.currentFingerprint = currentFingerprint
        self.groups = groups
        self.blocker = blocker
        self.scopeDescription = scopeDescription
        self.selectedGroupIDs = selectedGroupIDs
    }
}

// Each image is decoded for this result and then treated as immutable by the
// diff presentation. Existing AppKit image pair types do not declare Sendable.
public enum CheckpointDiffContent: @unchecked Sendable {
    case text(ParsedDiff)
    case image(ImageDiffPair)
    case binary(beforeByteCount: Int64?, afterByteCount: Int64?)
    case unavailable(String)
}

/// A file's bytes at a checkpoint, as `WorktreeCheckpointService.baselineBytes` reads them.
public enum CheckpointBaselineBytes: Equatable, Sendable {
    case data(Data)
    case absent
    case tooLarge(byteCount: Int64)
    case unavailable(String)
}

public enum CheckpointKind: String, Codable, Equatable, Sendable {
    case manual
    case automatic
    case recovery
}

public enum CheckpointLeafKind: String, Codable, Equatable, Sendable {
    case absent
    case regular
    case symlink
}

public enum CheckpointModelError: Error, Equatable, Sendable {
    case invalidFileState(kind: CheckpointLeafKind, mode: String?, hasBlob: Bool)
    case invalidBlobReference
    case invalidAutomaticStateKey
    case invalidLabel
    case unsupportedSchemaVersion(Int)
}

public struct CheckpointBlobReference: Codable, Equatable, Hashable, Sendable {
    public let sha256: String
    public let byteCount: Int64

    public init(sha256: String, byteCount: Int64) {
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    public static func make(for data: Data) -> Self {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Self(sha256: hash, byteCount: Int64(data.count))
    }

    public func validate() throws {
        guard byteCount >= 0,
              sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw CheckpointModelError.invalidBlobReference
        }
    }
}

public struct CheckpointFileState: Codable, Equatable, Sendable {
    public let kind: CheckpointLeafKind
    public let mode: String?
    public let blob: CheckpointBlobReference?

    public init(kind: CheckpointLeafKind, mode: String?, blob: CheckpointBlobReference?) {
        self.kind = kind
        self.mode = mode
        self.blob = blob
    }

    public static let absent = Self(kind: .absent, mode: nil, blob: nil)

    public static func regular(blob: CheckpointBlobReference, executable: Bool) -> Self {
        Self(kind: .regular, mode: executable ? "100755" : "100644", blob: blob)
    }

    public static func symlink(blob: CheckpointBlobReference) -> Self {
        Self(kind: .symlink, mode: "120000", blob: blob)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(CheckpointLeafKind.self, forKey: .kind)
        self.mode = try container.decodeIfPresent(String.self, forKey: .mode)
        self.blob = try container.decodeIfPresent(CheckpointBlobReference.self, forKey: .blob)
        try validate()
    }

    public func validate() throws {
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

public enum CheckpointLineage: Sendable {
    /// Directory name that stores a lineage's checkpoints. Plain worktrees use
    /// a lowercase UUID, which maps to itself so existing stores stay put.
    /// Workspace members use `workspace-<checkout>-<member>`, which is hashed
    /// into a UUID-shaped name. Returns nil for IDs that are not trimmed.
    public static func storageKey(for lineageID: String) -> String? {
        guard !lineageID.isEmpty,
              lineageID == lineageID.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        if UUID(uuidString: lineageID)?.uuidString.lowercased() == lineageID { return lineageID }
        var bytes = Array(SHA256.hash(data: Data("alas-checkpoint-lineage:\(lineageID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString.lowercased()
    }
}

public struct CheckpointWorktreeTarget: Equatable, Sendable {
    public let worktreeID: String
    public let projectID: String
    public let path: URL
    public let lineageID: String
    public let branch: String
    public let repositoryName: String
    public let workspaceName: String?

    public init(worktreeID: String, projectID: String, path: URL, lineageID: String, branch: String, repositoryName: String, workspaceName: String?) {
        self.worktreeID = worktreeID
        self.projectID = projectID
        self.path = path
        self.lineageID = lineageID
        self.branch = branch
        self.repositoryName = repositoryName
        self.workspaceName = workspaceName
    }
}

public struct CheckpointPathState: Codable, Equatable, Sendable {
    public let relativePath: String
    public let head: CheckpointFileState
    public let index: CheckpointFileState
    public let worktree: CheckpointFileState

    public init(relativePath: String, head: CheckpointFileState, index: CheckpointFileState, worktree: CheckpointFileState) {
        self.relativePath = relativePath
        self.head = head
        self.index = index
        self.worktree = worktree
    }
}

public struct CheckpointFileGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let primaryPath: String
    public let renameSource: String?
    public let memberPaths: [String]

    public init(id: UUID, primaryPath: String, renameSource: String?, memberPaths: [String]) {
        self.id = id
        self.primaryPath = primaryPath
        self.renameSource = renameSource
        self.memberPaths = memberPaths
    }
}

public enum CheckpointExclusionReason: String, Codable, Equatable, Sendable {
    case ignoredByPolicy
    case likelySecret
    case tooLarge
    case specialFile
    case unsafePath
    case internalRestoreDirectory
}

public struct CheckpointExclusion: Codable, Equatable, Sendable {
    public let relativePath: String
    public let reason: CheckpointExclusionReason

    public init(relativePath: String, reason: CheckpointExclusionReason) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

public struct WorktreeCheckpointManifest: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1
    public static let currentCapturePolicyVersion = 1

    public let schemaVersion: Int
    public let id: CheckpointID
    public let kind: CheckpointKind
    public let label: String
    public let createdAt: Date
    public let byteCount: Int64
    public let lineageID: String
    public let capturedPath: String
    public let repositoryName: String
    public let branch: String
    public let headOID: String
    public let capturePolicyVersion: Int
    public let automaticStateKey: String?
    public let exclusions: [CheckpointExclusion]
    public let groups: [CheckpointFileGroup]
    public let paths: [CheckpointPathState]

    public init(
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
        automaticStateKey: String? = nil,
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
        self.automaticStateKey = automaticStateKey
        self.exclusions = exclusions
        self.groups = groups
        self.paths = paths
        try validate()
    }

    public init(from decoder: Decoder) throws {
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
            automaticStateKey: container.decodeIfPresent(String.self, forKey: .automaticStateKey),
            exclusions: container.decode([CheckpointExclusion].self, forKey: .exclusions),
            groups: container.decode([CheckpointFileGroup].self, forKey: .groups),
            paths: container.decode([CheckpointPathState].self, forKey: .paths)
        )
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CheckpointModelError.unsupportedSchemaVersion(schemaVersion)
        }
        guard capturePolicyVersion == Self.currentCapturePolicyVersion,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.count <= 120,
              byteCount >= 0,
              (kind == .automatic) == (automaticStateKey != nil),
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

public struct WorktreeCheckpointSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: CheckpointID
    public let kind: CheckpointKind
    public let label: String
    public let createdAt: Date
    public let byteCount: Int64
    public let stagedFileCount: Int
    public let unstagedFileCount: Int
    public let untrackedFileCount: Int
    public let unavailableReason: String?

    public init(id: CheckpointID, kind: CheckpointKind, label: String, createdAt: Date, byteCount: Int64, stagedFileCount: Int, unstagedFileCount: Int, untrackedFileCount: Int, unavailableReason: String?) {
        self.id = id
        self.kind = kind
        self.label = label
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.stagedFileCount = stagedFileCount
        self.unstagedFileCount = unstagedFileCount
        self.untrackedFileCount = untrackedFileCount
        self.unavailableReason = unavailableReason
    }
}

public struct CheckpointCatalogSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let lineageID: String
    public let summaries: [WorktreeCheckpointSummary]
    public let byteCount: Int64

    public init(
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

public struct CheckpointRestoreJournal: Codable, Equatable, Sendable, Identifiable {
    public struct IndexLockCandidate: Codable, Equatable, Sendable {
        public let path: String
        public let checksum: String
        public let device: UInt64
        public let inode: UInt64

        public init(path: String, checksum: String, device: UInt64, inode: UInt64) {
            self.path = path
            self.checksum = checksum
            self.device = device
            self.inode = inode
        }
    }

    public enum Phase: String, Codable, Equatable, Sendable {
        case prepared
        case applyingFiles
        case installingIndex
        case verifying
        case rollingBack
        case completed
        case recovered

        public var isTerminal: Bool {
            self == .completed || self == .recovered
        }
    }

    public let id: UUID
    public let lineageID: String
    public let checkpointID: CheckpointID
    public let recoveryCheckpointID: CheckpointID
    public var phase: Phase
    public let stagingRoot: String
    public let selectedPaths: [String]
    public var completedPaths: [String]
    public var pendingPath: String?
    public let expectedFingerprint: String
    public let expectedIndexChecksum: String
    public let preparedIndexChecksum: String?
    public var ownedIndexLockPath: String?
    public var ownedIndexLockChecksum: String?
    public var ownedIndexLockDevice: UInt64?
    public var ownedIndexLockInode: UInt64?
    public var pendingIndexLock: IndexLockCandidate?
    public let stagingNames: [String: String]

    public init(
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
    public static var checkpoints: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var checkpoints: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum CheckpointRestoreErrorPresentation {
    public static func message(_ error: Error) -> String {
        guard let restoreError = error as? CheckpointRestoreError else {
            return error.localizedDescription
        }
        switch restoreError {
        case let .blocked(blocker):
            return blocker.description
        case .stalePreview:
            return "Refresh the restore preview before trying again."
        case .emptySelection:
            return "Select at least one file group to restore."
        case let .missingPreviewGroup(id):
            return "The restore preview no longer contains group \(id.uuidString). Refresh the preview."
        case let .missingCurrentPath(path):
            return "The current worktree state for \(path) could not be read. Refresh the preview."
        case let .missingDesiredPath(path):
            return "The checkpoint state for \(path) could not be read."
        case .invalidGitOutput:
            return "Git returned output Alas could not parse."
        case .invalidJournal:
            return "The interrupted restore journal is invalid."
        case .restoreFailedButRecovered:
            return "Restore failed and the pre-restore state was recovered."
        case let .recoveryRequired(operationID, paths, phase):
            return "Restore interrupted in \(CheckpointRecoveryPresentation.phase(phase)) for \(paths.count) paths. Recover operation \(CheckpointRecoveryPresentation.operationSuffix(operationID)) before continuing."
        }
    }
}

public enum CheckpointRecoveryPresentation {
    public static func phase(_ phase: CheckpointRestoreJournal.Phase) -> String {
        switch phase {
        case .prepared: "Prepared"
        case .applyingFiles: "Applying files"
        case .installingIndex: "Installing index"
        case .verifying: "Verifying"
        case .rollingBack: "Rolling back"
        case .completed: "Completed"
        case .recovered: "Recovered"
        }
    }

    public static func operationSuffix(_ id: UUID) -> String {
        String(id.uuidString.suffix(8)).lowercased()
    }

    public static func affectedPathsSummary(_ paths: [String]) -> String {
        switch paths.count {
        case 0:
            "No paths recorded"
        case 1:
            paths[0]
        default:
            "\(paths.count) paths"
        }
    }

    public static func affectedPathsText(_ paths: [String]) -> String {
        paths.sorted().joined(separator: "\n")
    }

    public static let recoverButtonTitle = "Recover pre-restore state"
}
