import SwiftUI

struct WorkingTreeSectionView: View {
    let changes: [ChangedFile]
    @Binding var expanded: Bool
    let onSelect: (ChangedFile) -> Void

    @Environment(\.theme) private var theme

    @State private var stagedExpanded: Bool = true
    @State private var unstagedExpanded: Bool = true
    @State private var collapsedChangePaths: Set<String> = []

    private var staged:   [ChangedFile] { changes.filter { $0.stage == .staged   } }
    private var unstaged: [ChangedFile] { changes.filter { $0.stage == .unstaged } }
    private var totalAdd: Int { changes.reduce(0) { $0 + $1.add } }
    private var totalDel: Int { changes.reduce(0) { $0 + $1.del } }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "Working tree",
                count: changes.count,
                expanded: expanded,
                onToggle: { expanded.toggle() }
            ) {
                if shouldShowChangeSummary(additions: totalAdd, deletions: totalDel) {
                    HStack(spacing: 6) {
                        Text("+\(totalAdd)").foregroundColor(theme.color("add"))
                        Text("−\(totalDel)").foregroundColor(theme.color("del"))
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }

            if expanded {
                if changes.isEmpty {
                    Text("no changes")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-faint"))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if !staged.isEmpty {
                        subsection(title: "Staged", files: staged, expanded: $stagedExpanded, collapseNamespace: "staged")
                    }
                    if !unstaged.isEmpty {
                        subsection(title: "Unstaged", files: unstaged, expanded: $unstagedExpanded, collapseNamespace: "unstaged")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func subsection(
        title: String,
        files: [ChangedFile],
        expanded: Binding<Bool>,
        collapseNamespace: String
    ) -> some View {
        SubHeader(
            title: title,
            count: files.count,
            expanded: expanded.wrappedValue,
            onToggle: { expanded.wrappedValue.toggle() }
        )
        if expanded.wrappedValue {
            let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
            ForEach(ChangesTreeBuilder.build(files: files)) { node in
                renderNode(node, filesByPath: filesByPath, depth: 0, collapseNamespace: collapseNamespace)
            }
        }
    }

    private func renderNode(
        _ node: FileTreeNode,
        filesByPath: [String: ChangedFile],
        depth: Int,
        collapseNamespace: String
    ) -> AnyView {
        if node.kind == .dir {
            let collapseKey = "\(collapseNamespace):\(node.path)"
            let open = !collapsedChangePaths.contains(collapseKey)
            return AnyView(
                Group {
                    Button {
                        if open {
                            collapsedChangePaths.insert(collapseKey)
                        } else {
                            collapsedChangePaths.remove(collapseKey)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Icon(name: open ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
                            Icon(name: "folder", size: 11, color: open ? theme.color("accent") : theme.color("fg-dim"))
                            Text(node.name)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(theme.color("fg"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.leading, CGFloat(12 + depth * 14))
                        .padding(.trailing, 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if open, let kids = node.children {
                        ForEach(kids) {
                            renderNode(
                                $0,
                                filesByPath: filesByPath,
                                depth: depth + 1,
                                collapseNamespace: collapseNamespace
                            )
                        }
                    }
                }
            )
        } else if let file = filesByPath[node.path] {
            return AnyView(
                ChangedRow(file: file, depth: depth, onSelect: { onSelect(file) })
            )
        } else {
            return AnyView(EmptyView())
        }
    }
}
