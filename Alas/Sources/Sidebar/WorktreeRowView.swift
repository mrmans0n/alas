import SwiftUI

struct GGWorktreeMenuModel: Equatable {
    let selectedMode: GGWorktreeMode
    let isEffectiveActive: Bool
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

    let worktree: Worktree
    let isSelected: Bool
    let isMain: Bool
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
    let onRetryDelete: () -> Void
    let onSetGGWorktreeMode: (GGWorktreeMode) -> Void
    @Environment(\.theme) var theme
    @State private var hovering = false

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
        case .deleteFailed(let msg): return "Delete failed: \(msg.trimmedForDisplay)"
        case .none: return ""
        }
    }

    nonisolated static func showsProgress(operationState: WorktreeOperationState?) -> Bool {
        switch operationState {
        case .preparingDelete, .deleting: return true
        case .creating, .createFailed, .deleteFailed, .none: return false
        }
    }

    private var isPending: Bool {
        Self.isPending(operationState: operationState)
    }

    private var errorMessage: String? {
        switch operationState {
        case .createFailed(_, let message, _, _, _, _), .deleteFailed(let message):
            return message
        case .creating, .preparingDelete, .deleting, .none:
            return nil
        }
    }

    private var stackSummary: GGStackSummary? {
        GGStackSummaryStore.shared.summaries[worktree.path.path]
    }

    var body: some View {
        let status = Self.statusPresentation(
            harnessState: harnessSummary?.state,
            worktreeStatus: .unknown
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
                    .fill(theme.color("bg-2"))
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
        HStack(spacing: 7) {
            // Dot and label render together or not at all. An idle worktree has
            // nothing to report until the git status service lands, and a dot on
            // its own reads as an unexplained decoration.
            if let status {
                HStack(spacing: 5) {
                    StatusDot(color: theme.color(status.colorToken), pulses: status.pulses)
                    Text(status.note)
                        .foregroundColor(theme.color(status.colorToken))
                }
            }
            if worktree.addedLines > 0 {
                Text("+\(worktree.addedLines)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("add"))
            }
            if worktree.deletedLines > 0 {
                Text("−\(worktree.deletedLines)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("del"))
            }
            stackSummaryView
            Spacer(minLength: 0)
            Text(relative(worktree.lastActivity))
                .monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundColor(theme.color("fg-dim"))
        // Aligns line 2 under the branch text, not under the row's icon.
        .padding(.leading, 19)
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
            let summaryText = Self.stackSummaryTooltip(merged: stack.merged, total: stack.total)
            HStack(spacing: 3) {
                GGStackIcon(size: 9, color: theme.color("fg-faint"))
                    .accessibilityHidden(true)
                Text("\(stack.merged)/\(stack.total)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
            }
            .help(summaryText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Self.stackSummaryAccessibilityLabel(merged: stack.merged, total: stack.total)
            )
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
            ForEach(summary.sessions.prefix(2)) { session in
                HarnessSessionBadge(
                    session: session,
                    onActivate: { onActivateHarness(session.id) },
                    isSelected: isSelected
                )
            }
            if summary.sessions.count > 2 {
                let hiddenSessions = Array(summary.sessions.dropFirst(2))
                let overflowState: HarnessService.AggregatedState =
                    hiddenSessions.contains { $0.state == .running } ? .running : .awaiting
                Menu {
                    ForEach(hiddenSessions) { session in
                        Button {
                            onActivateHarness(session.id)
                        } label: {
                            Label {
                                Text("\(session.agent.displayName) · \(session.state == .running ? "running" : "waiting")")
                            } icon: {
                                Image(nsImage: AgentLogoView.menuImage(for: session.agent, size: 14))
                            }
                        }
                    }
                } label: {
                    Text("+\(summary.sessions.count - 2)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                        .frame(
                            width: HarnessSessionBadge.diameter,
                            height: HarnessSessionBadge.diameter
                        )
                        .modifier(HarnessSessionBadgeChrome(state: overflowState, isSelected: isSelected))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("\(summary.sessions.count - 2) more active session\(summary.sessions.count == 3 ? "" : "s")")
                .accessibilityLabel("\(summary.sessions.count - 2) more active sessions")
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
