import AlasRemoteKit
import FoundationModels
import SwiftUI

/// The Changes tab: the working tree, branch changes and commits, files as folder trees; a file opens the review at it.
struct ChangesView: View {
    let workspace: SessionWorkspace
    let owner: UUID
    @State private var showingReviews = false

    var body: some View {
        CheckoutScope(workspace: workspace) { tab }
    }

    private var tab: some View {
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
            if workspace.canReview {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reviews", systemImage: "text.bubble") { showingReviews = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Compare Against", systemImage: "arrow.left.arrow.right") {
                    Picker("Compare Against", selection: Binding(
                        get: { workspace.comparisonMode },
                        set: { workspace.comparisonMode = $0 }
                    )) {
                        Text("Mac's Setting").tag(ChangesComparisonMode?.none)
                        Text("Base Branch").tag(ChangesComparisonMode?.some(.auto))
                        Text("Branch Upstream").tag(ChangesComparisonMode?.some(.branchUpstream))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh Changes", systemImage: "arrow.clockwise") { workspace.refreshChanges() }
            }
        }
        .navigationDestination(isPresented: $showingReviews) { ReviewsView(workspace: workspace) }
        .onAppear {
            if case .idle = workspace.changes { workspace.refreshChanges() } else { workspace.refreshIfComparisonChanged() }
        }
    }
}

private struct ChangeList: View {
    let reply: ChangeListReply
    let workspace: SessionWorkspace
    let owner: UUID

    private var working: [RemoteWorkingTreeFile] {
        RemoteChangesRules.workingTree(staged: reply.staged, unstaged: reply.unstaged)
    }

