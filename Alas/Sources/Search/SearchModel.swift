import Foundation
import Observation

/// A worktree the search dialog can target. Decoupled from `Worktree` so
/// the model is testable without the full `AppState`.
struct SearchWorktree: Equatable, Sendable, Identifiable {
    let id: String
    let projectId: String
    let displayName: String
    let absolutePath: URL
    var executionLocation: ExecutionLocation? = nil
    var workspaceCheckoutMemberID: UUID? = nil

    var remoteHost: String? {
        switch executionLocation?.normalized {
        case .some(.local):
            return nil
        case .some(.ssh(let host)):
            return host
        case nil:
            return RemoteHostRegistry.shared.host(forPath: absolutePath.path)
        }
    }

    var usesRemoteHostRegistry: Bool {
        executionLocation == nil
    }

    var cacheKey: String {
        if let remoteHost {
            return "ssh:\(remoteHost):\(absolutePath.path)"
        }
        return "local:\(absolutePath.path)"
    }
}

/// All inputs SearchModel needs from the rest of the app, isolated for
/// testing. Closures capture `AppState` in production wiring.
struct SearchEnvironment: Sendable {
    var currentWorktreeId: @Sendable () -> String?
    var allWorktrees: @Sendable () -> [SearchWorktree]
    var entries: @Sendable (SearchWorktree) async throws -> [FileIndex.Entry]
    var statuses: @Sendable (SearchWorktree) async throws -> [String: GitStatusBadge]
    var workspaceCheckoutWorktrees: @Sendable () -> [SearchWorktree] = { [] }
    var fileSearch: @Sendable (String, SearchWorktree) async throws -> [FileSearchBackendResult]?
    var rankFiles: @Sendable (
        String, [FileSearchRankingSource]
    ) async throws -> [FileSearchResult]
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
        didSet { if isOpen && kind == .content { reschedule() } }
    }
    var kind: SearchKind = .files {
        didSet { if isOpen { reschedule() } }
    }
    var scope: SearchScope = .thisWorktree {
        didSet { if isOpen { reschedule() } }
    }
    var selectedIndex: Int = 0
    /// Bumped when selection moves deliberately (keyboard nav, or the
    /// post-search clamp that pulls a stale out-of-range selection back to
    /// row 0). The dialog scrolls to `selectedIndex` on changes to this, not
    /// on `selectedIndex` itself, so hover-driven selection updates don't
    /// trigger scroll-to-center and fight the user's scroll input.
    private(set) var scrollToSelectionTick: Int = 0
    private(set) var results: SearchResults = SearchResults()
    private(set) var isLoading: Bool = false

    func moveSelection(to index: Int) {
        selectedIndex = index
        scrollToSelectionTick &+= 1
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
        if !env.workspaceCheckoutWorktrees().isEmpty {
            scope = .workspaceCheckout
        } else {
            scope = (env.currentWorktreeId() != nil) ? .thisWorktree : .allRepos
        }
        results = SearchResults()
        reschedule()
    }

    func close() {
        isOpen = false
        taskGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        isLoading = false
        results = SearchResults()
        query = ""
        signalIdle()
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
        let snapshotContentOptions = contentOptions
        taskGeneration &+= 1
        let myGeneration = taskGeneration

        searchTask = Task { [weak self] in
            guard let self else { return }
            let debounce = (snapshotKind == .files) ? self.fileDebounce : self.contentDebounce
            try? await Task.sleep(nanoseconds: debounce)
            if Task.isCancelled { return }
            await self.runSearch(
                kind: snapshotKind,
                scope: snapshotScope,
                query: snapshotQuery,
                contentOptions: snapshotContentOptions,
                taskGeneration: myGeneration
            )
        }
    }

    private func runSearch(
        kind: SearchKind,
        scope: SearchScope,
        query: String,
        contentOptions: SearchContentOptions,
        taskGeneration: Int
    ) async {
        guard isCurrent(taskGeneration) else { return }
        isLoading = true

        let targets: [SearchWorktree]
        switch scope {
        case .thisWorktree:
            if let id = env.currentWorktreeId(),
               let wt = env.allWorktrees().first(where: { $0.id == id }) {
                targets = [wt]
            } else {
                targets = []
            }
        case .workspaceCheckout:
            targets = env.workspaceCheckoutWorktrees()
        case .allRepos:
            targets = env.allWorktrees()
        }

        switch kind {
        case .files:
            await runFileSearch(query: query, targets: targets, taskGeneration: taskGeneration)
        case .content:
            await runContentSearch(
                query: query,
                options: contentOptions,
                targets: targets,
                taskGeneration: taskGeneration
            )
        }

        guard isCurrent(taskGeneration) else { return }
        if selectedIndex >= totalResultRows {
            moveSelection(to: 0)
        }
        isLoading = false
        searchTask = nil
        signalIdle()
    }

    private func runFileSearch(
        query: String,
        targets: [SearchWorktree],
        taskGeneration: Int
    ) async {
        var sources: [FileSearchRankingSource] = []
        var failures: [String] = []
        for wt in targets {
            async let statusTask = env.statuses(wt)
            async let entriesTask = env.entries(wt)
            let backendResults: [FileSearchBackendResult]?
            if Self.canUseFileSearchBackend(query: query) {
                backendResults = try? await env.fileSearch(query, wt)
            } else {
                backendResults = nil
            }
            let entries: [FileIndex.Entry]
            do {
                entries = try await entriesTask
            } catch {
                failures.append(wt.displayName)
                entries = []
            }
            let statuses = (try? await statusTask) ?? [:]
            sources.append(FileSearchRankingSource(
                worktreeId: wt.id,
                projectId: wt.projectId,
                workspaceCheckoutMemberID: wt.workspaceCheckoutMemberID,
                entries: entries,
                backendResults: backendResults,
                statuses: statuses
            ))
        }

        guard let rows = try? await env.rankFiles(query, sources) else { return }
        publish(SearchResults(
            fileResults: rows,
            contentGroups: [],
            partialFailureMessage: failures.isEmpty
                ? nil
                : "Couldn't read files for \(failures.joined(separator: ", "))"
        ), taskGeneration: taskGeneration)
    }

    private static func canUseFileSearchBackend(query: String) -> Bool {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .contains { $0.count >= 2 }
    }

    private func runContentSearch(
        query: String,
        options: SearchContentOptions,
        targets: [SearchWorktree],
        taskGeneration: Int
    ) async {
        // Empty content queries match everything; rg would scan the whole
        // worktree for nothing useful. Short-circuit to a clean state so the
        // empty-state copy renders instead.
        guard !query.isEmpty else {
            publish(SearchResults(), taskGeneration: taskGeneration)
            return
        }

        // Validate regex up-front when the toggle is on. rg's exit-2 covers
        // both regex syntax errors and soft I/O errors, so the `rgFailed`
        // catch can't tell them apart — surfacing the regex error here lets
        // that catch stay generic for genuine I/O issues. NSRegularExpression
        // is ICU-regex; rg uses Rust's regex crate. Most simple patterns
        // (`[`, `(`, `\?`) are flagged identically; for exotic features
        // they may diverge, in which case this just falls through to rg.
        if options.regex {
            do {
                _ = try NSRegularExpression(pattern: query, options: [])
            } catch {
                publish(SearchResults(
                    fileResults: [],
                    contentGroups: [],
                    partialFailureMessage: "Invalid regex pattern."
                ), taskGeneration: taskGeneration)
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
            let stream = env.contentSearch(query, options, targets)
            for try await hit in stream {
                guard isCurrent(taskGeneration) else { return }

                let key = hit.groupKey
                if let idx = groupIndex[key] {
                    groups[idx].hits.append(hit)
                } else if groups.count < maxFiles {
                    let newGroup = ContentSearchGroup(
                        worktreeId: hit.worktreeId,
                        projectId: hit.projectId,
                        workspaceCheckoutMemberID: hit.workspaceCheckoutMemberID,
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
                    publish(SearchResults(
                        fileResults: [],
                        contentGroups: groups,
                        partialFailureMessage: nil
                    ), taskGeneration: taskGeneration)
                }

                if totalHits >= maxHits { break }
            }
            publish(SearchResults(
                fileResults: [],
                contentGroups: groups,
                partialFailureMessage: nil
            ), taskGeneration: taskGeneration)
        } catch ContentSearcher.SearchError.rgNotFound {
            publish(SearchResults(
                fileResults: [],
                contentGroups: [],
                partialFailureMessage: "Install ripgrep (`brew install ripgrep`) to enable content search."
            ), taskGeneration: taskGeneration)
        } catch ContentSearcher.SearchError.regexInvalid {
            // rg's stderr-detected regex parse error — covers patterns
            // that the up-front NSRegularExpression preflight accepted
            // but rg's Rust regex rejects (look-around, backrefs).
            publish(SearchResults(
                fileResults: [],
                contentGroups: [],
                partialFailureMessage: "Invalid regex pattern."
            ), taskGeneration: taskGeneration)
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
            publish(SearchResults(
                fileResults: [],
                contentGroups: groups,
                partialFailureMessage: message
            ), taskGeneration: taskGeneration)
        } catch is CancellationError {
            // A newer keystroke superseded this query — let the new task
            // own `results`. Don't surface a banner.
            return
        } catch {
            // Flush whatever was accumulated so far.
            publish(SearchResults(
                fileResults: [],
                contentGroups: groups,
                partialFailureMessage: "Content search interrupted."
            ), taskGeneration: taskGeneration)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        isOpen && taskGeneration == generation
    }

    private func publish(_ newResults: SearchResults, taskGeneration generation: Int) {
        guard isCurrent(generation) else { return }
        results = newResults
    }

    private func signalIdle() {
        let conts = idleContinuations
        idleContinuations.removeAll()
        for c in conts { c.resume() }
    }
}
