import SwiftUI

struct GGWorktreeMenuModel: Equatable {
    let selectedMode: GGWorktreeMode
    let isEffectiveActive: Bool
    let permitsStackSummary: Bool
    let inactiveExplanation: String?
    let showsStatusIndicator: Bool
    let isVisible: Bool

    init(
        selectedMode: GGWorktreeMode,
        context: GGWorktreeContext,
        hasStackSummary: Bool,
        isRemoteWorktree: Bool = false
    ) {
        self.selectedMode = selectedMode
        isEffectiveActive = context.isActive
        permitsStackSummary = !isRemoteWorktree && context.permitsCurrentStackQuery
        showsStatusIndicator = context.isActive && !hasStackSummary
        let contextIsRemote = context == .inactive(reason: .remoteProject)
        let isGloballyDisabled = context == .inactive(reason: .masterDisabled)
        isVisible = !isRemoteWorktree && !contextIsRemote && !isGloballyDisabled

        guard !isRemoteWorktree else {
            inactiveExplanation = nil
            return
        }

        switch context {
        case .active:
            inactiveExplanation = nil
        case .inactive(reason: .masterDisabled):
            inactiveExplanation = "Stacked diffs are disabled in Settings."
        case .inactive(reason: .cliMissing):
            inactiveExplanation = "gg is not installed."
        case .inactive(reason: .remoteProject):
            inactiveExplanation = nil
        case .inactive(reason: .policyOff):
            inactiveExplanation = nil
        case .inactive(reason: .branchUsernameMissing):
            inactiveExplanation = "Set branch_username in gg config."
        case .inactive(reason: .branchPrefixMismatch(let expectedPrefix)):
            inactiveExplanation = "Branch must start with \(expectedPrefix)"
        }
    }
}

struct WorktreeRowView: View {
    nonisolated static let ggModeMenuTitle = "Stacked Diffs Mode"

    struct GGModeMenuItem: Equatable, Identifiable {
        let mode: GGWorktreeMode
        let title: String
        let isSelected: Bool

        var id: GGWorktreeMode { mode }
    }

    nonisolated static func ggModeMenuItems(selectedMode: GGWorktreeMode) -> [GGModeMenuItem] {
        [
            GGModeMenuItem(
                mode: .inherit,
                title: "Inherit repository default",
                isSelected: selectedMode == .inherit
            ),
            GGModeMenuItem(
                mode: .on,
                title: "On",
                isSelected: selectedMode == .on
            ),
            GGModeMenuItem(
                mode: .off,
                title: "Off",
                isSelected: selectedMode == .off
            )
        ]
    }

    static func stackSummaryTooltip(merged: Int, total: Int) -> String {
        stackSummaryText(merged: merged, total: total)
    }

    static func stackSummaryAccessibilityLabel(merged: Int, total: Int) -> String {
        stackSummaryText(merged: merged, total: total)
    }

    static func pendingStackIndicatorColorToken() -> String {
        "fg-faint"
    }

    /// A worktree an active Workspace checkout owns must be deleted from the
    /// checkout, not this row — the checkout freezes destination/lineage and
    /// removing the worktree out from under it leaves a "missing" member with
    /// no signal pointing back at the checkout that actually needs attention.
    /// An archived or Former Workspace checkout no longer manages the
    /// worktree's lifecycle, so this row's own actions apply again.
    static func showsRemovalActions(isMain: Bool, workspaceOwned: Bool = false) -> Bool {
        !isMain && !workspaceOwned
    }

    nonisolated static func visibleHarnessSessionCount(for sessionCount: Int) -> Int {
        min(sessionCount, 3)
    }

    private nonisolated static let agentBadgeSpacing: CGFloat = 4

    /// What a row says about its state: the note on line 2 and, unless it is a
    /// plain file count, the dot in the glyph slot.
    struct StatusPresentation: Equatable {
        let note: String
        /// Theme token for the note text and the dot.
        let colorToken: String
        let pulses: Bool
    }

    /// Derives the status chip, or `nil` when there is nothing to report.
    ///
    /// Harness activity outranks working-tree state: the row has one chip slot
    /// and an agent mid-flight is the more urgent fact. Within working-tree
    /// state, conflicts outrank plain modifications because a conflicted
    /// worktree is blocked rather than merely dirty.
    ///
    /// `clean` and `unknown` both yield nil. They are distinct cases so that a
    /// row before its first scan does not claim to be clean, but neither draws
    /// a chip — the sidebar speaks up only when something is wrong.
    nonisolated static func statusPresentation(
        harnessState: HarnessService.AggregatedState?,
        worktreeStatus: WorktreeDirtyState
    ) -> StatusPresentation? {
        switch harnessState {
        case .running:
            return StatusPresentation(note: "running", colorToken: "add", pulses: true)
        case .awaiting:
            return StatusPresentation(note: "waiting", colorToken: "mod", pulses: false)
        case .limited:
            return StatusPresentation(note: "limited", colorToken: "warn", pulses: false)
        case .failed:
            return StatusPresentation(note: "failed", colorToken: "del", pulses: false)
        case nil:
            break
        }

        switch worktreeStatus {
        case .unknown, .clean:
            return nil
        case .dirty(let fileCount, let conflictCount):
            if conflictCount > 0 {
                return StatusPresentation(
                    note: "\(conflictCount) conflict\(conflictCount == 1 ? "" : "s")",
                    colorToken: "del",
                    pulses: false
                )
            }
            return StatusPresentation(
                note: "\(fileCount) file\(fileCount == 1 ? "" : "s")",
                // Modified files are normal work, so they don't get a status colour.
                colorToken: "fg-dim",
                pulses: false
            )
        }
    }

