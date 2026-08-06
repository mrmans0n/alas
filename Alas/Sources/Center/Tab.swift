import CryptoKit
import Foundation

typealias TabID = String

struct MissionTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let missionID: MissionID
    var title: String

    init(missionID: MissionID, title: String) {
        id = "mission:\(missionID.rawValue)"
        self.missionID = missionID
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case missionID
        case title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        missionID = try container.decode(MissionID.self, forKey: .missionID)
        title = try container.decode(String.self, forKey: .title)
        id = "mission:\(missionID.rawValue)"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(missionID, forKey: .missionID)
        try container.encode(title, forKey: .title)
    }
}

enum Tab: Codable, Equatable, Identifiable {
    case terminal(TerminalTabState)
    case editor(EditorTabState)
    case diff(DiffTabState)
    case stashDiff(StashDiffTabState)
    case commit(CommitTabState)
    case commitEditor(CommitEditorTabState)
    case draftCommit(DraftCommitTabState)
    case draftReviewRequest(DraftReviewRequestTabState)
    case reviewChanges(ReviewChangesTabState)
    case reviewSession(ReviewSessionTabState)
    case imagePreview(ImagePreviewTabState)
    case binaryPreview(BinaryPreviewTabState)
    case mergeConflict(MergeConflictTabState)
    case acpSession(ACPSessionTabState)
    case reviewPR(ReviewPRTabState)
    case fileSnapshot(FileSnapshotTabState)
    case fileHistory(FileHistoryTabState)
    case ggInbox(GGInboxTabState)
    case ggSplitCommit(GGSplitCommitTabState)
    case mission(MissionTabState)

    var id: TabID {
        switch self {
        case .terminal(let s):     return s.id
        case .editor(let s):       return s.id
        case .diff(let s):         return s.id
        case .stashDiff(let s):    return s.id
        case .commit(let s):       return s.id
        case .commitEditor(let s): return s.id
        case .draftCommit(let s):  return s.id
        case .draftReviewRequest(let s): return s.id
        case .reviewChanges(let s): return s.id
        case .reviewSession(let s): return s.id
        case .imagePreview(let s): return s.id
        case .binaryPreview(let s): return s.id
        case .mergeConflict(let s): return s.id
        case .acpSession(let s):   return s.id
        case .reviewPR(let s):     return s.id
        case .fileSnapshot(let s): return s.id
        case .fileHistory(let s):  return s.id
        case .ggInbox(let s):      return s.id
        case .ggSplitCommit(let s): return s.id
        case .mission(let s):      return s.id
        }
    }

    var title: String {
        switch self {
        case .terminal(let s):     return s.title
        case .editor(let s):       return s.title
        case .diff(let s):         return s.title
        case .stashDiff(let s):    return s.title
        case .commit(let s):       return s.title
        case .commitEditor(let s): return s.title
        case .draftCommit:         return "Draft commit"
        case .draftReviewRequest(let s): return s.displayTitle
        case .reviewChanges:       return "Review Changes"
        case .reviewSession(let s): return s.title
        case .imagePreview(let s): return s.title
        case .binaryPreview(let s): return s.title
        case .mergeConflict(let s): return s.title
        case .acpSession(let s):   return s.title
        case .reviewPR(let s):     return s.displayTitle
        case .fileSnapshot(let s): return s.title
        case .fileHistory(let s):  return s.title
        case .ggInbox(let s):      return s.title
        case .ggSplitCommit:       return "Split Commit"
        case .mission(let s):      return s.title
        }
    }

    var iconName: String {
        switch self {
        case .terminal:     return "terminal"
        case .editor:       return "code"
        case .diff:         return "diff"
        case .stashDiff:    return "archivebox"
        case .commit:       return "commit"
        case .commitEditor: return "commit"
        case .draftCommit:  return "commit"
        case .draftReviewRequest: return "pull-request"
        case .reviewChanges: return "diff"
        case .reviewSession: return "text.badge.checkmark"
        case .imagePreview: return "image"
        case .binaryPreview: return "doc.fill"
        case .mergeConflict: return "diff"
        case .acpSession:   return "sparkle"
        case .reviewPR:     return "list.bullet.rectangle.portrait.fill"
        case .fileSnapshot: return "doc.text.magnifyingglass"
        case .fileHistory:  return "clock.arrow.circlepath"
        case .ggInbox:      return "branch"
        case .ggSplitCommit: return "arrow.trianglehead.branch"
        case .mission:      return "scope"
        }
    }

    var supportsRevisionFollowActions: Bool {
        switch self {
        case .commit, .reviewSession:
            true
        default:
            false
        }
    }

