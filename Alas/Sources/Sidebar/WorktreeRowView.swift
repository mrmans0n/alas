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
    let onActivateHarness: () -> Void
    let onCopyError: (String) -> Void
    let onRemoveFailed: () -> Void
    let onRetryCreate: () -> Void
    let onRetryDelete: () -> Void
    let onSetGGWorktreeMode: (GGWorktreeMode) -> Void
    @Environment(\.theme) var theme

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
        ZStack(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.color("bg-4"))
                Rectangle()
                    .fill(theme.color("accent"))
                    .frame(width: 3, height: 14)
                    .cornerRadius(2)
                    .offset(x: 2, y: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Icon(
                        name: isMain ? "home" : "branch",
                        size: 11,
                        color: theme.color(isMain ? "fg-muted" : "fg-faint")
                    )
                    Text(worktree.branch)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.color(isPending ? "fg-faint" : "fg"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if operationState != nil {
                    HStack(spacing: 5) {
                        if Self.showsProgress(operationState: operationState) {
                            Spinner(lineWidth: 1.5, duration: 0.7, color: theme.color("warning"))
                                .frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                        }
                        Text(Self.statusText(for: operationState))
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.color("warning"))
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(relative(worktree.lastActivity))
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.color("fg-faint"))
                        if worktree.addedLines > 0 {
                            Text("+\(worktree.addedLines)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(theme.color("add"))
                        }
                        if worktree.deletedLines > 0 {
                            Text("−\(worktree.deletedLines)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(theme.color("del"))
                        }
                        if let stack = stackSummary {
                            let summaryText = Self.stackSummaryTooltip(merged: stack.merged, total: stack.total)
                            HStack(spacing: 3) {
                                GGStackIcon(
                                    size: 9,
                                    color: theme.color("fg-faint")
                                )
                                    .accessibilityHidden(true)
                                Text("\(stack.merged)/\(stack.total)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(theme.color("fg-faint"))
                            }
                            .help(summaryText)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Self.stackSummaryAccessibilityLabel(merged: stack.merged, total: stack.total))
                        } else if ggMenuModel.showsStatusIndicator {
                            GGStackIcon(
                                size: 9,
                                color: theme.color(Self.pendingStackIndicatorColorToken())
                            )
                                .help("gg is active for this worktree.")
                                .accessibilityLabel("gg is active for this worktree.")
                        }
                        if let summary = harnessSummary {
                            Spacer()
                            Button(action: onActivateHarness) {
                                HarnessPill(
                                    summary: summary,
                                    variant: .full,
                                    tooltip: pillTooltip(for: summary),
                                    isSelected: isSelected
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(minHeight: 18)
                }
            }
            .padding(.leading, 32)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(isPending ? 0.55 : 1)
        .onTapGesture {
            if !isPending {
                onTap()
            }
        }
        .contextMenu {
            if case .createFailed = operationState {
                Button("Retry Create", action: onRetryCreate)
                Button("Remove from List", role: .destructive, action: onRemoveFailed)
                Divider()
                if let errorMessage {
                    Button("Copy Error") { onCopyError(errorMessage) }
                }
                Button("Copy Path", action: onCopyPath)
            } else if case .deleteFailed = operationState {
                Button("Retry Delete", action: onRetryDelete)
                Button("Archive", action: onArchive)
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
                        ForEach(Self.ggModeMenuItems(selectedMode: ggMenuModel.selectedMode)) { item in
                            Toggle(item.title, isOn: Binding(
                                get: { item.isSelected },
                                set: { isOn in
                                    guard isOn, item.mode != ggMenuModel.selectedMode else { return }
                                    onSetGGWorktreeMode(item.mode)
                                }
                            ))
                        }
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
    }

    private func relative(_ date: Date) -> String {
        Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func pillTooltip(for summary: HarnessService.WorktreeHarnessSummary) -> String {
        let stateText: String
        switch summary.state {
        case .running:  stateText = "running"
        case .awaiting: stateText = "awaiting"
        }
        return "\(summary.agent.displayName) · \(stateText)"
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private extension String {
    var trimmedForDisplay: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
