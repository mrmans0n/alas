import Foundation

typealias TabID = String

enum Tab: Codable, Equatable, Identifiable {
    case terminal(TerminalTabState)
    case editor(EditorTabState)
    case diff(DiffTabState)
    case commit(CommitTabState)
    case commitEditor(CommitEditorTabState)
    case draftCommit(DraftCommitTabState)
    case draftReviewRequest(DraftReviewRequestTabState)
    case reviewEvidence(ReviewEvidenceTabState)
    case reviewChanges(ReviewChangesTabState)
    case reviewSession(ReviewSessionTabState)
    case imagePreview(ImagePreviewTabState)
    case mergeConflict(MergeConflictTabState)
    case acpSession(ACPSessionTabState)
    case reviewPR(ReviewPRTabState)

    var id: TabID {
        switch self {
        case .terminal(let s):     return s.id
        case .editor(let s):       return s.id
        case .diff(let s):         return s.id
        case .commit(let s):       return s.id
        case .commitEditor(let s): return s.id
        case .draftCommit(let s):  return s.id
        case .draftReviewRequest(let s): return s.id
        case .reviewEvidence(let s): return s.id
        case .reviewChanges(let s): return s.id
        case .reviewSession(let s): return s.id
        case .imagePreview(let s): return s.id
        case .mergeConflict(let s): return s.id
        case .acpSession(let s):   return s.id
        case .reviewPR(let s):     return s.id
        }
    }

    var title: String {
        switch self {
        case .terminal(let s):     return s.title
        case .editor(let s):       return s.title
        case .diff(let s):         return s.title
        case .commit(let s):       return s.title
        case .commitEditor(let s): return s.title
        case .draftCommit:         return "Draft commit"
        case .draftReviewRequest(let s): return s.displayTitle
        case .reviewEvidence(let s): return s.displayTitle
        case .reviewChanges:       return "Review Changes"
        case .reviewSession(let s): return s.title
        case .imagePreview(let s): return s.title
        case .mergeConflict(let s): return s.title
        case .acpSession(let s):   return s.title
        case .reviewPR(let s):     return s.displayTitle
        }
    }

    var iconName: String {
        switch self {
        case .terminal:     return "terminal"
        case .editor:       return "code"
        case .diff:         return "diff"
        case .commit:       return "commit"
        case .commitEditor: return "commit"
        case .draftCommit:  return "commit"
        case .draftReviewRequest: return "pull-request"
        case .reviewEvidence: return "doc.text.magnifyingglass"
        case .reviewChanges: return "diff"
        case .reviewSession: return "text.badge.checkmark"
        case .imagePreview: return "image"
        case .mergeConflict: return "diff"
        case .acpSession:   return "sparkle"
        case .reviewPR:     return "list.bullet.rectangle.portrait.fill"
        }
    }

    var relativeFilePath: String? {
        switch self {
        case .editor(let s):       return s.isExternal ? nil : s.relativePath
        case .imagePreview(let s): return s.relativePath
        case .mergeConflict(let s): return s.relativePath
        default:                   return nil
        }
    }
}

struct ReviewChangesTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String

    init(worktreeId: String) {
        self.id = "review-changes:\(worktreeId)"
        self.worktreeId = worktreeId
    }
}

struct ReviewSessionTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let sessionID: ReviewSessionID
    var title: String
    var selectedFileID: DiffReviewFileID?
    var focusedCommentID: String?

    init(worktreeId: String, record: ReviewSessionRecord) {
        self.id = "review-session:\(record.id.rawValue)"
        self.worktreeId = worktreeId
        self.sessionID = record.id
        self.title = record.target.title
        self.selectedFileID = record.selectedFileID
        self.focusedCommentID = record.focusedCommentID
    }
}

struct ReviewEvidenceTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let provider: CodeHostKind
    let repositorySlug: String
    let number: Int
    var url: URL
    var title: String
    var selectedSection: ReviewEvidenceSection
    var selectedItemID: String?

    var displayTitle: String {
        "\(provider.reviewRequestLabel) evidence"
    }

    init(
        worktreeId: String,
        snapshot: ReviewLoopSnapshot,
        initialSection: ReviewEvidenceSection?
    ) {
        let request = snapshot.reviewRequest
        let remote = request?.remote ?? snapshot.remote
        self.worktreeId = worktreeId
        self.provider = request?.provider ?? remote?.kind ?? .github
        self.repositorySlug = remote?.repositorySlug ?? ""
        self.number = request?.number ?? 0
        self.url = request?.url ?? remote?.webURL ?? URL(fileURLWithPath: "/")
        self.title = request?.title ?? ""
        self.selectedSection = initialSection ?? .files
        self.selectedItemID = nil
        let host = remote?.host ?? self.url.host ?? ""
        self.id = [
            "review-evidence",
            worktreeId,
            provider.rawValue,
            host,
            repositorySlug,
            "\(number)",
        ].joined(separator: ":")
    }

    mutating func refreshSnapshotMetadata(from snapshot: ReviewLoopSnapshot) {
        guard let request = snapshot.reviewRequest else { return }
        url = request.url
        title = request.title
    }

    func matches(_ snapshot: ReviewLoopSnapshot) -> Bool {
        guard let request = snapshot.reviewRequest else { return false }
        return request.provider == provider
            && request.remote.host.lowercased() == (url.host ?? "").lowercased()
            && request.remote.repositorySlug == repositorySlug
            && request.number == number
    }
}

