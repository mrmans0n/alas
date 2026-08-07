import Foundation
import Observation

/// State + logic for the review target palette (⇧⌘R). Level 1 lists the
/// active project's worktrees; level 2 lists a worktree's commits-ahead
/// (with range-anchor selection) and local branches. View-agnostic; all
/// external reads go through `ReviewTargetPaletteEnvironment` so the model
/// is unit-testable (same pattern as `RepoSelectorModel`).
@Observable
@MainActor
final class ReviewTargetPaletteModel {
    enum Level: Equatable {
        case worktrees
        case targets(Worktree)
    }

    struct WorktreeEntry: Equatable, Identifiable {
        var id: String { worktree.id }
        let worktree: Worktree
        let isCurrent: Bool
        let aheadCount: Int?
        let comparisonRef: String?
    }

    enum TargetRow: Equatable {
        case header(String)
        case followedRevision(expression: String, resolvedSHA: String, branch: String, headSHA: String)
        case commit(CommitInfo)
        case branch(String)
        case message(String)

        var isSelectable: Bool {
            switch self {
            case .followedRevision, .commit, .branch: return true
            case .header, .message: return false
            }
        }

        /// Stable, content-derived identity for SwiftUI list rows. Must not be
        /// the row's position: a positional id lets LazyVStack cache a row and
        /// never rebuild it when the filtered content at that position changes,
        /// freezing stale rows (see FileSearchDialog for the full rationale).
        var stableId: String {
            switch self {
            case .header(let title):  return "header:\(title)"
            case .followedRevision(let expression, let resolvedSHA, let branch, let headSHA):
                return "followed:\(expression):\(resolvedSHA):\(branch):\(headSHA)"
            case .commit(let commit): return "commit:\(commit.sha)"
            case .branch(let name):   return "branch:\(name)"
            case .message(let text):  return "message:\(text)"
            }
        }
    }