    private static func stackSummaryText(merged: Int, total: Int) -> String {
        "gg stack · \(merged) of \(total) commit\(total == 1 ? "" : "s") merged"
    }

    static func upstreamStatusItems(
        _ status: WorktreeUpstreamStatus?,
        isMain: Bool
    ) -> [WorktreeUpstreamStatus.SubtitleItem] {
        guard isMain, let status else { return [] }
        return status.subtitleItems
    }

    let worktree: Worktree
    let isSelected: Bool
    let isMain: Bool
    let upstreamStatus: WorktreeUpstreamStatus?
    var onPullUpstream: (() -> Void)? = nil
    var isPullUpstreamInFlight: Bool = false
    let operationState: WorktreeOperationState?
    var landingStatus: GGLandingPresentation.SidebarStatus? = nil
    var onOpenGGLanding: (() -> Void)? = nil
    let harnessSummary: HarnessService.WorktreeHarnessSummary?
    let ggMenuModel: GGWorktreeMenuModel
    let onTap: () -> Void
    let onOpenTerminal: () -> Void
    var onOpenIssue: (() -> Void)? = nil
    let onCopyPath: () -> Void
    let onCopyBranch: () -> Void
    var onRenameBranch: (() -> Void)? = nil
    /// Still on the temporary branch it was created on, waiting for a chat
    /// prompt to name it.
    var isBranchNamePending = false
    /// A local model is naming the branch right now.
    var isNamingBranch = false
    let onRevealInFinder: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onDeleteKeepBranch: () -> Void
    let showKeepBranchOption: Bool
    let onActivateHarness: (String) -> Void
    let onCopyError: (String) -> Void
    let onRemoveFailed: () -> Void
    let onRetryCreate: () -> Void
    let onRetryLaunch: () -> Void
    let onRetryDelete: () -> Void
    let onSetGGWorktreeMode: (GGWorktreeMode) -> Void
    let workspaceCheckout: WorktreeWorkspaceCheckoutPresentation?
    var onOpenWorkspaceCheckout: (WorktreeWorkspaceCheckoutPresentation) -> Void = { _ in }
    var commitQuery: CommitQuery? = nil
    var worktreeExplanation: String? = nil
    var worktreeExplainerEvidence: WorktreeExplainerEvidence? = nil
    var onPrepareWorktreeExplanation: @MainActor (WorktreeExplainerEvidence) async -> Bool = { _ in true }

    var pluginCommands: [PluginCommandItem] = []
    var onRunPluginCommand: (PluginCommandItem) -> Void = { _ in }
    var pluginDecorations: [PluginDecorationItem] = []
    var onRunPluginDecoration: (PluginDecorationItem) -> Void = { _ in }
    /// Keyboard cursor from the sidebar filter; drawn like hover.
    var isHighlighted = false
    @Environment(\.theme) var theme
    @Environment(\.designScale) private var scale
    @State private var hovering = false
    @State private var loadedCommitQuery: CommitQuery?
    @State private var branchCommits: GitService.BranchCommitCount?
    /// Last count loaded for each query identity. Rows unmount as the lazy
    /// sidebar scrolls them away; one coming back draws its count at once
    /// and, while its revision is unchanged, skips git entirely.
    @MainActor static var loadedCommitCounts: [CommitQuery.Identity: LoadedCommitCount] = [:]

    struct LoadedCommitCount {
        let query: CommitQuery
        let commits: GitService.BranchCommitCount?
    }

    /// This row's loaded count, or the cached one before its own load runs.
    private var loadedCommitCount: LoadedCommitCount? {
        if let loadedCommitQuery { return LoadedCommitCount(query: loadedCommitQuery, commits: branchCommits) }
        return activeCommitQuery.flatMap { Self.loadedCommitCounts[$0.identity] }
    }

    struct CommitQuery: Hashable {
        let path: URL
        let branch: String
        let baseBranch: String
        let preferLocal: Bool
        let revision: Int

        /// What's actually being counted, excluding `revision`. A revision
        /// bump alone — e.g. an unrelated ref change elsewhere in the project —
        /// still triggers a refetch via `.task(id:)`, but should not hide an
        /// already-loaded count while that refetch is in flight.
        struct Identity: Hashable {
            let path: URL
            let branch: String
            let baseBranch: String
            let preferLocal: Bool
        }