struct ReviewPRTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let provider: CodeHostKind
    let repositorySlug: String
    let number: Int
    var url: URL
    var title: String

    var displayTitle: String {
        "\(provider.reviewRequestLabel) Review"
    }

    init(worktreeId: String, snapshot: ReviewLoopSnapshot) {
        let request = snapshot.reviewRequest
        let remote = request?.remote ?? snapshot.remote
        self.worktreeId = worktreeId
        self.provider = request?.provider ?? remote?.kind ?? .github
        self.repositorySlug = remote?.repositorySlug ?? ""
        self.number = request?.number ?? 0
        self.url = request?.url ?? remote?.webURL ?? URL(fileURLWithPath: "/")
        self.title = request?.title ?? ""
        let host = remote?.host ?? self.url.host ?? ""
        self.id = [
            "review-pr",
            worktreeId,
            provider.rawValue,
            host,
            repositorySlug,
            "\(number)",
        ].joined(separator: ":")
    }

    mutating func refreshSnapshotMetadata(from snapshot: ReviewLoopSnapshot) {
        guard let request = snapshot.reviewRequest else { return }
        url = request.url
        title = request.title
    }

    func matches(_ snapshot: ReviewLoopSnapshot) -> Bool {
        guard let request = snapshot.reviewRequest else { return false }
        return request.provider == provider
            && request.remote.host.lowercased() == (url.host ?? "").lowercased()
            && request.remote.repositorySlug == repositorySlug
            && request.number == number
    }
}

struct CommitTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let sha: String
    let title: String

    init(worktreeId: String, sha: String, title: String) {
        self.id = "commit:\(worktreeId):\(sha)"
        self.worktreeId = worktreeId
        self.sha = sha
        self.title = title
    }
}

struct CommitEditorTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let baseRef: String
    let originalSha: String
    var currentSha: String
    var title: String

    init(worktreeId: String, baseRef: String, originalSha: String, currentSha: String, title: String) {
        self.id = "commit-editor:\(worktreeId):\(originalSha)"
        self.worktreeId = worktreeId
        self.baseRef = baseRef
        self.originalSha = originalSha
        self.currentSha = currentSha
        self.title = title
    }
}

struct DraftCommitTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    var subject: String
    var bodyText: String
    var amend: Bool
    var selectedPath: String?

    init(
        worktreeId: String,
        subject: String = "",
        bodyText: String = "",
        amend: Bool = false,
        selectedPath: String? = nil
    ) {
        self.id = "draft-commit:\(worktreeId)"
        self.worktreeId = worktreeId
        self.subject = subject
        self.bodyText = bodyText
        self.amend = amend
        self.selectedPath = selectedPath
    }
}

struct DraftReviewRequestTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let provider: CodeHostKind
    let repositorySlug: String
    let branchName: String
    let baseBranch: String
    var headOwner: String?
    var headSHA: String
    var title: String
    var body: String
    var createAsDraft: Bool
    var selectedPath: String?
    var createdURL: URL?

    var displayTitle: String {
        if createdURL != nil { return "\(provider.reviewRequestLabel) created" }
        return "Draft \(provider.reviewRequestLabel)"
    }

    init(worktreeId: String, snapshot: ReviewLoopSnapshot) {
        let provider = snapshot.remote?.kind ?? .github
        self.worktreeId = worktreeId
        self.provider = provider
        self.repositorySlug = snapshot.remote?.repositorySlug ?? ""
        self.branchName = snapshot.local.branchName
        self.baseBranch = snapshot.local.baseBranch
        self.id = [
            "draft-review-request",
            worktreeId,
            provider.rawValue,
            self.repositorySlug,
            snapshot.local.branchName,
            snapshot.local.baseBranch,
        ].joined(separator: ":")
        self.headOwner = snapshot.local.headRemoteOwner
        self.headSHA = snapshot.local.headSHA
        self.title = ""
        self.body = ""
        self.createAsDraft = false
        self.selectedPath = nil
        self.createdURL = nil
    }

    mutating func refreshSnapshotMetadata(from snapshot: ReviewLoopSnapshot) {
        if headSHA != snapshot.local.headSHA {
            createdURL = nil
        }
        headOwner = snapshot.local.headRemoteOwner
        headSHA = snapshot.local.headSHA
    }

    func matchesTarget(_ snapshot: ReviewLoopSnapshot) -> Bool {
        snapshot.remote?.kind == provider
            && snapshot.remote?.repositorySlug == repositorySlug
            && snapshot.local.branchName == branchName
            && snapshot.local.baseBranch == baseBranch
            && snapshot.local.headSHA == headSHA
    }
}

