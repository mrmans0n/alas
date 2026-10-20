import CryptoKit
import Foundation

public struct ReviewSessionID: Codable, Equatable, Hashable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ReviewSessionTargetKind: String, Codable, Equatable, Hashable, Sendable {
    case localChanges = "local-changes"
    case draftCommit = "draft-commit"
    case commit
    case trackedCommit = "tracked-commit"
    case commitRange = "commit-range"
    case branch
    case branchWithLocalChanges = "branch-with-local-changes"
    case sinceSnapshot = "since-snapshot"
    case reviewRequest = "review-request"
    case draftReviewRequest = "draft-review-request"
}

public struct ReviewSessionTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: ReviewSessionID
    public let kind: ReviewSessionTargetKind
    public let worktreeID: String
    public let repositoryPath: URL
    public let title: String
    public let sourceDescription: String
    public let providerDescription: String?
    public let providerURL: URL?
    public let revisionDescription: String?
    public let draftSessionID: ReviewDraftSessionID
    public let payload: Payload

    public static func localChanges(
        worktreeID: String,
        repositoryPath: URL,
        scope: ReviewDraftLocalChangesScope
    ) -> Self {
        let path = standardizedPath(repositoryPath)
        return ReviewSessionTarget(
            id: makeID(.localChanges, [worktreeID, path, scope.rawValue]),
            kind: .localChanges,
            worktreeID: worktreeID,
            repositoryPath: standardizedURL(repositoryPath),
            title: "Review \(scope.rawValue) changes",
            sourceDescription: "Local changes: \(scope.rawValue)",
            providerDescription: nil,
            providerURL: nil,
            revisionDescription: nil,
            draftSessionID: .localChanges(worktreeID: worktreeID, worktreePath: repositoryPath, scope: scope),
            payload: .localChanges(scope: scope)
        )
    }

    public static func draftCommit(worktreeID: String, repositoryPath: URL) -> Self {
        let path = standardizedPath(repositoryPath)
        return ReviewSessionTarget(
            id: makeID(.draftCommit, [worktreeID, path]),
            kind: .draftCommit,
            worktreeID: worktreeID,
            repositoryPath: standardizedURL(repositoryPath),
            title: "Review draft commit",
            sourceDescription: "Draft commit",
            providerDescription: nil,
            providerURL: nil,
            revisionDescription: nil,
            draftSessionID: .draftCommit(worktreeID: worktreeID, repositoryPath: repositoryPath),
            payload: .draftCommit
        )
    }

    public static func commit(
        worktreeID: String,
        repositoryPath: URL,
        sha: String,
        title: String
    ) -> Self {
        let path = standardizedPath(repositoryPath)
        return ReviewSessionTarget(
            id: makeID(.commit, [worktreeID, path, sha]),
            kind: .commit,
            worktreeID: worktreeID,
            repositoryPath: standardizedURL(repositoryPath),
            title: title,
            sourceDescription: "Commit \(sha)",
            providerDescription: nil,
            providerURL: nil,
            revisionDescription: sha,
            draftSessionID: .commit(worktreeID: worktreeID, repositoryPath: repositoryPath, sha: sha),
            payload: .commit(sha: sha)
        )
    }

    public static func trackedCommit(
        worktreeID: String,
        repositoryPath: URL,
        revision: TrackedRevision,
        title: String
    ) -> Self {
        let path = standardizedPath(repositoryPath)
        let revisionDescription = "\(revision.target.displayLabel) -> \(revision.resolvedSHA)"
        return ReviewSessionTarget(
            id: makeID(.trackedCommit, [worktreeID, path, revision.target.identityKey]),
            kind: .trackedCommit,
            worktreeID: worktreeID,
            repositoryPath: standardizedURL(repositoryPath),
            title: title,
            sourceDescription: "Commit \(revisionDescription)",
            providerDescription: nil,
            providerURL: nil,
            revisionDescription: revisionDescription,
            draftSessionID: .trackedCommit(
                worktreeID: worktreeID,
                repositoryPath: repositoryPath,
                targetKey: revision.target.identityKey
            ),
            payload: .trackedCommit(revision)
        )
    }

    public func updatingTrackedRevision(
        _ revision: TrackedRevision,
        title: String
    ) -> ReviewSessionTarget {
        guard case .trackedCommit = payload else { return self }
        return .trackedCommit(
            worktreeID: worktreeID,
            repositoryPath: repositoryPath,
            revision: revision,
            title: title
        )
    }

    public func freezingTrackedRevision(title: String) -> ReviewSessionTarget? {
        guard case .trackedCommit(let revision) = payload else { return nil }
        return .commit(
            worktreeID: worktreeID,
            repositoryPath: repositoryPath,
            sha: revision.resolvedSHA,
            title: title
        )
    }

    public static func commitRange(
        worktreeID: String,
        repositoryPath: URL,
        base: String,
        head: String,
        title: String? = nil
    ) -> Self {
        let path = standardizedPath(repositoryPath)
        return ReviewSessionTarget(
            id: makeID(.commitRange, [worktreeID, path, base, head]),
            kind: .commitRange,
            worktreeID: worktreeID,
            repositoryPath: standardizedURL(repositoryPath),
            title: title ?? "Review \(base)..\(head)",
            sourceDescription: "Commit range \(base)..\(head)",
            providerDescription: nil,
            providerURL: nil,
            revisionDescription: "\(base)..\(head)",
            draftSessionID: .commitRange(worktreeID: worktreeID, repositoryPath: repositoryPath, base: base, head: head),
            payload: .commitRange(base: base, head: head)
        )
    }

    public static func branch(
        worktreeID: String,
        repositoryPath: URL,
        base: String,
        head: String,
        title: String? = nil
    ) -> Self {
        let path = standardizedPath(repositoryPath)
        return ReviewSessionTarget(
            id: makeID(.branch, [worktreeID, path, base, head]),
            kind: .branch,
            worktreeID: worktreeID,
            repositoryPath: standardizedURL(repositoryPath),
            title: title ?? "Review \(head) against \(base)",
            sourceDescription: "Branch \(head) against \(base)",
            providerDescription: nil,
            providerURL: nil,
            revisionDescription: "\(base)..\(head)",
            draftSessionID: .branch(worktreeID: worktreeID, repositoryPath: repositoryPath, base: base, head: head),
            payload: .branch(base: base, head: head)
        )
    }

    /// The branch's commits since it forked from `base` plus every
    /// uncommitted change (staged, unstaged, and untracked), as one diff from
    /// the merge base to the working tree.
    public static func branchWithLocalChanges(
        worktreeID: String,
        repositoryPath: URL,
        base: String,
        title: String? = nil
    ) -> Self {
        let path = standardizedPath(repositoryPath)
        return ReviewSessionTarget(
            id: makeID(.branchWithLocalChanges, [worktreeID, path, base]),
            kind: .branchWithLocalChanges,
            worktreeID: worktreeID,
            repositoryPath: standardizedURL(repositoryPath),
            title: title ?? "Review working tree against \(base)",
            sourceDescription: "Branch and uncommitted changes against \(base)",
            providerDescription: nil,
            providerURL: nil,
            revisionDescription: "\(base)...working tree",
            draftSessionID: .branchWithLocalChanges(worktreeID: worktreeID, repositoryPath: repositoryPath, base: base),
            payload: .branchWithLocalChanges(base: base)
        )
    }

    /// Everything that changed in the working tree since `tree`, a snapshot
    /// taken when review feedback last went to an agent.
    public static func sinceSnapshot(
        worktreeID: String,
        repositoryPath: URL,
        tree: String,
        title: String = "Review changes since last review"
    ) -> Self {
        let path = standardizedPath(repositoryPath)
        return ReviewSessionTarget(
            id: makeID(.sinceSnapshot, [worktreeID, path, tree]),
            kind: .sinceSnapshot,
            worktreeID: worktreeID,
            repositoryPath: standardizedURL(repositoryPath),
            title: title,
            sourceDescription: "Working tree changes since the last review",
            providerDescription: nil,
            providerURL: nil,
            revisionDescription: "\(tree)...working tree",
            draftSessionID: .sinceSnapshot(worktreeID: worktreeID, repositoryPath: repositoryPath, tree: tree),
            payload: .sinceSnapshot(tree: tree)
        )
    }

    public static func reviewRequest(
        worktreeID: String,
        repositoryPath: URL,
        provider: CodeHostKind,
        host: String,
        repositorySlug: String,
        number: Int,
        url: URL,
        title: String,
        headSHA: String?
    ) -> Self {
        let path = standardizedPath(repositoryPath)
        let normalizedHost = host.lowercased()
        let normalizedSlug = standardizedRepositorySlug(repositorySlug)
        return ReviewSessionTarget(
            id: makeID(.reviewRequest, [worktreeID, path, provider.rawValue, normalizedHost, normalizedSlug, "\(number)"]),
            kind: .reviewRequest,
            worktreeID: worktreeID,
            repositoryPath: standardizedURL(repositoryPath),
            title: title,
            sourceDescription: "\(provider.reviewRequestLabel) \(provider.reviewRequestNumberPrefix)\(number)",
            providerDescription: "\(provider.displayName) \(normalizedSlug) \(provider.reviewRequestNumberPrefix)\(number)",
            providerURL: url,
            revisionDescription: headSHA,
            draftSessionID: .reviewRequest(
                worktreeID: worktreeID,
                provider: provider,
                host: normalizedHost,
                repositorySlug: normalizedSlug,
                number: number
            ),
            payload: .reviewRequest(
                provider: provider,
                host: normalizedHost,
                repositorySlug: normalizedSlug,
                number: number,
                headSHA: headSHA
            )
        )
    }

    public static func draftReviewRequest(
        worktreeID: String,
        repositoryPath: URL,
        provider: CodeHostKind,
        repositorySlug: String,
        base: String,
        head: String,
        headSHA: String?,
        draftSessionHead: String? = nil
    ) -> Self {
        let path = standardizedPath(repositoryPath)
        let normalizedSlug = standardizedRepositorySlug(repositorySlug)
        return ReviewSessionTarget(
            id: makeID(.draftReviewRequest, [
                worktreeID, path, provider.rawValue, normalizedSlug, base, draftSessionHead ?? head, headSHA ?? ""
            ]),
            kind: .draftReviewRequest,
            worktreeID: worktreeID,
            repositoryPath: standardizedURL(repositoryPath),
            title: "Review draft \(provider.reviewRequestLabel)",
            sourceDescription: "Draft \(provider.reviewRequestLabel) \(head) against \(base)",
            providerDescription: "\(provider.displayName) \(normalizedSlug)",
            providerURL: nil,
            revisionDescription: headSHA,
            draftSessionID: .draftReviewRequest(
                worktreeID: worktreeID, repositoryPath: repositoryPath,
                base: base, head: draftSessionHead ?? head
            ),
            payload: .draftReviewRequest(
                provider: provider,
                repositorySlug: normalizedSlug,
                base: base,
                head: head,
                headSHA: headSHA
            )
        )
    }

    private static let separator: Character = "\u{1f}"

    private static func makeID(_ kind: ReviewSessionTargetKind, _ fields: [String]) -> ReviewSessionID {
        let values = ([kind.rawValue] + fields).map(escape)
        return ReviewSessionID(rawValue: values.joined(separator: String(separator)))
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: String(separator), with: "\\u001f")
    }

    private static func standardizedURL(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    private static func standardizedPath(_ url: URL) -> String {
        standardizedURL(url).path
    }

    private static func standardizedRepositorySlug(_ slug: String) -> String {
        slug
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .joined(separator: "/")
    }

    public enum Payload: Codable, Equatable, Hashable, Sendable {
        case localChanges(scope: ReviewDraftLocalChangesScope)
        case draftCommit
        case commit(sha: String)
        case trackedCommit(TrackedRevision)
        case commitRange(base: String, head: String)
        case branch(base: String, head: String)
        case branchWithLocalChanges(base: String)
        case sinceSnapshot(tree: String)
        case reviewRequest(provider: CodeHostKind, host: String, repositorySlug: String, number: Int, headSHA: String?)
        case draftReviewRequest(provider: CodeHostKind, repositorySlug: String, base: String, head: String, headSHA: String?)

        public func hash(into hasher: inout Hasher) {
            switch self {
            case .localChanges(let scope):
                hasher.combine(0)
                hasher.combine(scope)
            case .draftCommit:
                hasher.combine(1)
            case .commit(let sha):
                hasher.combine(2)
                hasher.combine(sha)
            case .trackedCommit(let revision):
                hasher.combine(7)
                hasher.combine(revision)
            case .commitRange(let base, let head):
                hasher.combine(3)
                hasher.combine(base)
                hasher.combine(head)
            case .branch(let base, let head):
                hasher.combine(4)
                hasher.combine(base)
                hasher.combine(head)
            case .branchWithLocalChanges(let base):
                hasher.combine(8)
                hasher.combine(base)
            case .sinceSnapshot(let tree):
                hasher.combine(9)
                hasher.combine(tree)
            case .reviewRequest(let provider, let host, let repositorySlug, let number, let headSHA):
                hasher.combine(5)
                hasher.combine(provider.rawValue)
                hasher.combine(host)
                hasher.combine(repositorySlug)
                hasher.combine(number)
                hasher.combine(headSHA)
            case .draftReviewRequest(let provider, let repositorySlug, let base, let head, let headSHA):
                hasher.combine(6)
                hasher.combine(provider.rawValue)
                hasher.combine(repositorySlug)
                hasher.combine(base)
                hasher.combine(head)
                hasher.combine(headSHA)
            }
        }
    }

    public init(id: ReviewSessionID, kind: ReviewSessionTargetKind, worktreeID: String, repositoryPath: URL, title: String, sourceDescription: String, providerDescription: String?, providerURL: URL?, revisionDescription: String?, draftSessionID: ReviewDraftSessionID, payload: Payload) {
        self.id = id
        self.kind = kind
        self.worktreeID = worktreeID
        self.repositoryPath = repositoryPath
        self.title = title
        self.sourceDescription = sourceDescription
        self.providerDescription = providerDescription
        self.providerURL = providerURL
        self.revisionDescription = revisionDescription
        self.draftSessionID = draftSessionID
        self.payload = payload
    }
}

