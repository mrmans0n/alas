import AlasRemoteKit
import SwiftUI

/// A whole change in one scroll: a strip of its files above, every file's diff below.
struct ReviewScreen: View {
    let workspace: SessionWorkspace
    @State private var document: ReviewDocument

    init(workspace: SessionWorkspace, source: ReviewSource, focus: ReviewEntryID?) {
        self.workspace = workspace
        _document = State(initialValue: ReviewDocument(workspace: workspace, source: source, focus: focus))
    }

    private var title: String {
        switch document.source {
        case .localChanges: "Local Changes"
        case .branchChanges: "Branch Changes"
        case .commit(let sha): String(sha.prefix(7))
        case .pullRequest:
            // "pull request #12" as "Pull request #12".
            document.pullRequest.map { $0.displayName.prefix(1).uppercased() + $0.displayName.dropFirst() } ?? "Pull Request"
        }
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    let wraps = ReviewPreferences.shared.wrapsLines
                    Button(wraps ? "Scroll Long Lines" : "Wrap Long Lines",
                           systemImage: wraps ? "arrow.left.and.right" : "text.alignleft") {
                        ReviewPreferences.shared.wrapsLines.toggle()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(document.allFolded ? "Unfold All" : "Fold All",
                           systemImage: document.allFolded ? "rectangle.expand.vertical" : "rectangle.compress.vertical") {
                        document.toggleFoldAll()
                    }
                    .disabled(document.entries.isEmpty)
                }
            }
            .task { await document.start() }
            .onChange(of: workspace.reconnects) { Task { await document.refresh() } }
            .sheet(item: Binding { document.composing } set: { document.composing = $0 }) { composing in
                sheet(composing)
            }
            .alert("Couldn't do that", isPresented: Binding { document.error != nil } set: { if !$0 { document.error = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(document.error ?? "")
            }
            // Backstop for a pop that skips the destination binding (a stack reset to the root).
            .onDisappear { workspace.closeReview() }
    }

    @ViewBuilder private func sheet(_ composing: ReviewComposing) -> some View {
        switch composing {
        case .lines(let entry, let anchor, let title, let quote):
            CommentSheet(title: title, text: "", quote: quote) { body in
                Task { await document.comment(on: entry, anchor: anchor, body: body) }
            }
        case .file(let entry):
            CommentSheet(title: "Comment on File", text: "") { body in
                Task { await document.comment(on: entry, anchor: .file, body: body) }
            }
        case .edit(let comment):
            CommentSheet(title: "Edit Comment", text: comment.body) { body in
                Task { await document.change(.edit(commentID: comment.id, body: body)) }
            }
        case .reply(let thread):
            CommentSheet(title: "Reply", text: "",
                         confirmation: "It's posted on the pull request, as \(document.pullRequest?.poster ?? "").") { body in
                Task { await document.changeThread(thread, .reply, body: body) }
            }
        case .submit:
            if let pullRequest = document.pullRequest {
                SubmitReviewSheet(review: pullRequest, drafts: document.comments, poster: pullRequest.poster) { decision, body in
                    await document.submit(decision, body: body)
                }
            }
        }
    }

    private var truncationNote: String {
        if case .pullRequest = document.source { return "This pull request's diff is too big for the phone; some files are missing." }
        return "Showing the first \(document.entries.count) files; the Mac capped this change."
    }

    @ViewBuilder private var content: some View {
        if let message = document.listError {
            ContentUnavailableView {
                Label("Changes unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await document.refresh() } }
            }
        } else if !document.listLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if document.entries.isEmpty {
            ContentUnavailableView("No changes to review.", systemImage: "checkmark.circle")
        } else {
            ReviewCollectionView(document: document, wraps: ReviewPreferences.shared.wrapsLines)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        FileStrip(document: document)
                        if document.listTruncated {
                            Text(truncationNote)
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                                .background(.bar)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { ActionBar(document: document) }
        }
    }
}

/// One chip per file; the current one follows the scroll, and a tap jumps to its file.
private struct FileStrip: View {
    let document: ReviewDocument

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(document.entries, id: \.id) { entry in
                        chip(entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .onChange(of: document.current) {
                guard let current = document.current else { return }
                withAnimation { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .background(.bar)
    }

    private func chip(_ entry: ReviewEntry) -> some View {
        let current = entry.id == document.current
        let viewed = document.isViewed(entry)
        return Button { document.scrollTo?(entry.id) } label: {
            HStack(spacing: 4) {
                if viewed { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                Text(entry.id.path.split(separator: "/").last.map(String.init) ?? entry.id.path).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(current ? Color.white : viewed ? Color.secondary : Color.primary)
            .background(current ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.id.path + (viewed ? ", viewed" : ""))
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// How far through the change the reviewer is, its drafts, and for a pull request **Submit…**.
private struct ActionBar: View {
    let document: ReviewDocument

    var body: some View {
        HStack(spacing: 12) {
            Text(summary)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            if document.pullRequest != nil {
                Button("Submit…") { document.composing = .submit }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!document.canSubmit)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, 4)
    }

    private var summary: String {
        let viewed = "\(document.entries.filter(document.isViewed).count) of \(document.entries.count) files viewed"
        guard document.reviewSessionID != nil else { return viewed }
        let drafts = document.draftCount
        return viewed + " · " + (drafts == 1 ? "1 draft" : "\(drafts) drafts")
    }
}
