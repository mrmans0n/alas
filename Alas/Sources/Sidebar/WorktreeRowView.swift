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

    static func showsRemovalActions(isMain: Bool) -> Bool {
        !isMain
    }

    nonisolated static func visibleHarnessSessionCount(for sessionCount: Int) -> Int {
        min(sessionCount, 3)
    }

    /// What line 2's status chip shows for a row. The dot and its label are one
    /// unit — a presentation always carries a label, so there is no way to
    /// render a bare, unexplained dot.
    struct StatusPresentation: Equatable {
        let note: String
        /// Theme token for both the dot and the note text.
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
                colorToken: "mod",
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
    let operationState: WorktreeOperationState?
    let harnessSummary: HarnessService.WorktreeHarnessSummary?
    let ggMenuModel: GGWorktreeMenuModel
    let onTap: () -> Void
    let onOpenTerminal: () -> Void
    var onOpenIssue: (() -> Void)? = nil
    let onCopyPath: () -> Void
    let onCopyBranch: () -> Void
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
    var commitQuery: CommitQuery? = nil
    @Environment(\.theme) var theme
    @State private var hovering = false
    @State private var loadedCommitQuery: CommitQuery?
    @State private var branchCommits: GitService.BranchCommitCount?

    struct CommitQuery: Hashable {
        let path: URL
        let branch: String
        let baseBranch: String
        let preferLocal: Bool
        let revision: Int
    }

    nonisolated static func showsCommitCount(
        harnessState: HarnessService.AggregatedState?,
        worktreeStatus: WorktreeDirtyState,
        isMain: Bool
    ) -> Bool {
        !isMain && harnessState == nil && worktreeStatus == .clean
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
        guard loadedCommitQuery == activeCommitQuery,
              Self.showsCommitCount(
                harnessState: harnessSummary?.state,
                worktreeStatus: WorktreeStatusStore.shared.status(forPath: worktree.path.path),
                isMain: isMain
              ) else { return nil }
        return branchCommits
    }

    nonisolated static func isPending(operationState: WorktreeOperationState?) -> Bool {
        switch operationState {
        case .creating, .preparingDelete, .deleting: return true
        default: return false
        }
    }

    nonisolated static func statusText(for operationState: WorktreeOperationState?) -> String {
        switch operationState {
        case .creating: return "Creating…"
        case .preparingDelete: return "Preparing deletion…"
        case .deleting: return "Deleting…"
        case .createFailed(_, let msg, _, _, _, _): return "Create failed: \(msg.trimmedForDisplay)"
        case .launchFailed(_, let msg, _): return "Launch failed: \(msg.trimmedForDisplay)"
        case .deleteFailed(let msg): return "Delete failed: \(msg.trimmedForDisplay)"
        case .none: return ""
        }
    }

    nonisolated static func showsProgress(operationState: WorktreeOperationState?) -> Bool {
        switch operationState {
        case .preparingDelete, .deleting: return true
        case .creating, .createFailed, .launchFailed, .deleteFailed, .none: return false
        }
    }

    private var isPending: Bool {
        Self.isPending(operationState: operationState)
    }

    private var errorMessage: String? {
        switch operationState {
        case .createFailed(_, let message, _, _, _, _), .launchFailed(_, let message, _), .deleteFailed(let message):
            return message
        case .creating, .preparingDelete, .deleting, .none:
            return nil
        }
    }

    private var stackSummary: GGStackSummary? {
        guard ggMenuModel.permitsStackSummary else { return nil }
        return GGStackSummaryStore.shared.summary(forPath: worktree.path.path)
    }

    var body: some View {
        let status = Self.statusPresentation(
            harnessState: harnessSummary?.state,
            worktreeStatus: WorktreeStatusStore.shared.status(forPath: worktree.path.path)
        )
        ZStack(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 9)
                    .fill(theme.color("accent-soft"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(theme.color("accent").opacity(0.5), lineWidth: 0.5)
                    )
            } else if hovering {
                RoundedRectangle(cornerRadius: 9)
                    .fill(theme.color("bg-3").opacity(0.55))
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(theme.color("line").opacity(0.75), lineWidth: 0.75)
            }
            VStack(alignment: .leading, spacing: 2) {
                firstLine()
                if operationState != nil {
                    operationLine
                } else {
                    secondLine(status: status)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(isPending ? 0.55 : 1)
        .onHover { hovering = $0 }
        .onTapGesture {
            if !isPending {
                onTap()
            }
        }
        .nativeContextMenu {
            contextMenuContent
        }
        .task(id: activeCommitQuery) {
            branchCommits = nil
            loadedCommitQuery = nil
            guard let query = activeCommitQuery else { return }
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
        }
    }

    private func firstLine() -> some View {
        HStack(spacing: 7) {
            Icon(
                name: isMain ? "home" : "branch",
                size: 12,
                color: theme.color(iconColorToken(harnessState: harnessSummary?.state))
            )
            Text(worktree.branch)
                // Pre-E1 metrics, restored: E1 shrank this to 11.5pt, muted it
                // until hover, and tightened it with negative tracking. Those
                // compounded into a branch name that was harder to read, and a
                // monospace face at this size suffers most from the tracking.
                // Selection and hover are carried by the row's fill and outline,
                // so the label does not need to dim to stay out of their way.
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.color(branchColorToken))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let summary = harnessSummary {
                agentBadges(summary: summary)
            }
        }
        .frame(minHeight: HarnessSessionBadge.diameter)
    }

    /// E1 tints the branch glyph green while a session runs, so activity
    /// reads from line 1 without the row having to be scanned twice.
    ///
    /// Keyed off the harness state directly rather than `StatusPresentation.pulses`:
    /// `pulses` is a presentation detail (whether the dot animates), not the
    /// state itself, so a future state that also pulses should not turn the
    /// icon green by accident.
    private func iconColorToken(harnessState: HarnessService.AggregatedState?) -> String {
        if harnessState == .running { return "add" }
        return isMain ? "fg-muted" : "fg-faint"
    }

    /// Full-strength `fg` at rest. There is no brighter token to move to on
    /// hover, which is the point — the name stays legible in every state and
    /// the row's fill and outline carry selection instead.
    private var branchColorToken: String {
        isPending ? "fg-faint" : "fg"
    }

    private func secondLine(status: StatusPresentation?) -> some View {
        ViewThatFits(in: .horizontal) {
            subtitleContents(status: status, showsDiffBar: true)
            subtitleContents(status: status, showsDiffBar: false)
        }
        .font(.system(size: 10))
        .foregroundColor(theme.color("fg-dim"))
        .padding(.leading, 19)
    }

    private var diffStats: WorktreeDiffStats {
        WorktreeStatusStore.shared.diffStats(forPath: worktree.path.path)
            ?? WorktreeDiffStats(added: worktree.addedLines, deleted: worktree.deletedLines)
    }

    private func subtitleContents(status: StatusPresentation?, showsDiffBar: Bool) -> some View {
        HStack(spacing: 7) {
            if let workspaceCheckout {
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
                .help(workspaceCheckout.accessibilityLabel)
                .accessibilityLabel(workspaceCheckout.accessibilityLabel)
            }
            if let status {
                HStack(spacing: 5) {
                    StatusDot(color: theme.color(status.colorToken), pulses: status.pulses)
                    Text(status.note)
                        .foregroundColor(theme.color(status.colorToken))
                }
                .fixedSize()
            } else if let commits = visibleBranchCommits {
                HStack(spacing: 4) {
                    Icon(name: "commit", size: 10, color: theme.color("fg-dim"))
                        .accessibilityHidden(true)
                    Text("\(commits.count) commit\(commits.count == 1 ? "" : "s")")
                }
                .fixedSize()
                .help("\(commits.count) commit\(commits.count == 1 ? "" : "s") beyond \(commits.baseRef)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(commits.count) commit\(commits.count == 1 ? "" : "s") beyond \(commits.baseRef)")
            }
            ForEach(Self.upstreamStatusItems(upstreamStatus, isMain: isMain), id: \.text) { item in
                Text(item.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color(item.text.hasPrefix("↓") ? "caution" : "accent"))
                    .help(item.accessibilityLabel)
                    .accessibilityLabel(item.accessibilityLabel)
            }
            if let additionTicks = Self.diffBarAdditionCount(added: diffStats.added, deleted: diffStats.deleted) {
                HStack(spacing: 5) {
                    if showsDiffBar {
                        HStack(spacing: 1.5) {
                            ForEach(0..<5) { tick in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(theme.color(tick < additionTicks ? "add" : "del"))
                                    .frame(width: 2, height: 7)
                            }
                        }
                        .accessibilityHidden(true)
                    }
                    if diffStats.added > 0 {
                        Text("+\(diffStats.added)").foregroundColor(theme.color("add"))
                    }
                    if diffStats.deleted > 0 {
                        Text("−\(diffStats.deleted)").foregroundColor(theme.color("del"))
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(diffStats.added) lines added, \(diffStats.deleted) lines deleted")
            }
            stackSummaryView
            Spacer(minLength: 0)
            Text(relative(worktree.lastActivity))
                .monospacedDigit()
                .fixedSize()
        }
    }

    private var operationLine: some View {
        HStack(spacing: 5) {
            if Self.showsProgress(operationState: operationState) {
                Spinner(lineWidth: 1.5, duration: 0.7, color: theme.color("warn"))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            Text(Self.statusText(for: operationState))
                .font(.system(size: 10.5))
                .foregroundColor(theme.color("warn"))
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .padding(.leading, 19)
    }

    @ViewBuilder
    private var stackSummaryView: some View {
        if let stack = stackSummary {
            let summaryText = stack.isRemoteStateKnown
                ? Self.stackSummaryTooltip(merged: stack.merged, total: stack.total)
                : "gg stack · \(stack.total) commits · merge status pending"
            HStack(spacing: 3) {
                GGStackIcon(size: 9, color: theme.color("fg-faint"))
                    .accessibilityHidden(true)
                Text(stack.isRemoteStateKnown ? "\(stack.merged)/\(stack.total)" : "\(stack.total)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
            }
            .help(summaryText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summaryText)
        } else if ggMenuModel.showsStatusIndicator {
            GGStackIcon(size: 9, color: theme.color(Self.pendingStackIndicatorColorToken()))
                .help("gg is active for this worktree.")
                .accessibilityLabel("gg is active for this worktree.")
        }
    }

    private func agentBadges(
        summary: HarnessService.WorktreeHarnessSummary
    ) -> some View {
        HStack(spacing: 4) {
            let visibleSessionCount = Self.visibleHarnessSessionCount(for: summary.sessions.count)
            ForEach(summary.sessions.prefix(visibleSessionCount)) { session in
                HarnessSessionBadge(
                    session: session,
                    onActivate: { onActivateHarness(session.id) },
                    isSelected: isSelected
                )
            }
            if summary.sessions.count > visibleSessionCount {
                let hiddenSessions = Array(summary.sessions.dropFirst(visibleSessionCount))
                HarnessSessionOverflowBadge(
                    sessions: hiddenSessions,
                    onActivate: onActivateHarness,
                    isSelected: isSelected
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
            if Self.showsRemovalActions(isMain: isMain) {
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
        Button("Open in Terminal", action: onOpenTerminal)
        if let onOpenIssue {
            Button("Open Issue", action: onOpenIssue)
            Divider()
        }
        Button("Copy Path", action: onCopyPath)
        Button("Copy Branch Name", action: onCopyBranch)
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
        if Self.showsRemovalActions(isMain: isMain) {
            Button("Archive", action: onArchive)
            Button("Delete Worktree…", role: .destructive, action: onDelete)
            if showKeepBranchOption {
                Button("Delete Worktree, Keep Branch…", role: .destructive, action: onDeleteKeepBranch)
            }
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

    private func relative(_ date: Date) -> String {
        Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// Line 2's status dot. Pulses for a running session, matching E1's
/// `@keyframes pulse`, and holds still under Reduce Motion — a sidebar full
/// of running worktrees would otherwise animate continuously.
private struct StatusDot: View {
    let color: Color
    let pulses: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay {
                if pulses && !reduceMotion {
                    Circle()
                        .stroke(color, lineWidth: 2)
                        .scaleEffect(animating ? 2.2 : 1)
                        .opacity(animating ? 0 : 0.5)
                        .animation(
                            .easeInOut(duration: 1.9).repeatForever(autoreverses: false),
                            value: animating
                        )
                }
            }
            .onAppear { animating = true }
            .accessibilityHidden(true)
    }
}

private extension String {
    var trimmedForDisplay: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
