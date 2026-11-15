import AlasRemoteKit
import SwiftUI

/// The Changes tab: branch, staged, unstaged and commit sections as a flat list; a file opens its diff.
struct ChangesView: View {
    let workspace: SessionWorkspace
    let owner: UUID

    var body: some View {
        Group {
            switch workspace.changes {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Changes unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { workspace.refreshChanges() }
                }
            case .loaded(let reply):
                ChangeList(reply: reply, workspace: workspace, owner: owner)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh Changes", systemImage: "arrow.clockwise") { workspace.refreshChanges() }
            }
        }
        .onAppear {
            if case .idle = workspace.changes { workspace.refreshChanges() }
        }
    }
}

private struct ChangeList: View {
    let reply: ChangeListReply
    let workspace: SessionWorkspace
    let owner: UUID

    private struct Section: Identifiable {
        let title: String
        let files: [RemoteChangedFile]
        let stage: String?
        let commits: [RemoteCommit]
        var id: String { title }
    }

    /// `changeSections` in changes-view.js.
    private var sections: [Section] {
        var out: [Section] = []
        let working = !reply.staged.isEmpty || !reply.unstaged.isEmpty
        if !reply.files.isEmpty, !reply.commits.isEmpty || !working {
            out.append(Section(title: "Branch Changes", files: reply.files, stage: nil, commits: []))
        }
        if !reply.staged.isEmpty { out.append(Section(title: "Staged", files: reply.staged, stage: "staged", commits: [])) }
        if !reply.unstaged.isEmpty { out.append(Section(title: "Unstaged", files: reply.unstaged, stage: "unstaged", commits: [])) }
        if !reply.commits.isEmpty { out.append(Section(title: "Commits", files: [], stage: nil, commits: reply.commits)) }
        return out
    }

    private var summary: String {
        let files = reply.changedFiles
        return RemoteChangesRules.summary(
            comparisonRef: reply.comparisonRef, fileCount: files.count,
            add: files.reduce(0) { $0 + $1.add }, del: files.reduce(0) { $0 + $1.del },
            commitCount: reply.commits.count, commitsTruncated: reply.commitsTruncated)
    }

    var body: some View {
        if !reply.metricsAvailable {
            ContentUnavailableView("Change metrics are unavailable for this worktree.", systemImage: "chart.bar.xaxis")
        } else if sections.isEmpty {
            ContentUnavailableView("No changes yet.", systemImage: "checkmark.circle")
        } else {
            List {
                Text(summary).font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                ForEach(sections) { section in
                    SwiftUI.Section(section.title) {
                        ForEach(RemoteChangesRules.grouped(section.files), id: \.directory) { group in
                            if !group.directory.isEmpty {
                                Label(group.directory, systemImage: "folder")
                                    .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                            }
                            ForEach(group.files, id: \.path) { file in
                                Button { workspace.openDiff(file.path, stage: section.stage, by: owner) } label: {
                                    FileRow(file: file, nested: !group.directory.isEmpty)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        ForEach(section.commits, id: \.revision) { CommitRow(commit: $0) }
                    }
                }
                if reply.truncated {
                    Text("File list truncated — too many changed files to show.").font(.footnote).foregroundStyle(.secondary)
                }
                if reply.commitsTruncated {
                    Text("Commit list truncated — showing the first 100 commits.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
        }
    }
}

private struct Counts: View {
    let add: Int
    let del: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(add)").foregroundStyle(.green)
            Text("\u{2212}\(del)").foregroundStyle(.red)
        }
        .font(.caption.monospacedDigit())
    }
}

private struct FileRow: View {
    let file: RemoteChangedFile
    let nested: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                .lineLimit(1).truncationMode(.middle)
            if file.conflict != nil {
                Text("conflict").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Text(file.status).font(.caption).foregroundStyle(.secondary)
            Counts(add: file.add, del: file.del)
        }
        .padding(.leading, nested ? 16 : 0)
        .contentShape(Rectangle())
    }
}

private struct CommitRow: View {
    let commit: RemoteCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject).lineLimit(2)
            HStack(spacing: 8) {
                Text(commit.shortSha).font(.caption.monospaced())
                Text(commit.author).lineLimit(1)
                Spacer(minLength: 8)
                Counts(add: commit.add, del: commit.del)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}