        var identity: Identity {
            Identity(path: path, branch: branch, baseBranch: baseBranch, preferLocal: preferLocal)
        }
    }

    nonisolated static func hasVisibleCommits(_ commits: GitService.BranchCommitCount?) -> Bool {
        (commits?.count ?? 0) > 0
    }

    nonisolated static func showsCommitCount(
        harnessState: HarnessService.AggregatedState?,
        worktreeStatus: WorktreeDirtyState,
        isMain: Bool
    ) -> Bool {
        !isMain && harnessState == nil && worktreeStatus == .clean
    }

    nonisolated static func showsExplanation(
        isMain: Bool,
        hasOperation: Bool,
        hasWorkspaceCheckout: Bool,
        worktreeStatus: WorktreeDirtyState,
        hasStatus: Bool,
        hasVisibleCommits: Bool,
        commitQueryResolved: Bool,
        hasDiff: Bool,
        hasStackStatus: Bool
    ) -> Bool {
        !isMain
            && !hasOperation
            && !hasWorkspaceCheckout
            && worktreeStatus == .clean
            && !hasStatus
            && !hasVisibleCommits
            && commitQueryResolved
            && !hasDiff
            && !hasStackStatus
    }

    nonisolated static func diffBarAdditionCount(added: Int, deleted: Int) -> Int? {
        guard added > 0 || deleted > 0 else { return nil }
        if added <= 0 { return 0 }
        if deleted <= 0 { return 5 }
        let fraction = Double(added) / (Double(added) + Double(deleted))
        return min(4, max(1, Int((5 * fraction).rounded())))
    }

    private var activeCommitQuery: CommitQuery? {
        guard !isMain,
              operationState == nil,
              Self.showsCommitCount(
                harnessState: harnessSummary?.state,
                worktreeStatus: WorktreeStatusStore.shared.status(forPath: worktree.path.path),
                isMain: isMain
              ) else { return nil }
        return commitQuery
    }

    private var visibleBranchCommits: GitService.BranchCommitCount? {
        guard let activeCommitQuery,
              let loaded = loadedCommitCount,
              loaded.query.identity == activeCommitQuery.identity,
              Self.showsCommitCount(
                harnessState: harnessSummary?.state,
                worktreeStatus: WorktreeStatusStore.shared.status(forPath: worktree.path.path),
                isMain: isMain
              ),
              Self.hasVisibleCommits(loaded.commits) else { return nil }
        return loaded.commits
    }

    nonisolated static func isPending(operationState: WorktreeOperationState?) -> Bool {
        switch operationState {
        case .creating, .preparingDelete, .deleting, .archiving: return true
        default: return false
        }
    }

    nonisolated static func statusText(for operationState: WorktreeOperationState?) -> String {
        switch operationState {
        case .creating: return "Creating…"
        case .preparingDelete: return "Preparing deletion…"
        case .deleting: return "Deleting…"
        case .archiving: return "Archiving…"
        case .createFailed(_, let msg, _, _, _, _, _): return "Create failed: \(msg.trimmedForDisplay)"
        case .launchFailed(_, let msg, _): return "Launch failed: \(msg.trimmedForDisplay)"
        case .deleteFailed(let msg): return "Delete failed: \(msg.trimmedForDisplay)"
        case .none: return ""
        }
    }

    nonisolated static func showsProgress(operationState: WorktreeOperationState?) -> Bool {
        switch operationState {
        case .preparingDelete, .deleting, .archiving: return true
        case .creating, .createFailed, .launchFailed, .deleteFailed, .none: return false
        }
    }

    private var isPending: Bool {
        Self.isPending(operationState: operationState)
    }

    private var errorMessage: String? {
        switch operationState {
        case .createFailed(_, let message, _, _, _, _, _), .launchFailed(_, let message, _), .deleteFailed(let message):
            return message
        case .creating, .preparingDelete, .deleting, .archiving, .none:
            return nil
        }
    }

    private var stackSummary: GGStackSummary? {
        guard ggMenuModel.permitsStackSummary else { return nil }
        return GGStackSummaryStore.shared.summary(forPath: worktree.path.path)
    }

