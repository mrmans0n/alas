import Foundation
import Observation

/// A worktree the search dialog can target. Decoupled from `Worktree` so
/// the model is testable without the full `AppState`.
struct SearchWorktree: Equatable, Sendable, Identifiable {
    let id: String
    let projectId: String
    let displayName: String
    let absolutePath: URL
}

/// All inputs SearchModel needs from the rest of the app, isolated for
/// testing. Closures capture `AppState` in production wiring.
struct SearchEnvironment: Sendable {
    var currentWorktreeId: @Sendable () -> String?
    var allWorktrees: @Sendable () -> [SearchWorktree]
    var entries: @Sendable (SearchWorktree) async throws -> [FileIndex.Entry]
    var statuses: @Sendable (SearchWorktree) async throws -> [String: GitStatusBadge]
    var contentSearch: @Sendable (
        String, SearchContentOptions, [SearchWorktree]
    ) -> AsyncThrowingStream<ContentSearchHit, Error>
}

struct SearchContentOptions: Equatable, Sendable {
    var caseSensitive: Bool = false
    var wholeWord: Bool = false
    var regex: Bool = false
}

/// Bundle of what the dialog renders — keeps the model's published surface
/// to one type so views observe a single property.
struct SearchResults: Equatable, Sendable {
    var fileResults: [FileSearchResult] = []
    var contentGroups: [ContentSearchGroup] = []
    /// Set when at least one worktree's enumeration failed in `.allRepos`.
    /// Rendered as an inline banner above results.
    var partialFailureMessage: String? = nil
}

@Observable
@MainActor
final class SearchModel {
    var isOpen: Bool = false
    // didSets gate on `isOpen` so that the resets in `close()` (which set
    // these properties back to defaults) don't kick off a debounced search
    // for a hidden dialog. `open()` calls `reschedule()` explicitly after
    // seeding all the defaults.
    var query: String = "" {
        didSet { if isOpen { onQueryChanged() } }
    }
    var contentOptions: SearchContentOptions = SearchContentOptions() {
        didSet { if kind == .content { reschedule() } }
    }
    var kind: SearchKind = .files {
        didSet { if isOpen { reschedule() } }
    }
    var scope: SearchScope = .thisWorktree {
        didSet { if isOpen { reschedule() } }
    }
    var selectedIndex: Int = 0
    /// Bumped when selection moves via keyboard. The dialog scrolls to
    /// `selectedIndex` on changes to this, not on `selectedIndex` itself, so
    /// hover-driven selection updates don't trigger scroll-to-center and
    /// fight the user's scroll input.
    private(set) var keyboardSelectionTick: Int = 0
    private(set) var results: SearchResults = SearchResults()
    private(set) var isLoading: Bool = false

    func moveSelection(to index: Int) {
        selectedIndex = index
        keyboardSelectionTick &+= 1
    }

    /// Total selectable rows across both modes, used by the view's keyboard
    /// handler to clamp Up/Down. In files mode it's `fileResults.count`; in
    /// content mode it's the total hit count across groups.
    var totalResultRows: Int {
        switch kind {
        case .files:   return results.fileResults.count
        case .content: return results.contentGroups.reduce(0) { $0 + $1.hits.count }
        }
    }

    /// Trimmed query — strips the `> ` prefix used to invoke content mode
    /// and caps length to avoid pathological matching on huge inputs.
    var trimmedQuery: String {
        let stripped = query.hasPrefix("> ") ? String(query.dropFirst(2)) : query
        return stripped.count > 200 ? String(stripped.prefix(200)) : stripped
    }

    private let env: SearchEnvironment
    private var searchTask: Task<Void, Never>?
    private var taskGeneration: Int = 0
    private let fileDebounce: UInt64 = 30_000_000     // 30ms in ns
    private let contentDebounce: UInt64 = 120_000_000 // 120ms in ns
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []

    init(environment: SearchEnvironment) {
        self.env = environment
    }

    func open() {
        isOpen = true
        query = ""
        kind = .files
        selectedIndex = 0
        scope = (env.currentWorktreeId() != nil) ? .thisWorktree : .allRepos
        results = SearchResults()
        reschedule()
    }

    func close() {
        isOpen = false
        searchTask?.cancel()
        searchTask = nil
        results = SearchResults()
        query = ""
    }

    func toggleKind() {
        kind = (kind == .files) ? .content : .files
    }

    /// Awaits the next scheduled search to settle. Test helper.
    func waitForIdle() async {
        if searchTask == nil && !isLoading { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            idleContinuations.append(cont)
        }
    }

