import AlasRemoteKit
import SwiftUI

/// The worktree's draft reviews on the Mac, pushed from the Changes tab.
struct ReviewsView: View {
    let workspace: SessionWorkspace
    @State private var reviews: Load<[RemoteReviewSummary]> = .loading

    var body: some View {
        Group {
            switch reviews {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Reviews unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            case .loaded(let list) where list.isEmpty:
                ContentUnavailableView("No draft reviews", systemImage: "text.bubble",
                                       description: Text("Comment on a diff here, or start a review on the Mac."))
            case .loaded(let list):
                List(list) { review in
                    NavigationLink {
                        ReviewDetailView(workspace: workspace, summary: review)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(review.title).lineLimit(2)
                            Text([review.source, review.openCommentCount == 1 ? "1 open comment" : "\(review.openCommentCount) open comments"]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await load() }
            }
        }
        .navigationTitle("Reviews")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground))
        // Runs again on coming back from a review, whose counts may have changed.
        .task { await load() }
    }

    private func load() async {
        switch await workspace.reviews() {
        case .success(let list): reviews = .loaded(list)
        case .failure(let failure): reviews = .failed(failure.message)
        }
    }
}

/// One draft review's comments, by file, each resolvable, dismissable, editable and deletable;
/// for a pull or merge request, its threads on the provider too, each answerable and resolvable.
private struct ReviewDetailView: View {
    let workspace: SessionWorkspace
    let summary: RemoteReviewSummary
    @State private var review: Load<RemoteReview> = .loading
    @State private var threads: Load<RemoteProviderReview> = .loading
    @State private var composing: Composing?
    @State private var deleting: RemoteReviewComment?
    @State private var resolving: RemoteProviderThread?
    @State private var error: String?

    private enum Composing: Identifiable {
        case add(RemoteReviewFileID, path: String)
        case edit(RemoteReviewComment)
        case reply(RemoteProviderThread)
        case submit(RemoteProviderReview, [RemoteReviewComment])

        var id: String {
            switch self {
            case .add(let fileID, _): "add:\(fileID.namespace):\(fileID.path)"
            case .edit(let comment): "edit:\(comment.id)"
            case .reply(let thread): "reply:\(thread.id)"
            case .submit: "submit"
            }
        }
    }

    private var readsThreads: Bool { summary.kind == "review-request" && workspace.canReadPullRequestThreads }

    private var canSubmit: Bool {
        guard case .loaded(let pr) = threads, case .loaded(let drafts) = review else { return false }
        return !RemoteReviewSubmission(pr, drafts: drafts.comments).decisions.isEmpty
    }

    /// Who the provider posts as, for the confirmations.
    private var poster: String {
        guard case .loaded(let pr) = threads else { return "the account signed in on the Mac" }
        return pr.poster
    }

