import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public struct GGEffectiveConfig: Equatable, Sendable {
    public var syncAutoRebase: Bool
    public var syncBehindThreshold: Int
    public var syncAutoLint: Bool = false

    public static let defaults = GGEffectiveConfig(
        syncAutoRebase: false,
        syncBehindThreshold: 1,
        syncAutoLint: false
    )

    public init(syncAutoRebase: Bool, syncBehindThreshold: Int, syncAutoLint: Bool = false) {
        self.syncAutoRebase = syncAutoRebase
        self.syncBehindThreshold = syncBehindThreshold
        self.syncAutoLint = syncAutoLint
    }
}

public struct GGCapabilities: Equatable, Sendable {
    public var structuredSplit: Bool
    public var keepCurrentUnstack: Bool
    public var clientOperationID: Bool = false
    public var stagedOnlyAmend: Bool = false
    public var syncJSONL: Bool = false
    public var landJSONL: Bool = false
    public var localStackSnapshot: Bool = false

    public init(structuredSplit: Bool, keepCurrentUnstack: Bool, clientOperationID: Bool = false, stagedOnlyAmend: Bool = false, syncJSONL: Bool = false, landJSONL: Bool = false, localStackSnapshot: Bool = false) {
        self.structuredSplit = structuredSplit
        self.keepCurrentUnstack = keepCurrentUnstack
        self.clientOperationID = clientOperationID
        self.stagedOnlyAmend = stagedOnlyAmend
        self.syncJSONL = syncJSONL
        self.landJSONL = landJSONL
        self.localStackSnapshot = localStackSnapshot
    }
}

public struct GGLocalChangeStatistics: Equatable, Sendable {
    public var staged: Int
    public var unstaged: Int

    public static let zero = GGLocalChangeStatistics(staged: 0, unstaged: 0)

    public var hasChanges: Bool { staged > 0 || unstaged > 0 }

    public init(staged: Int, unstaged: Int) {
        self.staged = staged
        self.unstaged = unstaged
    }
}

public enum GGMutationRequest: Equatable, Sendable {
    case amendCurrent
    case absorbStaged
    case checkout(target: String)
    case drop(target: String)
    case unstack(target: String, name: String, createWorktree: Bool)
    case reorder(order: [String])
    case restack
    case rebase(target: String?)
    case sync
    case land(target: String)
    case clean
    case continueOperation
    case abortOperation
    case undo(operationID: String)
    case applySplit(planURL: URL, target: GGSplitTargetIdentity, planToken: String)

    public var actionKind: GGStackActionKind {
        switch self {
        case .amendCurrent: .amendCurrent
        case .absorbStaged: .absorbStaged
        case .checkout: .checkout
        case .drop: .drop
        case .unstack: .unstack
        case .reorder: .reorder
        case .restack: .restack
        case .rebase: .rebase
        case .sync: .sync
        case .land: .land
        case .clean: .clean
        case .continueOperation: .continueOp
        case .abortOperation: .abortOp
        case .undo: .undo
        case .applySplit: .split
        }
    }

    public var requiresStagedChanges: Bool {
        switch self {
        case .amendCurrent, .absorbStaged: true
        default: false
        }
    }
}

public struct GGStackIdentity: Equatable, Sendable {
    public var stackName: String
    public var base: String
    public var headSHA: String
    public var operationID: String?

    public init(stackName: String, base: String, headSHA: String, operationID: String? = nil) {
        self.stackName = stackName
        self.base = base
        self.headSHA = headSHA
        self.operationID = operationID
    }
}

/// The stable portion of a stack identity used to protect a commit-and-sync
/// workflow across the local commit that intentionally changes the stack head.
public struct GGStackTargetIdentity: Codable, Equatable, Sendable {
    public var branch: String
    public var stackName: String
    public var base: String
    public var expectedHeadSHA: String

    public func matches(branch: String, stackName: String, base: String, headSHA: String) -> Bool {
        branch == self.branch
            && stackName == self.stackName
            && base == self.base
            && Self.matchesSHA(headSHA, expectedHeadSHA)
    }

    private static func matchesSHA(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    public init(branch: String, stackName: String, base: String, expectedHeadSHA: String) {
        self.branch = branch
        self.stackName = stackName
        self.base = base
        self.expectedHeadSHA = expectedHeadSHA
    }
}

public struct GGPreparedMutation: Equatable, Sendable {
    public var request: GGMutationRequest
    public var snapshot: GGStackIdentity
    public var confirmation: GGMutationConfirmation?
    public var stack: GGStack? = nil

    public init(request: GGMutationRequest, snapshot: GGStackIdentity, confirmation: GGMutationConfirmation? = nil, stack: GGStack? = nil) {
        self.request = request
        self.snapshot = snapshot
        self.confirmation = confirmation
        self.stack = stack
    }
}

public struct GGPreparedRestack: Equatable, Sendable {
    public var plan: GGRestackResult
    public var snapshot: GGStackIdentity

