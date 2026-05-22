import SwiftUI

struct WorktreeRowView: View {
    let worktree: Worktree
    let isSelected: Bool
    let operationState: WorktreeOperationState?
    let harnessSummary: HarnessService.WorktreeHarnessSummary?
    let onTap: () -> Void
    let onOpenTerminal: () -> Void
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
    @Environment(\.theme) var theme

    private var isPending: Bool {
        switch operationState {
        case .creating, .deleting: return true
        default: return false
        }
    }

    private var statusText: String {
        switch operationState {
        case .creating: return "Creating…"
        case .deleting: return "Deleting…"
        case .createFailed(let msg, _): return "Create failed: \(msg.trimmedForDisplay)"
        case .deleteFailed(let msg): return "Delete failed: \(msg.trimmedForDisplay)"
        case .none: return ""
        }
    }

    private var errorMessage: String? {
        switch operationState {
        case .createFailed(let message, _), .deleteFailed(let message):
            return message
        case .creating, .deleting, .none:
            return nil
        }
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
                    Icon(name: "branch", size: 11, color: theme.color("fg-faint"))
                    Text(worktree.branch)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.color(isPending ? "fg-faint" : "fg"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if operationState != nil {
                    Text(statusText)
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.color("warning"))
                        .lineLimit(2)
                        .truncationMode(.tail)
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
                Button("Copy Path", action: onCopyPath)
                Button("Copy Branch Name", action: onCopyBranch)
                Button("Reveal in Finder", action: onRevealInFinder)
                Divider()
                Button("Archive", action: onArchive)
                Button("Delete Worktree…", role: .destructive, action: onDelete)
                if showKeepBranchOption {
                    Button("Delete Worktree, Keep Branch…", role: .destructive, action: onDeleteKeepBranch)
                }
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func pillTooltip(for summary: HarnessService.WorktreeHarnessSummary) -> String {
        let stateText: String
        switch summary.state {
        case .running:  stateText = "running"
        case .awaiting: stateText = "awaiting"
        }
        return "\(summary.agent.displayName) · \(stateText)"
    }
}

private extension String {
    var trimmedForDisplay: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
