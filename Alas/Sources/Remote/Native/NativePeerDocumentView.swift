import AppKit
import SwiftUI

/// A peer file or diff opened from the peer right pane. It covers the
/// transcript until closed; the session stays subscribed underneath.
struct NativePeerDocumentView: View {
    let document: NativePeerWorkspace.Document
    let content: NativePeerWorkspace.Load<NativePeerWorkspace.DocumentContent>
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @State private var displayModel: DiffDisplayModel?
    @State private var layoutMode: DiffLayoutMode = .split
    @State private var wrapLines = false
    @State private var showWhitespace = false

    var body: some View {
        VStack(spacing: 0) {
            header
            documentBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .task(id: content) { await buildDisplayModel() }
    }

    private var badge: String {
        switch document {
        case .diff(_, .staged): "staged"
        case .diff(_, .unstaged): "unstaged"
        case .diff(_, nil): "branch"
        case .commitDiff(_, let sha): String(sha.prefix(7))
        case .file: "peer"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text((document.path as NSString).lastPathComponent)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                .foregroundColor(theme.color("fg"))
            Text(badge)
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.color("accent").opacity(0.16))
                .foregroundColor(theme.color("accent"))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text((document.path as NSString).deletingLastPathComponent)
                .font(.system(size: codeFontSize - 1.5))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            ToolbarBtn(icon: "x", tooltip: "Back to session", action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var documentBody: some View {
        switch content {
        case .idle, .loading:
            Spinner()
                .frame(width: 16, height: 16)
                .padding()
        case .failed(let message):
            note(message, color: "del")
        case .loaded(.text(let text, let truncated)):
            if truncated { note("Showing the start of this file; the peer cut off the rest.") }
            ReadonlyTextView(
                text: text,
                font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
                textColor: NSColor(theme.color("fg")),
                backgroundColor: .clear
            )
        case .loaded(.diff(let diff, let truncated)):
            if truncated { note("The peer cut off this diff.") }
            if diff.hunks.isEmpty {
                note(diff.metadataSummary ?? "No changes for \(document.path)")
            } else if let displayModel {
                DiffPaneView(
                    model: displayModel,
                    fileExtension: LanguageRegistry.highlighterExtension(forPath: document.path),
                    layoutMode: $layoutMode,
                    wrapLines: $wrapLines,
                    showWhitespace: $showWhitespace,
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    allowsReviewLineSelection: false,
                    hunkActions: { _ in DiffPaneHunkActions() }
                )
            } else {
                Spinner()
                    .frame(width: 16, height: 16)
                    .padding()
            }
        }
    }

    private func note(_ text: String, color: String = "fg-dim") -> some View {
        Text(text)
            .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 2))
            .foregroundColor(theme.color(color))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
    }

    private func buildDisplayModel() async {
        guard case .loaded(.diff(let diff, _)) = content, !diff.hunks.isEmpty else {
            displayModel = nil
            return
        }
        let path = document.path
        let model = await Task.detached(priority: .userInitiated) {
            DiffDisplayModelBuilder.build(diff: diff, filePath: path)
        }.value
        guard !Task.isCancelled else { return }
        displayModel = model
    }
}

/// A host worktree's draft review, read and commented on over the host
/// channel. It covers the peer center pane until closed.
struct NativePeerReviewView: View {
    let hosts: NativePeerHosts
    let selection: NativePeerReviewSelection
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13
    let onClose: () -> Void

    private enum DiffLoad {
        case loading
        case loaded(ReviewSessionLoadedContext, truncated: Bool)
        case failed(String)
    }

    private struct FailedMutation {
        let mutation: HostReviewMutation
        let message: String
    }

    private struct ReadKey: Equatable {
        let revision: Int?
        let subscription: Int?
        let generation: Int
    }

    private struct DiffLoadKey: Equatable {
        let target: ReviewSessionTarget?
        let generation: Int
    }

