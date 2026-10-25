import Foundation

/// Read-only mirror of the selected peer session's worktree, built from the
/// gateway's changes and files replies. Carries none of the local right
/// pane's write actions: the peer protocol has no endpoints for them.
struct NativePeerWorkspace: Equatable {
    enum Load<Value: Equatable>: Equatable {
        case idle
        case loading
        case loaded(Value)
        case failed(String)
    }

    struct Changes: Equatable {
        var comparisonRef: String?
        /// Every file that differs from `comparisonRef`, committed or not.
        var branchFiles: [ChangedFile]
        var staged: [ChangedFile]
        var unstaged: [ChangedFile]
        var commits: [RemoteCommit]
        var truncated: Bool
        var commitsTruncated: Bool
    }

    struct CommitFiles: Equatable {
        var files: [ChangedFile]
        var truncated: Bool
    }

    enum Document: Hashable {
        /// A nil `stage` diffs against the comparison ref, matching
        /// `RemoteClientMessage.fileDiff`.
        case diff(path: String, stage: ChangeStage?)
        case commitDiff(path: String, sha: String)
        case file(path: String)

        var path: String {
            switch self {
            case .diff(let path, _), .commitDiff(let path, _), .file(let path): path
            }
        }
    }

    enum DocumentContent: Equatable {
        case diff(ParsedDiff, truncated: Bool)
        case text(String, truncated: Bool)
    }

    static let offlineMessage = "Peer is offline."

    private(set) var commitFiles: [String: Load<CommitFiles>] = [:]
    private(set) var changes: Load<Changes> = .idle
    private(set) var fileTree: Load<[FileTreeNode]> = .idle
    /// Bumped on every tree merge so `FileTreeListView` re-evaluates its
    /// lazy-load tasks, like `RightPaneState.fileTreeRefreshRevision`.
    private(set) var fileTreeRevision = 0
    private(set) var document: Document?
    private(set) var documentContent: Load<DocumentContent> = .idle
    private var loadingPaths: Set<String> = []
    private var loadedPaths: Set<String> = []
    private var failedPaths: Set<String> = []
    /// Directories (root keyed by `""`) whose last listing was cut off by the
    /// peer's `RemoteWorktreeFileAccess.maxFileTreeNodes` cap.
    private var truncatedPaths: Set<String> = []
    /// Child listings already in flight when a root refresh starts belong to
    /// the previous tree snapshot and must not merge into the replacement.
    private var invalidatedLoadingPaths: Set<String> = []
    private var invalidatedRepliesBeforeRoot: Set<String> = []
    private var rootLoadInFlight = false

    /// True while any loaded listing — root or a directory — was truncated by
    /// the peer, so the UI can note that the tree may be incomplete.
    var fileTreeTruncated: Bool { !truncatedPaths.isEmpty }

    /// Keeps showing the last list while a refresh is in flight.
    mutating func beginChangesLoad() {
        if case .loaded = changes { return }
        changes = .loading
    }

    /// Commit contents are immutable, so loaded lists can be reused.
    mutating func beginCommitFilesLoad(sha: String) -> Bool {
        // Full commit identities were added with the inspection endpoints.
        // Older peers silently discard these request types.
        if case .loaded(let changes) = changes,
           let commit = changes.commits.first(where: { $0.revision == sha }), commit.sha == nil {
            commitFiles[sha] = .failed("Update the peer to inspect commit files.")
            return false
        }
        switch commitFiles[sha] {
        case .loading?, .loaded?: return false
        default:
            commitFiles[sha] = .loading
            return true
        }
    }

    /// False while the root listing is already in flight. A loaded tree
    /// stays on screen until the new listing replaces it.
    mutating func beginRootLoad() -> Bool {
        guard !rootLoadInFlight else { return false }
        rootLoadInFlight = true
        invalidatedLoadingPaths.formUnion(loadingPaths)
        if case .loaded = fileTree { return true }
        fileTree = .loading
        return true
    }

    /// False when `path` is already loading or loaded, so a re-rendered row
    /// does not send the same request twice. Marks the directory `.loading`
    /// in the tree so the row shows a spinner while the reply is pending.
    mutating func beginChildrenLoad(path: String) -> Bool {
        guard !loadedPaths.contains(path) else { return false }
        guard loadingPaths.insert(path).inserted else { return false }
        if case .loaded(let tree) = fileTree {
            fileTree = .loaded(RightPaneState.mergingChildren(
                in: tree, for: path, with: [], state: .loading).nodes)
            fileTreeRevision &+= 1
        }
        return true
    }

    func shouldLoadChildren(path: String, childrenState: DirectoryChildrenState) -> Bool {
        RightPaneState.shouldAutoLoadFileTreeChildren(
            path: path,
            childrenState: childrenState,
            loadedPaths: loadedPaths,
            loadingPaths: loadingPaths,
            failedPaths: failedPaths
        )
    }

