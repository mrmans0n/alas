import AlasHighlight
import AlasRemoteKit
import Foundation
import Observation

/// What a review screen goes through.
enum ReviewSource: Equatable {
    /// The working tree: staged files, then unstaged ones.
    case localChanges
    /// The branch's files against the comparison ref, the Changes tab's Branch Changes.
    case branchChanges
    case commit(sha: String)

    var isCommit: Bool {
        if case .commit = self { true } else { false }
    }
}

/// A comment sheet the review screen shows.
enum ReviewComposing: Identifiable {
    case lines(ReviewEntryID, RemoteReviewAnchor, title: String, quote: String)
    case file(ReviewEntryID)
    case edit(RemoteReviewComment)

    var id: String {
        switch self {
        case .lines(let entry, _, let title, _): "lines:\(entry.namespace):\(entry.path):\(title)"
        case .file(let entry): "file:\(entry.namespace):\(entry.path)"
        case .edit(let comment): "edit:\(comment.id)"
        }
    }
}

/// Every file of one change, each fetched as it nears the screen.
@MainActor @Observable
final class ReviewDocument {
    let workspace: SessionWorkspace
    let source: ReviewSource
    /// The entry to show first.
    let focus: ReviewEntryID?
    var entries: [ReviewEntry] = []
    var folded: Set<ReviewEntryID> = []
    var marks: ReviewViewedMarks
    /// The topmost entry on screen, which the collection view reports.
    var current: ReviewEntryID?
    /// Why the file list couldn't be read.
    var listError: String?
    /// A hunk or comment action's refusal.
    var error: String?
    /// The lines picked to comment on.
    var selection: ReviewSelection?
    /// The review's draft comments, every file's.
    var comments: [RemoteReviewComment] = []
    var composing: ReviewComposing?
    private(set) var listLoaded = false
    /// The Mac capped the file list, so the review doesn't hold every file.
    private(set) var listTruncated = false
    /// Each loaded entry's `ReviewViewedMarks.hash`, computed once per diff: hashing hashes every line.
    @ObservationIgnored private var hashes: [ReviewEntryID: String] = [:]
    /// Syntax spans by `spanKey`, each line's counted across the entry's hunks.
    private(set) var spans: [String: [[HighlightSpan]]] = [:]
    @ObservationIgnored private var spansInFlight: Set<String> = []
    /// Ticked while their diff was still loading; marked once it lands.
    @ObservationIgnored private var pendingViewed: Set<ReviewEntryID> = []
    /// Scrolls the collection view to an entry; installed by it.
    @ObservationIgnored var scrollTo: ((ReviewEntryID) -> Void)?

    private let scope: String

    init(workspace: SessionWorkspace, source: ReviewSource, focus: ReviewEntryID?) {
        self.workspace = workspace
        self.source = source
        self.focus = focus
        switch source {
        case .localChanges, .branchChanges: scope = workspace.localChangesReviewID ?? "local." + workspace.sessionId
        case .commit(let sha): scope = "commit." + sha
        }
        marks = ReviewPreferences.shared.marks(for: scope)
    }

    // MARK: Files

    /// Builds the entries from what the workspace already holds, else from the host.
    func start() async {
        guard !listLoaded else { return }
        if let cached = cachedFiles() {
            replace(with: cached.entries, truncated: cached.truncated)
            await loadComments()
        } else {
            await refresh()
        }
    }

    private typealias FileList = (entries: [ReviewEntry], truncated: Bool)

    private func cachedFiles() -> FileList? {
        switch source {
        case .localChanges, .branchChanges:
            if case .loaded(let reply) = workspace.changes { return files(from: reply) }
        case .commit(let sha):
            if let open = workspace.commit, open.commit.revision == sha, case .loaded(let reply) = open.1 {
                return (entries(from: reply.files, namespace: "commit"), reply.truncated)
            }
        }
        return nil
    }

    private func fetchFiles() async -> Result<FileList, RemoteGitFailure> {
        switch source {
        case .localChanges, .branchChanges: await workspace.loadChanges().map(files(from:))
        case .commit(let sha): await workspace.loadCommitFiles(sha).map { (entries(from: $0.files, namespace: "commit"), $0.truncated) }
        }
    }

    private func files(from reply: ChangeListReply) -> FileList {
        let entries = source == .branchChanges ? entries(from: reply.files, namespace: "branch")
            : entries(from: reply.staged, namespace: "staged") + entries(from: reply.unstaged, namespace: "unstaged")
        return (entries, reply.truncated)
    }

    private func entries(from files: [RemoteChangedFile], namespace: String) -> [ReviewEntry] {
        files.map {
            ReviewEntry(id: ReviewEntryID(namespace: namespace, path: $0.path), status: $0.status, add: $0.add, del: $0.del,
                        renameFrom: $0.renameFrom, content: .notLoaded)
        }
    }

