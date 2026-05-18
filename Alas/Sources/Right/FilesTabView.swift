import SwiftUI

struct FilesTabView: View {
    let nodes: [FileTreeNode]
    let fileTreeGeneration: Int
    @Binding var openPaths: Set<String>
    let onSelectFile: (FileTreeNode) -> Void
    let shouldAutoLoadChildren: (String, DirectoryChildrenState) -> Bool
    let onLoadChildren: (String) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(nodes) { node in
                    renderNode(node, depth: 0)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func renderNode(_ node: FileTreeNode, depth: Int) -> AnyView {
        if node.kind == .dir {
            let open = openPaths.contains(node.path)
            return AnyView(
                Group {
                    Button {
                        if open {
                            openPaths.remove(node.path)
                        } else {
                            openPaths.insert(node.path)
                            onLoadChildren(node.path)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Icon(name: open ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
                            Icon(name: "folder", size: 11, color: folderColor(for: node, open: open))
                            Text(node.name)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(rowForeground(for: node))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if isOffGit(node) {
                                visibilityPill(node)
                            }
                        }
                        .padding(.leading, CGFloat(12 + depth * 14))
                        .padding(.trailing, 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(isOffGit(node) ? 0.72 : 1.0)
                        .overlay(alignment: .leading) {
                            if isOffGit(node) {
                                ghostRail(depth: depth)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if open {
                        switch node.childrenState {
                        case .loading:
                            treeMessage("Loading...", depth: depth + 1)
                            renderChildren(of: node, depth: depth + 1)
                        case .failed:
                            treeMessage("Could not load children", depth: depth + 1)
                            renderChildren(of: node, depth: depth + 1)
                        case .loaded:
                            renderChildren(of: node, depth: depth + 1)
                        case .notLoaded:
                            EmptyView()
                        }
                    }
                }
                .task(id: loadTaskID(for: node, open: open)) {
                    if shouldAutoLoadChildren(for: node, open: open) {
                        onLoadChildren(node.path)
                    }
                }
            )
        } else {
            return AnyView(
                Button { onSelectFile(node) } label: {
                    HStack(spacing: 6) {
                        FileTypeIconView(filename: node.name, size: 18)
                        Text(node.name)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(rowForeground(for: node))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if isOffGit(node) {
                            visibilityPill(node)
                        }
                        if let badge = node.badge {
                            StatusBadge(status: badge)
                        }
                    }
                    .padding(.leading, CGFloat(12 + depth * 14 + 14))
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(isOffGit(node) ? 0.72 : 1.0)
                    .overlay(alignment: .leading) {
                        if isOffGit(node) {
                            ghostRail(depth: depth)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            )
        }
    }

    private func loadTaskID(for node: FileTreeNode, open: Bool) -> String {
        "\(fileTreeGeneration):\(node.path):\(open):\(node.childrenState.rawValue)"
    }

    private func shouldAutoLoadChildren(for node: FileTreeNode, open: Bool) -> Bool {
        open && shouldAutoLoadChildren(node.path, node.childrenState)
    }

    private func renderChildren(of node: FileTreeNode, depth: Int) -> some View {
        Group {
            if let kids = node.children {
                ForEach(kids) { renderNode($0, depth: depth) }
            }
        }
    }

    private func isOffGit(_ node: FileTreeNode) -> Bool {
        node.visibility == .ignored || node.visibility == .excluded
    }

    private func rowForeground(for node: FileTreeNode) -> Color {
        isOffGit(node) ? theme.color("fg-dim") : theme.color("fg")
    }

    private func folderColor(for node: FileTreeNode, open: Bool) -> Color {
        if isOffGit(node) {
            return theme.color("fg-dim")
        }
        return open ? theme.color("accent") : theme.color("fg-dim")
    }

    private func visibilityPill(_ node: FileTreeNode) -> some View {
        Text(node.visibility.rawValue)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(theme.color("fg-dim"))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(theme.color("bg-4").opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func ghostRail(depth: Int) -> some View {
        Rectangle()
            .fill(theme.color("fg-faint").opacity(0.55))
            .frame(width: 2)
            .padding(.leading, CGFloat(8 + depth * 14))
            .padding(.vertical, 4)
    }

    private func treeMessage(_ text: String, depth: Int) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(theme.color("fg-faint"))
            .padding(.leading, CGFloat(12 + depth * 14 + 14))
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