    var body: some View {
        Group {
            switch review {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
            case .loaded(let review) where review.comments.isEmpty && !readsThreads:
                ContentUnavailableView("No comments yet", systemImage: "text.bubble",
                                       description: Text("Comment on a file's diff from the Changes tab."))
            case .loaded(let review):
                list(review)
            }
        }
        .navigationTitle(summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground))
        .task { await load() }
        .toolbar {
            if readsThreads {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ReviewScreen(workspace: workspace, source: .pullRequest(sessionID: summary.id), focus: nil)
                    } label: {
                        Label("Review Code", systemImage: "doc.text.magnifyingglass")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Submit Review") {
                        if case .loaded(let pr) = threads, case .loaded(let drafts) = review { composing = .submit(pr, drafts.comments) }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .sheet(item: $composing) { composing in sheet(composing) }
        .confirmationDialog(resolving?.isResolved == true ? "Unresolve this thread?" : "Resolve this thread?",
                            isPresented: Binding { resolving != nil } set: { if !$0 { resolving = nil } },
                            titleVisibility: .visible, presenting: resolving) { thread in
            Button(thread.isResolved ? "Unresolve" : "Resolve") { changeThread(thread, thread.isResolved ? .unresolve : .resolve) }
        } message: { _ in
            Text("It changes on the pull request, as \(poster).")
        }
        .confirmationDialog("Delete this comment?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
                            titleVisibility: .visible, presenting: deleting) { comment in
            Button("Delete", role: .destructive) { change(.delete(commentID: comment.id)) }
        } message: { _ in
            Text("It's deleted on the Mac too.")
        }
        .alert("Couldn't do that", isPresented: Binding { error != nil } set: { if !$0 { error = nil } }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder private func sheet(_ composing: Composing) -> some View {
        switch composing {
        case .add(let fileID, let path):
            CommentSheet(title: "Comment on File", text: "") { body in
                await changed(.add(fileID: fileID, path: path, anchor: .file, body: body))
            }
        case .edit(let comment):
            CommentSheet(title: "Edit Comment", text: comment.body) { body in
                await changed(.edit(commentID: comment.id, body: body))
            }
        case .reply(let thread):
            CommentSheet(title: "Reply", text: "", confirmation: "It's posted on the pull request, as \(poster).") { body in
                await changedThread(thread, .reply, body: body)
            }
        case .submit(let pr, let drafts):
            SubmitReviewSheet(review: pr, drafts: drafts, poster: poster) { decision, body in
                switch await workspace.submitReview(summary.id, decision, body: body, headSHA: pr.headSHA) {
                case .failure(let failure): return failure.message
                case .success(let problems):
                    error = problems.map { "The review was submitted, but:\n\($0)" }
                    await load()
                    return nil
                }
            }
        }
    }

    private func list(_ review: RemoteReview) -> some View {
        let files = Dictionary(grouping: review.comments, by: \.path).sorted { $0.key < $1.key }
        return List {
            if readsThreads { threadsSection }
            ForEach(files, id: \.key) { path, comments in
                Section {
                    ForEach(comments.sorted(by: Self.order)) { comment in
                        CommentRow(comment: comment)
                            .swipeActions(edge: .leading) {
                                if comment.isOpen {
                                    Button("Resolve", systemImage: "checkmark") { change(.resolve(commentID: comment.id)) }.tint(.green)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash") { deleting = comment }.tint(.red)
                                if comment.isOpen {
                                    Button("Dismiss", systemImage: "xmark") { change(.dismiss(commentID: comment.id)) }.tint(.gray)
                                }
                            }
                            .contextMenu {
                                if comment.isOpen {
                                    Button("Edit…", systemImage: "pencil") { composing = .edit(comment) }
                                    Button("Resolve", systemImage: "checkmark") { change(.resolve(commentID: comment.id)) }
                                    Button("Dismiss", systemImage: "xmark") { change(.dismiss(commentID: comment.id)) }
                                }
                                Button("Delete…", systemImage: "trash", role: .destructive) { deleting = comment }
                            }
                    }
                } header: {
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if summary.takesNewComments, let fileID = comments.first?.fileID {
                            Button("Comment", systemImage: "plus.bubble") { composing = .add(fileID, path: path) }
                                .labelStyle(.iconOnly)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await load() }
    }

    private var threadsSection: some View {
        Section {
            switch threads {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            case .loaded(let pr) where pr.threads.isEmpty:
                Text("No threads on the pull request.").font(.subheadline).foregroundStyle(.secondary)
            case .loaded(let pr):
                ForEach(pr.threads.sorted(by: PullRequestThreadRow.order)) { threadRow($0, in: pr) }
            }
        } header: {
            Text("Pull Request Threads")
        } footer: {
            if case .loaded(let pr) = threads, !pr.areThreadsComplete {
                Text("Some threads couldn't be loaded.")
            }
        }
    }

    private func threadRow(_ thread: RemoteProviderThread, in pr: RemoteProviderReview) -> some View {
        let canReply = pr.canReply && thread.viewerCanReply
        let canResolve = pr.canResolve && (thread.isResolved ? thread.viewerCanUnresolve : thread.viewerCanResolve)
        return PullRequestThreadRow(thread: thread)
            .swipeActions(edge: .leading) {
                if canResolve {
                    Button(thread.isResolved ? "Unresolve" : "Resolve",
                           systemImage: thread.isResolved ? "arrow.uturn.backward" : "checkmark") { resolving = thread }
                        .tint(thread.isResolved ? .orange : .green)
                }
            }
            .swipeActions(edge: .trailing) {
                if canReply { Button("Reply", systemImage: "arrowshape.turn.up.left") { composing = .reply(thread) }.tint(.blue) }
            }
            .contextMenu {
                if canReply { Button("Reply…", systemImage: "arrowshape.turn.up.left") { composing = .reply(thread) } }
                if canResolve {
                    Button(thread.isResolved ? "Unresolve…" : "Resolve…",
                           systemImage: thread.isResolved ? "arrow.uturn.backward" : "checkmark") { resolving = thread }
                }
            }
    }

    /// File comments first, then by line; open ones before closed ones on the same line.
    private static func order(_ a: RemoteReviewComment, _ b: RemoteReviewComment) -> Bool {
        (a.line, a.isOpen ? 0 : 1, a.updatedAt) < (b.line, b.isOpen ? 0 : 1, b.updatedAt)
    }

    /// Each read of the threads fetches the pull request from its provider: only on opening and pulling to refresh.
    private func load() async {
        await loadDrafts()
        if readsThreads { await loadThreads() }
    }

    private func loadDrafts() async {
        switch await workspace.review(summary.id) {
        case .success(let found): review = .loaded(found)
        case .failure(let failure): review = .failed(failure.message)
        }
    }

    private func loadThreads() async {
        switch await workspace.pullRequestReview(summary.id, withDiff: false) {
        case .success(let found): threads = .loaded(found)
        case .failure(let failure): threads = .failed(failure.message)
        }
    }

    private func change(_ mutation: RemoteReviewMutation) {
        Task { error = await changed(mutation) }
    }

    /// Returns the host's refusal, or nil once the comment changed.
    private func changed(_ mutation: RemoteReviewMutation) async -> String? {
        let failure = await workspace.changeReview(summary.id, mutation)
        await loadDrafts()
        return failure
    }

    private func changeThread(_ thread: RemoteProviderThread, _ action: RemoteProviderThreadAction, body: String? = nil) {
        Task { error = await changedThread(thread, action, body: body) }
    }

    /// Returns the host's refusal, or nil once the thread changed.
    private func changedThread(_ thread: RemoteProviderThread, _ action: RemoteProviderThreadAction,
                               body: String? = nil) async -> String? {
        let failure = await workspace.changeThread(summary.id, threadID: thread.id, action, body: body)
        if failure == nil { await loadThreads() }
        return failure
    }
}

private extension RemoteReviewComment {
    var line: Int {
        if case .line(_, let start, _) = anchor { return start }
        return 0
    }
}

private struct CommentRow: View {
    let comment: RemoteReviewComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(location).font(.caption.monospaced())
                Text(comment.author).font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                if !comment.isOpen {
                    Text(comment.state.capitalized)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .foregroundStyle(.secondary)
            Text(markdown(comment.body)).foregroundStyle(comment.isOpen ? .primary : .secondary)
            ForEach(Array(comment.replies.enumerated()), id: \.offset) { _, reply in
                VStack(alignment: .leading, spacing: 2) {
                    Text(reply.author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(markdown(reply.body)).font(.subheadline)
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            }
        }
        .padding(.vertical, 4)
    }

    private var location: String {
        switch comment.anchor {
        case .file: return "File"
        case .image: return "Image"
        case .line(let side, let start, let end):
            let range = end.flatMap { $0 != start ? "L\(start)–\($0)" : nil } ?? "L\(start)"
            return range + (side == "old" ? " (old)" : "")
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Writes or edits one review comment.
struct CommentSheet: View {
    let title: String
    @State var text: String
    /// Asked before saving, for a comment others see at once.
    var confirmation: String?
    /// The lines commented on, shown above the field.
    var quote: String?
    /// Returns the host's refusal, which keeps the sheet and its text up, or nil to close it.
    let submit: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var confirming = false
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                if let quote {
                    Text(quote).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(8)
                }
                TextField("Comment", text: $text, axis: .vertical).lineLimit(4...12).focused($focused)
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(confirmation == nil ? "Save" : "Post") {
                            if confirmation == nil { save() } else { confirming = true }
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .confirmationDialog("Post this reply?", isPresented: $confirming, titleVisibility: .visible) {
                            Button("Post") { save() }
                        } message: {
                            Text(confirmation ?? "")
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }

    private func save() {
        saving = true
        failure = nil
        Task {
            failure = await submit(text.trimmingCharacters(in: .whitespacesAndNewlines))
            saving = false
            if failure == nil { dismiss() }
        }
    }
}