    // MARK: - Internals

    private func onQueryChanged() {
        // VSCode-style content-mode prefix.
        if query.hasPrefix("> ") && kind == .files {
            kind = .content
            return // setting kind triggers reschedule
        }
        reschedule()
    }

    private func reschedule() {
        searchTask?.cancel()
        let snapshotKind = kind
        let snapshotScope = scope
        let snapshotQuery = trimmedQuery
        taskGeneration &+= 1
        let myGeneration = taskGeneration

        searchTask = Task { [weak self] in
            guard let self else { return }
            let debounce = (snapshotKind == .files) ? self.fileDebounce : self.contentDebounce
            try? await Task.sleep(nanoseconds: debounce)
            if Task.isCancelled { return }
            await self.runSearch(kind: snapshotKind, scope: snapshotScope, query: snapshotQuery)
            if Task.isCancelled { return }
            self.signalIdle()
            // Only clear if no newer reschedule has supplanted this one.
            if self.taskGeneration == myGeneration {
                self.searchTask = nil
            }
        }
    }

    private func runSearch(kind: SearchKind, scope: SearchScope, query: String) async {
        isLoading = true
        defer { isLoading = false }

        let targets: [SearchWorktree]
        switch scope {
        case .thisWorktree:
            if let id = env.currentWorktreeId(),
               let wt = env.allWorktrees().first(where: { $0.id == id }) {
                targets = [wt]
            } else {
                targets = []
            }
        case .allRepos:
            targets = env.allWorktrees()
        }

        switch kind {
        case .files:
            await runFileSearch(query: query, targets: targets)
        case .content:
            await runContentSearch(query: query, targets: targets)
        }

        if selectedIndex >= totalResultRows {
            selectedIndex = 0
        }
    }

