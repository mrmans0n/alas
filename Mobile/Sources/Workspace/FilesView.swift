import AlasRemoteKit
import SwiftUI

/// The session's file tree. Each appearance asks the host for the root listing again, and the
/// root reply re-lists every expanded directory, so files the agent changed show up.
struct FilesView: View {
    let workspace: SessionWorkspace
    let session: TranscriptSession
    let owner: UUID
    @State private var query = ""

    var body: some View {
        let rows = workspace.tree.rows()
        Group {
            if !query.isEmpty {
                results
            } else if rows.isEmpty {
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
        .searchable(text: $query, prompt: "Search files")
        // The host's file search, as the composer's @ picker uses, after 120 ms of quiet.
        .task(id: query) {
            guard !query.isEmpty, query.count <= RemoteAttachmentLimits.maxMentionQueryLength else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            session.searchMentions(query)
        }
        .task { workspace.loadTree() }
    }

    @ViewBuilder
    private var results: some View {
        let files = session.mentionCandidates.filter { $0.kind == RemoteMention.file }
        if files.isEmpty {
            if session.mentionCandidatesQuery == query {
                ContentUnavailableView.search(text: query)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List(files, id: \.value) { file in
                Button { workspace.openFile(file.value, by: owner) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        Text(file.value).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                .foregroundStyle(.primary)
            }
            .listStyle(.plain)
            // The previous answer stays up, dimmed, until this query's arrives.
            .opacity(session.mentionCandidatesQuery == query ? 1 : 0.5)
        }
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
                StatusBadge(status: badge)
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
    }
}