    mutating func beginDocument(_ document: Document) {
        self.document = document
        documentContent = .loading
    }

    mutating func closeDocument() {
        document = nil
        documentContent = .idle
    }

    /// The peer went away: fail whatever is still waiting on it so nothing
    /// spins forever. Loaded content stays readable. `loadingPaths` is
    /// cleared (not moved to `failedPaths`) so a directory that was mid-load
    /// can be retried immediately once the peer returns, rather than staying
    /// gated the way an explicit `fileTreeFailed` reply gates it.
    mutating func markUnavailable() {
        for (sha, load) in commitFiles where load == .loading {
            commitFiles[sha] = .failed(Self.offlineMessage)
        }
        if changes == .loading { changes = .failed(Self.offlineMessage) }
        if fileTree == .loading {
            fileTree = .failed(Self.offlineMessage)
        } else if case .loaded(var tree) = fileTree {
            for path in loadingPaths {
                tree = RightPaneState.mergingChildren(in: tree, for: path, with: [], state: .failed).nodes
            }
            fileTree = .loaded(tree)
            fileTreeRevision &+= 1
        }
        if documentContent == .loading { documentContent = .failed(Self.offlineMessage) }
        loadingPaths = []
        rootLoadInFlight = false
        invalidatedLoadingPaths = []
        invalidatedRepliesBeforeRoot = []
    }

    /// Folds a changes/files reply in. Returns false for every other message
    /// so the caller can hand it to the transcript.
    mutating func apply(_ message: RemoteServerMessage) -> Bool {
        switch message {
        case .changeList(_, let ref, _, let files, let staged, let unstaged, let commits,
                         let truncated, let commitsTruncated):
            changes = .loaded(Changes(
                comparisonRef: ref,
                // The branch list has no stage; `.unstaged` only satisfies
                // `ChangedFile`, and its rows open with a nil diff stage.
                branchFiles: files.map { Self.changedFile($0, stage: .unstaged) },
                staged: staged.map { Self.changedFile($0, stage: .staged) },
                unstaged: unstaged.map { Self.changedFile($0, stage: .unstaged) },
                commits: commits,
                truncated: truncated,
                commitsTruncated: commitsTruncated
            ))
        case .changeListFailed(_, let reason, let message):
            // A failed refresh keeps the list the user is already reading.
            if case .loaded = changes { return true }
            changes = .failed(Self.describe(reason, message: message))
        case .commitFiles(_, let sha, let files, let truncated):
            commitFiles[sha] = .loaded(CommitFiles(
                files: files.map { Self.changedFile($0, stage: .unstaged) }, truncated: truncated))
        case .commitFilesFailed(_, let sha, let reason, let message):
            commitFiles[sha] = .failed(Self.describe(reason, message: message))
        case .commitDiffResult(_, let sha, let path, let hunks, let truncated, let metadataNote):
            guard document == .commitDiff(path: path, sha: sha) else { return true }
            documentContent = .loaded(.diff(
                ParsedDiff(hunks: hunks.map(Self.hunk), metadataSummary: metadataNote), truncated: truncated))
        case .commitDiffFailed(_, let sha, let path, let reason, let message):
            guard document == .commitDiff(path: path, sha: sha) else { return true }
            documentContent = .failed(Self.describe(reason, message: message))
        case .fileTree(_, let path, let nodes, let truncated):
            let mapped = nodes.map(Self.fileTreeNode)
            let truncationKey = path ?? ""
            if let path, !path.isEmpty {
                if discardInvalidatedChildReply(path: path) { return true }
                loadingPaths.remove(path)
                guard case .loaded(let tree) = fileTree else { return true }
                let merge = RightPaneState.mergingChildren(in: tree, for: path, with: mapped, state: .loaded)
                guard merge.didMerge else { return true }
                fileTree = .loaded(merge.nodes)
                loadedPaths.insert(path)
            } else {
                rootLoadInFlight = false
                invalidatedRepliesBeforeRoot = []
                fileTree = .loaded(mapped)
                loadedPaths = []
                failedPaths = []
                // A full root reload replaces every directory's children
                // wholesale, so any previously-noted child truncation no
                // longer describes what's on screen.
                truncatedPaths = []
            }
            if truncated {
                truncatedPaths.insert(truncationKey)
            } else {
                truncatedPaths.remove(truncationKey)
            }
            fileTreeRevision &+= 1
        case .fileTreeFailed(_, let path, let reason, let message):
            if let path, !path.isEmpty {
                if discardInvalidatedChildReply(path: path) { return true }
                loadingPaths.remove(path)
                failedPaths.insert(path)
                if case .loaded(let tree) = fileTree {
                    fileTree = .loaded(RightPaneState.mergingChildren(
                        in: tree, for: path, with: [], state: .failed).nodes)
                }
                fileTreeRevision &+= 1
            } else {
                rootLoadInFlight = false
                resetInvalidatedRepliesBeforeRoot()
                if fileTree == .loading {
                    fileTree = .failed(Self.describe(reason, message: message))
                }
            }
        case .fileDiffResult(_, let path, let stage, let hunks, let truncated, let metadataNote):
            guard document == .diff(path: path, stage: stage.flatMap(ChangeStage.init(rawValue:))) else {
                return true
            }
            documentContent = .loaded(.diff(
                ParsedDiff(hunks: hunks.map(Self.hunk), metadataSummary: metadataNote),
                truncated: truncated
            ))
        case .fileDiffFailed(_, let path, let stage, let reason, let message):
            guard document == .diff(path: path, stage: stage.flatMap(ChangeStage.init(rawValue:))) else {
                return true
            }
            documentContent = .failed(Self.describe(reason, message: message))
        case .fileContents(_, let path, let text, let truncated):
            guard document == .file(path: path) else { return true }
            documentContent = .loaded(.text(text, truncated: truncated))
        case .fileUnavailable(_, let path, let reason, _, let message):
            guard document == .file(path: path) else { return true }
            documentContent = .failed(Self.describe(reason, message: message))
        default:
            return false
        }
        return true
    }

