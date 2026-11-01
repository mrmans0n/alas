import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations
import AlasACP
import AlasSessions

/// The host protocol: the messages a client exchanges with `AlasHost` over
/// any transport. A client sends `HostClientMessage`s and receives
/// `HostServerMessage`s: one response per request, matched by id, and the
/// events of its subscription in between. Who the client is comes from the
/// transport, never from a message.
public enum HostProtocolVersion {
    public static let current = 1
}

/// A worktree named the way the host keys its claims: a path can be listed
/// under more than one host's project.
public struct WorktreeRef: Codable, Hashable, Sendable {
    public var projectID: String
    public var path: String

    public init(projectID: String, path: String) {
        self.projectID = projectID
        self.path = path
    }
}

public struct HostClientMessage: Codable, Equatable, Sendable {
    public var version: Int
    /// Echoed on the response, so a client can match it.
    public var id: Int
    public var request: HostRequest

    public init(version: Int = HostProtocolVersion.current, id: Int, request: HostRequest) {
        self.version = version
        self.id = id
        self.request = request
    }
}

public enum HostRequest: Codable, Equatable, Sendable {
    case snapshot
    /// Starts the connection's subscription with the events after `after`,
    /// a cursor from a snapshot. A second subscribe replaces the first.
    case subscribe(after: HostCursor)
    case unsubscribe
    case listSessions
    case addProject(path: String, displayName: String, host: String?, kind: ProjectKind)
    /// Forgets a project. A host before it answers `invalidRequest`.
    case removeProject(projectID: String)
    case createWorktree(projectID: String, base: String, branch: String, destination: String)
    /// `lineageID` and `branch` are the worktree's as the client last saw
    /// it: a checkout replaced or switched since is refused as changed.
    /// `discardUnsavedEdits`: whether the user agreed to discard unsaved
    /// editor changes on the host (`host.worktrees.lifecycle.v1`). Nil from an
    /// older client, refused like false with an untyped message.
    case deleteWorktree(
        worktree: WorktreeRef, lineageID: String?, branch: String, force: Bool, deleteBranchIfMerged: Bool,
        discardUnsavedEdits: Bool? = nil
    )
    /// Like a delete, names the lineage and branch the client last saw, and
    /// acknowledges discarding unsaved editor changes.
    case archiveWorktree(worktree: WorktreeRef, lineageID: String?, branch: String, discardUnsavedEdits: Bool? = nil)
    case unarchiveWorktree(worktree: WorktreeRef)
    /// Renames a listed worktree's branch `from`, the one the client last
    /// saw, to `to`, or a numbered variant when taken, under the local menu's
    /// rules (`host.worktrees.renameBranch.v1`).
    case renameBranch(worktree: WorktreeRef, from: String, to: String)
    case listWorkspaceCheckouts
    case workspaceCheckout(id: UUID)
    case startRun(scriptKey: String, worktree: WorktreeRef)
    case stopRun(scriptKey: String, worktree: WorktreeRef)
    /// The scripts a listed worktree's Run tab lists (`host.runs.scripts.v1`).
    case listRunScripts(worktree: WorktreeRef)
    /// Stops whatever the script's slot holds, then starts it again
    /// (`host.runs.scripts.v1`).
    case restartRun(scriptKey: String, worktree: WorktreeRef)
    case createSession(target: SessionTarget, agentID: String, modelID: String?, autoRun: Bool)
    case sendPrompt(sessionID: String, prompt: String)
    case stopSession(sessionID: String)
    case renameSession(sessionID: String, title: String)
    case archiveSession(sessionID: String)
    case setSessionModel(sessionID: String, modelID: String)
    case setSessionMode(sessionID: String, modeID: String)
    case setSessionConfigOption(sessionID: String, configID: String, value: ACPConfigValue)
    /// Answers the request the subscription announced under `requestID`.
    case answerPermission(sessionID: String, requestID: JSONRPCID, optionID: String, scope: ACPRequestAnswers.PermissionScope)
    case answerQuestion(sessionID: String, requestID: JSONRPCID, answers: [ACPQuestionAnswer])
    case respondToPlan(sessionID: String, requestID: JSONRPCID, action: ACPRequestAnswers.PlanAction)
    case respondToUserInput(sessionID: String, requestID: UUID, answer: ACPRequestAnswers.UserInputAnswer)
    /// Streams the session's transcript and pending requests on the
    /// connection's subscription, which must exist: a new subscription
    /// follows nothing until asked.
    case followSession(sessionID: String, from: TranscriptRevision?)
    case unfollowSession(sessionID: String)
    /// Keeps the worktree's review status refreshed while the connection's
    /// subscription follows it (`host.worktrees.follow.v1`).
    case followWorktree(worktreeID: String)
    case unfollowWorktree(worktreeID: String)
    /// The optional features this host serves, for clients without Remote's
    /// `hello`. A host before them cannot decode it and answers
    /// `invalidRequest`, which a client takes as no extensions.
    case capabilities
    /// Subscribes as `subscribe` does, also sending the event kinds in
    /// `events` that a version 1 client cannot decode (`host.events.v1`).
    case subscribeAccepting(after: HostCursor, events: [String])
    /// What run `runID` of project `projectID` printed, once it finished
    /// (`host.runs.output.v1`).
    case runOutput(runID: String, projectID: String)
    /// A new code a device redeems at the Remote server's `POST /pair`, from
    /// a host that serves Remote headlessly and to a local client only. A
    /// host that serves no Remote, or the app, refuses it.
    case remotePairingCode
    /// The Macs paired with a host that serves Remote headlessly, to a local
    /// client only. A host that serves no Remote, or the app, refuses it.
    case listPeers
    /// Forgets a paired Mac and revokes its token; local client only.
    case forgetPeer(peerID: String)
    /// Reads a listed worktree's code as a session in it would
    /// (`host.worktrees.read.v1`).
    case readWorktree(worktree: WorktreeRef, read: HostWorktreeRead)
    /// Changes a listed worktree on `branch`, the one the client last saw,
    /// as its Changes tab would (`host.worktrees.git.v1`).
    case mutateWorktree(worktree: WorktreeRef, branch: String, change: HostWorktreeChange)
    /// What a commit message is suggested from, for the client's own model
    /// (`host.worktrees.git.v1`).
    case commitMessageInput(worktree: WorktreeRef)
    /// A listed worktree's branch sync and pull request status, read again
    /// first (`host.worktrees.git.v1`).
    case reviewStatus(worktree: WorktreeRef)
    /// A listed worktree's draft reviews, newest first (`host.reviews.v1`).
    case listReviews(worktree: WorktreeRef)
    /// One of them, `sessionID` as listed, with every comment (`host.reviews.v1`).
    case readReview(worktree: WorktreeRef, sessionID: String)
    /// Changes a comment of review `sessionID` (`host.reviews.v1`).
    case mutateReview(worktree: WorktreeRef, sessionID: String, mutation: HostReviewMutation)
    /// Pull or merge request review `sessionID` as its provider shows it to
    /// the host's user, with its raw diff when `withDiff` (`host.reviews.provider.v1`).
    case readProviderReview(worktree: WorktreeRef, sessionID: String, withDiff: Bool)
    /// Opens the review of the worktree's pull or merge request `number`,
    /// reusing the open one, as an agent would (`host.reviews.provider.v1`).
    case openProviderReview(worktree: WorktreeRef, number: Int)
    /// Replies to, resolves or unresolves thread `threadID` of pull or merge
    /// request review `sessionID` on its provider, as the host's user
    /// (`host.reviews.provider.v1`).
    case mutateReviewThread(
        worktree: WorktreeRef, sessionID: String, threadID: String, kind: ProviderThreadMutationKind, body: String?
    )
    /// Publishes pull or merge request review `sessionID` on its provider, as
    /// the host's user (`host.reviews.provider.v1`).
    case publishReview(worktree: WorktreeRef, sessionID: String, publish: HostReviewPublish)
    /// The repository's stashes, as a worktree's Stashes list shows them
    /// (`host.worktrees.stash.v1`).
    case listStashes(worktree: WorktreeRef)
    /// The files of `stash`, as listed (`host.worktrees.stash.v1`).
    case stashFiles(worktree: WorktreeRef, stash: HostStashRef)
    /// One file's diff in `stash`, as listed (`host.worktrees.stash.v1`).
    case stashDiff(worktree: WorktreeRef, stash: HostStashRef, path: String)
    /// A commit as its editor shows it, named by its SHA (`host.worktrees.commitEdit.v1`).
    case commitDetails(worktree: WorktreeRef, sha: String)
    /// The worktree's checkpoints, newest first (`host.worktrees.checkpoints.v1`).
    case listCheckpoints(worktree: WorktreeRef)
    /// One of them, as listed (`host.worktrees.checkpoints.v1`).
    case checkpointManifest(worktree: WorktreeRef, id: CheckpointID)
    /// How `path` changed since checkpoint `id`, as listed (`host.worktrees.checkpoints.v1`).
    case checkpointDiff(worktree: WorktreeRef, id: CheckpointID, path: String)
    /// What restoring checkpoint `id` would change, and what blocks it on the
    /// host; nil `groupIDs` selects every group (`host.worktrees.checkpoints.v1`).
    case checkpointRestorePreview(worktree: WorktreeRef, id: CheckpointID, groupIDs: Set<UUID>?)
    /// Replaces `path`'s text if the file is still at `expected`; nil `expected` creates it, refusing if anything is there
    /// (`host.worktrees.files.v1`).
    case writeFile(worktree: WorktreeRef, path: String, text: String, expected: WorktreeFileVersion?)
    /// Makes folder `path` in a folder that exists (`host.worktrees.files.v1`).
    case createFolder(worktree: WorktreeRef, path: String)
    /// Sends `fileChanged` for `path` on the connection's subscription while it
    /// follows the file (`host.worktrees.files.v1`).
    case followFile(worktree: WorktreeRef, path: String)
    case unfollowFile(worktree: WorktreeRef, path: String)
}