    var body: some View {
        let worktreeStatus = WorktreeStatusStore.shared.status(forPath: worktree.path.path)
        let status = Self.statusPresentation(
            harnessState: harnessSummary?.state,
            worktreeStatus: worktreeStatus
        )
        let explanationEvidence = explanationEvidence(
            status: status,
            worktreeStatus: worktreeStatus
        )

        VStack(alignment: .leading, spacing: scale.space[0]) {
            firstLine(status: status, worktreeStatus: worktreeStatus)
            if operationState != nil {
                operationLine
            } else if let landingStatus {
                landingLine(status: landingStatus)
            } else {
                secondLine(
                    status: status,
                    worktreeStatus: worktreeStatus,
                    showsExplanation: explanationEvidence != nil
                )
            }
        }
        .padding(.horizontal, scale.space[2])
        .padding(.vertical, scale.space[1])
        .frame(maxWidth: .infinity, minHeight: scale.sidebarRowMinHeight, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .fill(theme.color("accent-soft"))
            } else if hovering || isHighlighted {
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .fill(theme.color("bg-3").opacity(0.55))
            }
        }
        .aiBeam(isActive: isNamingBranch, cornerRadius: scale.radius.medium)
        .contentShape(Rectangle())
        .opacity(isPending ? 0.55 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(status: status, worktreeStatus: worktreeStatus, showsExplanation: explanationEvidence != nil))
        // The tiles are not mounted at rest, so each session stays reachable.
        .accessibilityActions {
            ForEach(harnessSummary?.sessions ?? []) { session in
                Button("Open \(session.agent.displayName) session") { onActivateHarness(session.id) }
            }
        }
        .sidebarHover { hovering = $0 }
        .onTapGesture {
            if !isPending {
                onTap()
            }
        }
        .nativeContextMenu(mountsWhileHovered: true) {
            contextMenuContent
        }
        .task(id: activeCommitQuery) {
            guard let query = activeCommitQuery else {
                branchCommits = nil
                loadedCommitQuery = nil
                return
            }
            if let cached = Self.loadedCommitCounts[query.identity], cached.query == query {
                loadedCommitQuery = query
                branchCommits = cached.commits
                return
            }
            if loadedCommitQuery?.identity != query.identity {
                branchCommits = nil
                loadedCommitQuery = nil
            }
            // Coalesce bursts of ref updates before launching Git.
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            let summary = try? await GitService().branchCommitCount(
                worktreePath: query.path,
                baseBranch: query.baseBranch,
                preferLocal: query.preferLocal
            )
            guard !Task.isCancelled else { return }
            loadedCommitQuery = query
            branchCommits = summary
            Self.loadedCommitCounts[query.identity] = LoadedCommitCount(query: query, commits: summary)
        }
        .task(id: explanationEvidence) {
            guard let explanationEvidence else { return }
            await WorktreeExplanationRetry.run {
                await onPrepareWorktreeExplanation(explanationEvidence)
            }
        }
    }

    /// Width of the slot that holds a row's icon or status dot; the second
    /// line starts where the name does.
    private static let glyphSlotWidth: CGFloat = 12

    private var textInset: CGFloat { Self.glyphSlotWidth + scale.space[2] }

    private func firstLine(status: StatusPresentation?, worktreeStatus: WorktreeDirtyState) -> some View {
        HStack(spacing: scale.space[2]) {
            leadingGlyph(status: status, worktreeStatus: worktreeStatus)
                .frame(width: Self.glyphSlotWidth)
            Text(worktree.title)
                .font(isSelected ? scale.emphasisFont : scale.bodyFont)
                .foregroundColor(theme.color(branchColorToken))
                .lineLimit(1)
                // Sibling branches differ at the end, so that is what survives.
                .truncationMode(.middle)
                // The full name, for when the middle is cut.
                .help(worktree.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isBranchNamePending, !isNamingBranch {
                Image(systemName: "sparkles")
                    .font(scale.captionFont)
                    .foregroundColor(theme.color("fg-faint"))
                    .help("The branch will be named from your first chat message.")
            }
            if worktree.isDetached {
                DetachedTag()
            }
            // A pull action is waiting, so this stays through every state.
            ForEach(WorktreeRowPresentation.upstreamItemsAtRest(Self.upstreamStatusItems(upstreamStatus, isMain: isMain)), id: \.text) {
                upstreamView($0)
            }
            // On the name line, which can truncate; line 2's facts are fixed-size.
            if let summary = harnessSummary {
                agentBadges(summary: summary)
            }
        }
        .frame(minHeight: HarnessSessionBadge.diameter)
    }

    /// A row's branch or home icon, unless agent state or a conflict takes over.
    /// The dot replaces a linked worktree's icon so state reads down one
    /// column. Main keeps its icon, with the dot as a badge, so telling it apart
    /// never depends on its position in the group.
    @ViewBuilder
    private func leadingGlyph(status: StatusPresentation?, worktreeStatus: WorktreeDirtyState) -> some View {
        let dotStatus = WorktreeRowPresentation.isStatusLoud(
            harnessState: harnessSummary?.state,
            worktreeStatus: worktreeStatus
        ) ? status : nil
        if isMain {
            Icon(name: "home", size: Self.glyphSlotWidth, color: theme.color("fg-dim"))
                .overlay(alignment: .bottomTrailing) {
                    if let dotStatus {
                        StatusDot(color: theme.color(dotStatus.colorToken), pulses: dotStatus.pulses)
                            .offset(x: scale.space[0], y: scale.space[0])
                    }
                }
        } else if let dotStatus {
            StatusDot(color: theme.color(dotStatus.colorToken), pulses: dotStatus.pulses)
        } else {
            Icon(name: "branch", size: Self.glyphSlotWidth, color: theme.color("fg-dim"))
        }
    }

    private var timeLabel: some View {
        Text(WorktreeRowPresentation.compactAge(since: worktree.lastActivity, now: Date()))
            .monospacedDigit()
            .fixedSize()
            .help(relative(worktree.lastActivity))
    }

    /// Full-strength `fg` at rest. There is no brighter token to move to on
    /// hover, which is the point — the name stays legible in every state and
    /// the row's fill carries selection instead.
    private var branchColorToken: String {
        isPending ? "fg-faint" : "fg"
    }

    private func secondLine(
        status: StatusPresentation?,
        worktreeStatus: WorktreeDirtyState,
        showsExplanation: Bool
    ) -> some View {
        // Everything a row knows stays on screen: it is what a scan of the
        // list reads. Narrow sidebars drop the diff bar, then the time.
        ViewThatFits(in: .horizontal) {
            subtitleContents(status: status, worktreeStatus: worktreeStatus, showsDiffBar: true, showsTime: true, showsExplanation: showsExplanation)
            subtitleContents(status: status, worktreeStatus: worktreeStatus, showsDiffBar: false, showsTime: true, showsExplanation: showsExplanation)
            subtitleContents(status: status, worktreeStatus: worktreeStatus, showsDiffBar: false, showsTime: false, showsExplanation: showsExplanation)
        }
        .font(scale.metaFont)
        .foregroundColor(rowColor("fg-dim"))
        .padding(.leading, textInset)
    }

    private func landingLine(status: GGLandingPresentation.SidebarStatus) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: scale.space[2]) {
                landingButton(status: status)
                    .fixedSize()
                workspaceCheckoutButton
                    .fixedSize()
            }
            landingButton(status: status)
        }
        .font(scale.metaFont)
        .foregroundStyle(theme.color("fg-dim"))
        .padding(.leading, textInset)
    }

    private func landingButton(status: GGLandingPresentation.SidebarStatus) -> some View {
        Button {
            onOpenGGLanding?()
        } label: {
            HStack(spacing: 5) {
                if status.isSpinning {
                    Spinner(lineWidth: 1.2, duration: 0.7, color: theme.color(status.colorToken))
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                }
                Text(status.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(theme.color(status.colorToken))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("\(status.title). Open gg land details.")
        .accessibilityLabel("gg land: \(status.title)")
        .accessibilityHint("Opens the landing tab for this repository")
    }

    @ViewBuilder
    private var workspaceCheckoutButton: some View {
        if let workspaceCheckout {
            Button { onOpenWorkspaceCheckout(workspaceCheckout) } label: {
                HStack(spacing: 4) {
                    Icon(
                        name: "square.grid.2x2",
                        size: 9,
                        color: theme.color(workspaceCheckout.isActive ? "accent" : "fg-dim")
                    )
                    .accessibilityHidden(true)
                    Text(workspaceCheckout.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundColor(theme.color(workspaceCheckout.isActive ? "accent" : "fg-dim"))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(workspaceCheckout.accessibilityLabel)
            .accessibilityLabel(workspaceCheckout.accessibilityLabel)
            .accessibilityHint("Opens the workspace focused on this repository")
        }
    }

    private var diffStats: WorktreeDiffStats {
        WorktreeStatusStore.shared.diffStats(forPath: worktree.path.path)
            ?? WorktreeDiffStats(added: worktree.addedLines, deleted: worktree.deletedLines)
    }

    private func explanationEvidence(
        status: StatusPresentation?,
        worktreeStatus: WorktreeDirtyState
    ) -> WorktreeExplainerEvidence? {
        guard let worktreeExplainerEvidence,
              Self.showsExplanation(
                isMain: isMain,
                hasOperation: operationState != nil,
                hasWorkspaceCheckout: workspaceCheckout != nil,
                worktreeStatus: worktreeStatus,
                hasStatus: status != nil,
                hasVisibleCommits: visibleBranchCommits != nil,
                commitQueryResolved: activeCommitQuery == nil
                    || loadedCommitCount?.query.identity == activeCommitQuery?.identity,
                hasDiff: Self.diffBarAdditionCount(added: diffStats.added, deleted: diffStats.deleted) != nil,
                hasStackStatus: stackSummary != nil || ggMenuModel.showsStatusIndicator
              )
        else { return nil }
        return worktreeExplainerEvidence
    }

    /// Agent state and conflicts lead, since they are what needs you.
    private func subtitleContents(
        status: StatusPresentation?,
        worktreeStatus: WorktreeDirtyState,
        showsDiffBar: Bool,
        showsTime: Bool,
        showsExplanation: Bool
    ) -> some View {
        let noteLeads = WorktreeRowPresentation.isStatusLoud(
            harnessState: harnessSummary?.state,
            worktreeStatus: worktreeStatus
        )
        let upstreamItems = Self.upstreamStatusItems(upstreamStatus, isMain: isMain)
        let upstreamOnNameLine = WorktreeRowPresentation.upstreamItemsAtRest(upstreamItems)
        return HStack(spacing: scale.space[2]) {
            if let status, noteLeads {
                statusNote(status)
            }
            PluginDecorationBadges(items: pluginDecorations, run: onRunPluginDecoration)
            stackSummaryView
            workspaceCheckoutButton
            if let status {
                if !noteLeads { statusNote(status) }
            } else if let commits = visibleBranchCommits {
                commitCount(commits, label: "\(commits.count) commit\(commits.count == 1 ? "" : "s")")
            }
            ForEach(upstreamItems.filter { !upstreamOnNameLine.contains($0) }, id: \.text) { upstreamView($0) }
            if Self.diffBarAdditionCount(added: diffStats.added, deleted: diffStats.deleted) != nil {
                diffCounts(showsDiffBar: showsDiffBar)
            }
            if showsExplanation, let worktreeExplanation {
                Text(worktreeExplanation)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if showsTime {
                timeLabel
            }
        }
    }

    private func commitCount(_ commits: GitService.BranchCommitCount, label: String) -> some View {
        HStack(spacing: scale.space[1]) {
            Icon(name: "commit", size: 10, color: rowColor("fg-dim"))
                .accessibilityHidden(true)
            Text(label)
        }
        .fixedSize()
        .help(Self.commitsLabel(commits))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.commitsLabel(commits))
    }

    private func diffCounts(showsDiffBar: Bool) -> some View {
        HStack(spacing: scale.space[1]) {
            if showsDiffBar, let additionTicks = Self.diffBarAdditionCount(added: diffStats.added, deleted: diffStats.deleted) {
                HStack(spacing: 1.5) {
                    ForEach(0..<5) { tick in
                        RoundedRectangle(cornerRadius: 1) // design-literal: 2pt-wide diff tick
                            .fill(theme.color(tick < additionTicks ? "add" : "del"))
                            .frame(width: 2, height: 7)
                    }
                }
                .accessibilityHidden(true)
            }
            if diffStats.added > 0 {
                Text("+\(diffStats.added)").foregroundColor(rowColor("add"))
            }
            if diffStats.deleted > 0 {
                Text("−\(diffStats.deleted)").foregroundColor(rowColor("del"))
            }
        }
        .monospacedDigit()
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(diffStats.added) lines added, \(diffStats.deleted) lines deleted")
    }

    private func statusNote(_ status: StatusPresentation) -> some View {
        Text(status.note)
            .foregroundColor(rowColor(status.colorToken))
            .fixedSize()
    }

    /// A status token as text on this row's fill. The selected fill is strong
    /// enough to wash some tokens out, so there they are adjusted to stay legible.
    private func rowColor(_ token: String) -> Color {
        isSelected ? theme.legibleOnSelection(token, over: Self.sidebarFillToken) : theme.color(token)
    }

    /// What the selected fill is composited over.
    nonisolated static let sidebarFillToken = "bg-1"

    @ViewBuilder
    private func upstreamView(_ item: WorktreeUpstreamStatus.SubtitleItem) -> some View {
        let label = Text(item.text)
            .font(scale.metaFont)
            .monospacedDigit()
            .foregroundColor(rowColor(item.text.hasPrefix("↓") ? "caution" : "accent"))
        if item.text.hasPrefix("↓"), let onPullUpstream, let upstreamStatus {
            let count = upstreamStatus.behind
            Button(action: onPullUpstream) {
                HStack(spacing: 3) {
                    if isPullUpstreamInFlight {
                        // Matches the changes-tab chip: the count
                        // keeps reading, the spinner replaces only the
                        // arrow's spot in the eye.
                        Spinner(lineWidth: 1.2, duration: 0.7)
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                    }
                    label
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(isPullUpstreamInFlight
                ? "Pulling from \(upstreamStatus.upstreamRef)…"
                : "Pull \(count) commit\(count == 1 ? "" : "s") from \(upstreamStatus.upstreamRef) (rebase)")
            .accessibilityLabel(item.accessibilityLabel)
        } else {
            label
                .help(item.accessibilityLabel)
                .accessibilityLabel(item.accessibilityLabel)
        }
    }

    private static func commitsLabel(_ commits: GitService.BranchCommitCount) -> String {
        "\(commits.count) commit\(commits.count == 1 ? "" : "s") beyond \(commits.baseRef)"
    }

    private func accessibilityLabel(status: StatusPresentation?, worktreeStatus: WorktreeDirtyState, showsExplanation: Bool) -> String {
        WorktreeRowPresentation.accessibilityLabel(WorktreeRowAccessibilityContent(
            name: worktree.title,
            statusNote: status?.note,
            added: diffStats.added,
            deleted: diffStats.deleted,
            workspaceCheckout: workspaceCheckout?.accessibilityLabel,
            commits: visibleBranchCommits.map(Self.commitsLabel),
            upstream: Self.upstreamStatusItems(upstreamStatus, isMain: isMain).map(\.accessibilityLabel),
            stack: stackAccessibilityText,
            agents: harnessSummary?.sessions.map { "\($0.agent.displayName) · \($0.state.statusNote)" } ?? [],
            explanation: showsExplanation ? worktreeExplanation : nil,
            lastActivity: relative(worktree.lastActivity)
        ))
    }

    private var operationLine: some View {
        HStack(spacing: 5) {
            if Self.showsProgress(operationState: operationState) {
                Spinner(lineWidth: 1.5, duration: 0.7, color: theme.color("warn"))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            Text(Self.statusText(for: operationState))
                .font(scale.metaFont)
                .foregroundColor(theme.color("warn"))
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .padding(.leading, textInset)
    }

    private var stackAccessibilityText: String? {
        if let stack = stackSummary {
            return stack.isRemoteStateKnown
                ? Self.stackSummaryTooltip(merged: stack.merged, total: stack.total)
                : "gg stack · \(stack.total) commits · merge status pending"
        }
        return ggMenuModel.showsStatusIndicator ? "gg is active for this worktree." : nil
    }

    @ViewBuilder
    private var stackSummaryView: some View {
        if let stack = stackSummary {
            HStack(spacing: 3) {
                GGStackIcon(size: 9, color: theme.color("fg-faint"))
                    .accessibilityHidden(true)
                Text(stack.isRemoteStateKnown ? "\(stack.merged)/\(stack.total)" : "\(stack.total)")
                    .monospacedDigit()
                    .foregroundColor(theme.color("fg-faint"))
            }
            .help(stackAccessibilityText ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stackAccessibilityText ?? "")
        } else if ggMenuModel.showsStatusIndicator {
            GGStackIcon(size: 9, color: theme.color(Self.pendingStackIndicatorColorToken()))
                .help("gg is active for this worktree.")
                .accessibilityLabel("gg is active for this worktree.")
        }
    }

    private func agentBadges(
        summary: HarnessService.WorktreeHarnessSummary
    ) -> some View {
        HStack(spacing: Self.agentBadgeSpacing) {
            let visibleSessionCount = Self.visibleHarnessSessionCount(for: summary.sessions.count)
            ForEach(summary.sessions.prefix(visibleSessionCount)) { session in
                HarnessSessionBadge(
                    session: session,
                    onActivate: { onActivateHarness(session.id) }
                )
            }
            if summary.sessions.count > visibleSessionCount {
                let hiddenSessions = Array(summary.sessions.dropFirst(visibleSessionCount))
                HarnessSessionOverflowBadge(
                    sessions: hiddenSessions,
                    onActivate: onActivateHarness
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active agent sessions")
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if case .createFailed = operationState {
            Button("Retry Create", action: onRetryCreate)
            Button("Remove from List", role: .destructive, action: onRemoveFailed)
            Divider()
            if let errorMessage {
                Button("Copy Error") { onCopyError(errorMessage) }
            }
            Button("Copy Path", action: onCopyPath)
        } else if case .launchFailed = operationState {
            Button("Retry Launch", action: onRetryLaunch)
            if let errorMessage {
                Divider()
                Button("Copy Error") { onCopyError(errorMessage) }
            }
            Divider()
            availableWorktreeContextMenuContent
        } else if case .deleteFailed = operationState {
            if Self.showsRemovalActions(isMain: isMain, workspaceOwned: workspaceCheckout?.isActive == true) {
                Button("Retry Delete", action: onRetryDelete)
                Button("Archive", action: onArchive)
            }
            Divider()
            if let errorMessage {
                Button("Copy Error") { onCopyError(errorMessage) }
            }
            Button("Copy Path", action: onCopyPath)
            Button("Copy Branch Name", action: onCopyBranch)
        } else if !isPending {
            availableWorktreeContextMenuContent
        }
    }

    @ViewBuilder
    private var availableWorktreeContextMenuContent: some View {
        // The session tiles are not mounted at rest, so the menu, which Full
        // Keyboard Access reaches, offers each session too.
        if let sessions = harnessSummary?.sessions, !sessions.isEmpty {
            ForEach(sessions) { session in
                Button("Open \(session.agent.displayName) Session") { onActivateHarness(session.id) }
            }
            Divider()
        }
        if let workspaceCheckout {
            Button("Go to Workspace") { onOpenWorkspaceCheckout(workspaceCheckout) }
        }
        Button("Open in Terminal", action: onOpenTerminal)
        if let onOpenIssue {
            Button("Open Issue", action: onOpenIssue)
            Divider()
        }
        Button("Copy Path", action: onCopyPath)
        // Folder-project rows have no branch.
        if !worktree.branch.isEmpty {
            Button("Copy Branch Name", action: onCopyBranch)
        }
        // An active Workspace checkout records its branch by name for cleanup.
        if let onRenameBranch, !isMain, !worktree.branch.isEmpty, !worktree.isDetached,
           workspaceCheckout?.isActive != true {
            Button("Rename Branch…", action: onRenameBranch)
        }
        if !worktree.path.isRemoteAlasPath {
            Button("Reveal in Finder", action: onRevealInFinder)
        }
        Divider()
        if ggMenuModel.isVisible {
            Menu(Self.ggModeMenuTitle) {
                // Static buttons: a data-driven ForEach inside a hover-revealed
                // context-menu submenu renders empty on macOS.
                let items = Self.ggModeMenuItems(selectedMode: ggMenuModel.selectedMode)
                ggModeMenuButton(items[0])
                ggModeMenuButton(items[1])
                ggModeMenuButton(items[2])
            }
            if let explanation = ggMenuModel.inactiveExplanation {
                Divider()
                Text(explanation)
            }
            Divider()
        }
        if !pluginCommands.isEmpty {
            PluginCommandButtons(items: pluginCommands, run: onRunPluginCommand)
            Divider()
        }
        if Self.showsRemovalActions(isMain: isMain, workspaceOwned: workspaceCheckout?.isActive == true) {
            Button("Archive", action: onArchive)
            Button("Delete Worktree…", role: .destructive, action: onDelete)
            if showKeepBranchOption {
                Button("Delete Worktree, Keep Branch…", role: .destructive, action: onDeleteKeepBranch)
            }
        } else if workspaceCheckout?.isActive == true {
            Text("Managed by Workspace checkout \(workspaceCheckout!.name)")
        }
    }

    private func ggModeMenuButton(_ item: GGModeMenuItem) -> some View {
        Button {
            guard item.mode != ggMenuModel.selectedMode else { return }
            onSetGGWorktreeMode(item.mode)
        } label: {
            if item.isSelected {
                Label(item.title, systemImage: "checkmark")
            } else {
                Text(item.title)
            }
        }
    }

    /// Asked for on every body, by the accessibility label and the age's help,
    /// so a string is reused within the second it was formatted in.
    private func relative(_ date: Date) -> String {
        let now = Date()
        let second = Int(now.timeIntervalSinceReferenceDate)
        if let cached = Self.relativeCache[date], cached.second == second { return cached.text }
        let text = Self.relativeDateFormatter.localizedString(for: date, relativeTo: now)
        if Self.relativeCache.count >= 512 { Self.relativeCache.removeAll() }
        Self.relativeCache[date] = (second, text)
        return text
    }

    @MainActor private static var relativeCache: [Date: (second: Int, text: String)] = [:]

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// Line 2's status dot. Pulses for a running session, matching E1's
/// `@keyframes pulse`, and holds still under Reduce Motion — a sidebar full
/// of running worktrees would otherwise animate continuously.
struct StatusDot: View {
    let color: Color
    let pulses: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay {
                if pulses && !reduceMotion {
                    StatusDotPulse(color: NSColor.drawingColor(color))
                        .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The pulse ring, run by Core Animation in the render server. A SwiftUI
/// `repeatForever` animation updated the view graph every frame, and each
/// update re-rendered the whole sidebar's display list, so one running agent
/// cost a full sidebar render per frame.
private struct StatusDotPulse: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> StatusDotPulseView {
        StatusDotPulseView()
    }

    func updateNSView(_ view: StatusDotPulseView, context: Context) {
        view.color = color
    }
}

private final class StatusDotPulseView: NSView {
    private let ring = CAShapeLayer()

    var color: NSColor = .clear {
        didSet { updateColor() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The ring scales to 2.2x, past the dot's 6pt frame.
        clipsToBounds = false
        ring.fillColor = nil
        ring.lineWidth = 2
        layer?.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.5
        fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [scale, fade]
        pulse.duration = 1.9
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.repeatCount = .infinity
        pulse.isRemovedOnCompletion = false
        ring.opacity = 0
        ring.add(pulse, forKey: "pulse")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        // Stroked on the dot's edge, like the `Circle().stroke` it replaces.
        ring.path = CGPath(ellipseIn: bounds, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.strokeColor = color.cgColor
        }
    }
}

/// Neutral marker beside a detached worktree's directory-name title, so the
/// row still says HEAD is detached without spending the title on it.
struct DetachedTag: View {
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        Text("detached")
            .font(scale.captionFont)
            .foregroundColor(theme.color("fg-dim"))
            .padding(.horizontal, scale.space[1])
            .padding(.vertical, 1) // design-literal: fits the tag inside a name line
            .background(theme.color("bg-3"), in: RoundedRectangle(cornerRadius: scale.radius.small))
            .fixedSize()
            .help("HEAD is detached")
    }
}

private extension String {
    var trimmedForDisplay: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
