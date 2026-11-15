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

    @State private var error: String?
    @State private var committing = false
    /// Paths a Discard waits to confirm.
    @State private var discarding: [String]?

    private var canGit: Bool { workspace.canUseGit }

    var body: some View {
        content
            .safeAreaInset(edge: .bottom) {
                if canGit {
                    GitBar(canCommit: !reply.staged.isEmpty, running: workspace.gitRunning != nil,
                           commit: { committing = true }, run: run)
                }
            }
            .sheet(isPresented: $committing) {
                CommitSheet { subject, body in run(.commit(subject: subject, body: body)) }
            }
            .confirmationDialog(
                discarding?.count == 1 ? "Discard changes to this file?" : "Discard these changes?",
                isPresented: Binding { discarding != nil } set: { if !$0 { discarding = nil } },
                titleVisibility: .visible, presenting: discarding
            ) { paths in
                Button("Discard", role: .destructive) { run(.discard(paths: paths)) }
            } message: { paths in
                // The host restores the whole file from HEAD, staged edits included.
                let staged = Set(reply.staged.map(\.path))
                Text(paths.contains(where: staged.contains)
                    ? "Its staged changes are discarded too. This can't be undone."
                    : "This can't be undone.")
            }
            .alert("Couldn't do that", isPresented: Binding { error != nil } set: { if !$0 { error = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    private func run(_ change: RemoteGitChange) {
        Task { if let message = await workspace.git(change) { error = message } }
    }

    @ViewBuilder private var content: some View {
        if !reply.metricsAvailable {
            ContentUnavailableView("Change metrics are unavailable for this worktree.", systemImage: "chart.bar.xaxis")
        } else if sections.isEmpty {
            ContentUnavailableView("No changes yet.", systemImage: "checkmark.circle")
        } else {
            List {
                Text(summary).font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                ForEach(sections) { section in
                    SwiftUI.Section {
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
                                .swipeActions(edge: .leading) {
                                    if canGit, section.stage == "unstaged" {
                                        Button("Stage", systemImage: "plus") { run(.stage(paths: [file.path])) }.tint(.green)
                                    } else if canGit, section.stage == "staged" {
                                        Button("Unstage", systemImage: "minus") { run(.unstage(paths: [file.path])) }.tint(.orange)
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    if canGit, section.stage == "unstaged" {
                                        Button("Discard", systemImage: "trash", role: .destructive) { discarding = [file.path] }
                                    }
                                }
                            }
                        }
                        ForEach(section.commits, id: \.revision) { CommitRow(commit: $0) }
                    } header: {
                        HStack {
                            Text(section.title)
                            Spacer()
                            // A truncated list doesn't name every file, so "all" would not be all.
                            if canGit, !reply.truncated, let stage = section.stage {
                                let paths = section.files.map(\.path)
                                Button(stage == "staged" ? "Unstage All" : "Stage All") {
                                    run(stage == "staged" ? .unstage(paths: paths) : .stage(paths: paths))
                                }
                                .font(.footnote.weight(.semibold))
                                .disabled(workspace.gitRunning != nil)
                            }
                        }
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
        HStack(spacing: 10) {
            StatusBadge(status: file.status)
            Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                .lineLimit(1).truncationMode(.middle)
            if file.conflict != nil {
                Text("conflict").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            if file.add + file.del > 0 { Counts(add: file.add, del: file.del) }
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.leading, nested ? 16 : 0)
        .contentShape(Rectangle())
    }
}

/// Git's status letter on its color, as in Xcode's navigator: green added, blue modified, red deleted.
struct StatusBadge: View {
    let status: String

    var body: some View {
        let letter = String(status.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        Text(letter.isEmpty ? "·" : letter)
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(color(letter), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(name(letter))
    }

    private func color(_ letter: String) -> Color {
        switch letter {
        case "A", "?": .green
        case "D": .red
        case "R", "C": .purple
        case "U": .orange
        default: .blue
        }
    }

    private func name(_ letter: String) -> String {
        switch letter {
        case "A": "Added"
        case "?": "Untracked"
        case "D": "Deleted"
        case "R": "Renamed"
        case "C": "Copied"
        case "U": "Unmerged"
        default: "Modified"
        }
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

/// Commit and sync, under the change list.
private struct GitBar: View {
    let canCommit: Bool
    let running: Bool
    let commit: () -> Void
    let run: (RemoteGitChange) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("Commit…", systemImage: "checkmark.circle", action: commit)
                .buttonStyle(.borderedProminent)
                .disabled(!canCommit || running)
            Spacer(minLength: 0)
            if running { ProgressView() }
            Menu {
                Button("Push", systemImage: "arrow.up") { run(.push) }
                Button("Pull", systemImage: "arrow.down") { run(.pull) }
                Button("Fetch", systemImage: "arrow.clockwise") { run(.fetch) }
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .disabled(running)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 12).padding(.bottom, 4)
    }
}

/// A commit message for what is staged.
private struct CommitSheet: View {
    let commit: (_ subject: String, _ body: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var subject = ""
    @State private var message = ""
    @FocusState private var subjectFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Summary", text: $subject).focused($subjectFocused)
                TextField("Description (optional)", text: $message, axis: .vertical).lineLimit(3...10)
            }
            .navigationTitle("Commit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Commit") {
                        commit(subject.trimmingCharacters(in: .whitespacesAndNewlines),
                               message.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { subjectFocused = true }
    }
}