/// One git action on a worktree. Paths are relative to the worktree, as its
/// changes list them.
public enum HostWorktreeChange: Codable, Equatable, Sendable {
    case stage(paths: [String]), unstage(paths: [String]), discard(paths: [String])
    case commit(subject: String, body: String, amend: Bool)
    case push(forceWithLease: Bool), pull, fetch
    /// Stashes the worktree's changes (`host.worktrees.stash.v1`).
    case stash(message: String, includeUntracked: Bool)
    /// Act on a stash as listed (`host.worktrees.stash.v1`).
    case applyStash(HostStashRef), popStash(HostStashRef), dropStash(HostStashRef)
    /// Leave the in-progress operation of `kind`, the one the client saw
    /// (`host.worktrees.operations.v1`).
    case continueOperation(kind: HostOperationKind), skipOperation(kind: HostOperationKind), abortOperation(kind: HostOperationKind)
    /// Resolve a conflicted path, with or without an operation in progress
    /// (`host.worktrees.operations.v1`).
    case useOurs(path: String), useTheirs(path: String), keepDeleted(path: String), markResolved(path: String)
    /// Apply or undo one of the repository's commits, named by its SHA; a
    /// conflict leaves the operation in place (`host.worktrees.operations.v1`).
    case cherryPick(sha: String), revert(sha: String)
    /// Merge a listed branch into the worktree's, or rebase its branch onto
    /// one; a conflict leaves the operation in place (`host.worktrees.integrate.v1`).
    case merge(branch: String), rebase(onto: String)
    /// Edit a commit above the fold of `comparisonMode`, nil for the host's,
    /// replaying the commits above it, as its editor does
    /// (`host.worktrees.commitEdit.v1`).
    case editCommit(sha: String, edit: HostCommitEdit, comparisonMode: AppConfig.Changes.ChangesComparisonMode?)
    /// Take a manual checkpoint named `label`; answers `checkpointManifest`
    /// (`host.worktrees.checkpoints.v1`).
    case createCheckpoint(label: String)
    /// Delete a listed checkpoint (`host.worktrees.checkpoints.v1`).
    case deleteCheckpoint(id: CheckpointID)
    /// Restore the groups `groupIDs` of a listed checkpoint, as previewed at
    /// `fingerprint`, after a recovery checkpoint (`host.worktrees.checkpoints.v1`).
    case restoreCheckpoint(id: CheckpointID, groupIDs: Set<UUID>, fingerprint: String)
    /// Recover the worktree's interrupted checkpoint restores, back to the
    /// state each saved first; the one change a pending recovery lets through
    /// (`host.worktrees.checkpointRecovery.v1`).
    case recoverCheckpointRestore
    /// Stage, unstage or discard the `index`th hunk of `path`'s `stage` diff
    /// as the Mac was shown it, with `header` and `RemoteDiffHunk.linesHash`
    /// `linesHash` (`host.worktrees.hunks.v1`). Unstage takes the staged diff,
    /// stage and discard the unstaged one.
    case hunk(path: String, stage: ChangeStage, index: Int, header: String, linesHash: String, action: HostHunkAction)