    /// Re-reads the file list, keeping what each surviving entry showed, and fetches again every
    /// loaded or viewed entry, so a viewed file whose diff changed loses its mark.
    func refresh() async {
        switch await fetchFiles() {
        case .failure(let failure):
            if !listLoaded { listError = failure.message }
        case .success(let fresh):
            replace(with: fresh.entries, truncated: fresh.truncated)
        }
        await loadComments()
    }

    /// Takes `fresh` in the host's order, which keeps the order of the paths both lists hold.
    private func replace(with fresh: [ReviewEntry], truncated: Bool) {
        listTruncated = truncated
        let old = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let refetch = fresh.map(\.id).filter { id in
            if case .hunks = old[id]?.content { return true }
            if case .note = old[id]?.content { return true }
            return marks.hasMark(id)
        }
        entries = fresh.map { entry in
            var entry = entry
            if let kept = old[entry.id]?.content { entry.content = kept }
            return entry
        }
        let ids = Set(fresh.map(\.id))
        folded = folded.intersection(ids)
        if let selection, !ids.contains(selection.entry) { self.selection = nil }
        // The focused file opens unfolded: the user tapped it to read it.
        for entry in fresh where old[entry.id] == nil && (listLoaded || entry.id != focus)
            && (ReviewLayout.startsFolded(path: entry.id.path, add: entry.add, del: entry.del) || marks.hasMark(entry.id)) {
            folded.insert(entry.id)
        }
        listLoaded = true
        listError = nil
        for id in refetch { Task { await fetch(id) } }
    }

    // MARK: Diffs

    private func index(_ id: ReviewEntryID) -> Int? { entries.firstIndex { $0.id == id } }

    private func diffKey(_ id: ReviewEntryID) -> DiffKey {
        switch source {
        case .localChanges: DiffKey(path: id.path, stage: id.namespace)
        case .branchChanges: DiffKey(path: id.path, stage: nil)
        case .commit(let sha): DiffKey(path: id.path, stage: nil, sha: sha)
        }
    }

    /// Fetches the entry's diff the first time it's asked for.
    func load(_ id: ReviewEntryID) {
        guard let i = index(id), entries[i].content == .notLoaded else { return }
        entries[i].content = .loading
        Task { await fetch(id) }
    }

    /// Fetches the entry's diff; what it showed stays until the reply.
    private func fetch(_ id: ReviewEntryID) async {
        let result = await workspace.loadDiff(diffKey(id))
        guard let i = index(id) else { return }
        let content: ReviewEntryContent = switch result {
        case .success(let reply) where reply.hunks.isEmpty && reply.metadataNote != nil: .note(reply.metadataNote ?? "")
        case .success(let reply): .hunks(reply.hunks, truncated: reply.truncated)
        case .failure(let failure): .note(failure.message)
        }
        let hash = ReviewViewedMarks.hash(of: Self.hunks(content))
        hashes[id] = hash
        // Its line indexes point into the old diff.
        if selection?.entry == id, entries[i].content != content { selection = nil }
        entries[i].content = content
        if case .failure = result {
            // No diff, so nothing to mark or to check a mark against; a tick waiting on it lapses.
            if pendingViewed.remove(id) != nil { folded.remove(id) }
        } else if pendingViewed.remove(id) != nil {
            setViewed(id, hash: hash)
        } else if marks.hasMark(id), !marks.isViewed(id, hash: hash) {
            marks.unmark(id)
            ReviewPreferences.shared.save(marks, for: scope)
            folded.remove(id)
        }
        tokenize(entries[i])
    }

    private static func hunks(_ content: ReviewEntryContent) -> [RemoteDiffHunk] {
        if case .hunks(let hunks, _) = content { return hunks }
        return []
    }

    // MARK: Viewed and folded

    /// Viewed, or taken to be while its diff is still unread.
    func isViewed(_ entry: ReviewEntry) -> Bool {
        switch entry.content {
        case .notLoaded, .loading: marks.hasMark(entry.id) || pendingViewed.contains(entry.id)
        case .hunks, .note: marks.isViewed(entry.id, hash: hashes[entry.id] ?? "")
        }
    }

    func toggleViewed(_ id: ReviewEntryID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        if isViewed(entry) {
            pendingViewed.remove(id)
            marks.unmark(id)
            ReviewPreferences.shared.save(marks, for: scope)
            folded.remove(id)
            return
        }
        switch entry.content {
        case .hunks, .note:
            setViewed(id, hash: hashes[id] ?? "")
        case .notLoaded, .loading:
            // The mark needs the diff's hash.
            pendingViewed.insert(id)
            folded.insert(id)
            load(id)
        }
    }