    @Environment(\.theme) private var theme
    @State private var review: HostReview?
    @State private var readFailed = false
    @State private var diff = DiffLoad.loading
    /// Bumped by Reload: reads the review and its diff again.
    @State private var reloadGeneration = 0
    /// Why a reload failed; the diff loaded before stays shown.
    @State private var reloadError: String?
    /// The last change the host refused or never answered, kept so its text
    /// isn't lost: the surface clears its composer when it saves.
    @State private var failedMutation: FailedMutation?
    @State private var selectedFileID: DiffReviewFileID?
    @State private var railCollapsed = false
    @State private var reviewSummaryCollapsed = false
    @State private var layoutMode: DiffLayoutMode = .split
    @State private var wrapLines = false
    @State private var showWhitespace = false
    /// A pull or merge request review's threads, capabilities and account,
    /// as the host's provider shows them; its diff is kept only for the load.
    @State private var providerReview: HostProviderReview?
    @State private var providerConfirmation: ProviderReviewPublishConfirmationState?
    @State private var providerDecision = ProviderReviewDecision.comment
    @State private var providerSummaryBody = ""
    @State private var isProviderPublishing = false
    /// Thread and publish failures, shown as a note and in the confirmation.
    @State private var providerError: String?
    /// What a thread change or publish that went through could not finish,
    /// such as one draft that failed to post: a note, not a failure.
    @State private var providerWarning: String?
    /// Threads with a reply or (un)resolve on its way to the host: a second
    /// click on one is ignored until the first returns.
    @State private var threadsInFlight: Set<String> = []
    /// Set when re-reading the provider's threads failed: the ones read
    /// before stay shown, with a note that they may be stale.
    @State private var providerRefreshFailed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let failedMutation { failedMutationNote(failedMutation) }
            if let providerError, providerConfirmation == nil { note(providerError, color: "del") }
            if let providerWarning, providerConfirmation == nil { note(providerWarning, color: "warn") }
            if readFailed { note(readFailedMessage, color: "del") }
            if providerRefreshFailed {
                note("Couldn't refresh this \(providerReview?.remote.kind == .gitlab ? "merge" : "pull") request's threads from the host.")
            }
            if let reloadError { note(reloadError, color: "del") }
            if case .loaded(_, truncated: true) = diff {
                note("The host cut off part of this review; some files or lines are not shown.")
            }
            reviewBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .overlay(providerConfirmationOverlay)
        .task(id: ReadKey(
            revision: hosts.reviewRevisions[selection.serverId]?[selection.worktree.snapshot.worktree.id],
            subscription: hosts.subscriptions[selection.serverId],
            generation: reloadGeneration
        )) {
            await readReview()
        }
        // ponytail: local changes don't live-refresh from the Mac; add a host
        // diff event if that bites. Until then the refresh button reloads.
        .task(id: DiffLoadKey(target: review?.summary.record.target, generation: reloadGeneration)) {
            await loadDiff()
        }
    }

    private var readFailedMessage: String { "The host could not read this review." }