    /// The capability beyond host.worktrees.git.v1 a change needs; nil for the original seven.
    public var capability: String? {
        switch self {
        case .stage, .unstage, .discard, .commit, .push, .pull, .fetch: nil
        case .stash, .applyStash, .popStash, .dropStash: HostProtocolCapability.worktreesStashV1
        case .continueOperation, .skipOperation, .abortOperation, .useOurs, .useTheirs, .keepDeleted, .markResolved, .cherryPick,
             .revert:
            HostProtocolCapability.worktreesOperationsV1
        case .editCommit: HostProtocolCapability.worktreesCommitEditV1
        case .merge, .rebase: HostProtocolCapability.worktreesIntegrateV1
        case .createCheckpoint, .deleteCheckpoint, .restoreCheckpoint: HostProtocolCapability.worktreesCheckpointsV1
        case .recoverCheckpointRestore: HostProtocolCapability.worktreesCheckpointRecoveryV1
        case .hunk: HostProtocolCapability.worktreesHunksV1
        }
    }

    /// The changes that leave or resolve an operation: the rebase gate lets only these through.
    public var leavesAnOperation: Bool {
        switch self {
        case .continueOperation, .skipOperation, .abortOperation, .useOurs, .useTheirs, .keepDeleted, .markResolved: true
        default: false
        }
    }
}