    private func setViewed(_ id: ReviewEntryID, hash: String) {
        marks.mark(id, hash: hash)
        ReviewPreferences.shared.save(marks, for: scope)
        folded.insert(id)
    }

    func toggleFolded(_ id: ReviewEntryID) {
        if folded.remove(id) == nil { folded.insert(id) }
    }

    var allFolded: Bool { !entries.isEmpty && folded.count == entries.count }

    func toggleFoldAll() {
        folded = allFolded ? [] : Set(entries.map(\.id))
    }

    // MARK: Hunks

    /// As the Mac: stage or discard from the unstaged diff, unstage from the staged one.
    func hunkActions(_ id: ReviewEntryID) -> [RemoteHunkAction] {
        guard source == .localChanges, workspace.canChangeHunks else { return [] }
        switch id.namespace {
        case "unstaged": return [.stage, .discard]
        case "staged": return [.unstage]
        default: return []
        }
    }

    var gitBusy: Bool { workspace.gitRunning != nil }

    func changeHunk(_ action: RemoteHunkAction, entry id: ReviewEntryID, index: Int, _ hunk: RemoteDiffHunk) async {
        if let message = await workspace.changeHunk(action, index: index, hunk, in: diffKey(id)) { error = message }
        // The hunk moves between the staged and unstaged entries.
        await refresh()
    }

    // MARK: Comments

    /// Where comments go: the worktree's local-changes review. Branch changes and commits take none,
    /// as no Mac review files comments under their entries.
    var reviewSessionID: String? {
        source == .localChanges && workspace.canReview ? workspace.localChangesReviewID : nil
    }

    func loadComments() async {
        guard let session = reviewSessionID else { return }
        // ponytail: a failed read keeps the comments shown; the next refresh tries again.
        if case .success(let review) = await workspace.review(session) { comments = review.comments }
    }

    func select(_ entry: ReviewEntryID, hunk: Int, line: Int) {
        selection = ReviewSelection(entry: entry, hunk: hunk, line: line)
    }

    /// Ignored outside the selection's hunk: a range never spans hunks or files.
    func extendSelection(_ entry: ReviewEntryID, hunk: Int, line: Int) {
        guard selection?.entry == entry else { return }
        selection?.extend(to: line, inHunk: hunk)
    }

    /// A gutter tap: extends the selection within its hunk, else starts one; tapping the only selected line clears it.
    func tapLine(_ entry: ReviewEntryID, hunk: Int, line: Int) {
        guard let current = selection, current.entry == entry, current.hunk == hunk else {
            return select(entry, hunk: hunk, line: line)
        }
        if current.start == line, current.end == line { selection = nil } else { extendSelection(entry, hunk: hunk, line: line) }
    }

    /// Opens the comment sheet on the selection, if its lines are still in the diff.
    func composeSelection() {
        guard let selection else { return }
        let hunks = entries.first { $0.id == selection.entry }.map { Self.hunks($0.content) } ?? []
        guard selection.isValid(in: hunks) else {
            self.selection = nil
            return
        }
        let hunk = hunks[selection.hunk]
        let anchor = selection.anchor(in: hunk)
        guard case .line(_, let start, let end) = anchor else { return }
        let title = end.map { "Lines \(start)\u{2013}\($0)" } ?? "Line \(start)"
        composing = .lines(selection.entry, anchor, title: title, quote: selection.quotedText(in: hunk))
    }

    func comment(on entry: ReviewEntryID, anchor: RemoteReviewAnchor, body: String) async {
        guard let session = reviewSessionID else { return }
        if let message = await workspace.comment(in: session, entry: entry, anchor: anchor, body: body) {
            error = message
            return
        }
        await loadComments()
        if case .line = anchor { selection = nil }
    }

    func change(_ mutation: RemoteReviewMutation) async {
        guard let session = reviewSessionID else { return }
        if let message = await workspace.changeReview(session, mutation) { error = message }
        await loadComments()
    }

    // MARK: Syntax

    func spanKey(_ entry: ReviewEntry) -> String? {
        guard case .hunks = entry.content, let hash = hashes[entry.id] else { return nil }
        return entry.id.path + "\u{1F}" + hash
    }

    /// Tokenizes the entry's lines off the main actor, once per diff text.
    private func tokenize(_ entry: ReviewEntry) {
        guard let key = spanKey(entry), spans[key] == nil, !spansInFlight.contains(key) else { return }
        spansInFlight.insert(key)
        let lines = Self.hunks(entry.content).flatMap(\.lines).map(\.text)
        let path = entry.id.path
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                DiffHunksView.spans(forLines: lines, path: path)
            }.value
            spansInFlight.remove(key)
            spans[key] = found
        }
    }
}
