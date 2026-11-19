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
                if let pr = workspace.pullRequest { PullRequestSection(pr: pr) }
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
                        ForEach(section.commits, id: \.revision) { commit in
                            Button { workspace.openCommit(commit, by: owner) } label: { CommitRow(commit: commit) }
                                .buttonStyle(.plain)
                        }
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

/// The branch's pull request: a tap opens it, and its checks fold out with links to their runs.
private struct PullRequestSection: View {
    let pr: RemotePullRequest

    var body: some View {
        SwiftUI.Section {
            Link(destination: pr.url) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                    Text(["#\(pr.number)", status, review].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !pr.checks.isEmpty {
                DisclosureGroup {
                    ForEach(Array(pr.checks.enumerated()), id: \.offset) { _, check in
                        let row = Label(check.name, systemImage: Self.symbol(check.bucket))
                            .font(.footnote).foregroundStyle(Self.tint(check.bucket))
                        if let url = check.detailURL { Link(destination: url) { row } } else { row }
                    }
                } label: {
                    Label(checksSummary, systemImage: Self.symbol(worstBucket)).font(.footnote).foregroundStyle(Self.tint(worstBucket))
                }
            }
        } header: {
            Text("Pull Request")
        }
    }

    private var status: String {
        switch pr.state {
        case "merged": "Merged"
        case "closed": "Closed"
        default: pr.isDraft ? "Draft" : "Open"
        }
    }

    private var review: String? {
        switch pr.reviewDecision {
        case "approved": "Approved"
        case "changesRequested": "Changes requested"
        case "reviewRequired": "Review required"
        default: nil
        }
    }

    /// `ReviewCheckBucket.severity`'s order: a failure outranks a pending check, which outranks a pass.
    private var worstBucket: String {
        ["fail", "pending", "cancel", "unknown", "pass", "skipping"].first { b in pr.checks.contains { $0.bucket == b } } ?? "unknown"
    }

    private var checksSummary: String {
        let count = { (bucket: String) in pr.checks.filter { $0.bucket == bucket }.count }
        let parts = [("failed", count("fail")), ("pending", count("pending")), ("passed", count("pass"))]
            .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
        return parts.isEmpty ? "\(pr.checks.count) checks" : parts.joined(separator: " · ")
    }

    private static func symbol(_ bucket: String) -> String {
        switch bucket {
        case "pass": "checkmark.circle.fill"
        case "fail": "xmark.circle.fill"
        case "pending": "clock.fill"
        default: "minus.circle"
        }
    }

    private static func tint(_ bucket: String) -> Color {
        switch bucket {
        case "pass": .green
        case "fail": .red
        case "pending": .orange
        default: .secondary
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
        .contentShape(Rectangle())
    }
}

/// One commit's files, pushed from the Commits section; a file opens what the commit changed in it.
struct CommitFilesView: View {
    let workspace: SessionWorkspace

    var body: some View {
        Group {
            switch workspace.commit?.1 {
            case .loaded(let reply) where reply.files.isEmpty:
                ContentUnavailableView("No file changes in this commit.", systemImage: "doc.text")
            case .loaded(let reply):
                List {
                    if let commit = workspace.commit?.commit {
                        Text(commit.subject).font(.subheadline).listRowSeparator(.hidden)
                    }
                    ForEach(RemoteChangesRules.grouped(reply.files), id: \.directory) { group in
                        if !group.directory.isEmpty {
                            Label(group.directory, systemImage: "folder")
                                .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                        }
                        ForEach(group.files, id: \.path) { file in
                            Button { open(file.path) } label: { FileRow(file: file, nested: !group.directory.isEmpty) }
                                .buttonStyle(.plain)
                        }
                    }
                    if reply.truncated {
                        Text("File list truncated — too many changed files to show.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            case .failed(let message):
                ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
            default:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(workspace.commit?.commit.shortSha ?? "Commit")
        .navigationSubtitle(workspace.commit?.commit.author ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground))
        .navigationDestination(isPresented: Binding(
            get: { workspace.diff?.key.sha != nil },
            set: { if !$0 { workspace.closeDiff() } })) {
            DiffView(workspace: workspace)
        }
    }

    private func open(_ path: String) {
        guard let commit = workspace.commit?.commit, let owner = workspace.pushedBy else { return }
        workspace.openDiff(path, stage: nil, sha: commit.revision, by: owner)
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