struct TerminalTabState: Codable, Equatable, Identifiable {
    let id: TabID
    var title: String
    var root: PaneNode
    var focusedLeafId: String

    init(id: TabID, title: String, root: PaneNode, focusedLeafId: String) {
        self.id = id
        self.title = title
        self.root = root
        self.focusedLeafId = focusedLeafId
    }

    /// Convenience for callers that still create a single-leaf tab. The
    /// leaf id is set to `sessionId` so that the leaf identity matches the
    /// registry key and zmx session name (both keyed by leaf id since the
    /// switch to stable identity). Callers MUST pass the live
    /// `TerminalSession.id` here, not an unrelated string.
    init(id: TabID, title: String, sessionId: String) {
        let leafId = sessionId
        self.id = id
        self.title = title
        self.root = .leaf(PaneLeaf(id: leafId, sessionId: sessionId, lastCwd: nil))
        self.focusedLeafId = leafId
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, root, focusedLeafId, sessionId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(TabID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        if let root = try c.decodeIfPresent(PaneNode.self, forKey: .root) {
            self.root = root
            self.focusedLeafId = try c.decodeIfPresent(String.self, forKey: .focusedLeafId)
                ?? root.firstLeaf().id
        } else {
            // Legacy shape: {id, title, sessionId}. Migrate to a single-leaf
            // tree. Use the persisted sessionId as the leaf id so the leaf
            // identity already matches the new "leaf.id == session id"
            // invariant on the first decode (and the next encode is a no-op
            // since sessionId is now mirrored to id).
            let legacy = try c.decode(String.self, forKey: .sessionId)
            self.root = .leaf(PaneLeaf(id: legacy, sessionId: legacy, lastCwd: nil))
            self.focusedLeafId = legacy
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(root, forKey: .root)
        try c.encode(focusedLeafId, forKey: .focusedLeafId)
    }
}

struct EditorTabState: Codable, Equatable, Identifiable {
    let id: TabID
    var title: String
    var relativePath: String   // relative to worktree root; empty when external
    var revealLine: Int? = nil       // 0-based, optional reveal hint set by go-to-definition
    var revealCharacter: Int? = nil  // 0-based UTF-16
    var externalAbsolutePath: String? = nil  // set when navigating to a file outside the worktree
    /// The worktree-relative path of the in-worktree file the user was
    /// viewing when they ⌘-clicked to open this external tab. Persisted so
    /// that app-restart reopens can still route LSP traffic to the correct
    /// holder in nested-package layouts. Nil for tabs persisted before this
    /// field was added (backward-compatible via the default value).
    var originatingRelativePath: String? = nil
    /// Last view mode the user selected for this markdown tab. `nil` means
    /// "use `AppConfig.markdown.defaultViewMode`". Nil for non-markdown tabs.
    var markdownViewMode: MarkdownViewMode? = nil
    /// Editor-pane width as a fraction of the split container, persisted
    /// per-tab. Nil → 0.5. Nil for non-markdown or non-split tabs.
    var markdownSplitFraction: Double? = nil

    var isExternal: Bool { externalAbsolutePath != nil }
}

struct DiffTabState: Codable, Equatable, Identifiable {
    let id: TabID
    var title: String
    var relativePath: String
    var staged: Bool = false

    init(id: TabID, title: String, relativePath: String, staged: Bool = false) {
        self.id = id
        self.title = title
        self.relativePath = relativePath
        self.staged = staged
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, relativePath, staged
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TabID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        staged = try container.decodeIfPresent(Bool.self, forKey: .staged) ?? false
    }
}

struct ImagePreviewTabState: Codable, Equatable, Identifiable {
    let id: TabID
    var title: String
    var relativePath: String
}

struct ACPSessionTabState: Codable, Equatable, Identifiable {
    let id: TabID        // "acp:<sessionId>"
    let sessionId: ACPSession.ID
    var title: String

    init(sessionId: ACPSession.ID, title: String) {
        self.id = "acp:\(sessionId)"
        self.sessionId = sessionId
        self.title = title
    }
}