    var isFollowingRevision: Bool {
        switch self {
        case .commit(let state):
            state.revision.tracked != nil
        default:
            false
        }
    }

    var relativeFilePath: String? {
        switch self {
        case .editor(let s):       return s.isExternal ? nil : s.relativePath
        case .stashDiff(let s):    return s.file.path
        case .imagePreview(let s): return s.relativePath
        case .binaryPreview(let s): return s.relativePath.hasPrefix("/") ? nil : s.relativePath
        case .mergeConflict(let s): return s.relativePath
        case .fileSnapshot(let s): return s.relativePath
        case .fileHistory(let s):  return s.relativePath
        default:                   return nil
        }
    }

    /// Absolute path for file-backed tabs whose path is not worktree-relative
    /// (external editor tabs, external binary previews). Used by tab-bar
    /// actions that resolve a URL for system-open / reveal-in-Finder without
    /// going through `worktree.path.appendingPathComponent`.
    var absoluteFilePath: String? {
        switch self {
        case .editor(let s):       return s.isExternal ? s.externalAbsolutePath : nil
        case .binaryPreview(let s): return s.relativePath.hasPrefix("/") ? s.relativePath : nil
        default:                   return nil
        }
    }

    /// True for tabs that represent the live, current on-disk file at
    /// `relativeFilePath` / `absoluteFilePath` — i.e. opening with the system
    /// or revealing in Finder operates on the file the tab is actually
    /// showing. False for `.stashDiff`, `.fileSnapshot`, and `.fileHistory`,
    /// whose `relativeFilePath` points at a historical/stashed revision and
    /// must not be handed to `NSWorkspace` as if it were the current file.
    var supportsSystemOpenActions: Bool {
        switch self {
        case .editor, .imagePreview, .binaryPreview, .mergeConflict:
            return true
        case .stashDiff, .fileSnapshot, .fileHistory:
            return false
        default:
            return false
        }
    }
}

enum GGSplitCommitTabPresentation: Equatable {
    case available
    case unavailable(reason: String)
}

struct GGSplitCommitTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let targetGGID: String?
    let targetSHA: String

    init(worktreeId: String, targetGGID: String?, targetSHA: String) {
        self.id = "gg-split:\(worktreeId):\(targetGGID ?? targetSHA)"
        self.worktreeId = worktreeId
        self.targetGGID = targetGGID
        self.targetSHA = targetSHA
    }

    func presentation(
        capabilities: GGCapabilities,
        workflowAvailable: Bool,
        hasBlockingGitOperation: Bool = false
    ) -> GGSplitCommitTabPresentation {
        if !capabilities.structuredSplit {
            return .unavailable(reason: GGSplitCommitModel.unavailableReason)
        }
        if hasBlockingGitOperation {
            return .unavailable(reason: "Finish the current Git operation before splitting a commit.")
        }
        return workflowAvailable
            ? .available
            : .unavailable(reason: GGSplitCommitModel.workflowUnavailableReason)
    }

    func belongs(to stack: GGStack?) -> Bool {
        targetEntry(in: stack) != nil
    }

    func targetEntry(in stack: GGStack?) -> GGStackEntry? {
        guard let stack else { return nil }
        if let targetGGID {
            return stack.entries.first { $0.ggId == targetGGID }
        }
        return stack.entry(matchingCommitSHA: targetSHA)
    }

    /// Whether an in-flight split identity refers to this tab's own target,
    /// so a `.split` action started here can be treated as this tab applying
    /// rather than as another tab's operation.
    func matches(splitTarget identity: GGSplitTargetIdentity) -> Bool {
        if let ggID = identity.ggID, let targetGGID {
            return ggID == targetGGID
        }
        return identity.sha == targetSHA
    }
}

struct FileSnapshotTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let relativePath: String
    let ref: String
    var title: String

    init(worktreeId: String, relativePath: String, ref: String = "HEAD") {
        self.worktreeId = worktreeId
        self.relativePath = relativePath
        self.ref = ref
        self.title = "\((relativePath as NSString).lastPathComponent) @ \(ref)"
        self.id = "file-snapshot:\(worktreeId):\(ref):\(relativePath)"
    }
}

struct FileHistoryTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let relativePath: String
    var title: String

    init(worktreeId: String, relativePath: String) {
        self.worktreeId = worktreeId
        self.relativePath = relativePath
        self.title = "\((relativePath as NSString).lastPathComponent) History"
        self.id = "file-history:\(worktreeId):\(relativePath)"
    }
}

struct ReviewSessionTabState: Codable, Equatable, Identifiable {
    var id: TabID
    let worktreeId: String
    var sessionID: ReviewSessionID
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