    private mutating func discardInvalidatedChildReply(path: String) -> Bool {
        guard invalidatedLoadingPaths.remove(path) != nil else { return false }
        loadingPaths.remove(path)
        if rootLoadInFlight {
            invalidatedRepliesBeforeRoot.insert(path)
        } else {
            resetChildForReload(path: path)
        }
        return true
    }

    private mutating func resetInvalidatedRepliesBeforeRoot() {
        for path in invalidatedRepliesBeforeRoot {
            resetChildForReload(path: path)
        }
        invalidatedRepliesBeforeRoot = []
    }

    private mutating func resetChildForReload(path: String) {
        if case .loaded(let tree) = fileTree {
            fileTree = .loaded(RightPaneState.mergingChildren(
                in: tree, for: path, with: [], state: .notLoaded).nodes)
        }
        fileTreeRevision &+= 1
    }

    static func describe(_ reason: RemoteFileAccessReason, message: String?) -> String {
        if let message, !message.isEmpty { return message }
        switch reason {
        case .sessionUnknown: return "The peer no longer has this session."
        case .worktreeUnavailable: return "The worktree is not available on the peer."
        case .pathRejected: return "The peer refused this path."
        case .notFound: return "File not found on the peer."
        case .binary: return "Binary files cannot be shown."
        case .tooLarge: return "This file is too large to show."
        case .gitFailed: return "Git failed on the peer."
        case .unknown: return "The peer could not serve this request."
        }
    }

    static func changedFile(_ file: RemoteChangedFile, stage: ChangeStage) -> ChangedFile {
        ChangedFile(
            path: file.path,
            status: file.status,
            stage: stage,
            add: file.add,
            del: file.del,
            renameFrom: file.renameFrom,
            conflict: file.conflict.flatMap(ConflictKind.init(rawValue:))
        )
    }

    private static func fileTreeNode(_ node: RemoteFileNode) -> FileTreeNode {
        FileTreeNode(
            name: node.name,
            path: node.path,
            kind: node.kind == "dir" ? .dir : .file,
            children: nil,
            badge: node.badge,
            childrenState: DirectoryChildrenState(rawValue: node.childrenState) ?? .notLoaded,
            isSubmodule: node.isSubmodule
        )
    }

    static func hunk(_ hunk: RemoteDiffHunk) -> ParsedDiff.Hunk {
        ParsedDiff.Hunk(
            header: hunk.header,
            oldStart: hunk.oldStart,
            newStart: hunk.newStart,
            lines: hunk.lines.map { line in
                let kind: ParsedDiff.Hunk.Line.Kind = switch line.kind {
                case "add": .add
                case "delete": .delete
                default: .context
                }
                return ParsedDiff.Hunk.Line(
                    kind: kind,
                    text: line.text,
                    oldNumber: line.oldNumber,
                    newNumber: line.newNumber,
                    noTrailingNewline: line.noTrailingNewline
                )
            }
        )
    }
}

/// The host's reads behind the review loaders. Per-file read failures become
/// an empty diff, which the loaders show as their "No text diff" placeholder;
/// a failed file list throws. No context expansion or images from a peer.
struct NativePeerReviewGitClient: ReviewChangesGitClient, CommitReviewGitClient {
    /// `@unchecked` is sound: its only state is main-actor isolated.
    final class Notes: @unchecked Sendable {
        /// Set when any reply was cut off by the host's caps.
        @MainActor var truncated = false
    }