public enum ReviewSessionStatus: String, Codable, Equatable, Hashable, Sendable {
    case active
    case sent
    case addressing
    case addressed
    case reviewed
    case archived
}

public struct ReviewSessionVerdict: Codable, Equatable, Sendable {
    public let verdict: ReviewVerdict
    public let summary: String
    public let reviewedAt: Date

    public init(verdict: ReviewVerdict, summary: String, reviewedAt: Date) {
        self.verdict = verdict
        self.summary = summary
        self.reviewedAt = reviewedAt
    }
}

public enum ReviewFeedbackHandoffStatus: String, Codable, Equatable, Hashable, Sendable {
    case sent
    case failed
    case addressed
}

public struct ReviewFeedbackHandoff: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: ReviewSessionID
    public let commentIDs: [String]
    public let target: ReviewFeedbackAgentTarget
    public let createdAt: Date
    public let promptRevision: String
    public var status: ReviewFeedbackHandoffStatus

    public static func revisionKey(commentIDs: [String], prompt: String) -> String {
        var data = Data()
        for commentID in commentIDs.sorted() {
            append(commentID, to: &data)
        }
        append(prompt, to: &data)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Array(value.utf8)
        data.append(contentsOf: "\(bytes.count):".utf8)
        data.append(contentsOf: bytes)
        data.append(0)
    }

    public init(id: String, sessionID: ReviewSessionID, commentIDs: [String], target: ReviewFeedbackAgentTarget, createdAt: Date, promptRevision: String, status: ReviewFeedbackHandoffStatus) {
        self.id = id
        self.sessionID = sessionID
        self.commentIDs = commentIDs
        self.target = target
        self.createdAt = createdAt
        self.promptRevision = promptRevision
        self.status = status
    }
}