    private var header: some View {
        HStack(spacing: 10) {
            Text(review?.summary.record.target.title ?? "Review")
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
                .truncationMode(.middle)
            if let verdict = review?.summary.record.verdict?.verdict {
                Text(verdict.peerLabel)
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(theme.color("accent").opacity(0.16))
                    .foregroundColor(theme.color("accent"))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
            ToolbarBtn(icon: "arrow.clockwise", tooltip: "Reload from host") { reloadGeneration += 1 }
            ToolbarBtn(icon: "x", tooltip: "Back to session", action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var reviewBody: some View {
        if review == nil {
            if !readFailed {
                Spinner()
                    .frame(width: 16, height: 16)
                    .padding()
            }
        } else {
            switch diff {
            case .loading:
                Spinner()
                    .frame(width: 16, height: 16)
                    .padding()
            case .failed(let message):
                note(message, color: "del")
            case .loaded(let loaded, _):
                DiffReviewSurface(
                    session: loaded.session,
                    selectedFileID: $selectedFileID,
                    railCollapsed: $railCollapsed,
                    reviewSummaryCollapsed: $reviewSummaryCollapsed,
                    layoutMode: $layoutMode,
                    wrapLines: $wrapLines,
                    showWhitespace: $showWhitespace,
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    showsRailDisplayControls: true,
                    // Lets a review with no drafts still approve or request changes.
                    showsDraftSummaryRail: review?.summary.record.target.kind == .reviewRequest && providerReview != nil,
                    inlineFeedbackByFileID: providerReview.map { pr in
                        ReviewSessionTabView.inlineFeedbackByFileID(
                            threads: pr.request.threads,
                            files: loaded.session.summary.files,
                            providerName: pr.remote.kind.displayName
                        )
                    } ?? [:],
                    inlineFeedbackActions: inlineFeedbackActions,
                    reviewFeedbackTarget: loaded.feedbackTarget,
                    draftCommentsByFileID: ReviewDraftCommentGrouping.commentsByFileID(review?.comments ?? []),
                    draftCommentActions: commentActions,
                    // The host files file and line comments only. Image
                    // comments can't start here: the peer client lists no
                    // image files.
                    onSaveDraftComment: { fileID, path, originalPath, anchor, body in
                        mutate(.add(fileID: fileID, path: path, originalPath: originalPath, anchor: anchor, body: body))
                    }
                )
            }
        }
    }

    /// As `ReviewDraftWorkspaceActions`, less what only this Mac's agents and
    /// providers could do.
    private var commentActions: ReviewDraftCommentActions {
        let publishes = review?.summary.record.target.kind == .reviewRequest ? providerReview : nil
        return ReviewDraftCommentActions(
            availability: { comment in
                ReviewDraftCommentActionAvailability(
                    canEdit: comment.isActive,
                    canDelete: true,
                    canResolve: comment.isActive,
                    canDismiss: comment.isActive,
                    canCopyPrompt: false,
                    canShowSendToAgent: false,
                    canSendToAgent: false,
                    canPublishProvider: publishes != nil && !ProviderReviewPublishPlanner.publishableDrafts([comment]).isEmpty
                )
            },
            canPublishReview: {
                publishes.map { $0.capabilities.canComment || $0.capabilities.canSubmitReview } ?? false
            },
            edit: { comment, body in mutate(.edit(commentID: comment.id, body: body)) },
            delete: { mutate(.delete(commentID: $0.id)) },
            resolve: { mutate(.resolve(commentID: $0.id)) },
            dismiss: { mutate(.dismiss(commentID: $0.id)) },
            publishProvider: { openProviderConfirmation(commentID: $0.id) },
            publishReview: { openProviderConfirmation(commentID: nil) }
        )
    }

    /// As the local review's, over the host's capabilities.
    private var inlineFeedbackActions: DiffReviewInlineFeedbackActions {
        var actions = DiffReviewInlineFeedbackActions()
        guard let capabilities = providerReview?.capabilities else { return actions }
        let threadsInFlight = threadsInFlight
        actions.availability = { item, _ in
            let idle = !threadsInFlight.contains(item.id)
            return DiffReviewInlineFeedbackActionAvailability(
                canOpenProvider: item.providerURL != nil,
                canCopyContext: true,
                canSendToAgent: false,
                canReplyProvider: idle && item.status == .actionable && capabilities.canReply,
                canResolveProvider: idle && item.status == .actionable && capabilities.canResolve,
                canUnresolveProvider: idle && item.status == .resolved && capabilities.canResolve
            )
        }
        actions.replyProvider = { item, _, body in mutateThread(item, kind: .reply, body: body) }
        actions.resolveProvider = { item, _ in mutateThread(item, kind: .resolve, body: nil) }
        actions.unresolveProvider = { item, _ in mutateThread(item, kind: .unresolve, body: nil) }
        actions.openProvider = { item, _ in
            guard let url = item.providerURL else { return }
            NSWorkspace.shared.open(url)
        }
        actions.copyContext = { item, file in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                DiffReviewInlineFeedbackContextFormatter.format(item: item, file: file),
                forType: .string
            )
        }
        return actions
    }

    private func mutateThread(_ item: DiffReviewInlineFeedback, kind: ProviderThreadMutationKind, body: String?) {
        guard threadsInFlight.insert(item.id).inserted else { return }
        Task { @MainActor in
            defer { threadsInFlight.remove(item.id) }
            let result = await hosts.mutateReviewThread(
                item.id, kind: kind, body: body, sessionID: selection.sessionID,
                in: selection.worktree, serverId: selection.serverId
            )
            switch result {
            case .success(let mutated):
                providerReview?.request = mutated.refreshedRequest
                providerError = nil
                providerWarning = mutated.warnings.isEmpty ? nil : mutated.warnings.joined(separator: "\n")
            case .failure(let error):
                providerError = error.message
                providerWarning = nil
            }
        }
    }

    /// As `ReviewSessionTabView.openProviderPublishConfirmation`, over the
    /// host's drafts and capabilities.
    private func openProviderConfirmation(commentID: String?) {
        guard let pr = providerReview else { return }
        let all = review?.comments ?? []
        let filtered = commentID.map { id in all.filter { $0.id == id } } ?? all
        let comments = ProviderReviewPublishPlanner.publishableDrafts(filtered)
        let unpublishableMessages = ProviderReviewPublishPlanner.unpublishableMessages(filtered)
        guard commentID == nil || !comments.isEmpty || !unpublishableMessages.isEmpty else { return }
        guard !comments.isEmpty || !unpublishableMessages.isEmpty || pr.capabilities.canSubmitReview else { return }
        let allowedDecisions = ReviewSessionTabView.allowedProviderDecisions(
            commentCount: comments.count, capabilities: pr.capabilities
        )
        guard !allowedDecisions.isEmpty else { return }
        providerDecision = ReviewSessionTabView.defaultProviderDecision(allowedDecisions: allowedDecisions)
        providerSummaryBody = ""
        providerError = nil
        providerConfirmation = ProviderReviewPublishConfirmationState(
            commentID: commentID,
            providerName: pr.remote.kind.displayName,
            reviewIdentity: pr.request.displayIdentity,
            commentCount: comments.count,
            unpublishableMessages: unpublishableMessages,
            allowedDecisions: allowedDecisions
        )
    }

    @ViewBuilder
    private var providerConfirmationOverlay: some View {
        if let providerConfirmation {
            ZStack {
                theme.color("bg-0").opacity(0.45)
                    .ignoresSafeArea()
                ProviderReviewPublishConfirmationView(
                    providerName: providerConfirmation.providerName,
                    reviewIdentity: providerConfirmation.reviewIdentity,
                    commentCount: providerConfirmation.commentCount,
                    unpublishableMessages: providerConfirmation.unpublishableMessages,
                    allowedDecisions: providerConfirmation.allowedDecisions,
                    selectedDecision: $providerDecision,
                    summaryBody: $providerSummaryBody,
                    isPublishing: isProviderPublishing,
                    errorMessage: providerError,
                    onCancel: {
                        self.providerConfirmation = nil
                        providerError = nil
                    },
                    onConfirm: { Task { @MainActor in await confirmProviderPublish() } },
                    account: providerReview?.account
                )
            }
        }
    }

    /// Per-draft results arrive with the comments the host's
    /// `reviewsChanged` reads again.
    private func confirmProviderPublish() async {
        guard !isProviderPublishing, let confirmation = providerConfirmation, providerReview != nil,
              case .loaded(let loaded, _) = diff else { return }
        if let refusal = ReviewSessionTabView.publishRefusal(
            decision: providerDecision, allowed: confirmation.allowedDecisions, summaryBody: providerSummaryBody
        ) {
            providerError = refusal
            return
        }
        isProviderPublishing = true
        providerError = nil
        defer { isProviderPublishing = false }
        let publish = HostReviewPublish(
            decision: providerDecision,
            body: providerSummaryBody.trimmingCharacters(in: .whitespacesAndNewlines),
            draftIDs: confirmation.commentID.map { [$0] },
            // The head the diff showed: thread re-reads replace
            // `providerReview`, only a reload replaces the diff.
            headSHA: loaded.providerContext?.reviewRequest.headSHA
        )
        switch await hosts.publishReview(
            publish, sessionID: selection.sessionID, in: selection.worktree, serverId: selection.serverId
        ) {
        case .success(let result):
            providerReview?.request = result.refreshedRequest
            providerConfirmation = nil
            providerError = nil
            providerWarning = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
        case .failure(let error):
            providerError = error.message
            providerWarning = nil
        }
    }

    /// The host's `reviewsChanged` then reads the comments again.
    private func mutate(_ mutation: HostReviewMutation) {
        failedMutation = nil
        Task { @MainActor in
            let error = await hosts.mutateReview(
                mutation, sessionID: selection.sessionID, in: selection.worktree, serverId: selection.serverId
            )
            failedMutation = error.map { FailedMutation(mutation: mutation, message: $0) }
        }
    }

    /// The refusal, with the comment text an add or edit carried, to send
    /// again or copy. ponytail: the surface has no way to seed its composer;
    /// restore the text there if one is added.
    private func failedMutationNote(_ failed: FailedMutation) -> some View {
        let text: String? = switch failed.mutation {
        case .add(_, _, _, _, let body), .edit(_, let body): body
        case .delete, .resolve, .dismiss: nil
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(failed.message).foregroundColor(theme.color("del"))
            if let text {
                Text(text)
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button("Retry") { mutate(failed.mutation) }
                if let text {
                    Button("Copy text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                Button("Dismiss") { failedMutation = nil }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 2))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-2"))
    }

    private func readReview() async {
        let read = await hosts.review(selection.sessionID, in: selection.worktree, serverId: selection.serverId)
        guard !Task.isCancelled else { return }
        // A failed re-read keeps the comments last read.
        readFailed = read == nil
        if let read { review = read }
        // ponytail: one provider read per `reviewsChanged`; cache on the host
        // if gh latency bites.
        guard providerReview != nil, review?.summary.record.target.kind == .reviewRequest else { return }
        let refreshed = await hosts.providerReview(
            selection.sessionID, in: selection.worktree, serverId: selection.serverId, withDiff: false
        )
        guard !Task.isCancelled else { return }
        if case .success(let pr) = refreshed {
            providerReview = pr
            providerRefreshFailed = false
        } else {
            providerRefreshFailed = true
        }
    }

    private func loadDiff() async {
        guard let target = review?.summary.record.target else { return }
        // A reload keeps the loaded surface, with its unsaved comment and scroll.
        if case .loaded = diff {} else { diff = .loading }
        // One client per load: its notes are never reset.
        let hosts = hosts
        let selection = selection
        let git = NativePeerReviewGitClient(read: { read in
            await hosts.read(read, in: selection.worktree, serverId: selection.serverId)
        })
        let message: String
        do {
            // Without the host's provider reviews, the loader refuses the target.
            var pr: HostProviderReview?
            if target.kind == .reviewRequest, hosts.servesProviderReviews(serverId: selection.serverId) {
                pr = try await hosts.providerReview(
                    selection.sessionID, in: selection.worktree, serverId: selection.serverId, withDiff: true
                ).get()
            }
            let loaded = try await ReviewSessionLoader.peer(git: git, providerReview: pr).load(target: target)
            guard !Task.isCancelled else { return }
            diff = .loaded(loaded, truncated: git.notes.truncated || pr?.diffTruncated == true)
            pr?.diff = nil
            providerReview = pr
            reloadError = nil
            providerError = nil
            providerWarning = nil
            providerRefreshFailed = false
            return
        } catch ReviewSessionLoaderError.unsupportedTarget {
            message = "Not available from this Mac yet."
        } catch {
            message = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        if case .loaded = diff { reloadError = message } else { diff = .failed(message) }
    }

    private func note(_ text: String, color: String = "fg-dim") -> some View {
        Text(text)
            .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 2))
            .foregroundColor(theme.color(color))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
    }
}

extension ReviewVerdict {
    /// How a peer review's header and the Reviews list show the verdict.
    var peerLabel: String {
        switch self {
        case .approve: "Approved"
        case .requestChanges: "Changes requested"
        case .comment: "Commented"
        }
    }
}