    let read: @Sendable (HostWorktreeRead) async -> RemoteServerMessage?
    let notes = Notes()

    func status(worktreePath _: URL) async throws -> [ChangedFile] {
        switch await read(.changes(comparisonMode: nil)) {
        case .changeList(_, _, _, _, let staged, let unstaged, _, let truncated, _)?:
            // ponytail: `truncated` also covers the branch file list, so a
            // capped branch diff notes a cut-off review that may be whole.
            await note(truncated)
            return staged.map { NativePeerWorkspace.changedFile($0, stage: .staged) }
                + unstaged.map { NativePeerWorkspace.changedFile($0, stage: .unstaged) }
        case .changeListFailed(_, let reason, let message)?:
            throw NativePeerReviewGitClientError(message: NativePeerWorkspace.describe(reason, message: message))
        default:
            throw NativePeerReviewGitClientError(message: NativePeerWorkspace.offlineMessage)
        }
    }

    func imageStatus(worktreePath _: URL) async throws -> [ChangedFile] { [] }

    func diff(worktreePath _: URL, file: String, staged: Bool, originalPath _: String?) async throws -> ParsedDiff {
        let stage = staged ? ChangeStage.staged : .unstaged
        guard case .fileDiffResult(_, _, _, let hunks, let truncated, let metadataNote)? = await read(
            .fileDiff(path: file, stage: stage.rawValue, comparisonMode: nil)
        ) else { return ParsedDiff(hunks: []) }
        await note(truncated)
        return ParsedDiff(hunks: hunks.map(NativePeerWorkspace.hunk), metadataSummary: metadataNote)
    }

    func diff(worktreePath _: URL, sha: String, file: String, originalPath _: String?) async throws -> ParsedDiff {
        guard case .commitDiffResult(_, _, _, let hunks, let truncated, let metadataNote)? = await read(
            .commitDiff(sha: sha, path: file)
        ) else { return ParsedDiff(hunks: []) }
        await note(truncated)
        return ParsedDiff(hunks: hunks.map(NativePeerWorkspace.hunk), metadataSummary: metadataNote)
    }

    func commitFiles(sha: String) async throws -> [CommitChangedFile] {
        switch await read(.commitFiles(sha: sha)) {
        case .commitFiles(_, _, let files, let truncated)?:
            await note(truncated)
            return files.map {
                CommitChangedFile(path: $0.path, originalPath: $0.renameFrom, status: $0.status, add: $0.add, del: $0.del)
            }
        case .commitFilesFailed(_, _, let reason, let message)?:
            throw NativePeerReviewGitClientError(message: NativePeerWorkspace.describe(reason, message: message))
        default:
            throw NativePeerReviewGitClientError(message: NativePeerWorkspace.offlineMessage)
        }
    }

    func contextSnapshot(
        worktreePath _: URL, file _: String, staged _: Bool, originalPath _: String?
    ) async throws -> DiffReviewFileContextSnapshot {
        throw NativePeerReviewGitClientError.unavailable
    }

    func commitContextSnapshot(
        worktreePath _: URL, sha _: String, file _: String, originalPath _: String?
    ) async throws -> DiffReviewFileContextSnapshot {
        throw NativePeerReviewGitClientError.unavailable
    }

    func workingCopyImageProvider(worktreePath: URL, change: ChangedFile) async -> DiffReviewImageProvider {
        Self.unavailableImage(.workingCopy, worktreePath: worktreePath, revision: change.stage.rawValue,
                              beforePath: change.renameFrom, path: change.path)
    }

    func commitImageProvider(worktreePath: URL, sha: String, file: CommitChangedFile) -> DiffReviewImageProvider {
        Self.unavailableImage(.commit, worktreePath: worktreePath, revision: sha, beforePath: file.originalPath, path: file.path)
    }

    private func note(_ truncated: Bool) async {
        guard truncated else { return }
        let notes = notes
        await MainActor.run { notes.truncated = true }
    }

    private static func unavailableImage(
        _ source: DiffReviewImageProviderID.Source, worktreePath: URL, revision: String, beforePath: String?, path: String
    ) -> DiffReviewImageProvider {
        DiffReviewImageProvider(
            id: DiffReviewImageProviderID(source: source, repository: worktreePath.path, beforeRevision: revision,
                                          afterRevision: revision, beforePath: beforePath, afterPath: path),
            load: { .failedLoading() }
        )
    }
}

struct NativePeerReviewGitClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static let unavailable = NativePeerReviewGitClientError(message: "Not available from this Mac yet.")
}
