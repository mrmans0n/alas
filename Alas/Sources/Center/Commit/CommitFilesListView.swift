// Alas/Sources/Center/Commit/CommitFilesListView.swift
import SwiftUI

struct CommitFilesListView: View {
    let files: [CommitChangedFile]
    @Binding var selectedPath: String?
    let onDropFile: ((CommitChangedFile) -> Void)?
    let dropFileEnabled: (CommitChangedFile) -> Bool
    let dragPayload: ((CommitChangedFile) -> DragOutPayload?)?

    @Environment(\.theme) private var theme

    init(
        files: [CommitChangedFile],
        selectedPath: Binding<String?>,
        onDropFile: ((CommitChangedFile) -> Void)? = nil,
        dropFileEnabled: @escaping (CommitChangedFile) -> Bool = { _ in false },
        dragPayload: ((CommitChangedFile) -> DragOutPayload?)? = nil
    ) {
        self.files = files
        self._selectedPath = selectedPath
        self.onDropFile = onDropFile
        self.dropFileEnabled = dropFileEnabled
        self.dragPayload = dragPayload
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(files) { file in
                    row(file)
                }
            }
            .padding(.vertical, 4)
        }
        .background(theme.color("bg-1"))
    }

    private func row(_ file: CommitChangedFile) -> some View {
        let isSelected = file.path == selectedPath
        return Button {
            selectedPath = file.path
        } label: {
            HStack(spacing: 8) {
                Text(file.status)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(statusColor(file.status))
                    .frame(width: 12)
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((file.path as NSString).deletingLastPathComponent)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                if shouldShowChangeSummary(additions: file.add, deletions: file.del) {
                    Text("+\(file.add)").foregroundColor(theme.color("add"))
                    Text("−\(file.del)").foregroundColor(theme.color("del"))
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .centerPanelRowSpacing()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? theme.color("accent").opacity(0.2) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onDropFile {
                Button("Drop file from commit...") { onDropFile(file) }
                    .disabled(!dropFileEnabled(file))
            }
        }
        .dragOut { dragPayload?(file) }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "A": return theme.color("add")
        case "D": return theme.color("del")
        case "M": return theme.color("warn")
        case "R", "C": return theme.color("info")
        default:  return theme.color("fg-faint")
        }
    }
}