/// What `HostWorktreeChange.hunk` does with its hunk.
public enum HostHunkAction: String, Codable, Sendable {
    case stage, unstage, discard
}

/// One edit of a commit, as a paired Mac asks it.
public enum HostCommitEdit: Codable, Equatable, Sendable {
    case message(subject: String, body: String)
    case dropFile(path: String)
    /// The `index`th hunk of the commit's diff of `path`, which must have `header`.
    case dropHunk(path: String, index: Int, header: String)
}

/// The kind of a worktree's in-progress git operation, as a client names it.
public enum HostOperationKind: String, Codable, Sendable {
    case merge, rebase, cherryPick, revert

    public init(_ operation: MergeOperation) {
        switch operation {
        case .merge: self = .merge
        case .rebase: self = .rebase
        case .cherryPick: self = .cherryPick
        case .revert: self = .revert
        }
    }
}

/// One read of a worktree's code, as the Remote session requests of the same name.
public enum HostWorktreeRead: Codable, Equatable, Sendable {
    case changes(comparisonMode: AppConfig.Changes.ChangesComparisonMode?)
    case fileDiff(path: String, stage: String?, comparisonMode: AppConfig.Changes.ChangesComparisonMode?)
    case files(path: String?, comparisonMode: AppConfig.Changes.ChangesComparisonMode?)
    case commitFiles(sha: String)
    case commitDiff(sha: String, path: String)
    /// A range's files, answered as `.commitFiles` / `.commitFilesFailed`
    /// whose `sha` is `rangeSpec(base:head:threeDot:)`. Both ends are commit
    /// SHAs; `base` may also be `<sha>^`, a root commit's missing parent.
    case rangeFiles(base: String, head: String, threeDot: Bool)
    /// One file's diff across a range, answered as `.commitDiffResult` /
    /// `.commitDiffFailed` named by `rangeSpec(base:head:threeDot:)`.
    case rangeDiff(base: String, head: String, threeDot: Bool, path: String, originalPath: String?)
    case file(path: String)
    /// A file's raw bytes, for a preview: the working tree's when `revision`
    /// is nil. Answered as `.fileBytes` or `.fileUnavailable`.
    case fileBytes(path: String, revision: HostFileRevision?)
    /// The commits that touched a file, newest first and following renames,
    /// up to `RemoteWorktreeFileAccess.maxHistoryEntries`. Answered as
    /// `.fileHistory` or `.fileHistoryFailed`.
    case fileHistory(path: String)

    /// How a range's replies name it: `base..head`, or `base...head` for
    /// a branch comparison from their merge base.
    public static func rangeSpec(base: String, head: String, threeDot: Bool) -> String {
        "\(base)\(threeDot ? "..." : "..")\(head)"
    }
}

/// One commit of a file's history, with the file's path in it, which differs before a rename.
public struct HostFileHistoryEntry: Codable, Equatable, Sendable {
    public var commit: CommitInfo
    public var pathAtCommit: String

    public init(commit: CommitInfo, pathAtCommit: String) {
        self.commit = commit
        self.pathAtCommit = pathAtCommit
    }
}

