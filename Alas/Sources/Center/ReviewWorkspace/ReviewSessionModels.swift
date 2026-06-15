import CryptoKit
import Foundation

struct ReviewSessionID: Codable, Equatable, Hashable, RawRepresentable, Sendable {
    let rawValue: String
}

enum ReviewSessionTargetKind: String, Codable, Equatable, Hashable, Sendable {
    case localChanges = "local-changes"
    case draftCommit = "draft-commit"
    case commit
    case commitRange = "commit-range"
    case branch
    case reviewRequest = "review-request"
    case draftReviewRequest = "draft-review-request"
}

struct ReviewSessionTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: ReviewSessionID
    let kind: ReviewSessionTargetKind
    let worktreeID: String
    let repositoryPath: URL
    let title: String
    let sourceDescription: String
    let providerDescription: String?
    let providerURL: URL?
    let revisionDescription: String?
    let draftSessionID: ReviewDraftSessionID
    let payload: Payload

    static func localChanges(
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

    static func draftCommit(worktreeID: String, repositoryPath: URL) -> Self {
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

    static func commit(
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

    static func commitRange(
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
            draftSessionID: .branch(worktreeID: worktreeID, repositoryPath: repositoryPath, base: base, head: head),
            payload: .commitRange(base: base, head: head)
        )
    }

    static func branch(
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

    static func reviewRequest(
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

    static func draftReviewRequest(
        worktreeID: String,
        repositoryPath: URL,
        provider: CodeHostKind,
        repositorySlug: String,
        base: String,
        head: String,
        headSHA: String?
    ) -> Self {
        let path = standardizedPath(repositoryPath)
        let normalizedSlug = standardizedRepositorySlug(repositorySlug)
        return ReviewSessionTarget(
            id: makeID(.draftReviewRequest, [worktreeID, path, provider.rawValue, normalizedSlug, base, head]),
            kind: .draftReviewRequest,
            worktreeID: worktreeID,
            repositoryPath: standardizedURL(repositoryPath),
            title: "Review draft \(provider.reviewRequestLabel)",
            sourceDescription: "Draft \(provider.reviewRequestLabel) \(head) against \(base)",
            providerDescription: "\(provider.displayName) \(normalizedSlug)",
            providerURL: nil,
            revisionDescription: headSHA,
            draftSessionID: .draftReviewRequest(worktreeID: worktreeID, repositoryPath: repositoryPath, base: base, head: head),
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

    enum Payload: Codable, Equatable, Hashable, Sendable {
        case localChanges(scope: ReviewDraftLocalChangesScope)
        case draftCommit
        case commit(sha: String)
        case commitRange(base: String, head: String)
        case branch(base: String, head: String)
        case reviewRequest(provider: CodeHostKind, host: String, repositorySlug: String, number: Int, headSHA: String?)
        case draftReviewRequest(provider: CodeHostKind, repositorySlug: String, base: String, head: String, headSHA: String?)

        func hash(into hasher: inout Hasher) {
            switch self {
            case .localChanges(let scope):
                hasher.combine(0)
                hasher.combine(scope)
            case .draftCommit:
                hasher.combine(1)
            case .commit(let sha):
                hasher.combine(2)
                hasher.combine(sha)
            case .commitRange(let base, let head):
                hasher.combine(3)
                hasher.combine(base)
                hasher.combine(head)
            case .branch(let base, let head):
                hasher.combine(4)
                hasher.combine(base)
                hasher.combine(head)
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
}

enum ReviewSessionStatus: String, Codable, Equatable, Hashable, Sendable {
    case active
    case sent
    case addressing
    case addressed
    case archived
}

enum ReviewFeedbackHandoffStatus: String, Codable, Equatable, Hashable, Sendable {
    case sent
    case failed
    case addressed
}

struct ReviewFeedbackHandoff: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sessionID: ReviewSessionID
    let commentIDs: [String]
    let target: ReviewFeedbackAgentTarget
    let createdAt: Date
    let promptRevision: String
    var status: ReviewFeedbackHandoffStatus

    static func revisionKey(commentIDs: [String], prompt: String) -> String {
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
}

struct ReviewSessionRecord: Codable, Equatable, Identifiable, Sendable {
    let id: ReviewSessionID
    var target: ReviewSessionTarget
    var selectedFileID: DiffReviewFileID?
    var focusedCommentID: String?
    var status: ReviewSessionStatus
    var handoffs: [ReviewFeedbackHandoff]
    var lastSendError: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: ReviewSessionID,
        target: ReviewSessionTarget,
        selectedFileID: DiffReviewFileID? = nil,
        focusedCommentID: String? = nil,
        status: ReviewSessionStatus = .active,
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
        self.handoffs = handoffs
        self.lastSendError = lastSendError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func recording(handoff: ReviewFeedbackHandoff) -> ReviewSessionRecord {
        var record = self
        record.handoffs.append(handoff)
        record.status = handoff.status == .failed ? .active : .sent
        record.lastSendError = nil
        record.updatedAt = handoff.createdAt
        return record
    }

    func markedAddressed(now: Date) -> ReviewSessionRecord {
        var record = self
        record.status = .addressed
        record.handoffs = record.handoffs.map { handoff in
            var updated = handoff
            updated.status = .addressed
            return updated
        }
        record.updatedAt = now
        return record
    }

    func selectingFile(_ fileID: DiffReviewFileID?, now: Date) -> ReviewSessionRecord {
        var record = self
        record.selectedFileID = fileID
        record.updatedAt = now
        return record
    }

    func focusingComment(_ commentID: String?, now: Date) -> ReviewSessionRecord {
        var record = self
        record.focusedCommentID = commentID
        record.updatedAt = now
        return record
    }
}
