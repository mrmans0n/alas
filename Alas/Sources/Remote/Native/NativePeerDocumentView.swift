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

    private struct DiffLoadKey: Equatable {
        let target: ReviewSessionTarget?
        let generation: Int
    }

    @Environment(\.theme) private var theme
    @State private var review: HostReview?
    @State private var readFailed = false
    @State private var diff = DiffLoad.loading
    @State private var diffGeneration = 0
    @State private var mutationError: String?
    @State private var selectedFileID: DiffReviewFileID?
    @State private var railCollapsed = false
    @State private var reviewSummaryCollapsed = false
    @State private var layoutMode: DiffLayoutMode = .split
    @State private var wrapLines = false
    @State private var showWhitespace = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let mutationError { note(mutationError, color: "del") }
            if readFailed { note(readFailedMessage, color: "del") }
            if case .loaded(_, truncated: true) = diff {
                note("The host cut off part of this review; some files or lines are not shown.")
            }
            reviewBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .task(id: hosts.reviewRevisions[selection.serverId]?[selection.worktree.snapshot.worktree.id]) {
            await readReview()
        }
        // ponytail: local changes don't live-refresh from the Mac; add a host
        // diff event if that bites. Until then the refresh button reloads.
        .task(id: DiffLoadKey(target: review?.summary.record.target, generation: diffGeneration)) {
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
            ToolbarBtn(icon: "arrow.clockwise", tooltip: "Reload from host") { diffGeneration += 1 }
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
        ReviewDraftCommentActions(
            availability: { comment in
                ReviewDraftCommentActionAvailability(
                    canEdit: comment.isActive,
                    canDelete: true,
                    canResolve: comment.isActive,
                    canDismiss: comment.isActive,
                    canCopyPrompt: false,
                    canShowSendToAgent: false,
                    canSendToAgent: false
                )
            },
            edit: { comment, body in mutate(.edit(commentID: comment.id, body: body)) },
            delete: { mutate(.delete(commentID: $0.id)) },
            resolve: { mutate(.resolve(commentID: $0.id)) },
            dismiss: { mutate(.dismiss(commentID: $0.id)) }
        )
    }

    /// The host's `reviewsChanged` then reads the comments again.
    private func mutate(_ mutation: HostReviewMutation) {
        mutationError = nil
        Task { @MainActor in
            mutationError = await hosts.mutateReview(
                mutation, sessionID: selection.sessionID, in: selection.worktree, serverId: selection.serverId
            )
        }
    }

    private func readReview() async {
        let read = await hosts.review(selection.sessionID, in: selection.worktree, serverId: selection.serverId)
        guard !Task.isCancelled else { return }
        // A failed re-read keeps the comments last read.
        readFailed = read == nil
        if let read { review = read }
    }

    private func loadDiff() async {
        guard let target = review?.summary.record.target else { return }
        diff = .loading
        // One client per load: its notes are never reset.
        let hosts = hosts
        let selection = selection
        let git = NativePeerReviewGitClient(read: { read in
            await hosts.read(read, in: selection.worktree, serverId: selection.serverId)
        })
        do {
            let loaded = try await ReviewSessionLoader.peer(git: git).load(target: target)
            guard !Task.isCancelled else { return }
            diff = .loaded(loaded, truncated: git.notes.truncated)
        } catch ReviewSessionLoaderError.unsupportedTarget {
            diff = .failed("Not available from this Mac yet.")
        } catch {
            guard !Task.isCancelled else { return }
            diff = .failed(error.localizedDescription)
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
