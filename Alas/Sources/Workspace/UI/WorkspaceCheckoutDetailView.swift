import SwiftUI

struct WorkspaceCheckoutDetailView: View {
    let model: WorkspaceCheckoutDetailModel
    var perform: (WorkspaceCheckoutActionKind, UUID?) -> Void = { _, _ in }
    var openReview: (WorkspaceReviewAction) -> Void = { _ in }
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Icon(name: "square.stack.3d.up", size: 18, color: theme.color("fg-muted"))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(2)
                    Label(model.checkout.branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(theme.color("fg-muted"))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DialogHeaderIconButton(icon: "x", tooltip: "Close checkout details") { dismiss() }
            }
            .padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(statusText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.color("fg-muted"))
                        Spacer()
                        ForEach(model.headerBadges.map(\.label), id: \.self) { badge in
                            Text(badge).font(.system(size: 10.5))
                                .foregroundColor(theme.color("fg-dim"))
                        }
                    }
                    if let stopMessage = model.stopMessage {
                        WorkspaceNotice(message: stopMessage)
                    }
                    ForEach(model.diagnostics, id: \.self) { diagnostic in
                        WorkspaceNotice(message: diagnostic, isError: true)
                    }
                    if model.checkout.operation == .creating || model.checkout.operation == .repairing {
                        ProgressView(value: Double(model.progress.completedMembers), total: Double(max(model.progress.totalMembers, 1)))
                            .tint(theme.color("accent"))
                    } else if model.checkout.operation != .idle {
                        ProgressView().controlSize(.small)
                    }
                    DialogField(label: "Checkout folder") {
                        Text(model.checkout.rootPath)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(theme.color("fg-muted"))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    DialogField(label: "Repositories") {
                        VStack(spacing: 0) {
                            ForEach(model.memberRows) { row in
                                WorkspaceCheckoutMemberRow(row: row) { action in perform(action, row.id) }
                                if row.id != model.memberRows.last?.id { Divider() }
                            }
                        }
                    }
                    if !model.checkout.workItems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Work items").font(.system(size: 11.5, weight: .medium)).foregroundColor(theme.color("fg-muted"))
                            SwiftUI.ForEach(0..<model.checkout.workItems.count, id: \.self) { index in
                                let item = model.checkout.workItems[index]
                                WorkspaceWorkItemDetailRow(item: item)
                            }
                        }
                    }
                    if let rollup = model.reviewRollup, !rollup.members.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Reviews").font(.system(size: 11.5, weight: .medium)).foregroundColor(theme.color("fg-muted"))
                            SwiftUI.ForEach(0..<rollup.members.count, id: \.self) { index in
                                let row = rollup.members[index]
                                WorkspaceReviewRollupDetailRow(row: row, openReview: openReview)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
            .frame(height: 380)
            HStack {
                Menu {
                    ForEach(model.primaryActions) { action in
                        Button(action.title, role: action.isDestructive ? .destructive : nil) {
                            perform(action.kind, nil)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Icon(name: "menu", size: 13)
                        Text("Checkout actions").font(.system(size: 12))
                    }
                    .foregroundColor(theme.color("fg-muted"))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.primaryActions.isEmpty)
                Spacer()
                AlasButton(title: "Done", style: .normal) { dismiss() }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(theme.color("bg-2"))
            .overlay(Divider(), alignment: .top)
        }
        .frame(width: 560)
        .background(theme.color("bg-1"))
        .onExitCommand { dismiss() }
    }

    private var statusText: String {
        switch model.checkout.operation {
        case .deleting: return "Deleting checkout"
        case .archiving: return "Archiving checkout"
        case .cleaning: return "Cleaning checkout"
        default: break
        }
        switch model.status {
        case .ready(let value), .creating(let value), .partial(let value), .needsAttention(let value), .archived(let value), .formerWorkspace(let value):
            return value
        }
    }
}

struct WorkspaceCheckoutMemberRow: View {
    let row: WorkspaceCheckoutMemberRowModel
    var perform: (WorkspaceCheckoutActionKind) -> Void = { _ in }
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Icon(name: row.status == .ready ? "checkmark.circle" : "folder", size: 14,
                 color: theme.color(row.status == .ready ? "add" : "fg-muted"))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.system(size: 12, weight: .medium)).foregroundColor(theme.color("fg"))
                Text(row.detail).font(.system(size: 11)).foregroundColor(theme.color("fg-dim"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.status.label).font(.system(size: 10.5)).foregroundColor(theme.color("fg-muted"))
            Menu {
                ForEach(row.actions) { action in
                    Button(action.title, role: action.isDestructive ? .destructive : nil) { perform(action.kind) }
                }
            } label: {
                Icon(name: "menu", size: 13).frame(width: 22, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(row.actions.isEmpty)
            .help("Actions for \(row.title)")
            .accessibilityLabel("Actions for \(row.title)")
        }
        .padding(.vertical, 10)
    }
}

