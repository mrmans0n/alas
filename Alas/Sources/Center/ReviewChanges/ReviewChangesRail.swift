import AppKit
import SwiftUI

struct ReviewChangesRail: View {
    let session: ReviewChangesSessionModel
    @Binding var selectedFileID: ReviewChangesFileID
    @Binding var collapsed: Bool
    let onSelectFile: (ReviewChangesFileID) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if collapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .frame(width: collapsed ? 44 : 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(width: 0.5), alignment: .trailing)
    }

    private var expandedBody: some View {
        VStack(spacing: 0) {
            expandedHeader
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(session.sections) { section in
                        sourceHeader(section)
                        ForEach(ReviewChangesFileTreeBuilder.build(files: section.files)) { node in
                            ReviewChangesRailTreeNode(
                                node: node,
                                depth: 0,
                                selectedFileID: $selectedFileID,
                                onSelectFile: onSelectFile
                            )
                        }
                        if section.id != session.sections.last?.id {
                            Divider()
                                .overlay(theme.color("line"))
                                .padding(.vertical, 6)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    private var collapsedBody: some View {
        VStack(spacing: 8) {
            collapseButton
                .padding(.top, 8)
            Divider()
                .overlay(theme.color("line"))
                .padding(.horizontal, 8)
            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(session.files) { file in
                        collapsedMarker(for: file)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var expandedHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(session.fileCount) changed \(session.fileCount == 1 ? "file" : "files")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("+\(session.totalAdditions)")
                        .foregroundColor(theme.color("add"))
                    Text("-\(session.totalDeletions)")
                        .foregroundColor(theme.color("del"))
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            Spacer(minLength: 8)
            collapseButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    private var collapseButton: some View {
        Button {
            collapsed.toggle()
        } label: {
            Image(systemName: collapsed ? "sidebar.left" : "sidebar.leading")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
                .frame(width: 26, height: 24)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Expand file rail" : "Collapse file rail")
        .accessibilityIdentifier("review-rail-collapse-toggle")
    }

    private func sourceHeader(_ section: ReviewChangesSourceSection) -> some View {
        HStack(spacing: 6) {
            Text(section.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
            Text("\(section.fileCount)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.color("fg-faint"))
        }
        .padding(.horizontal, 5)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func collapsedMarker(for file: ReviewChangesFileSummary) -> some View {
        let selected = selectedFileID == file.id
        return Button {
            selectedFileID = file.id
            onSelectFile(file.id)
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? theme.color("accent-soft") : theme.color("bg-3"))
                    .frame(width: 28, height: 26)
                Rectangle()
                    .fill(selected ? theme.color("accent") : Color.clear)
                    .frame(width: 3, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Text(file.status.glyph)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(selected ? theme.color("fg") : statusColor(file.status))
                    .frame(width: 28, height: 26)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review-rail-marker-\(file.id.rawValue)")
        .background(
            ZStack {
                ReviewChangesAccessibilityMarker(
                    identifier: "review-rail-marker-\(file.id.rawValue)",
                    label: file.path
                )
                if selected {
                    ReviewChangesAccessibilityMarker(
                        identifier: "review-rail-marker-selected-\(file.id.rawValue)",
                        label: file.path
                    )
                }
            }
        )
        .help(file.path)
    }

    private func statusColor(_ status: ReviewChangesFileStatus) -> Color {
        switch status {
        case .added:
            theme.color("add")
        case .deleted:
            theme.color("del")
        case .renamed, .copied:
            theme.color("accent")
        case .conflicted:
            theme.color("warn")
        case .modified, .unknown:
            theme.color("fg-dim")
        }
    }
}

private struct ReviewChangesRailTreeNode: View {
    let node: ReviewChangesFileTreeNode
    let depth: Int
    @Binding var selectedFileID: ReviewChangesFileID
    let onSelectFile: (ReviewChangesFileID) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let file = node.file {
                fileRow(file, name: node.name)
            } else {
                directoryRow
                ForEach(node.children ?? []) { child in
                    ReviewChangesRailTreeNode(
                        node: child,
                        depth: depth + 1,
                        selectedFileID: $selectedFileID,
                        onSelectFile: onSelectFile
                    )
                }
            }
        }
    }

    private var directoryRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.color("fg-faint"))
                .frame(width: 13)
            Text(node.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .frame(height: 22)
    }

    private func fileRow(_ file: ReviewChangesFileSummary, name: String) -> some View {
        let selected = selectedFileID == file.id
        return Button {
            selectedFileID = file.id
            onSelectFile(file.id)
        } label: {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(selected ? theme.color("accent") : Color.clear)
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Text(file.status.glyph)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(statusColor(file.status))
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(selected ? theme.color("fg") : theme.color("fg-muted"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let directory = file.directory {
                        Text(directory)
                            .font(.system(size: 10))
                            .foregroundColor(theme.color("fg-faint"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                changeSummary(file)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.trailing, 6)
            .frame(height: 34)
            .background(selected ? theme.color("accent-soft") : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review-rail-row-\(file.id.rawValue)")
        .background(
            ReviewChangesAccessibilityMarker(
                identifier: "review-rail-row-\(file.id.rawValue)",
                label: file.path
            )
        )
        .help(file.path)
    }

    private func changeSummary(_ file: ReviewChangesFileSummary) -> some View {
        HStack(spacing: 5) {
            if file.additions > 0 {
                Text("+\(file.additions)")
                    .foregroundColor(theme.color("add"))
            }
            if file.deletions > 0 {
                Text("-\(file.deletions)")
                    .foregroundColor(theme.color("del"))
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }

    private func statusColor(_ status: ReviewChangesFileStatus) -> Color {
        switch status {
        case .added:
            theme.color("add")
        case .deleted:
            theme.color("del")
        case .renamed, .copied:
            theme.color("accent")
        case .conflicted:
            theme.color("warn")
        case .modified, .unknown:
            theme.color("fg-dim")
        }
    }
}

struct ReviewChangesAccessibilityMarker: NSViewRepresentable {
    let identifier: String
    var label: String? = nil

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
    }
}