    mutating func retarget(to record: ReviewSessionRecord) {
        id = "review-session:\(record.id.rawValue)"
        sessionID = record.id
        title = record.target.title
        selectedFileID = record.selectedFileID
        focusedCommentID = record.focusedCommentID
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

enum CommitRevision: Codable, Equatable, Hashable, Sendable {
    case fixed(sha: String)
    case following(TrackedRevision)

    var resolvedSHA: String {
        switch self {
        case .fixed(let sha):
            sha
        case .following(let revision):
            revision.resolvedSHA
        }
    }

    var tracked: TrackedRevision? {
        if case .following(let revision) = self {
            return revision
        }
        return nil
    }
}

struct CommitTabState: Codable, Equatable, Identifiable {
    var id: TabID
    let worktreeId: String
    var revision: CommitRevision
    var title: String

    private enum CodingKeys: String, CodingKey {
        case id
        case worktreeId
        case revision
        case sha
        case title
    }

    var sha: String { revision.resolvedSHA }

    var fixedSHA: String? {
        guard case .fixed(let sha) = revision else { return nil }
        return sha
    }

    init(worktreeId: String, sha: String, title: String) {
        self.id = Self.fixedID(worktreeId: worktreeId, sha: sha)
        self.worktreeId = worktreeId
        self.revision = .fixed(sha: sha)
        self.title = title
    }

    init(worktreeId: String, trackedRevision: TrackedRevision, title: String) {
        self.id = Self.trackedID(worktreeId: worktreeId, expression: trackedRevision.expression)
        self.worktreeId = worktreeId
        self.revision = .following(trackedRevision)
        self.title = title
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TabID.self, forKey: .id)
        worktreeId = try container.decode(String.self, forKey: .worktreeId)
        title = try container.decode(String.self, forKey: .title)
        if let decodedRevision = try container.decodeIfPresent(CommitRevision.self, forKey: .revision) {
            revision = decodedRevision
        } else {
            revision = .fixed(sha: try container.decode(String.self, forKey: .sha))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(worktreeId, forKey: .worktreeId)
        try container.encode(revision, forKey: .revision)
        try container.encode(sha, forKey: .sha)
        try container.encode(title, forKey: .title)
    }

    mutating func follow(_ revision: TrackedRevision) {
        id = Self.trackedID(worktreeId: worktreeId, expression: revision.expression)
        self.revision = .following(revision)
    }

    mutating func fix(sha: String) {
        id = Self.fixedID(worktreeId: worktreeId, sha: sha)
        revision = .fixed(sha: sha)
    }

    private static func fixedID(worktreeId: String, sha: String) -> String {
        "commit:\(worktreeId):\(sha)"
    }

    private static func trackedID(worktreeId: String, expression: String) -> String {
        "commit:\(worktreeId):tracked:\(trackedIDDigest(for: expression))"
    }

    private static func trackedIDDigest(for expression: String) -> String {
        SHA256.hash(data: Data(expression.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
    private var presentationRevision: Int?

    var presentationID: String {
        "\(id):presentation:\(presentationRevision ?? 0)"
    }

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
        self.presentationRevision = nil
    }

    mutating func prepareForNewCommit() {
        amend = false
        presentationRevision = (presentationRevision ?? 0) + 1
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
    /// Key of the RunScript this tab was launched from (`"<scope>:<fileName>"`).
    /// Nil for plain terminals. Persisted so run/focus dedup survives restarts.
    var runScriptKey: String?
    /// The specific leaf that owns `runScriptKey`. A tab can be split into
    /// multiple panes after the script launches; if that specific pane's
    /// session exits or is closed while a sibling pane remains, the tab
    /// survives but no longer represents "the script is running" — cleared
    /// alongside `runScriptKey` in `TabsManager.removeLeaf` when this leaf
    /// goes away.
    var runScriptLeafId: String?

    init(id: TabID, title: String, root: PaneNode, focusedLeafId: String, runScriptKey: String? = nil, runScriptLeafId: String? = nil) {
        self.id = id
        self.title = title
        self.root = root
        self.focusedLeafId = focusedLeafId
        self.runScriptKey = runScriptKey
        self.runScriptLeafId = runScriptLeafId
    }

    /// Convenience for callers that still create a single-leaf tab. The
    /// leaf id is set to `sessionId` so that the leaf identity matches the
    /// registry key and zmx session name (both keyed by leaf id since the
    /// switch to stable identity). Callers MUST pass the live
    /// `TerminalSession.id` here, not an unrelated string.
    init(id: TabID, title: String, sessionId: String, runScriptKey: String? = nil) {
        let leafId = sessionId
        self.id = id
        self.title = title
        self.root = .leaf(PaneLeaf(id: leafId, sessionId: sessionId, lastCwd: nil))
        self.focusedLeafId = leafId
        self.runScriptKey = runScriptKey
        self.runScriptLeafId = runScriptKey != nil ? leafId : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, root, focusedLeafId, sessionId, runScriptKey, runScriptLeafId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(TabID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.runScriptKey = try c.decodeIfPresent(String.self, forKey: .runScriptKey)
        self.runScriptLeafId = try c.decodeIfPresent(String.self, forKey: .runScriptLeafId)
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
        // Best-effort backfill for payloads persisted between runScriptKey's
        // introduction and runScriptLeafId's: without it, the fix in
        // `removeLeaf` would never clear a stale marker for these tabs.
        if runScriptKey != nil, runScriptLeafId == nil {
            runScriptLeafId = root.firstLeaf().id
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(root, forKey: .root)
        try c.encode(focusedLeafId, forKey: .focusedLeafId)
        try c.encodeIfPresent(runScriptKey, forKey: .runScriptKey)
        try c.encodeIfPresent(runScriptLeafId, forKey: .runScriptLeafId)
    }
}

struct EditorTabState: Codable, Equatable, Identifiable {
    let id: TabID
    var title: String
    var relativePath: String   // relative to worktree root; empty when external
    var revealLine: Int? = nil       // 0-based, optional reveal hint set by go-to-definition
    var revealEndLine: Int? = nil    // 0-based, optional inclusive range end
    var revealCharacter: Int? = nil  // 0-based UTF-16
    var revealRevision: Int? = nil   // increments for each explicit reveal request
    var externalAbsolutePath: String? = nil  // set when navigating to a file outside the worktree
    /// The worktree-relative path of the in-worktree file the user was
    /// viewing when they ⌘-clicked to open this external tab. Persisted so
    /// that app-restart reopens can still route LSP traffic to the correct
    /// holder in nested-package layouts. Nil for tabs persisted before this
    /// field was added (backward-compatible via the default value).
    var originatingRelativePath: String? = nil
    /// Whether this external tab is editable (opt-in for run-script edits).
    /// Optional so payloads persisted before this field was added decode to
    /// nil, preserving the historical read-only-external behavior.
    var externalEditable: Bool? = nil
    /// Last view mode the user selected for this markdown tab. `nil` means
    /// "use `AppConfig.markdown.defaultViewMode`". Nil for non-markdown tabs.
    var markdownViewMode: MarkdownViewMode? = nil
    /// Editor-pane width as a fraction of the split container, persisted
    /// per-tab. Nil → 0.5. Nil for non-markdown or non-split tabs.
    var markdownSplitFraction: Double? = nil

    var isExternal: Bool { externalAbsolutePath != nil }
    var isExternalEditable: Bool { externalEditable ?? false }
}

struct DiffTabState: Codable, Equatable, Identifiable {
    let id: TabID
    var title: String
    var relativePath: String
    var staged: Bool = false
    var originalPath: String? = nil
    var compareWithHEAD: Bool = false

    init(
        id: TabID,
        title: String,
        relativePath: String,
        staged: Bool = false,
        originalPath: String? = nil,
        compareWithHEAD: Bool = false
    ) {
        self.id = id
        self.title = title
        self.relativePath = relativePath
        self.staged = staged
        self.originalPath = originalPath
        self.compareWithHEAD = compareWithHEAD
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, relativePath, staged, originalPath, compareWithHEAD
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TabID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        staged = try container.decodeIfPresent(Bool.self, forKey: .staged) ?? false
        originalPath = try container.decodeIfPresent(String.self, forKey: .originalPath)
        compareWithHEAD = try container.decodeIfPresent(Bool.self, forKey: .compareWithHEAD) ?? false
    }
}

struct StashDiffTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let stash: GitStash
    let file: GitStashFile
    let title: String

    init(worktreeId: String, stash: GitStash, file: GitStashFile) {
        self.worktreeId = worktreeId
        self.stash = stash
        self.file = file
        self.title = "\((file.path as NSString).lastPathComponent) @ \(stash.ref)"
        self.id = "stash-diff:\(worktreeId):\(stash.ref):\(stash.sha):\(file.path)\u{0}\(file.isUntracked)"
    }
}

struct ImagePreviewTabState: Codable, Equatable, Identifiable {
    let id: TabID
    var title: String
    var relativePath: String
}

struct BinaryPreviewTabState: Codable, Equatable, Identifiable {
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