/// A stored side of a file, in the forms the host's diff reads accept.
public enum HostFileRevision: Codable, Equatable, Sendable {
    case index
    /// HEAD, the old side of a staged change.
    case head
    /// The comparison ref the host's changes use, or HEAD without one.
    case base(comparisonMode: AppConfig.Changes.ChangesComparisonMode?)
    case commit(sha: String)
    /// The commit before `sha`: a root commit's has no file.
    case parent(sha: String)
    /// The commit a listed stash was made on, the old side of its diff.
    case stashBase(HostStashRef)
    /// A listed stash's file: from its saved tree, or with `untracked` from its untracked files.
    case stash(HostStashRef, untracked: Bool)
    /// The old side of a listed checkpoint's diff with the working tree.
    case checkpoint(id: CheckpointID)
    /// The old side of a range's diff, named as `HostWorktreeRead.rangeDiff` names the range.
    case rangeBase(base: String, head: String, threeDot: Bool)
    /// A side of pull or merge request review `sessionID`'s image diff: the
    /// commits its provider names to the host, never ones a Mac sends. The
    /// head with `after`, else what the provider diffs it from.
    case providerReview(sessionID: String, after: Bool)
}

/// A draft review as a worktree's Reviews list shows it.
public struct HostReviewSummary: Codable, Equatable, Sendable {
    /// Synthesized, never saved, for a local-changes review with no record.
    public var record: ReviewSessionRecord
    public var openCommentCount: Int
    public var sessionID: String { record.target.draftSessionID.rawValue }

    public init(record: ReviewSessionRecord, openCommentCount: Int) {
        self.record = record
        self.openCommentCount = openCommentCount
    }
}

/// A draft review with its comments, those on files that no longer differ included.
public struct HostReview: Codable, Equatable, Sendable {
    public var summary: HostReviewSummary
    public var comments: [ReviewDraftComment]

    public init(summary: HostReviewSummary, comments: [ReviewDraftComment]) {
        self.summary = summary
        self.comments = comments
    }

    /// Leaves out a comment a newer host sends in a shape this Mac can't read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(HostReviewSummary.self, forKey: .summary)
        comments = try container.decode([Lossy<ReviewDraftComment>].self, forKey: .comments).compactMap(\.value)
    }
}

/// One change to a review's comments, as a paired Mac files it.
public enum HostReviewMutation: Codable, Equatable, Sendable {
    case add(fileID: DiffReviewFileID, path: String, originalPath: String?, anchor: ReviewDraftCommentAnchor, body: String)
    case edit(commentID: String, body: String)
    case delete(commentID: String)
    case resolve(commentID: String)
    case dismiss(commentID: String)
}

/// What a Mac publishes of a pull or merge request review.
public struct HostReviewPublish: Codable, Equatable, Sendable {
    public var decision: ProviderReviewDecision
    public var body: String
    /// Only these drafts; nil for every publishable one.
    public var draftIDs: [String]?
    /// The head the Mac showed, so comments anchor where it saw them.
    public var headSHA: String?

    public init(decision: ProviderReviewDecision, body: String, draftIDs: [String]?, headSHA: String?) {
        self.decision = decision
        self.body = body
        self.draftIDs = draftIDs
        self.headSHA = headSHA
    }
}

/// A pull or merge request as its provider shows it to the host's user.
public struct HostProviderReview: Codable, Equatable, Sendable {
    public var remote: CodeHostRemote
    /// With its threads.
    public var request: ReviewRequest
    public var capabilities: CodeHostProviderCapabilities
    /// The host's login; nil when it can't tell.
    public var account: String?
    /// The provider's raw unified diff; nil unless asked.
    public var diff: String?
    public var diffTruncated: Bool

    /// `RemoteTranscriptSync.maxMessageBytes`; well under `WebSocketFrame.maxPayloadLength`.
    public static let maxDiffBytes = 4 * 1024 * 1024

    public init(
        remote: CodeHostRemote, request: ReviewRequest, capabilities: CodeHostProviderCapabilities,
        account: String?, diff: String?, diffTruncated: Bool
    ) {
        self.remote = remote
        self.request = request
        self.capabilities = capabilities
        self.account = account
        self.diff = diff
        self.diffTruncated = diffTruncated
    }