    /// `changeSections` in changes-view.js: the branch's files show beside a working tree only with commits.
    private var showsBranch: Bool {
        !reply.files.isEmpty && (!reply.commits.isEmpty || (reply.staged.isEmpty && reply.unstaged.isEmpty))
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
    @State private var collapsedWorking: Set<String> = []
    @State private var collapsedBranch: Set<String> = []

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
                CommitSheet(suggest: CommitMessageModel.isAvailable
                    ? { await CommitMessageModel.suggest(from: workspace.commitMessageInput()) } : nil
                ) { subject, body in run(.commit(subject: subject, body: body)) }
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

    private func open(_ path: String, stage: String?) {
        let source: ReviewSource = stage == nil ? .branchChanges : .localChanges
        workspace.openReview(source, focus: ReviewEntryID(namespace: stage ?? "branch", path: path), by: owner)
    }

    @ViewBuilder private var content: some View {
        if !reply.metricsAvailable {
            ContentUnavailableView("Change metrics are unavailable for this worktree.", systemImage: "chart.bar.xaxis")
        } else if working.isEmpty, !showsBranch, reply.commits.isEmpty, workspace.pullRequest == nil {
            // With a pull request, the list still shows it, as for a merged branch now level with its base.
            ContentUnavailableView("No changes yet.", systemImage: "checkmark.circle")
        } else {
            List {
                if let pr = workspace.pullRequest { PullRequestSection(pr: pr) }
                Text(summary).font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                let working = working
                if !working.isEmpty {
                    SwiftUI.Section {
                        ForEach(RemoteChangesRules.tree(working, path: \.file.path, collapsed: collapsedWorking), id: \.id) {
                            workingRow($0)
                        }
                    } header: {
                        SectionCard(title: "Working tree", systemImage: "plusminus", count: "\(working.count)",
                                    add: working.reduce(0) { $0 + $1.file.add }, del: working.reduce(0) { $0 + $1.file.del }) {
                            workingMenu(working)
                        }
                    }
                }
                if showsBranch {
                    SwiftUI.Section {
                        ForEach(RemoteChangesRules.tree(reply.files, path: \.path, collapsed: collapsedBranch), id: \.id) { row in
                            ChangeTreeRow(name: row.name, path: row.path, depth: row.depth, file: row.isDirectory ? nil : row.items.first,
                                          collapsed: collapsedBranch.contains(row.path), fileCount: row.items.count) {
                                if row.isDirectory { collapsedBranch.formSymmetricDifference([row.path]) } else { open(row.path, stage: nil) }
                            }
                        }
                    } header: {
                        SectionCard(title: "Branch changes", systemImage: "arrow.triangle.branch", count: "\(reply.files.count)",
                                    add: reply.files.reduce(0) { $0 + $1.add }, del: reply.files.reduce(0) { $0 + $1.del }) {}
                    }
                }
                if !reply.commits.isEmpty {
                    SwiftUI.Section {
                        ForEach(reply.commits, id: \.revision) { commit in
                            Button { workspace.openCommit(commit, by: owner) } label: { CommitRow(commit: commit) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        SectionCard(title: "Commits", systemImage: "smallcircle.filled.circle",
                                    count: "\(reply.commits.count)\(reply.commitsTruncated ? "+" : "")") {}
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
            .environment(\.defaultMinListRowHeight, 36)
        }
    }

    /// A working-tree folder or file: its chip stages what isn't staged yet, or unstages a fully staged one.
    @ViewBuilder private func workingRow(_ row: RemoteChangeTreeRow<RemoteWorkingTreeFile>) -> some View {
        let state = RemoteStageState(row.items.map(\.stage))
        let unstaged = row.items.filter { $0.stage != .staged }.map(\.file.path)
        let stage = { run(.stage(paths: unstaged)) }
        let unstage = { run(.unstage(paths: row.items.filter { $0.stage != .unstaged }.map(\.file.path))) }
        ChangeTreeRow(
            name: row.name, path: row.path, depth: row.depth, file: row.isDirectory ? nil : row.items.first?.file,
            collapsed: collapsedWorking.contains(row.path), fileCount: row.items.count,
            stage: canGit ? state : nil, stageDisabled: workspace.gitRunning != nil,
            toggleStage: state == .staged ? unstage : stage
        ) {
            if row.isDirectory {
                collapsedWorking.formSymmetricDifference([row.path])
            } else {
                open(row.path, stage: state == .staged ? "staged" : "unstaged")
            }
        }
        .contextMenu {
            if canGit {
                if state != .staged { Button("Stage", systemImage: "plus", action: stage) }
                if state != .unstaged { Button("Unstage", systemImage: "minus", action: unstage) }
                if !unstaged.isEmpty {
                    Button("Discard Changes…", systemImage: "trash", role: .destructive) { discarding = unstaged }
                }
            }
        }
        .swipeActions(edge: .leading) {
            if canGit, !row.isDirectory {
                if state == .staged {
                    Button("Unstage", systemImage: "minus", action: unstage).tint(.orange)
                } else {
                    Button("Stage", systemImage: "plus", action: stage).tint(.green)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if canGit, !row.isDirectory, !unstaged.isEmpty {
                Button("Discard", systemImage: "trash", role: .destructive) { discarding = unstaged }
            }
        }
    }

    /// A truncated list doesn't name every file, so "all" would not be all.
    @ViewBuilder private func workingMenu(_ working: [RemoteWorkingTreeFile]) -> some View {
        if canGit, !reply.truncated {
            let unstaged = working.filter { $0.stage != .staged }.map(\.file.path)
            let staged = working.filter { $0.stage != .unstaged }.map(\.file.path)
            Menu("Working Tree Actions", systemImage: "ellipsis.circle") {
                if !unstaged.isEmpty { Button("Stage All", systemImage: "plus") { run(.stage(paths: unstaged)) } }
                if !staged.isEmpty { Button("Unstage All", systemImage: "minus") { run(.unstage(paths: staged)) } }
                if !unstaged.isEmpty {
                    Divider()
                    Button("Discard All…", systemImage: "trash", role: .destructive) { discarding = unstaged }
                }
            }
            .labelStyle(.iconOnly)
            .disabled(workspace.gitRunning != nil)
        }
    }
}

/// A Changes section's title bar, as on the Mac: title, count, totals and its actions.
private struct SectionCard<Actions: View>: View {
    let title: String
    let systemImage: String
    let count: String
    var add: Int?
    var del: Int?
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(count)
                .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(.fill.secondary, in: Capsule())
            Spacer(minLength: 8)
            if let add, let del { Counts(add: add, del: del) }
            actions
        }
        .textCase(nil)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
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

/// A folder or file of a Changes tree, as on the Mac: stage chip, icon, name, then counts and
/// status letter in fixed columns. A tap opens a file or folds a folder.
private struct ChangeTreeRow: View {
    let name: String
    let path: String
    let depth: Int
    /// Nil for a folder.
    let file: RemoteChangedFile?
    let collapsed: Bool
    let fileCount: Int
    /// Nil where nothing can be staged.
    var stage: RemoteStageState? = nil
    var stageDisabled = false
    var toggleStage: () -> Void = {}
    let tap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let stage { StageChip(state: stage, action: toggleStage).disabled(stageDisabled) }
            if let file {
                FileTypeIconGlyph(filename: name)
                Text(name).lineLimit(1).truncationMode(.middle)
                if file.conflict != nil {
                    Text("conflict").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                column(file.add > 0 ? "+\(file.add)" : "", template: "+999").foregroundStyle(.green)
                column(file.del > 0 ? "\u{2212}\(file.del)" : "", template: "\u{2212}999").foregroundStyle(.red)
                StatusBadge(status: file.status)
            } else {
                FileTypeIconGlyph(folder: path)
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if collapsed { Text("\(fileCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .font(.subheadline)
        .padding(.leading, CGFloat(depth) * 16 + (stage == nil ? 8 : 0))
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: file == nil ? (collapsed ? "Expand" : "Collapse") : "Open", tap)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 12))
        .listRowSeparator(.hidden)
    }

    /// Wide enough for a three-digit count, right-aligned, so counts line up down the list.
    private func column(_ text: String, template: String) -> some View {
        ZStack(alignment: .trailing) {
            Text(template).hidden()
            Text(text)
        }
        .font(.caption.monospacedDigit())
    }
}

/// The Mac's stage chip: empty when unstaged, a check when staged, a dash when partly staged.
private struct StageChip: View {
    let state: RemoteStageState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(fill)
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(border, lineWidth: 1)
                Image(systemName: glyph).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            }
            .frame(width: 17, height: 17)
            .frame(width: 30, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    private var glyph: String {
        switch state {
        case .unstaged: "plus"
        case .staged: "checkmark"
        case .mixed: "minus"
        }
    }

    private var tint: Color {
        switch state {
        case .unstaged: .secondary
        case .staged: .green
        case .mixed: .orange
        }
    }

    private var fill: Color { state == .unstaged ? .clear : tint.opacity(0.18) }
    private var border: Color { state == .unstaged ? Color.secondary.opacity(0.6) : tint.opacity(0.6) }

    private var label: String {
        switch state {
        case .unstaged: "Stage"
        case .staged: "Unstage"
        case .mixed: "Stage remaining changes"
        }
    }
}

/// Git's status letter on a soft tint of its color, as on the Mac.
struct StatusBadge: View {
    let status: String

    var body: some View {
        let letter = String(status.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        let color = color(letter)
        Text(letter.isEmpty ? "·" : letter)
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(name(letter))
    }

    private func color(_ letter: String) -> Color {
        switch letter {
        case "A", "?": .green
        case "D": .red
        case "R", "C": .blue
        case "U": .orange
        default: .yellow
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

/// One commit's files, pushed from the Commits section; a file opens the commit's review at it.
struct CommitFilesView: View {
    let workspace: SessionWorkspace
    @State private var collapsed: Set<String> = []

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
                    ForEach(RemoteChangesRules.tree(reply.files, path: \.path, collapsed: collapsed), id: \.id) { row in
                        ChangeTreeRow(name: row.name, path: row.path, depth: row.depth, file: row.isDirectory ? nil : row.items.first,
                                      collapsed: collapsed.contains(row.path), fileCount: row.items.count) {
                            if row.isDirectory { collapsed.formSymmetricDifference([row.path]) } else { open(row.path) }
                        }
                    }
                    if reply.truncated {
                        Text("File list truncated — too many changed files to show.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 36)
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
        .commitReviewDestination(workspace)
    }

    private func open(_ path: String) {
        guard let commit = workspace.commit?.commit, let owner = workspace.pushedBy else { return }
        workspace.openReview(.commit(sha: commit.revision), focus: ReviewEntryID(namespace: "commit", path: path), by: owner)
    }
}

extension View {
    /// Pushes the open commit review, which a commit's files and a file's history open.
    func commitReviewDestination(_ workspace: SessionWorkspace) -> some View {
        navigationDestination(isPresented: Binding(
            get: { workspace.review?.source.isCommit == true },
            set: { if !$0 { workspace.closeReview() } })) {
            if let review = workspace.review { ReviewScreen(workspace: workspace, source: review.source, focus: review.focus) }
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
    /// Nil when this phone can't suggest a message.
    let suggest: (@MainActor () async -> CommitMessageSuggestion?)?
    let commit: (_ subject: String, _ body: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var subject = ""
    @State private var message = ""
    @State private var suggesting = false
    @FocusState private var subjectFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Summary", text: $subject).focused($subjectFocused)
                    TextField("Description (optional)", text: $message, axis: .vertical).lineLimit(3...10)
                } footer: {
                    if suggesting { Label("Suggesting a message…", systemImage: "sparkles") }
                }
            }
            // As on the Mac, a suggestion fills only the fields still empty when it arrives.
            .task {
                guard let suggest else { return }
                suggesting = true
                let suggestion = await suggest()
                suggesting = false
                guard let suggestion, !Task.isCancelled else { return }
                if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { subject = suggestion.subject }
                if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { message = suggestion.body ?? "" }
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

/// Apple's on-device model drafting a commit message from the host's view of the staged change,
/// with the Mac's prompt and checks.
enum CommitMessageModel {
    /// Asked for as a structure: as plain text the model wraps its JSON in a code fence, which the
    /// shared checks refuse.
    @Generable struct Draft {
        var subject: String
        var body: String?
    }

    @MainActor static var isAvailable: Bool {
        let model = SystemLanguageModel.default
        return model.isAvailable && model.supportsLocale(.current)
    }

    @MainActor static func suggest(from input: CommitMessageSuggestionInput?) async -> CommitMessageSuggestion? {
        typealias Policy = CommitMessageSuggestionPolicy
        // UTF-8 bytes bound the tokens from above: the most detailed prompt that surely fits.
        guard let input, isAvailable,
              let messages = Policy.messageCandidates(for: input).first(where: { messages in
                  messages.reduce(0) { $0 + $1.content.utf8.count } <= Policy.inputTokenLimit
              }),
              let instructions = messages.first(where: { $0.role == .system })?.content,
              let prompt = messages.first(where: { $0.role == .user })?.content else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0, maximumResponseTokens: Policy.maxTokens)
        guard let draft = try? await session.respond(to: prompt, generating: Draft.self, options: options).content,
              !Task.isCancelled,
              let json = try? JSONSerialization.data(withJSONObject: ["subject": draft.subject, "body": draft.body as Any? ?? NSNull()])
        else { return nil }
        return Policy.parse(String(decoding: json, as: UTF8.self),
                            conventionalCommits: Policy.usesConventionalCommits(input.recentSubjects))
    }
}
