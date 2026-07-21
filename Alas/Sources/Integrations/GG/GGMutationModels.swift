struct GGEffectiveConfig: Equatable, Sendable {
    var syncAutoRebase: Bool
    var syncBehindThreshold: Int

    static let defaults = GGEffectiveConfig(syncAutoRebase: false, syncBehindThreshold: 1)
}

struct GGCapabilities: Equatable, Sendable {
    var structuredSplit: Bool
    var keepCurrentUnstack: Bool
    var clientOperationID: Bool = false
    var stagedOnlyAmend: Bool = false
}

struct GGDropResult: Codable, Equatable, Sendable {
    let dropped: [GGDropCommit]
    let remaining: Int
}

struct GGDropCommit: Codable, Equatable, Sendable {
    let position: Int
    let sha: String
    let title: String
}

struct GGUnstackResult: Equatable, Sendable {
    var originalStack: String
    var newStack: String
    var movedCommits: [GGUnstackCommit]
    var worktreePath: String?
    var currentStack: String
}

struct GGUnstackCommit: Codable, Equatable, Sendable {
    let position: Int
    let sha: String
    let title: String
    let ggID: String?

    enum CodingKeys: String, CodingKey {
        case position, sha, title, ggID = "ggId"
    }
}

struct GGRestackResult: Codable, Equatable, Sendable {
    let stackName: String
    let totalEntries: Int
    let entriesRestacked: Int
    let entriesOK: Int
    let dryRun: Bool
    let steps: [GGRestackStep]

    enum CodingKeys: String, CodingKey {
        case stackName, totalEntries, entriesRestacked, entriesOK = "entriesOk", dryRun, steps
    }
}

struct GGRestackStep: Codable, Equatable, Sendable {
    let position: Int
    let ggID: String
    let title: String
    let action: String
    let currentParent: String?
    let expectedParent: String?

    enum CodingKeys: String, CodingKey {
        case position, ggID = "ggId", title, action, currentParent, expectedParent
    }
}

enum GGOperationStatus: Equatable, Sendable {
    case pending
    case completed
    case interrupted
}

extension GGOperationStatus: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "pending": self = .pending
        case "committed": self = .completed
        case "interrupted": self = .interrupted
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown gg operation status '\(value)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .pending: try container.encode("pending")
        case .completed: try container.encode("committed")
        case .interrupted: try container.encode("interrupted")
        }
    }
}

struct GGOperationSummary: Codable, Equatable, Sendable {
    let id: String
    let kind: String
    let status: GGOperationStatus
    let createdAtMs: UInt64
    let args: [String]
    let stackName: String?
    let touchedRemote: Bool
    let isUndoable: Bool
    let isUndo: Bool
    let undoes: String?

    init(
        id: String,
        kind: String,
        status: GGOperationStatus,
        createdAtMs: UInt64,
        args: [String],
        stackName: String? = nil,
        touchedRemote: Bool,
        isUndoable: Bool,
        isUndo: Bool = false,
        undoes: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.createdAtMs = createdAtMs
        self.args = args
        self.stackName = stackName
        self.touchedRemote = touchedRemote
        self.isUndoable = isUndoable
        self.isUndo = isUndo
        self.undoes = undoes
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, status, createdAtMs, args, stackName, touchedRemote, isUndoable, isUndo, undoes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        status = try container.decode(GGOperationStatus.self, forKey: .status)
        createdAtMs = try container.decode(UInt64.self, forKey: .createdAtMs)
        args = try container.decode([String].self, forKey: .args)
        stackName = try container.decodeIfPresent(String.self, forKey: .stackName)
        touchedRemote = try container.decode(Bool.self, forKey: .touchedRemote)
        isUndoable = try container.decode(Bool.self, forKey: .isUndoable)
        isUndo = try container.decodeIfPresent(Bool.self, forKey: .isUndo) ?? false
        undoes = try container.decodeIfPresent(String.self, forKey: .undoes)
    }
}

struct GGUndoResult: Codable, Equatable, Sendable {
    let undone: GGOperationSummary
}

struct GGSplitTargetIdentity: Codable, Equatable, Sendable {
    let ggID: String?
    let sha: String
    let tree: String

    enum CodingKeys: String, CodingKey {
        case ggID = "ggId", sha, tree
    }
}

struct GGSplitHunk: Codable, Equatable, Sendable {
    let id: String
    let path: String
    let header: String
    let patch: String
}

struct GGSplitDescription: Codable, Equatable, Sendable {
    let version: Int
    let planToken: String
    let target: GGSplitTargetIdentity
    let hunks: [GGSplitHunk]
    let nonTextualFiles: [String]
    let firstMessage: String
    let remainderMessage: String
}

struct GGSplitPlan: Codable, Equatable, Sendable {
    let version: Int
    let planToken: String
    let target: GGSplitTargetIdentity
    let selectedHunkIDs: [String]
    let firstMessage: String
    let remainderMessage: String

    enum CodingKeys: String, CodingKey {
        case version, planToken, target, selectedHunkIDs = "selectedHunkIds", firstMessage, remainderMessage
    }
}

struct GGSplitCommitIdentity: Codable, Equatable, Sendable {
    let sha: String
    let ggID: String?

    enum CodingKeys: String, CodingKey {
        case sha, ggID = "ggId"
    }
}

struct GGSplitApplyResult: Codable, Equatable, Sendable {
    let version: Int
    let operationID: String
    let originalSHA: String
    let first: GGSplitCommitIdentity
    let remainder: GGSplitCommitIdentity
    let rewrittenDescendants: [GGSplitCommitIdentity]

    enum CodingKeys: String, CodingKey {
        case version, operationID = "operationId", originalSHA = "originalSha",
             first, remainder, rewrittenDescendants
    }
}