    /// Within `maxBytes`, or cut just before the last "diff --git " header that starts within it.
    public static func capped(_ diff: String, maxBytes: Int = maxDiffBytes) -> (diff: String, truncated: Bool) {
        let bytes = Array(diff.utf8)
        guard bytes.count > maxBytes else { return (diff, false) }
        let header = Array("diff --git ".utf8)
        let cut = stride(from: min(maxBytes, bytes.count - header.count + 1) - 1, through: 0, by: -1).first { start in
            (start == 0 || bytes[start - 1] == UInt8(ascii: "\n")) && bytes[start..<start + header.count].elementsEqual(header)
        } ?? 0
        return (String(decoding: bytes[..<cut], as: UTF8.self), true)
    }
}

/// A stash as a Mac saw it listed: the host acts on it only while `ref`
/// still names `sha`.
public struct HostStashRef: Codable, Hashable, Sendable {
    public var ref: String
    public var sha: String

    public init(ref: String, sha: String) {
        self.ref = ref
        self.sha = sha
    }

    public init(_ stash: GitStash) {
        self.init(ref: stash.ref, sha: stash.sha)
    }
}

/// One file's diff, as a commit's is sent.
public struct HostDiff: Codable, Equatable, Sendable {
    public var hunks: [RemoteDiffHunk]
    public var truncated: Bool
    /// A metadata summary, or why there are no hunks.
    public var note: String?

    public init(hunks: [RemoteDiffHunk], truncated: Bool, note: String?) {
        self.hunks = hunks
        self.truncated = truncated
        self.note = note
    }

    /// Capped as a commit diff is (`RemoteWorktreeFileAccess.truncateHunks`); a binary diff
    /// has no hunks and the note "Binary files cannot be shown."
    public init(_ diff: ParsedDiff) {
        guard !diff.isBinary else {
            self.init(hunks: [], truncated: false, note: "Binary files cannot be shown.")
            return
        }
        let capped = RemoteWorktreeFileAccess.truncateHunks(diff.hunks)
        self.init(hunks: capped.hunks.map(RemoteDiffHunk.init), truncated: capped.truncated, note: diff.metadataSummary)
    }
}

/// An element that decodes as nil when it is in a shape this side can't read.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Picked over the generic `decode` by `HostResponse.reviews`'s
    /// synthesized decoding: a review of a kind a newer host added is left
    /// out, not the whole list.
    fileprivate func decode(_ type: [HostReviewSummary].Type, forKey key: Key) throws -> [HostReviewSummary] {
        try decode([Lossy<HostReviewSummary>].self, forKey: key).compactMap(\.value)
    }
}

/// A run script as a worktree's Run tab lists it.
public struct HostRunScript: Codable, Equatable, Sendable {
    public var scope: RunScriptScope
    public var fileName: String
    public var name: String
    /// Working directory relative to the worktree root. Nil = worktree root.
    public var cwd: String?
    /// Where a run executes: the host and working directory.
    public var target: RunExecutionTarget

    public var key: String { "\(scope.rawValue):\(fileName)" }

    public init(scope: RunScriptScope, fileName: String, name: String, cwd: String?, target: RunExecutionTarget) {
        self.scope = scope
        self.fileName = fileName
        self.name = name
        self.cwd = cwd
        self.target = target
    }

    public init(_ script: RunScript, target: RunExecutionTarget) {
        self.init(scope: script.scope, fileName: script.fileName, name: script.displayName, cwd: script.cwd, target: target)
    }
}

/// A paired Mac as `alas-host peers list` shows it; never its token.
public struct HostPeerSummary: Codable, Equatable, Sendable {
    public var id: String
    public var serverId: String
    public var name: String
    public var origins: [String]

    public init(id: String, serverId: String, name: String, origins: [String]) {
        self.id = id
        self.serverId = serverId
        self.name = name
        self.origins = origins
    }

    /// The peer `query` names: its id or server id, else a name only one peer has.
    public static func resolve(_ query: String, in peers: [HostPeerSummary]) throws -> HostPeerSummary {
        if let peer = peers.first(where: { $0.id == query || $0.serverId == query }) { return peer }
        let named = peers.filter { $0.name == query }
        if named.count == 1 { return named[0] }
        if named.isEmpty { throw HostError.failed(message: "No paired Mac has the id, name or server id \(query).") }
        let candidates = named.map { "  \($0.id)  \($0.name)" }.joined(separator: "\n")
        throw HostError.failed(message: "More than one paired Mac is named \(query); remove one by id:\n\(candidates)")
    }
}

