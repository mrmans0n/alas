import AlasRemoteKit
import SwiftUI

/// The session's file tree. The first appearance asks the host for the root listing.
struct FilesView: View {
    let workspace: SessionWorkspace
    let owner: UUID

    var body: some View {
        let rows = workspace.tree.rows()
        Group {
            if rows.isEmpty {
                if let error = workspace.treeError {
                    ContentUnavailableView {
                        Label(error, systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("Try Again") { workspace.loadTree() }
                    }
                } else if workspace.tree.children[""] != nil {
                    ContentUnavailableView("No files", systemImage: "folder")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    if let error = workspace.treeError {
                        Text(error).font(.footnote).foregroundStyle(.red).listRowSeparator(.hidden)
                    }
                    ForEach(rows, id: \.node.path) { row in
                        FileTreeRow(node: row.node, depth: row.depth, expanded: workspace.tree.expanded.contains(row.node.path))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if row.node.kind == "dir" {
                                    if RemoteFileTree.canExpand(row.node) { workspace.toggle(row.node.path) }
                                } else {
                                    workspace.openFile(row.node.path, by: owner)
                                }
                            }
                    }
                    if !workspace.truncatedDirs.isEmpty {
                        Text("Directory truncated — too many entries to show.")
                            .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .task { if workspace.tree.children.isEmpty { workspace.loadTree() } }
    }
}

private struct FileTreeRow: View {
    let node: RemoteFileNode
    let depth: Int
    let expanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            if RemoteFileTree.canExpand(node) {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Image(systemName: node.kind == "dir" ? (expanded ? "folder.fill" : "folder") : "doc")
                .foregroundStyle(node.kind == "dir" ? Color.accentColor : .secondary)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if node.isSubmodule {
                Text("submodule").font(.caption).foregroundStyle(.secondary)
            } else if let badge = node.badge {
                Text(badge).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
    }
}
