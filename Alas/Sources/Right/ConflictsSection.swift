import SwiftUI

struct ConflictsSection: View {
    let conflicts: [ChangedFile]
    let onSelect: (ChangedFile) -> Void
    let onUseOurs: (ChangedFile) -> Void
    let onUseTheirs: (ChangedFile) -> Void
    let onMarkResolved: (ChangedFile) -> Void

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

    private func row(for file: ChangedFile) -> some View {
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
            Button("Use ours") { onUseOurs(file) }
            Button("Use theirs") { onUseTheirs(file) }
            Divider()
            Button("Mark resolved") { onMarkResolved(file) }
        }
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