    private(set) var level: Level = .worktrees
    /// False when opened pre-drilled from the ReviewChanges toolbar: Esc
    /// closes instead of backing out to a worktree list the user never saw.
    private(set) var canGoBack = true
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            // Level 2 always has a non-selectable `Commits` header at row 0
            // (see `targetRows()`); snapping blindly to 0 after a filter
            // keystroke would land a following Enter on that header instead
            // of the first matching commit/branch. Level 1 has no header
            // rows, so 0 is already a real, selectable entry there.
            if case .targets = level {
                followedRevisionRow = nil
                revisionValidationError = nil
                setSelectedIndex(0, selectable: targetRows().map(\.isSelectable))
            } else {
                selectedIndex = 0
            }
            scrollToSelectionTick &+= 1
        }
    }
    private(set) var selectedIndex = 0
    /// Bumped by keyboard navigation so the view scrolls the selection into
    /// view without fighting hover-driven selection (see RepoSelectorModel).
    private(set) var scrollToSelectionTick = 0
    private(set) var rangeAnchor: CommitInfo?
    private(set) var launchError: String?

    // Level 1 metrics, keyed by worktree id. nil = still loading/unavailable.
    private(set) var aheadCounts: [String: Int] = [:]
    private(set) var comparisonRefs: [String: String] = [:]

    // Level 2 data for the drilled worktree.
    private(set) var commits: [CommitInfo] = []
    private(set) var branches: [String] = []
    private(set) var isLoadingTargets = false
    private(set) var targetsError: String?
    private(set) var followedRevisionRow: TargetRow?
    private(set) var revisionValidationError: String?
    private var revisionValidationToken = UUID()

    // MARK: - Lifecycle

    func open() {
        reset()
        level = .worktrees
        canGoBack = true
    }

    func open(prefill worktree: Worktree) {
        reset()
        level = .targets(worktree)
        canGoBack = false
    }

    func close() {
        reset()
        level = .worktrees
    }

    private func reset() {
        query = ""
        selectedIndex = 0
        rangeAnchor = nil
        launchError = nil
        commits = []
        branches = []
        targetsError = nil
        isLoadingTargets = false
        followedRevisionRow = nil
        revisionValidationError = nil
        aheadCounts = [:]
        comparisonRefs = [:]
    }

    // MARK: - Level 1 rows

    func worktreeEntries(environment env: ReviewTargetPaletteEnvironment) -> [WorktreeEntry] {
        let currentId = env.currentWorktreeId()
        let all = env.worktrees()
        func entry(_ worktree: Worktree) -> WorktreeEntry {
            WorktreeEntry(
                worktree: worktree,
                isCurrent: worktree.id == currentId,
                aheadCount: aheadCounts[worktree.id],
                comparisonRef: comparisonRefs[worktree.id]
            )
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return all
                .sorted { a, b in
                    if (a.id == currentId) != (b.id == currentId) { return a.id == currentId }
                    return a.branch.localizedCaseInsensitiveCompare(b.branch) == .orderedAscending
                }
                .map(entry)
        }
        return all
            .compactMap { worktree -> (Worktree, Double)? in
                if let r = FuzzyMatch.score(query: trimmed, target: worktree.branch) {
                    return (worktree, r.score)
                }
                if let r = FuzzyMatch.score(query: trimmed, target: worktree.name) {
                    return (worktree, r.score - 1)
                }
                return nil
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.branch.localizedCaseInsensitiveCompare(b.0.branch) == .orderedAscending
            }
            .map { entry($0.0) }
    }

    // MARK: - Level 2 rows

    func targetRows() -> [TargetRow] {
        guard case .targets = level else { return [] }
        if isLoadingTargets { return [.message("Loading commits…")] }
        var rows: [TargetRow] = []
        let revisionExpression = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let followedRevisionRow,
           case .followedRevision(let expression, _, _, _) = followedRevisionRow,
           expression == revisionExpression {
            rows.append(.header("Followed Revision"))
            rows.append(followedRevisionRow)
        }
        if let targetsError {
            rows.append(.message(targetsError))
            return rows
        }
        rows.append(.header("Commits"))
        let filteredCommits = ReviewScopeSelection.filteredCommits(commits, query: query)
        if filteredCommits.isEmpty {
            rows.append(.message(
                commits.isEmpty
                    ? "No commits ahead of the base branch"
                    : "No commits match the filter"
            ))
        } else {
            rows.append(contentsOf: filteredCommits.map(TargetRow.commit))
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredBranches = needle.isEmpty
            ? branches
            : branches.filter { $0.lowercased().contains(needle) }
        if !filteredBranches.isEmpty {
            rows.append(.header("Branches"))
            rows.append(contentsOf: filteredBranches.map(TargetRow.branch))
        }
        if let revisionValidationError, rows.filter(\.isSelectable).isEmpty {
            rows.append(.message(revisionValidationError))
        }
        return rows
    }

    // MARK: - Selection

    func moveSelection(step: Int, selectable: [Bool]) {
        var i = selectedIndex + step
        while i >= 0 && i < selectable.count {
            if selectable[i] {
                selectedIndex = i
                scrollToSelectionTick &+= 1
                return
            }
            i += step
        }
    }

    /// Extends a commit-range selection from the current commit to the next
    /// visible commit. Returns true when the key press was consumed, including
    /// the edge where there is no further commit in that direction.
    @discardableResult
    func extendCommitRangeSelection(step: Int) -> Bool {
        guard step != 0, case .targets = level else { return false }
        let rows = targetRows()
        guard rows.indices.contains(selectedIndex),
              case .commit(let currentCommit) = rows[selectedIndex]
        else { return false }

        var nextIndex = selectedIndex + step
        while rows.indices.contains(nextIndex) {
            switch rows[nextIndex] {
            case .commit:
                if rangeAnchor == nil {
                    rangeAnchor = currentCommit
                }
                selectedIndex = nextIndex
                scrollToSelectionTick &+= 1
                return true
            case .header, .message:
                nextIndex += step
            case .followedRevision, .branch:
                return true
            }
        }
        return true
    }

    /// Set selection directly, snapping forward (then backward) to the
    /// nearest selectable row if the target is not selectable. Used on hover
    /// and by the level-2 default selection.
    func setSelectedIndex(_ index: Int, selectable: [Bool]) {
        guard !selectable.isEmpty else {
            selectedIndex = 0
            return
        }
        let clamped = max(0, min(selectable.count - 1, index))
        if selectable[clamped] {
            selectedIndex = clamped
            return
        }
        var i = clamped + 1
        while i < selectable.count {
            if selectable[i] {
                selectedIndex = i
                return
            }
            i += 1
        }
        i = clamped - 1
        while i >= 0 {
            if selectable[i] {
                selectedIndex = i
                return
            }
            i -= 1
        }
        selectedIndex = clamped
    }

    // MARK: - Level transitions

    func drillIntoSelectedWorktree(environment env: ReviewTargetPaletteEnvironment) {
        guard case .worktrees = level else { return }
        let entries = worktreeEntries(environment: env)
        guard entries.indices.contains(selectedIndex) else { return }
        drill(into: entries[selectedIndex].worktree)
    }

    private func drill(into worktree: Worktree) {
        query = ""
        selectedIndex = 0
        rangeAnchor = nil
        targetsError = nil
        commits = []
        branches = []
        level = .targets(worktree)
        scrollToSelectionTick &+= 1
    }

    /// Returns false when there is nothing to go back to — the caller
    /// should close the palette instead.
    @discardableResult
    func back() -> Bool {
        guard case .targets = level, canGoBack else { return false }
        query = ""
        rangeAnchor = nil
        targetsError = nil
        level = .worktrees
        selectedIndex = 0
        scrollToSelectionTick &+= 1
        return true
    }

    // MARK: - Loading

    func loadWorktreeMetrics(environment env: ReviewTargetPaletteEnvironment) async {
        let worktrees = env.worktrees()
        await withTaskGroup(of: (id: String, count: Int, ref: String?)?.self) { group in
            for worktree in worktrees {
                group.addTask {
                    guard let result = try? await env.loadCommitsAhead(worktree) else { return nil }
                    return (worktree.id, result.commits.count, result.comparisonRef)
                }
            }
            for await item in group {
                guard let item else { continue }
                aheadCounts[item.id] = item.count
                if let ref = item.ref {
                    comparisonRefs[item.id] = ref
                }
            }
        }
    }

    func loadTargets(environment env: ReviewTargetPaletteEnvironment) async {
        guard case .targets(let worktree) = level else { return }
        isLoadingTargets = true
        targetsError = nil
        do {
            async let ahead = env.loadCommitsAhead(worktree)
            async let branchList = env.loadBranches(worktree)
            let (result, loadedBranches) = try await (ahead, branchList)
            guard case .targets(let current) = level, current.id == worktree.id else { return }
            commits = result.commits
            branches = loadedBranches
            aheadCounts[worktree.id] = result.commits.count
            if let ref = result.comparisonRef {
                comparisonRefs[worktree.id] = ref
            }
            isLoadingTargets = false
            let rows = targetRows()
            setSelectedIndex(0, selectable: rows.map(\.isSelectable))
        } catch {
            guard case .targets(let current) = level, current.id == worktree.id else { return }
            targetsError = "Could not load commits: \(error.localizedDescription)"
            isLoadingTargets = false
        }
    }

    /// Surfaces a launch failure from outside the model (e.g. the live
    /// environment's `openTarget` failure path), mirroring how the internal
    /// `launchError` assignments above report resolution failures.
    func presentLaunchError(_ message: String) {
        launchError = message
    }

    // MARK: - Range anchor

    func toggleAnchor(_ commit: CommitInfo) {
        rangeAnchor = (rangeAnchor?.id == commit.id) ? nil : commit
    }

    func isInRangePreview(_ commit: CommitInfo, selected: CommitInfo?) -> Bool {
        guard let anchor = rangeAnchor, let selected else { return false }
        guard let commitIndex = commits.firstIndex(of: commit),
              let anchorIndex = commits.firstIndex(of: anchor),
              let selectedIndex = commits.firstIndex(of: selected)
        else { return false }
        return (min(anchorIndex, selectedIndex) ... max(anchorIndex, selectedIndex))
            .contains(commitIndex)
    }

    // MARK: - Activation

    func activateSelection(environment env: ReviewTargetPaletteEnvironment) async {
        launchError = nil
        switch level {
        case .worktrees:
            let entries = worktreeEntries(environment: env)
            guard entries.indices.contains(selectedIndex) else { return }
            let entry = entries[selectedIndex]
            // Enter reviews the full range vs base in one keystroke — but
            // only when metrics confirm there is something to review and
            // what "base" means. Otherwise drill in so the user sees why.
            guard let ahead = entry.aheadCount, ahead > 0,
                  let comparisonRef = entry.comparisonRef else {
                drill(into: entry.worktree)
                return
            }
            await launchFullRange(worktree: entry.worktree, comparisonRef: comparisonRef, environment: env)
        case .targets(let worktree):
            let rows = targetRows()
            guard rows.indices.contains(selectedIndex) else { return }
            switch rows[selectedIndex] {
            case .followedRevision(let expression, _, _, _):
                await launchFollowedRevision(
                    expression: expression,
                    worktree: worktree,
                    environment: env
                )
            case .commit(let commit):
                launchCommitSelection(commit, worktree: worktree, environment: env)
            case .branch(let name):
                await launchBranch(name, worktree: worktree, environment: env)
            case .header, .message:
                break
            }
        }
    }

    func validateRevisionQuery(environment env: ReviewTargetPaletteEnvironment) async {
        guard case .targets(let worktree) = level else { return }
        let expression = query.trimmingCharacters(in: .whitespacesAndNewlines)
        revisionValidationToken = UUID()
        let token = revisionValidationToken
        followedRevisionRow = nil
        revisionValidationError = nil
        guard !expression.isEmpty else { return }
        do {
            let candidate = try await env.resolveTrackedRevision(worktree, expression)
            guard revisionValidationToken == token,
                  query.trimmingCharacters(in: .whitespacesAndNewlines) == expression,
                  case .targets(let current) = level,
                  current.id == worktree.id
            else { return }
            let previousSelection = targetRows().indices.contains(selectedIndex) ? targetRows()[selectedIndex] : nil
            followedRevisionRow = .followedRevision(
                expression: expression,
                resolvedSHA: candidate.sha,
                branch: candidate.branch,
                headSHA: candidate.headSHA
            )
            preserveSelectionAfterRevisionValidation(previousSelection: previousSelection)
        } catch {
            guard revisionValidationToken == token else { return }
            revisionValidationError = "Could not resolve \(expression): \(error.localizedDescription)"
        }
    }

    private func preserveSelectionAfterRevisionValidation(previousSelection: TargetRow?) {
        let rows = targetRows()
        let selectable = rows.map(\.isSelectable)
        let selectableIndexes = selectable.indices.filter { selectable[$0] }
        if selectableIndexes.count == 1 {
            setSelectedIndex(selectableIndexes[0], selectable: selectable)
            return
        }
        if let previousSelection,
           let preservedIndex = rows.firstIndex(of: previousSelection),
           selectable[preservedIndex] {
            selectedIndex = preservedIndex
            return
        }
        setSelectedIndex(selectedIndex, selectable: selectable)
    }

    private func launchFullRange(
        worktree: Worktree,
        comparisonRef: String,
        environment env: ReviewTargetPaletteEnvironment
    ) async {
        do {
            let headSHA = try await env.headSHA(worktree)
            let baseSHA = try await env.resolveRevision(worktree, comparisonRef)
            let target = ReviewScopeSelection.target(
                for: .branch(name: comparisonRef),
                worktreeID: worktree.id,
                repositoryPath: worktree.path,
                headSHA: headSHA,
                branchBaseSHA: baseSHA
            )
            env.openTarget(target, worktree)
        } catch {
            launchError = "Could not resolve \(comparisonRef): \(error.localizedDescription)"
        }
    }

    private func launchCommitSelection(
        _ commit: CommitInfo,
        worktree: Worktree,
        environment env: ReviewTargetPaletteEnvironment
    ) {
        let choice: ReviewScopeChoice
        if let anchor = rangeAnchor, anchor.id != commit.id,
           let ordered = orderByPosition(anchor, commit) {
            choice = .range(older: ordered.older, newer: ordered.newer)
        } else {
            choice = .commit(commit)
        }
        let target = ReviewScopeSelection.target(
            for: choice,
            worktreeID: worktree.id,
            repositoryPath: worktree.path
        )
        env.openTarget(target, worktree)
    }

    private func launchBranch(
        _ name: String,
        worktree: Worktree,
        environment env: ReviewTargetPaletteEnvironment
    ) async {
        do {
            let headSHA = try await env.headSHA(worktree)
            let baseSHA = try await env.resolveRevision(worktree, name)
            let target = ReviewScopeSelection.target(
                for: .branch(name: name),
                worktreeID: worktree.id,
                repositoryPath: worktree.path,
                headSHA: headSHA,
                branchBaseSHA: baseSHA
            )
            env.openTarget(target, worktree)
        } catch {
            launchError = "Could not resolve \(name): \(error.localizedDescription)"
        }
    }

    private func launchFollowedRevision(
        expression: String,
        worktree: Worktree,
        environment env: ReviewTargetPaletteEnvironment
    ) async {
        let candidate: TrackedRevisionCandidate
        do {
            candidate = try await env.resolveTrackedRevision(worktree, expression)
        } catch {
            launchError = "Could not resolve \(expression): \(error.localizedDescription)"
            return
        }
        guard let revision = TrackedRevision(
            expression: expression,
            baselineBranch: candidate.branch,
            baselineHEAD: candidate.headSHA,
            resolvedSHA: candidate.sha
        ) else { return }
        env.openTarget(
            ReviewSessionTarget.trackedCommit(
                worktreeID: worktree.id,
                repositoryPath: worktree.path,
                revision: revision,
                title: "Review \(revision.target.displayLabel)"
            ),
            worktree
        )
    }

    // Commits arrive newest-first (git log order); "older" = larger index.
    // Returns nil if either commit is no longer in the list (stale anchor
    // after a refresh) so the caller falls back to single-commit selection.
    private func orderByPosition(_ a: CommitInfo, _ b: CommitInfo) -> (older: CommitInfo, newer: CommitInfo)? {
        guard let ia = commits.firstIndex(of: a),
              let ib = commits.firstIndex(of: b)
        else { return nil }
        return ia > ib ? (a, b) : (b, a)
    }
}
