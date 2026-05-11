import SwiftUI

struct FilesTabView: View {
    let nodes: [FileTreeNode]
    @Binding var openPaths: Set<String>
    let onSelectFile: (FileTreeNode) -> Void

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
                        if open { openPaths.remove(node.path) } else { openPaths.insert(node.path) }
                    } label: {
                        HStack(spacing: 6) {
                            Icon(name: open ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
                            Icon(name: "folder", size: 11, color: open ? theme.color("accent") : theme.color("fg-dim"))
                            Text(node.name)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(theme.color("fg"))
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
                        ForEach(kids) { renderNode($0, depth: depth + 1) }
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
                            .foregroundColor(theme.color("fg"))
                        Spacer()
                        if let badge = node.badge {
                            StatusBadge(status: badge)
                        }
                    }
                    .padding(.leading, CGFloat(12 + depth * 14 + 14))
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            )
        }
    }
}
