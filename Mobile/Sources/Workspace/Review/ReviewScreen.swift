import AlasRemoteKit
import SwiftUI

/// A whole change in one scroll: a strip of its files above, every file's diff below.
struct ReviewScreen: View {
    let workspace: SessionWorkspace
    @State private var document: ReviewDocument
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var actionBarHeight: CGFloat = 0

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
            // As in the session it opens from: on the iPhone the action bar takes the tab bar's place. Set here
            // because a pull request's review pushes from the Reviews list, past the session's own setting.
            .toolbar(sizeClass == .compact ? .hidden : .automatic, for: .tabBar)
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
            .task {
                await document.start()
                await document.followComments()
            }
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
                await document.comment(on: entry, anchor: anchor, body: body)
            }
        case .file(let entry):
            CommentSheet(title: "Comment on File", text: "") { body in
                await document.comment(on: entry, anchor: .file, body: body)
            }
        case .edit(let comment):
            CommentSheet(title: "Edit Comment", text: comment.body) { body in
                await document.change(.edit(commentID: comment.id, body: body))
            }
        case .reply(let thread):
            CommentSheet(title: "Reply", text: "",
                         confirmation: "It's posted on the pull request, as \(document.pullRequest?.poster ?? "").") { body in
                await document.changeThread(thread, .reply, body: body)
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
        } else if document.entries.isEmpty, document.listTruncated {
            // The host's cap cut even the first file.
            ContentUnavailableView(truncationNote, systemImage: "exclamationmark.triangle")
        } else if document.entries.isEmpty {
            ContentUnavailableView("No changes to review.", systemImage: "checkmark.circle")
        } else {
            // Runs under the action bar to the screen's edge. Only the home indicator reaches UIKit as safe area,
            // so the bar's height goes in as a content inset for the last line to scroll clear of it.
            ReviewCollectionView(document: document, wraps: ReviewPreferences.shared.wrapsLines, bottomInset: actionBarHeight)
                .ignoresSafeArea(.container, edges: .bottom)
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
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ActionBar(document: document)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actionBarHeight = $0 }
                }
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
                    let names = Self.names(document.entries.map(\.id.path))
                    ForEach(document.entries, id: \.id) { entry in
                        chip(entry, name: names[entry.id.path] ?? entry.id.path).id(entry.id)
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

    /// Each path's file name, or where names collide the nearest folder that tells them apart:
    /// "Mobile/…/Package.resolved".
    /// ponytail: compares every pair of paths, fine for a review's file count.
    static func names(_ paths: [String]) -> [String: String] {
        Dictionary(paths.map { path in
            let parts = path.split(separator: "/")
            let depth = (1...max(parts.count, 1)).first { k in
                let tail = parts.suffix(k).joined(separator: "/")
                return !paths.contains { $0 != path && ($0 == tail || $0.hasSuffix("/" + tail)) }
            } ?? parts.count
            let name = parts.last.map(String.init) ?? path
            return (path, depth <= 1 ? name : depth == 2 ? parts.suffix(2).joined(separator: "/") : "\(parts[parts.count - depth])/…/\(name)")
        }, uniquingKeysWith: { a, _ in a })
    }

    private func chip(_ entry: ReviewEntry, name: String) -> some View {
        let current = entry.id == document.current
        let viewed = document.isViewed(entry)
        return Button { document.scrollTo?(entry.id) } label: {
            HStack(spacing: 4) {
                if viewed { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                Text(name).lineLimit(1)
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

/// How far through the change the reviewer is, its drafts, **Send to Agent** and for a pull request **Submit…**.
private struct ActionBar: View {
    let document: ReviewDocument
    @State private var targets: [RemoteAgentTarget] = []
    @State private var choosing = false
    @State private var confirming: RemoteAgentTarget?
    @State private var sending = false
    @State private var sent: String?

    var body: some View {
        HStack(spacing: 12) {
            Text(sent.map { "Sent to \($0)" } ?? summary)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .task(id: sent) {
                    guard sent != nil else { return }
                    try? await Task.sleep(for: .seconds(3))
                    sent = nil
                }
            if canSendToAgent {
                Button {
                    // Set before the task starts, so a second tap can't start another.
                    sending = true
                    Task { await chooseTarget() }
                } label: {
                    if sending { ProgressView().controlSize(.mini) } else { Text("Send to Agent") }
                }
                .accessibilityLabel("Send to Agent")
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(sending)
                .confirmationDialog("Send \(commentCount) to", isPresented: $choosing, titleVisibility: .visible) {
                    ForEach(targets, id: \.self) { target in
                        Button(label(target)) { startSending(to: target) }
                    }
                } message: {
                    if let alreadySent { Text(alreadySent) }
                }
                .alert(confirming.map { "Send \(commentCount) to \(label($0))?" } ?? "",
                       isPresented: Binding { confirming != nil } set: { if !$0 { confirming = nil } },
                       presenting: confirming) { target in
                    Button("Send") { startSending(to: target) }
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    if let alreadySent { Text(alreadySent) }
                }
            }
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

    /// Only where the Mac takes a phone's send (`reviewsAgentPhoneV1`), and with a draft to send.
    private var canSendToAgent: Bool {
        document.workspace.canSendReviewToAgent && document.reviewSessionID != nil && document.draftCount > 0
    }

    /// What the Mac sends: every open comment.
    private var commentCount: String {
        let count = document.comments.count(where: \.isOpen)
        return count == 1 ? "1 comment" : "\(count) comments"
    }

    /// How many of the open comments a send already took, when any did.
    private var alreadySent: String? {
        let count = document.comments.count { $0.isOpen && document.sent[$0.id] != nil }
        guard count > 0 else { return nil }
        return count == 1 ? "1 was already sent." : "\(count) were already sent."
    }

    private func label(_ target: RemoteAgentTarget) -> String {
        document.workspace.isThisChat(target) ? target.title + " (this chat)" : target.title
    }

    private func chooseTarget() async {
        defer { sending = false }
        guard let session = document.reviewSessionID else { return }
        switch await document.workspace.reviewAgentTargets(session) {
        case .failure(let failure): document.error = failure.message
        case .success(let found) where found.isEmpty:
            document.error = "No agent to send to. Open an agent chat in this worktree, or pick an available agent in Settings → Changes."
        case .success(let found) where found.count == 1: confirming = found[0]
        case .success(let found):
            targets = found
            choosing = true
        }
    }

    private func startSending(to target: RemoteAgentTarget) {
        guard !sending else { return }
        sending = true
        Task { await send(to: target) }
    }

    private func send(to target: RemoteAgentTarget) async {
        defer { sending = false }
        guard let session = document.reviewSessionID else { return }
        if let message = await document.workspace.sendReview(session, to: target) {
            document.error = message
            return
        }
        sent = target.title
        await document.loadComments()
    }

    private var summary: String {
        let viewed = "\(document.entries.filter(document.isViewed).count) of \(document.entries.count) files viewed"
        guard document.reviewSessionID != nil else { return viewed }
        let drafts = document.draftCount
        return viewed + " · " + (drafts == 1 ? "1 draft" : "\(drafts) drafts")
    }
}