    public init(plan: GGRestackResult, snapshot: GGStackIdentity) {
        self.plan = plan
        self.snapshot = snapshot
    }
}

public enum GGMutationConfirmation: Equatable, Sendable {
    case drop(target: String, rewrittenDescendants: Int, hasOpenReview: Bool)
    case unstack(
        target: String,
        targetTitle: String,
        movedCommits: Int,
        lowerStack: String,
        newStack: String
    )
    /// `commits` counts the not-yet-merged entries at or below the target —
    /// the land's scope. Deliberately not a "ready" count: approvals landing
    /// between confirmation and execution must not invalidate the dialog the
    /// user already accepted.
    case land(target: String, commits: Int)
    case clean(mergedCommits: Int)

    public var message: String {
        switch self {
        case .drop(let target, let rewrittenDescendants, let hasOpenReview):
            let descendants = Self.commitCount(rewrittenDescendants, qualifier: "descendant")
            let reviewWarning = hasOpenReview ? " The selected commit has an open review." : ""
            return "Drop \(target) and rewrite \(descendants).\(reviewWarning)"
        case .unstack(_, let targetTitle, let movedCommits, let lowerStack, let newStack):
            return "Split at \u{201C}\(targetTitle)\u{201D}. Move \(Self.commitCount(movedCommits)) from \(lowerStack) to \(newStack)."
        case .land(let target, let commits):
            return "Land \(Self.commitCount(commits)) through \(target)."
        case .clean(let mergedCommits):
            return "Clean \(Self.commitCount(mergedCommits, qualifier: "merged"))."
        }
    }

    private static func commitCount(_ count: Int, qualifier: String? = nil) -> String {
        let prefix = qualifier.map { "\($0) " } ?? ""
        return "\(count) \(prefix)commit\(count == 1 ? "" : "s")"
    }
}

public enum GGMutationError: Error, Equatable, Sendable {
    case operationInFlight
    case staleConfirmation
    case immutableTarget(reason: String)
    case pausedOperation
    case blockingGitOperation
    case stagingFailed
    case syncTerminalFailure(message: String)
}

extension GGMutationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .operationInFlight: "Another gg operation is already running."
        case .staleConfirmation: "The stack changed. Review the updated state and try again."
        case .immutableTarget(let reason): reason
        case .pausedOperation: "Continue or abort the paused gg operation first."
        case .blockingGitOperation: "Finish the current Git operation first."
        case .stagingFailed: "Staging failed. Fix the staging error and try again."
        case .syncTerminalFailure(let message): message
        }
    }
}

public struct GGDropResult: Codable, Equatable, Sendable {
    public let dropped: [GGDropCommit]
    public let remaining: Int

    public init(dropped: [GGDropCommit], remaining: Int) {
        self.dropped = dropped
        self.remaining = remaining
    }
}

public struct GGDropCommit: Codable, Equatable, Sendable {
    public let position: Int
    public let sha: String
    public let title: String

    public init(position: Int, sha: String, title: String) {
        self.position = position
        self.sha = sha
        self.title = title
    }
}

public struct GGUnstackResult: Equatable, Sendable {
    public var originalStack: String
    public var newStack: String
    public var movedCommits: [GGUnstackCommit]
    public var worktreePath: String?
    public var currentStack: String

    public init(originalStack: String, newStack: String, movedCommits: [GGUnstackCommit], worktreePath: String? = nil, currentStack: String) {
        self.originalStack = originalStack
        self.newStack = newStack
        self.movedCommits = movedCommits
        self.worktreePath = worktreePath
        self.currentStack = currentStack
    }
}

public struct GGUnstackCommit: Codable, Equatable, Sendable {
    public let position: Int
    public let sha: String
    public let title: String
    public let ggID: String?

    public enum CodingKeys: String, CodingKey, Sendable {
        case position, sha, title, ggID = "ggId"
    }

    public init(position: Int, sha: String, title: String, ggID: String?) {
        self.position = position
        self.sha = sha
        self.title = title
        self.ggID = ggID
    }
}

public struct GGRestackResult: Codable, Equatable, Sendable {
    public let stackName: String
    public let totalEntries: Int
    public let entriesRestacked: Int
    public let entriesOK: Int
    public let dryRun: Bool
    public let steps: [GGRestackStep]

    public enum CodingKeys: String, CodingKey, Sendable {
        case stackName, totalEntries, entriesRestacked, entriesOK = "entriesOk", dryRun, steps
    }

    public init(stackName: String, totalEntries: Int, entriesRestacked: Int, entriesOK: Int, dryRun: Bool, steps: [GGRestackStep]) {
        self.stackName = stackName
        self.totalEntries = totalEntries
        self.entriesRestacked = entriesRestacked
        self.entriesOK = entriesOK
        self.dryRun = dryRun
        self.steps = steps
    }
}

public struct GGRestackStep: Codable, Equatable, Sendable {
    public let position: Int
    public let ggID: String
    public let title: String
    public let action: String
    public let currentParent: String?
    public let expectedParent: String?

    public enum CodingKeys: String, CodingKey, Sendable {
        case position, ggID = "ggId", title, action, currentParent, expectedParent
    }

