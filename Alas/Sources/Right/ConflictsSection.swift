import SwiftUI

struct ConflictsSection: View {
    let conflicts: [ChangedFile]
    let onSelect: (ChangedFile) -> Void
    let onUseOurs: (ChangedFile) -> Void
    let onUseTheirs: (ChangedFile) -> Void
    let onKeepDeleted: (ChangedFile) -> Void
    let onMarkResolved: (ChangedFile) -> Void

    @State private var pendingBothDeletedConfirm: ChangedFile?

    var body: some View {
        if conflicts.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Conflicts (\(conflicts.count))")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                ForEach(conflicts) { file in
                    row(for: file)
                }
            }
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func row(for file: ChangedFile) -> some View {
        switch file.conflict {
        case .bothDeleted:
            bothDeletedRow(file)
        case .deletedByUs, .deletedByThem:
            deleteSideRow(file)
        default:
            textConflictRow(for: file)
        }
    }

    private func textConflictRow(for file: ChangedFile) -> some View {
        Button(action: { onSelect(file) }) {
            HStack(spacing: 6) {
                Image(systemName: iconName(for: file.conflict))
                    .foregroundColor(iconColor(for: file.conflict))
                    .frame(width: 14)
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.primary)
                Spacer()
                Text(kindLabel(file.conflict))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            menuItems(for: file)
        }
    }

    private func bothDeletedRow(_ file: ChangedFile) -> some View {
        Button(action: { pendingBothDeletedConfirm = file }) {
            HStack(spacing: 6) {
                Image(systemName: "trash.fill")
                    .foregroundColor(.red)
                    .frame(width: 14)
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.primary)
                Spacer()
                Text("both deleted")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            "Both sides deleted this file. Stage the deletion?",
            isPresented: Binding(
                get: { pendingBothDeletedConfirm?.id == file.id },
                set: { if !$0 { pendingBothDeletedConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Keep deleted", role: .destructive) {
                onKeepDeleted(file)
                pendingBothDeletedConfirm = nil
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func deleteSideRow(_ file: ChangedFile) -> some View {
        let isOursDeleted = file.conflict == .deletedByUs
        return HStack(spacing: 6) {
            Image(systemName: "trash.fill")
                .foregroundColor(.orange)
                .frame(width: 14)
            Text(file.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.primary)
            Spacer()
            Button(isOursDeleted ? "Keep theirs" : "Keep ours") {
                if isOursDeleted { onUseTheirs(file) } else { onUseOurs(file) }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            Button("Keep deleted") { onKeepDeleted(file) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contextMenu {
            if isOursDeleted {
                Button("Keep theirs") { onUseTheirs(file) }
            } else {
                Button("Keep ours") { onUseOurs(file) }
            }
            Button("Keep deleted") { onKeepDeleted(file) }
            Divider()
            Button("Mark resolved") { onMarkResolved(file) }
        }
    }

    /// Context menu for `textConflictRow` only. Delete-side and bothDeleted
    /// rows render their own dedicated rows + menus and never reach here.
    @ViewBuilder
    private func menuItems(for file: ChangedFile) -> some View {
        switch file.conflict {
        case .bothModified, .bothAdded:
            Button("Use ours") { onUseOurs(file) }
            Button("Use theirs") { onUseTheirs(file) }
        case .addedByUs:
            Button("Keep ours") { onUseOurs(file) }
        case .addedByThem:
            Button("Keep theirs") { onUseTheirs(file) }
        case .deletedByUs, .deletedByThem, .bothDeleted, nil:
            EmptyView()
        }
        Divider()
        Button("Mark resolved") { onMarkResolved(file) }
    }

    private func iconName(for kind: ConflictKind?) -> String {
        switch kind {
        case .bothModified, .bothAdded, .bothDeleted, nil:
            return "exclamationmark.triangle.fill"
        case .deletedByUs, .deletedByThem:
            return "trash.fill"
        case .addedByUs, .addedByThem:
            return "plus.circle.fill"
        }
    }

    private func iconColor(for kind: ConflictKind?) -> Color {
        switch kind {
        case .bothDeleted: return .red
        default:           return .orange
        }
    }

    private func kindLabel(_ kind: ConflictKind?) -> String {
        switch kind {
        case .bothModified:  return "both modified"
        case .bothAdded:     return "both added"
        case .bothDeleted:   return "both deleted"
        case .addedByUs:     return "added by us"
        case .addedByThem:   return "added by them"
        case .deletedByUs:   return "deleted by us"
        case .deletedByThem: return "deleted by them"
        case nil:            return ""
        }
    }
}
