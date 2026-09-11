import CryptoKit
import Foundation

typealias CheckpointID = UUID

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

    static let absent = Self(kind: .absent, mode: nil, blob: nil)

    static func regular(blob: CheckpointBlobReference, executable: Bool) -> Self {
        Self(kind: .regular, mode: executable ? "100755" : "100644", blob: blob)
    }

    static func symlink(blob: CheckpointBlobReference) -> Self {
        Self(kind: .symlink, mode: "120000", blob: blob)
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
    let phase: Phase
    let stagingRoot: String
    let selectedPaths: [String]
    let completedPaths: [String]
    let expectedFingerprint: String
    let expectedIndexChecksum: String
    let ownedIndexLockPath: String?
    let ownedIndexLockChecksum: String?
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
