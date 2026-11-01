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
        /// The host's in-progress cherry-pick/revert/merge/rebase; nil from older hosts.
        var operation: MergeOperation?
    }

    struct CommitFiles: Equatable {
        var files: [ChangedFile]
        var truncated: Bool
    }

    enum Document: Hashable, Sendable {
        /// A nil `stage` diffs against the comparison ref, matching
        /// `RemoteClientMessage.fileDiff`.
        case diff(path: String, stage: ChangeStage?)
        case commitDiff(path: String, sha: String)
        case file(path: String)
        /// Served over the host channel only, as the stash and its file were listed.
        case stashDiff(file: GitStashFile, stash: HostStashRef)
        /// How `path` changed since a checkpoint; served over the host channel only.
        case checkpointDiff(path: String, checkpointID: CheckpointID)

        /// What a host offers on hunk `index` of `count` of this document: stage
        /// and discard on an unstaged diff, unstage on a staged one. The last
        /// hunk of a cut-off diff may be partial, so it is not offered. As
        /// locally, an added or deleted file's hunk is not discarded, and a
        /// deletion is left to whole-file staging.
        func hunkActions(for hunk: ParsedDiff.Hunk, index: Int, of count: Int, truncated: Bool) -> [HostHunkAction] {
            guard case .diff(_, let stage?) = self, !truncated || index < count - 1, !hunk.deletesWholeFile else { return [] }
            switch stage {
            case .staged: return [.unstage]
            case .unstaged: return hunk.oldStart == 0 || hunk.newStart == 0 ? [.stage] : [.stage, .discard]
            }
        }

        var path: String {
            switch self {
            case .diff(let path, _), .commitDiff(let path, _), .file(let path), .checkpointDiff(let path, _): path
            case .stashDiff(let file, _): file.path
            }
        }
    }

    enum DocumentContent: Equatable {
        case diff(ParsedDiff, truncated: Bool)
        case text(String, truncated: Bool)
        /// A file's bytes, decoded by the view.
        case image(Data)
        /// A file shown as a placeholder card; `tooLarge` when it is an image above the preview cap.
        case binary(byteSize: Int?, tooLarge: Bool)
        /// An image diff's two sides, decoded by the view.
        case imageDiff(before: ImageSide, after: ImageSide, kind: ImageDiffPairKind, oldPath: String?)
    }

    /// One side of a host image diff, before decoding.
    enum ImageSide: Equatable {
        case data(Data)
        case missing
        case failed(String)
    }

    /// Which stored sides of an image a diff document compares, as `HostWorktreeRead.fileBytes` reads them.
    struct ImageDiffPlan: Equatable, Sendable {
        struct Side: Equatable, Sendable {
            var path: String
            /// Nil for the working tree.
            var revision: HostFileRevision?
        }

        /// Nil for a side the change has none of: an added file's before, a deleted file's after.
        var before: Side?
        var after: Side?
        var kind: ImageDiffPairKind
        var oldPath: String?
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
    /// The open `.file` document's version, when the host would save it. Kept while the same
    /// document reloads, so an editor open on it stays.
    private(set) var documentVersion: WorktreeFileVersion?
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
        if document != self.document { documentVersion = nil }
        self.document = document
        documentContent = .loading
    }

    /// Lands a host-served diff for `document` if it is still the open one.
    mutating func finishDocument(_ document: Document, with result: Result<HostDiff, NativePeerReviewGitClientError>) {
        guard document == self.document else { return }
        documentContent = switch result {
        case .success(let diff):
            .loaded(.diff(ParsedDiff(hunks: diff.hunks.map(Self.hunk), metadataSummary: diff.note), truncated: diff.truncated))
        case .failure(let error): .failed(error.message)
        }
    }

    /// The sides an image path's diff `document` compares, from its row in the loaded lists or the
    /// stash file it names; nil for any other document.
    func imageDiffPlan(
        for document: Document, comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    ) -> ImageDiffPlan? {
        var rows: [ChangedFile] = []
        switch (document, changes) {
        case (.diff(_, .staged?), .loaded(let loaded)): rows = loaded.staged
        case (.diff(_, .unstaged?), .loaded(let loaded)): rows = loaded.unstaged
        case (.diff(_, nil), .loaded(let loaded)): rows = loaded.branchFiles
        case (.commitDiff(_, let sha), _):
            if case .loaded(let loaded)? = commitFiles[sha] { rows = loaded.files }
        case (.stashDiff(let file, _), _):
            return Self.imageDiffPlan(for: document, status: file.status, renameFrom: file.oldPath, comparisonMode: comparisonMode)
        default: break
        }
        let row = rows.first { $0.path == document.path }
        return Self.imageDiffPlan(
            for: document, status: row?.status ?? "M", renameFrom: row?.renameFrom, comparisonMode: comparisonMode)
    }

    /// The sides an image diff reads, as local's image diffs pick them: unstaged compares the index with
    /// the working tree, staged HEAD with the index, a branch diff the comparison ref with the working
    /// tree, a commit its parent with itself, a stash the commit it was made on with its saved or
    /// untracked file, and a checkpoint its saved file with the working tree. A rename's old side reads
    /// its old path.
    static func imageDiffPlan(
        for document: Document, status: String, renameFrom: String?,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    ) -> ImageDiffPlan? {
        guard ImageFileType.isSupported(currentPath: document.path, originalPath: renameFrom) else { return nil }
        let path = document.path
        let resolution: ImageDiffPairResolver.Result
        let revisions: (before: HostFileRevision?, after: HostFileRevision?)
        switch document {
        case .diff(_, let stage):
            resolution = ImageDiffPairResolver.resolveWorkingCopy(
                entry: ChangedFile(path: path, status: status, stage: stage ?? .unstaged, add: 0, del: 0,
                                   renameFrom: renameFrom, conflict: nil),
                fileExistsOnDisk: true, staged: stage == .staged)
            revisions = switch stage {
            case .staged?: (.head, .index)
            case .unstaged?: (.index, nil)
            case nil: (.base(comparisonMode: comparisonMode), nil)
            }
        case .commitDiff(_, let sha):
            resolution = ImageDiffPairResolver.resolveCommit(
                entry: CommitChangedFile(path: path, originalPath: renameFrom, status: status, add: 0, del: 0))
            revisions = (.parent(sha: sha), .commit(sha: sha))
        case .stashDiff(let file, let stash):
            // An untracked file is new in the stash.
            resolution = ImageDiffPairResolver.resolveCommit(entry: CommitChangedFile(
                path: path, originalPath: renameFrom, status: file.isUntracked ? "A" : status, add: 0, del: 0))
            revisions = (.stashBase(stash), .stash(stash, untracked: file.isUntracked))
        case .checkpointDiff(_, let id):
            // Whether either side is missing shows once they are read.
            resolution = ImageDiffPairResolver.Result(kind: .modified, oldPath: nil)
            revisions = (.checkpoint(id: id), nil)
        case .file:
            return nil
        }
        return ImageDiffPlan(
            before: resolution.kind == .added
                ? nil : ImageDiffPlan.Side(path: resolution.oldPath ?? path, revision: revisions.before),
            after: resolution.kind == .deleted ? nil : ImageDiffPlan.Side(path: path, revision: revisions.after),
            kind: resolution.kind,
            oldPath: resolution.oldPath
        )
    }

    /// One side from a `fileBytes` reply: a file the host doesn't have at that side is missing.
    static func imageSide(_ reply: RemoteServerMessage?) -> ImageSide {
        switch reply {
        case .fileBytes(_, _, let data, _)?: .data(data)
        case .fileUnavailable(_, _, .notFound, _, _)?: .missing
        case .fileUnavailable(_, _, let reason, let byteSize, let message)?:
            .failed(imageFailure(reason, byteSize: byteSize, message: message))
        default: .failed(offlineMessage)
        }
    }

    /// What an image side the host refused shows in its place: the host's own message when it
    /// gave one (git's first line only), else why from `reason`, with the size of one too large to preview.
    static func imageFailure(_ reason: RemoteFileAccessReason, byteSize: Int?, message: String?) -> String {
        if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            guard reason == .gitFailed else { return message }
            let line: String = message.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { !$0.isEmpty }) ?? ""
            return "Git failed on the host: " + (line.count > 200 ? String(line.prefix(200)) + "…" : line)
        }
        switch reason {
        case .tooLarge:
            guard let byteSize else { return "Too large to preview." }
            return "Too large to preview (\(formattedByteSize(byteSize)))."
        case .notFound: return "The host doesn't have this revision of the file."
        case .pathRejected: return "The host refused to read this file."
        case .gitFailed: return "Git failed on the host."
        case .sessionUnknown: return "The host no longer has this session."
        case .worktreeUnavailable: return "The worktree isn't available on the host."
        case .binary, .unknown: return "The host couldn't read this image."
        }
    }

    static func formattedByteSize(_ byteSize: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    /// Lands a host-served image diff for `document` if it is still the open one.
    mutating func finishImageDiff(_ document: Document, plan: ImageDiffPlan, before: ImageSide, after: ImageSide) {
        guard document == self.document else { return }
        // A checkpoint's plan can't tell an add or delete from a change until its sides are read.
        let kind: ImageDiffPairKind = switch (plan.kind, before, after) {
        case (.modified, .missing, _): .added
        case (.modified, _, .missing): .deleted
        default: plan.kind
        }
        documentContent = .loaded(.imageDiff(before: before, after: after, kind: kind, oldPath: plan.oldPath))
    }

    mutating func closeDocument() {
        document = nil
        documentVersion = nil
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
                         let truncated, let commitsTruncated, _, let operation):
            changes = .loaded(Changes(
                comparisonRef: ref,
                // The branch list has no stage; `.unstaged` only satisfies
                // `ChangedFile`, and its rows open with a nil diff stage.
                branchFiles: files.map { Self.changedFile($0, stage: .unstaged) },
                staged: staged.map { Self.changedFile($0, stage: .staged) },
                unstaged: unstaged.map { Self.changedFile($0, stage: .unstaged) },
                commits: commits,
                truncated: truncated,
                commitsTruncated: commitsTruncated,
                operation: operation
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
        case .fileContents(_, let path, let text, let truncated, let version):
            guard document == .file(path: path) else { return true }
            // A known binary shows the card even when it reads as text, as it does locally.
            if BinaryFileType.isKnownBinary(relativePath: path) {
                documentContent = .loaded(.binary(byteSize: truncated ? nil : text.utf8.count, tooLarge: false))
                documentVersion = nil
            } else {
                documentContent = .loaded(.text(text, truncated: truncated))
                documentVersion = version
            }
        case .fileBytes(_, let path, let data, _):
            guard document == .file(path: path) else { return true }
            documentVersion = nil
            documentContent = .loaded(.image(data))
        case .fileUnavailable(_, let path, let reason, let byteSize, let message):
            guard document == .file(path: path) else { return true }
            documentVersion = nil
            documentContent = Self.unavailableContent(path: path, reason: reason, byteSize: byteSize, message: message)
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

    /// What a `.file` document the host would not serve shows: the local placeholder card for a binary
    /// file, and for an image or known binary above the cap; a note for anything else.
    private static func unavailableContent(
        path: String, reason: RemoteFileAccessReason, byteSize: Int?, message: String?
    ) -> Load<DocumentContent> {
        switch reason {
        case .binary:
            return .loaded(.binary(byteSize: byteSize, tooLarge: false))
        case .tooLarge where ImageFileType.isSupported(relativePath: path):
            return .loaded(.binary(byteSize: byteSize, tooLarge: true))
        case .tooLarge where BinaryFileType.isKnownBinary(relativePath: path):
            return .loaded(.binary(byteSize: byteSize, tooLarge: false))
        default:
            return .failed(describe(reason, message: message))
        }
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

/// The host's reads behind the review loaders. A file diff the host fails to
/// read becomes an empty diff, which the loaders show as their "No text diff"
/// placeholder; a failed file list, or no reply at all, throws. No context
/// expansion from a peer, and images only from a host that reads their sides.
struct NativePeerReviewGitClient: ReviewChangesGitClient, CommitReviewGitClient, RangeReviewGitClient {
    /// `@unchecked` is sound: its only state is main-actor isolated.
    final class Notes: @unchecked Sendable {
        /// Set when any reply was cut off by the host's caps.
        @MainActor var truncated = false
    }

    let read: @Sendable (HostWorktreeRead) async -> RemoteServerMessage?
    let notes = Notes()
    /// Which range `rangeDiff` reads: `base...head` from the merge base, or
    /// `base..head`. Set per review by `ReviewSessionLoader.peer(git:)`.
    var threeDot = false
    /// Whether the host reads image sides: working copy and commit ones with
    /// `fileBytes`, a range's and a pull request's with the newer revisions too.
    var readsImages = false
    var readsRangeImages = false
    var readsProviderReviewImages = false
    /// Names this load's working-copy images, which change under the same stage.
    let loadToken = UUID().uuidString

    func status(worktreePath _: URL) async throws -> [ChangedFile] {
        switch await read(.changes(comparisonMode: nil)) {
        case .changeList(_, _, _, _, let staged, let unstaged, _, let truncated, _, let workingTreeTruncated, _)?:
            // An older host sends no `workingTreeTruncated`; its `truncated`
            // also covers the branch file list, so a capped branch diff
            // notes a cut-off review that may be whole.
            await note(workingTreeTruncated ?? truncated)
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
        switch await read(.fileDiff(path: file, stage: stage.rawValue, comparisonMode: nil)) {
        case .fileDiffResult(_, _, _, let hunks, let truncated, let metadataNote)?:
            await note(truncated)
            return ParsedDiff(hunks: hunks.map(NativePeerWorkspace.hunk), metadataSummary: metadataNote)
        case nil: throw NativePeerReviewGitClientError(message: NativePeerWorkspace.offlineMessage)
        default: return ParsedDiff(hunks: [])
        }
    }

    func diff(worktreePath _: URL, sha: String, file: String, originalPath _: String?) async throws -> ParsedDiff {
        try await commitDiff(await read(.commitDiff(sha: sha, path: file)))
    }

    func commitFiles(sha: String) async throws -> [CommitChangedFile] {
        try await commitFiles(await read(.commitFiles(sha: sha)))
    }

    func rangeFiles(base: String, head: String, threeDot: Bool) async throws -> [CommitChangedFile] {
        try await commitFiles(await read(.rangeFiles(base: base, head: head, threeDot: threeDot)))
    }

    /// The host resolves the range itself, so its ends pass through as given.
    func resolvedRangeTrees(
        worktreePath _: URL, base: String, head: String, threeDot _: Bool
    ) async throws -> (before: String, after: String) {
        (base, head)
    }

    func rangeDiff(
        worktreePath _: URL, revisions: (before: String, after: String), file: String, originalPath: String?
    ) async throws -> ParsedDiff {
        try await commitDiff(await read(.rangeDiff(
            base: revisions.before, head: revisions.after, threeDot: threeDot, path: file, originalPath: originalPath
        )))
    }

    private func commitDiff(_ reply: RemoteServerMessage?) async throws -> ParsedDiff {
        switch reply {
        case .commitDiffResult(_, _, _, let hunks, let truncated, let metadataNote)?:
            await note(truncated)
            return ParsedDiff(hunks: hunks.map(NativePeerWorkspace.hunk), metadataSummary: metadataNote)
        case nil: throw NativePeerReviewGitClientError(message: NativePeerWorkspace.offlineMessage)
        default: return ParsedDiff(hunks: [])
        }
    }

    private func commitFiles(_ reply: RemoteServerMessage?) async throws -> [CommitChangedFile] {
        switch reply {
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

    func rangeContextSnapshot(
        worktreePath _: URL, base _: String, head _: String, threeDot _: Bool, file _: String, originalPath _: String?
    ) async throws -> DiffReviewFileContextSnapshot {
        throw NativePeerReviewGitClientError.unavailable
    }

    func workingCopyImageProvider(worktreePath: URL, change: ChangedFile) async -> DiffReviewImageProvider {
        let staged = change.stage == .staged
        return imageProvider(
            .workingCopy, worktreePath: worktreePath, ids: ("\(change.stage.rawValue):\(loadToken)", loadToken),
            resolution: ImageDiffPairResolver.resolveWorkingCopy(entry: change, fileExistsOnDisk: true, staged: staged),
            path: change.path, sides: staged ? (.head, .index) : (.index, nil), reads: readsImages)
    }

    func commitImageProvider(worktreePath: URL, sha: String, file: CommitChangedFile) -> DiffReviewImageProvider {
        imageProvider(
            .commit, worktreePath: worktreePath, ids: ("\(sha)^", sha), resolution: ImageDiffPairResolver.resolveCommit(entry: file),
            path: file.path, sides: (.parent(sha: sha), .commit(sha: sha)), reads: readsImages)
    }

    func rangeImageProvider(
        worktreePath: URL, revisions: (before: String, after: String), file: CommitChangedFile
    ) -> DiffReviewImageProvider {
        let (base, head) = revisions
        return imageProvider(
            .range, worktreePath: worktreePath,
            ids: (HostWorktreeRead.rangeSpec(base: base, head: head, threeDot: threeDot), head),
            resolution: ImageDiffPairResolver.resolveCommit(entry: file), path: file.path,
            sides: (.rangeBase(base: base, head: head, threeDot: threeDot), .commit(sha: head)), reads: readsRangeImages)
    }

    /// Reads an image's two sides from the host as the plan for a document reads them; a host that
    /// can't fails them.
    private func imageProvider(
        _ source: DiffReviewImageProviderID.Source, worktreePath: URL, ids: (before: String, after: String),
        resolution: ImageDiffPairResolver.Result, path: String, sides: (before: HostFileRevision?, after: HostFileRevision?),
        reads: Bool
    ) -> DiffReviewImageProvider {
        let read = read
        let beforePath = resolution.oldPath ?? path
        return DiffReviewImageProvider(
            id: DiffReviewImageProviderID(source: source, repository: worktreePath.path, beforeRevision: ids.before,
                                          afterRevision: ids.after, beforePath: resolution.oldPath, afterPath: path),
            load: {
                guard reads else { return .failedLoading("Update the host to compare images.") }
                func side(_ path: String, _ revision: HostFileRevision?, missing: Bool) async -> NativePeerWorkspace.ImageSide {
                    missing ? .missing : NativePeerWorkspace.imageSide(await read(.fileBytes(path: path, revision: revision)))
                }
                // ponytail: the sides are read one after the other, as a document's are.
                let before = await side(beforePath, sides.before, missing: resolution.kind == .added)
                let after = await side(path, sides.after, missing: resolution.kind == .deleted)
                return ImageDiffPair(
                    before: NativePeerDocumentView.decodedSide(before), after: NativePeerDocumentView.decodedSide(after),
                    oldPath: resolution.oldPath, kind: resolution.kind)
            }
        )
    }

    private func note(_ truncated: Bool) async {
        guard truncated else { return }
        let notes = notes
        await MainActor.run { notes.truncated = true }
    }
}

struct NativePeerReviewGitClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static let unavailable = NativePeerReviewGitClientError(message: "Not available from this Mac yet.")
}

/// The host's provider diff, for `ReviewRequestDiffLoader`. Runs no gh or
/// glab: image sides are read from the host with `readImage`, which an older
/// host leaves nil and fails them; everything else is unsupported.
struct NativePeerProviderDiff: CodeHostProvider {
    let kind: CodeHostKind
    let diff: String
    /// Reads a side of the review's image diff from the host, the head's with `after`.
    var readImage: (@Sendable (_ path: String, _ after: Bool) async -> RemoteServerMessage?)?

    private static let afterPrefix = "host-after:"

    func reviewDiff(remote _: CodeHostRemote, request _: ReviewRequest, cwd _: URL) async throws -> String { diff }

    /// Names for the host's sides, not commits: the host resolves the review's
    /// own. The base and head keep a new push's images apart in the image cache.
    func reviewImageRevisions(
        remote _: CodeHostRemote, request: ReviewRequest, cwd _: URL
    ) async throws -> CodeHostReviewImageRevisions {
        guard readImage != nil, let head = request.headSHA else { throw CodeHostProviderError.unsupportedProvider(kind) }
        return CodeHostReviewImageRevisions(
            beforeSHA: "host-before:\(request.baseSHA ?? "-"):\(head)", afterSHA: Self.afterPrefix + head
        )
    }

    func reviewFileData(
        remote _: CodeHostRemote, repository _: String, revision: String, path: String, cwd _: URL
    ) async throws -> Data {
        guard let readImage else { throw CodeHostProviderError.unsupportedProvider(kind) }
        switch await readImage(path, revision.hasPrefix(Self.afterPrefix)) {
        case .fileBytes(_, _, let data, _)?:
            return data
        case .fileUnavailable(_, _, let reason, let byteSize, let message)?:
            throw ImageDiffLoadFailure(message: NativePeerWorkspace.imageFailure(reason, byteSize: byteSize, message: message))
        default:
            throw ImageDiffLoadFailure(message: NativePeerWorkspace.offlineMessage)
        }
    }

    func isAvailable(cwd _: URL) async -> Bool { false }
    func isAuthenticated(remote _: CodeHostRemote, cwd _: URL) async -> Bool { false }

    func currentReviewRequest(
        remote _: CodeHostRemote, branch _: String, headOwner _: String?, baseBranch _: String, cwd _: URL
    ) async throws -> ReviewRequest? {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func createReviewRequest(
        remote _: CodeHostRemote, branch _: String, headOwner _: String?, baseBranch _: String,
        title _: String, body _: String, isDraft _: Bool, cwd _: URL
    ) async throws -> URL {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func checks(remote _: CodeHostRemote, request _: ReviewRequest, cwd _: URL) async throws -> [ReviewCheck] {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func rerunFailedChecks(
        remote _: CodeHostRemote, branch _: String, headSHA _: String, request _: ReviewRequest?, cwd _: URL
    ) async throws {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }
}
