import SwiftUI

struct WorkspaceCheckoutDetailView: View {
    let model: WorkspaceCheckoutDetailModel
    var perform: (WorkspaceCheckoutActionKind, UUID?) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.title).font(.title2)
                    Text(statusText).foregroundStyle(.secondary)
                }
                Spacer()
                ForEach(model.headerBadges.map(\.label), id: \.self) { badge in
                    Text(badge).font(.caption).padding(4).background(.quaternary, in: Capsule())
                }
            }
            if let stopMessage = model.stopMessage {
                Text(stopMessage).foregroundStyle(.secondary)
            }
            ForEach(model.diagnostics, id: \.self) { diagnostic in
                Text(diagnostic).foregroundStyle(.red)
            }
            ProgressView(value: Double(model.progress.completedMembers), total: Double(max(model.progress.totalMembers, 1)))
            HStack {
                ForEach(model.primaryActions) { action in
                    Button(action.title) { perform(action.kind, nil) }
                        .foregroundStyle(action.isDestructive ? .red : .primary)
                }
            }
            ForEach(model.memberRows) { row in
                WorkspaceCheckoutMemberRow(row: row) { action in perform(action, row.id) }
            }
        }
        .padding()
    }

    private var statusText: String {
        switch model.status {
        case .ready(let value), .creating(let value), .partial(let value), .needsAttention(let value), .archived(let value), .formerWorkspace(let value):
            value
        }
    }
}

struct WorkspaceCheckoutMemberRow: View {
    let row: WorkspaceCheckoutMemberRowModel
    var perform: (WorkspaceCheckoutActionKind) -> Void = { _ in }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(row.title)
                Text(row.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.status.label).font(.caption)
            ForEach(row.actions) { action in
                Button(action.title) { perform(action.kind) }
                    .foregroundStyle(action.isDestructive ? .red : .primary)
            }
        }
    }
}

struct WorkspaceRepairPlanSheet: View {
    let model: WorkspaceRepairPlanModel
    var choose: (WorkspaceRepairCandidate) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Repair \(model.memberName)")
                .font(.headline)
            ForEach(model.verifiedCandidates) { candidate in
                Button(candidate.path) { choose(candidate) }
            }
        }
        .padding()
    }
}

struct WorkspaceDeletionConfirmationSheet: View {
    let model: WorkspaceLifecycleConfirmationModel
    var confirm: (WorkspaceLifecycleAction) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.title).font(.headline)
            ForEach(model.risks, id: \.self) { risk in
                Text(risk)
            }
            Button("Confirm") { confirm(model.confirmAction) }
        }
        .padding()
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