public enum HostServerMessage: Codable, Equatable, Sendable {
    case response(id: Int, result: HostResponse)
    /// The subscription's next events, coalesced per key, and the cursor
    /// they reach: a client that reconnects subscribes after it.
    case events(events: [HostEvent], cursor: HostCursor)
}

public enum HostResponse: Codable, Equatable, Sendable {
    case snapshot(snapshot: HostSnapshot)
    case subscribed
    case unsubscribed
    case sessions(sessions: [HostSessionSummary])
    case project(project: ProjectSnapshot)
    case worktree(worktree: Worktree)
    /// The verb finished and has nothing to return.
    case done
    case workspaceCheckouts(checkouts: [WorkspaceCheckoutSnapshot])
    case workspaceCheckout(checkout: WorkspaceCheckoutSnapshot)
    case runStart(start: RunStart)
    case session(session: HostSessionSummary)
    case capabilities(capabilities: [String])
    case runOutput(output: HostRunOutput)
    /// `link` is absent from an older host, and where the host has no address for one.
    case remotePairingCode(code: String, expiresAt: Date, link: String?)
    case peers(peers: [HostPeerSummary])
    /// The message a session in the worktree gets for the same read, with
    /// the worktree's id as its `sessionId`. Indirect: a Remote message
    /// carries host messages.
    indirect case worktreeRead(reply: RemoteServerMessage)
    /// The answer to `listRunScripts`.
    case runScripts(scripts: [HostRunScript])
    /// The answer to `commitMessageInput`.
    case commitMessageInput(input: CommitMessageSuggestionInput)
    /// The answer to `reviewStatus`; nil when the host could not read it.
    case reviewStatus(snapshot: ReviewLoopSnapshot?)
    /// The answer to `listReviews`.
    case reviews(reviews: [HostReviewSummary])
    /// The answer to `readReview`.
    case review(review: HostReview)
    /// The answer to `readProviderReview`.
    case providerReview(review: HostProviderReview)
    /// The answer to `mutateReviewThread`.
    case reviewThreadMutated(result: ProviderThreadMutationResult)
    /// The answer to `publishReview`, warnings included.
    case reviewPublished(result: ProviderReviewPublishResult)
    /// The answer to `listStashes`.
    case stashes(stashes: [GitStash])
    /// The answer to `stashFiles`.
    case stashFiles(files: [GitStashFile])
    /// The answer to `stashDiff`.
    case diff(diff: HostDiff)
    /// The answer to `commitDetails`, its files capped as a commit's files read is.
    case commitDetails(details: CommitDetails)
    /// The answer to an `editCommit` change.
    case commitEdited(result: CommitEditResult)
    /// The answer to `listCheckpoints`. `interruptedRestore` is nil from a
    /// host older than `host.worktrees.checkpointRecovery.v1`.
    case checkpoints(catalog: CheckpointCatalogSnapshot, interruptedRestore: Bool? = nil)
    /// The answer to `checkpointManifest` and a `createCheckpoint` change.
    case checkpointManifest(manifest: WorktreeCheckpointManifest)
    /// The answer to `checkpointRestorePreview`.
    case checkpointRestorePreview(preview: CheckpointRestorePreview)
    /// The answer to `writeFile`: the version now on disk.
    case fileWritten(version: WorktreeFileVersion)
    case failure(error: HostError)
}

/// Why the host did not do what a request asked: the domain's own typed
/// refusal where there is one.
public enum HostError: Error, Codable, Equatable, Sendable {
    /// The host speaks `supported` and not the message's version.
    case unsupportedVersion(supported: Int)
    case invalidRequest(reason: String)
    /// A project, worktree or script the request names does not exist.
    case notFound(what: String)
    /// Another operation holds the worktree.
    case operationInProgress
    /// A session, run or terminal is live in one of the project's worktrees.
    case projectBusy
    case project(error: ProjectCreationError)
    case worktreeCreation(refusal: WorktreeCreationRefusal)
    case worktreeCreationFailed(message: String)
    case worktreeDeletion(refusal: WorktreeDeletionRefusal)
    case worktreeArchive(refusal: WorktreeArchiveRefusal)
    case workspace(error: WorkspaceAutomationError)
    case session(refusal: SessionRefusal)
    case failed(message: String)
    /// The file is no longer at the version the client named: `current`, or nil when it is gone.
    case fileChanged(current: WorktreeFileVersion?)
}