    private func runFileSearch(query: String, targets: [SearchWorktree]) async {
        var rows: [FileSearchResult] = []
        var failures: [String] = []
        var sinceCancelCheck = 0
        for wt in targets {
            do {
                async let entriesTask = env.entries(wt)
                async let statusTask = env.statuses(wt)
                let entries = try await entriesTask
                let statuses = (try? await statusTask) ?? [:]
                if Task.isCancelled { return }

                for entry in entries {
                    // Cooperative cancellation inside the scoring loop —
                    // a large worktree (or `.allRepos`) can have tens of
                    // thousands of entries; without periodic checks a
                    // stale task keeps scoring and overwrites a newer
                    // task's results when it eventually publishes.
                    sinceCancelCheck &+= 1
                    if sinceCancelCheck >= 256 {
                        sinceCancelCheck = 0
                        if Task.isCancelled { return }
                    }
                    let badge = statuses[entry.relativePath]
                    if query.isEmpty {
                        rows.append(FileSearchResult(
                            worktreeId: wt.id,
                            projectId: wt.projectId,
                            relativePath: entry.relativePath,
                            ext: entry.ext,
                            statusBadge: badge,
                            matchIndices: [],
                            score: badge != nil ? 100 : 0
                        ))
                    } else if let m = FuzzyMatch.score(query: query, target: entry.relativePath) {
                        let slash = entry.relativePath.lastIndex(of: "/")
                        let prefixLen = slash.map { entry.relativePath.distance(from: entry.relativePath.startIndex, to: $0) + 1 } ?? 0
                        let inName = m.indices.allSatisfy { $0 >= prefixLen }
                        let score = m.score + (inName ? 8 : 0) + (badge != nil ? 2 : 0)
                        rows.append(FileSearchResult(
                            worktreeId: wt.id,
                            projectId: wt.projectId,
                            relativePath: entry.relativePath,
                            ext: entry.ext,
                            statusBadge: badge,
                            matchIndices: m.indices,
                            score: score
                        ))
                    }
                }
            } catch {
                failures.append(wt.displayName)
            }
        }

        if query.isEmpty {
            // Status-tagged files first, then alphabetical.
            rows.sort { lhs, rhs in
                if (lhs.statusBadge != nil) != (rhs.statusBadge != nil) {
                    return lhs.statusBadge != nil
                }
                return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
        } else {
            rows.sort { $0.score > $1.score }
        }

        let capped = Array(rows.prefix(50))
        // Final cancellation check before publishing — stops a stale task
        // from clobbering a newer query's results during the time we spent
        // sorting/capping.
        if Task.isCancelled { return }
        results = SearchResults(
            fileResults: capped,
            contentGroups: [],
            partialFailureMessage: failures.isEmpty
                ? nil
                : "Couldn't read files for \(failures.joined(separator: ", "))"
        )
    }

    private func runContentSearch(query: String, targets: [SearchWorktree]) async {
        // Empty content queries match everything; rg would scan the whole
        // worktree for nothing useful. Short-circuit to a clean state so the
        // empty-state copy renders instead.
        guard !query.isEmpty else {
            results = SearchResults()
            return
        }

        // Validate regex up-front when the toggle is on. rg's exit-2 covers
        // both regex syntax errors and soft I/O errors, so the `rgFailed`
        // catch can't tell them apart — surfacing the regex error here lets
        // that catch stay generic for genuine I/O issues. NSRegularExpression
        // is ICU-regex; rg uses Rust's regex crate. Most simple patterns
        // (`[`, `(`, `\?`) are flagged identically; for exotic features
        // they may diverge, in which case this just falls through to rg.
        if contentOptions.regex {
            do {
                _ = try NSRegularExpression(pattern: query, options: [])
            } catch {
                results = SearchResults(
                    fileResults: [],
                    contentGroups: [],
                    partialFailureMessage: "Invalid regex pattern."
                )
                return
            }
        }

        // Caps
        let maxHits  = 200
        let maxFiles = 50
        let partialEvery = 25

        // Map from group key to index in `groups` (preserves encounter order).
        var groupIndex: [String: Int] = [:]
        // Accumulated groups, in encounter order.
        var groups: [ContentSearchGroup] = []
        var totalHits = 0

        do {
            let stream = env.contentSearch(query, contentOptions, targets)
            for try await hit in stream {
                if Task.isCancelled { return }

                let key = hit.groupKey
                if let idx = groupIndex[key] {
                    groups[idx].hits.append(hit)
                } else if groups.count < maxFiles {
                    let newGroup = ContentSearchGroup(
                        worktreeId: hit.worktreeId,
                        projectId: hit.projectId,
                        relativePath: hit.relativePath,
                        hits: [hit]
                    )
                    groupIndex[key] = groups.count
                    groups.append(newGroup)
                }
                // Always count toward totalHits — including hits dropped
                // because they belong to a new file past the file cap. Without
                // this, `maxHits` never fires for broad searches and we drain
                // the entire rg stream after the UI is already capped.
                totalHits += 1

                // Push partial results every 25 hits so the UI animates.
                if totalHits % partialEvery == 0 {
                    results = SearchResults(
                        fileResults: [],
                        contentGroups: groups,
                        partialFailureMessage: nil
                    )
                }

                if totalHits >= maxHits { break }
            }
            // Final flush — but only if we haven't been superseded by a
            // newer query. Otherwise the about-to-be-overwritten newer
            // task's results would be clobbered with our stale snapshot.
            if Task.isCancelled { return }
            results = SearchResults(
                fileResults: [],
                contentGroups: groups,
                partialFailureMessage: nil
            )
        } catch ContentSearcher.SearchError.rgNotFound {
            results = SearchResults(
                fileResults: [],
                contentGroups: [],
                partialFailureMessage: "Install ripgrep (`brew install ripgrep`) to enable content search."
            )
        } catch ContentSearcher.SearchError.regexInvalid {
            // rg's stderr-detected regex parse error — covers patterns
            // that the up-front NSRegularExpression preflight accepted
            // but rg's Rust regex rejects (look-around, backrefs).
            results = SearchResults(
                fileResults: [],
                contentGroups: [],
                partialFailureMessage: "Invalid regex pattern."
            )
        } catch ContentSearcher.SearchError.rgFailed {
            // ripgrep exit 2 covers both regex-syntax errors and soft I/O
            // errors (unreadable file, permission denied, etc.) — see
            // `rg --generate man`. Regex errors are caught up-front by the
            // NSRegularExpression validation above, so by the time we reach
            // here it's effectively always a soft I/O failure. Preserve any
            // hits accumulated from earlier files.
            let message = groups.isEmpty
                ? "Content search failed."
                : "Some files couldn't be searched."
            results = SearchResults(
                fileResults: [],
                contentGroups: groups,
                partialFailureMessage: message
            )
        } catch is CancellationError {
            // A newer keystroke superseded this query — let the new task
            // own `results`. Don't surface a banner.
            return
        } catch {
            // Flush whatever was accumulated so far.
            results = SearchResults(
                fileResults: [],
                contentGroups: groups,
                partialFailureMessage: "Content search interrupted."
            )
        }
    }

    private func signalIdle() {
        let conts = idleContinuations
        idleContinuations.removeAll()
        for c in conts { c.resume() }
    }
}