private struct WorkspaceWorkItemDetailRow: View {
    let item: WorkItemSnapshot
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading) {
            Text(item.snapshot.title).font(.system(size: 12)).foregroundColor(theme.color("fg"))
            if let refreshError = item.snapshot.refreshError {
                Text(refreshError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(item.snapshot.displayReference ?? item.snapshot.providerLabel)
                    .font(.caption)
                    .foregroundColor(theme.color("fg-dim"))
            }
        }
    }
}

private struct WorkspaceReviewRollupDetailRow: View {
    let row: WorkspaceMemberReviewRollup.Member
    var openReview: (WorkspaceReviewAction) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading) {
            Text(row.title).font(.system(size: 12)).foregroundColor(theme.color("fg"))
            Text("\(row.reviews.count) reviews · \(row.ggStack?.entries.count ?? 0) GG commits · \(row.unpublishedStackEntries.count) unpublished")
                .font(.caption)
                .foregroundColor(theme.color("fg-dim"))
            VStack(alignment: .leading, spacing: 4) {
                SwiftUI.ForEach(0..<row.reviewActions.count, id: \.self) { index in
                    let action = row.reviewActions[index]
                    AlasButton(title: "Open review", icon: "arrow.up.right", style: .subtle) { openReview(action) }
                }
            }
        }
    }
}

struct WorkspaceRepairPlanSheet: View {
    let model: WorkspaceRepairPlanModel
    var choose: (WorkspaceRepairCandidate) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        DialogContainer(
            title: "Repair \(model.memberName)", subtitle: nil,
            content: {
                if model.verifiedCandidates.isEmpty {
                    Text("No matching worktrees found.")
                        .font(.system(size: 12)).foregroundColor(theme.color("fg-muted"))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.verifiedCandidates) { candidate in
                                Button { choose(candidate) } label: {
                                    HStack(spacing: 8) {
                                        Icon(name: "folder", size: 13)
                                        Text(candidate.path).font(.system(size: 11.5, design: .monospaced))
                                            .foregroundColor(theme.color("fg"))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Icon(name: "arrow.right", size: 12)
                                    }
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 180)
                }
            },
            cancelTitle: "Cancel", confirmTitle: "Done", confirmStyle: .normal,
            onCancel: { dismiss() }, onConfirm: { dismiss() }, confirmEnabled: true
        )
        .onExitCommand { dismiss() }
    }
}

struct WorkspaceDeletionConfirmationSheet: View {
    let model: WorkspaceLifecycleConfirmationModel
    var confirm: (WorkspaceLifecycleAction) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogContainer(
            title: model.title, subtitle: nil,
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.risks, id: \.self) { WorkspaceNotice(message: $0, isError: true) }
                    }
                }
                .frame(height: min(CGFloat(max(model.risks.count, 1)) * 44, 220))
            },
            cancelTitle: "Cancel", confirmTitle: confirmTitle, confirmStyle: .normal,
            onCancel: { dismiss() }, onConfirm: { confirm(model.confirmAction) }, confirmEnabled: true
        )
        .onExitCommand { dismiss() }
    }

    private var confirmTitle: String {
        switch model.confirmAction {
        case .deleteCheckout: "Delete checkout"
        case .deleteMember: "Delete worktree"
        case .forgetCheckout: "Forget checkout"
        }
    }
}

private extension WorkspaceCheckoutHeaderBadge {
    var label: String {
        switch self {
        case .archived: "Archived"
        case .formerWorkspace: "Former Workspace"
        case .stopRequested: "Stop Requested"
        }
    }
}

private extension WorkspaceCheckoutMemberPresentationStatus {
    var label: String {
        switch self {
        case .ready: "Ready"
        case .creating: "Creating"
        case .missing: "Missing"
        case .identityConflict: "Identity Conflict"
        case .needsAttention: "Needs Attention"
        case .explicitlyDeleted: "Explicitly Deleted"
        case .pending: "Pending"
        }
    }
}
