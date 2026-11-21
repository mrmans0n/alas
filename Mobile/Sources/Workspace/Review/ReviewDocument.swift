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
    /// A hunk action's refusal.
    var error: String?
    private(set) var listLoaded = false
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
            replace(with: cached)
        } else {
            await refresh()
        }
    }

    private func cachedFiles() -> [ReviewEntry]? {
        switch source {
        case .localChanges, .branchChanges:
            if case .loaded(let reply) = workspace.changes { return entries(from: reply) }
        case .commit(let sha):
            if let open = workspace.commit, open.commit.revision == sha, case .loaded(let reply) = open.1 {
                return entries(from: reply.files, namespace: "commit")
            }
        }
        return nil
    }

    private func fetchFiles() async -> Result<[ReviewEntry], RemoteGitFailure> {
        switch source {
        case .localChanges, .branchChanges: await workspace.loadChanges().map(entries(from:))
        case .commit(let sha): await workspace.loadCommitFiles(sha).map { entries(from: $0.files, namespace: "commit") }
        }
    }

    private func entries(from reply: ChangeListReply) -> [ReviewEntry] {
        source == .branchChanges ? entries(from: reply.files, namespace: "branch")
            : entries(from: reply.staged, namespace: "staged") + entries(from: reply.unstaged, namespace: "unstaged")
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
            replace(with: fresh)
        }
    }

    /// Takes `fresh` in the host's order, which keeps the order of the paths both lists hold.
    private func replace(with fresh: [ReviewEntry]) {
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
        for entry in fresh where old[entry.id] == nil
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
        entries[i].content = content
        let hunks = Self.hunks(content)
        if pendingViewed.remove(id) != nil {
            setViewed(id, hunks: hunks)
        } else if marks.hasMark(id), !marks.isViewed(id, hunks: hunks) {
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
        case .hunks(let hunks, _): marks.isViewed(entry.id, hunks: hunks)
        case .note: marks.isViewed(entry.id, hunks: [])
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
            setViewed(id, hunks: Self.hunks(entry.content))
        case .notLoaded, .loading:
            // The mark needs the diff's hash.
            pendingViewed.insert(id)
            folded.insert(id)
            load(id)
        }
    }

    private func setViewed(_ id: ReviewEntryID, hunks: [RemoteDiffHunk]) {
        marks.mark(id, hunks: hunks)
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

    // MARK: Syntax

    func spanKey(_ entry: ReviewEntry) -> String? {
        guard case .hunks(let hunks, _) = entry.content else { return nil }
        return entry.id.path + "\u{1F}" + ReviewViewedMarks.hash(of: hunks)
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