    public init(position: Int, ggID: String, title: String, action: String, currentParent: String?, expectedParent: String?) {
        self.position = position
        self.ggID = ggID
        self.title = title
        self.action = action
        self.currentParent = currentParent
        self.expectedParent = expectedParent
    }
}

public enum GGOperationStatus: Equatable, Sendable {
    case pending
    case completed
    case interrupted
}

extension GGOperationStatus: Codable {
    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .pending: try container.encode("pending")
        case .completed: try container.encode("committed")
        case .interrupted: try container.encode("interrupted")
        }
    }
}

public struct GGOperationSummary: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let status: GGOperationStatus
    public let createdAtMs: UInt64
    public let args: [String]
    public let stackName: String?
    public let touchedRemote: Bool
    public let isUndoable: Bool
    public let isUndo: Bool
    public let undoes: String?

    public init(
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

    public enum CodingKeys: String, CodingKey, Sendable {
        case id, kind, status, createdAtMs, args, stackName, touchedRemote, isUndoable, isUndo, undoes
    }

    public init(from decoder: Decoder) throws {
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

public struct GGUndoResult: Codable, Equatable, Sendable {
    public let undone: GGOperationSummary

    public init(undone: GGOperationSummary) {
        self.undone = undone
    }
}

public struct GGUndoCandidate: Equatable, Sendable {
    public let operationID: String
    public let kind: String
    public let status: GGOperationStatus
    public let touchedRemote: Bool
    public let isUndoable: Bool

    public init(operation: GGOperationSummary) {
        operationID = operation.id
        kind = operation.kind
        status = operation.status
        touchedRemote = operation.touchedRemote
        isUndoable = operation.isUndoable
    }
}

public struct GGSplitTargetIdentity: Codable, Equatable, Sendable {
    public let ggID: String?
    public let sha: String
    public let tree: String

    public enum CodingKeys: String, CodingKey, Sendable {
        case ggID = "ggId", sha, tree
    }

    public init(ggID: String?, sha: String, tree: String) {
        self.ggID = ggID
        self.sha = sha
        self.tree = tree
    }
}

public struct GGSplitHunk: Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let header: String
    public let patch: String

    public init(id: String, path: String, header: String, patch: String) {
        self.id = id
        self.path = path
        self.header = header
        self.patch = patch
    }
}

public struct GGSplitDescription: Codable, Equatable, Sendable {
    public let version: Int
    public let planToken: String
    public let target: GGSplitTargetIdentity
    public let hunks: [GGSplitHunk]
    public let nonTextualFiles: [String]
    public let firstMessage: String
    public let remainderMessage: String

    public init(version: Int, planToken: String, target: GGSplitTargetIdentity, hunks: [GGSplitHunk], nonTextualFiles: [String], firstMessage: String, remainderMessage: String) {
        self.version = version
        self.planToken = planToken
        self.target = target
        self.hunks = hunks
        self.nonTextualFiles = nonTextualFiles
        self.firstMessage = firstMessage
        self.remainderMessage = remainderMessage
    }
}

public struct GGSplitPlan: Codable, Equatable, Sendable {
    public let version: Int
    public let planToken: String
    public let target: GGSplitTargetIdentity
    public let selectedHunkIDs: [String]
    public let firstMessage: String
    public let remainderMessage: String

    public enum CodingKeys: String, CodingKey, Sendable {
        case version, planToken, target, selectedHunkIDs = "selectedHunkIds", firstMessage, remainderMessage
    }

    public init(version: Int, planToken: String, target: GGSplitTargetIdentity, selectedHunkIDs: [String], firstMessage: String, remainderMessage: String) {
        self.version = version
        self.planToken = planToken
        self.target = target
        self.selectedHunkIDs = selectedHunkIDs
        self.firstMessage = firstMessage
        self.remainderMessage = remainderMessage
    }
}

public struct GGSplitCommitIdentity: Codable, Equatable, Sendable {
    public let sha: String
    public let ggID: String?

    public enum CodingKeys: String, CodingKey, Sendable {
        case sha, ggID = "ggId"
    }

    public init(sha: String, ggID: String?) {
        self.sha = sha
        self.ggID = ggID
    }
}

public struct GGSplitApplyResult: Codable, Equatable, Sendable {
    public let version: Int
    public let operationID: String
    public let originalSHA: String
    public let first: GGSplitCommitIdentity
    public let remainder: GGSplitCommitIdentity
    public let rewrittenDescendants: [GGSplitCommitIdentity]

    public enum CodingKeys: String, CodingKey, Sendable {
        case version, operationID = "operationId", originalSHA = "originalSha",
             first, remainder, rewrittenDescendants
    }

    public init(version: Int, operationID: String, originalSHA: String, first: GGSplitCommitIdentity, remainder: GGSplitCommitIdentity, rewrittenDescendants: [GGSplitCommitIdentity]) {
        self.version = version
        self.operationID = operationID
        self.originalSHA = originalSHA
        self.first = first
        self.remainder = remainder
        self.rewrittenDescendants = rewrittenDescendants
    }
}