public struct ReviewSessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: ReviewSessionID
    public var target: ReviewSessionTarget
    public var selectedFileID: DiffReviewFileID?
    public var focusedCommentID: String?
    public var status: ReviewSessionStatus
    public var verdict: ReviewSessionVerdict?
    public var handoffs: [ReviewFeedbackHandoff]
    public var lastSendError: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ReviewSessionID,
        target: ReviewSessionTarget,
        selectedFileID: DiffReviewFileID? = nil,
        focusedCommentID: String? = nil,
        status: ReviewSessionStatus = .active,
        verdict: ReviewSessionVerdict? = nil,
        handoffs: [ReviewFeedbackHandoff] = [],
        lastSendError: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.target = target
        self.selectedFileID = selectedFileID
        self.focusedCommentID = focusedCommentID
        self.status = status
        self.verdict = verdict
        self.handoffs = handoffs
        self.lastSendError = lastSendError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func recording(handoff: ReviewFeedbackHandoff) -> ReviewSessionRecord {
        var record = self
        record.handoffs.append(handoff)
        if record.status != .reviewed {
            record.status = handoff.status == .failed ? .active : .sent
        }
        record.lastSendError = nil
        record.updatedAt = handoff.createdAt
        return record
    }

    public func markedAddressed(now: Date) -> ReviewSessionRecord {
        var record = self
        if record.status != .reviewed {
            record.status = .addressed
        }
        record.handoffs = record.handoffs.map { handoff in
            var updated = handoff
            updated.status = .addressed
            return updated
        }
        record.updatedAt = now
        return record
    }

    public func markedReviewed(verdict: ReviewVerdict, summary: String, now: Date) -> ReviewSessionRecord {
        var record = self
        record.status = .reviewed
        record.verdict = ReviewSessionVerdict(verdict: verdict, summary: summary, reviewedAt: now)
        record.updatedAt = now
        return record
    }

    public func selectingFile(_ fileID: DiffReviewFileID?, now: Date) -> ReviewSessionRecord {
        var record = self
        record.selectedFileID = fileID
        record.updatedAt = now
        return record
    }

    public func focusingComment(_ commentID: String?, now: Date) -> ReviewSessionRecord {
        var record = self
        record.focusedCommentID = commentID
        record.updatedAt = now
        return record
    }

    public func retargetingCommit(
        to target: ReviewSessionTarget,
        resolvedSHAChanged: Bool,
        now: Date
    ) -> ReviewSessionRecord {
        var record = self
        if target.id != self.target.id {
            record.id = Self.retargetedID(sourceID: id, targetID: target.id)
        }
        record.target = target
        if resolvedSHAChanged {
            record.status = .active
            record.verdict = nil
        }
        record.updatedAt = now
        return record
    }

    private static func retargetedID(sourceID: ReviewSessionID, targetID: ReviewSessionID) -> ReviewSessionID {
        ReviewSessionID(rawValue: "\(targetID.rawValue)\u{1f}retargeted\u{1f}\(sourceID.rawValue)")
    }
}
