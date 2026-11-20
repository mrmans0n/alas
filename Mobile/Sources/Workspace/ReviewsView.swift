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

/// One draft review's comments, by file, each resolvable, dismissable, editable and deletable.
private struct ReviewDetailView: View {
    let workspace: SessionWorkspace
    let summary: RemoteReviewSummary
    @State private var review: Load<RemoteReview> = .loading
    @State private var composing: Composing?
    @State private var deleting: RemoteReviewComment?
    @State private var error: String?

    private enum Composing: Identifiable {
        case add(RemoteReviewFileID, path: String)
        case edit(RemoteReviewComment)

        var id: String {
            switch self {
            case .add(let fileID, _): "add:\(fileID.namespace):\(fileID.path)"
            case .edit(let comment): "edit:\(comment.id)"
            }
        }
    }

    var body: some View {
        Group {
            switch review {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
            case .loaded(let review) where review.comments.isEmpty:
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
        .sheet(item: $composing) { composing in
            switch composing {
            case .add(let fileID, let path):
                CommentSheet(title: "Comment on File", text: "") { body in
                    change(.add(fileID: fileID, path: path, anchor: .file, body: body))
                }
            case .edit(let comment):
                CommentSheet(title: "Edit Comment", text: comment.body) { body in
                    change(.edit(commentID: comment.id, body: body))
                }
            }
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

    private func list(_ review: RemoteReview) -> some View {
        let files = Dictionary(grouping: review.comments, by: \.path).sorted { $0.key < $1.key }
        return List {
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
                        if let fileID = comments.first?.fileID {
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

    /// File comments first, then by line; open ones before closed ones on the same line.
    private static func order(_ a: RemoteReviewComment, _ b: RemoteReviewComment) -> Bool {
        (a.line, a.isOpen ? 0 : 1, a.updatedAt) < (b.line, b.isOpen ? 0 : 1, b.updatedAt)
    }

    private func load() async {
        switch await workspace.review(summary.id) {
        case .success(let found): review = .loaded(found)
        case .failure(let failure): review = .failed(failure.message)
        }
    }

    private func change(_ mutation: RemoteReviewMutation) {
        Task {
            error = await workspace.changeReview(summary.id, mutation)
            await load()
        }
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
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Comment", text: $text, axis: .vertical).lineLimit(4...12).focused($focused)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        submit(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }
}
