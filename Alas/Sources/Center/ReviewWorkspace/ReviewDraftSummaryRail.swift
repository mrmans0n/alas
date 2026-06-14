import AppKit
import SwiftUI

struct ReviewDraftSummaryRail: View {
    let comments: [ReviewDraftComment]
    let bundle: ReviewFeedbackBundle
    @Binding var collapsed: Bool
    var focusedDraftCommentID: String?
    var draftCommentActions = ReviewDraftCommentActions()
    var onSelectDraftComment: (ReviewDraftComment) -> Void = { _ in }

    @Environment(\.theme) private var theme

    private var visibleComments: [ReviewDraftComment] {
        ReviewDraftCommentPlacement.sorted(comments)
    }

    private var activeCount: Int {
        visibleComments.filter(\.isActive).count
    }

    private var groupedComments: [CommentGroup] {
        let grouped = Dictionary(grouping: visibleComments, by: \.path)
        return grouped.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { path in
                CommentGroup(path: path, comments: ReviewDraftCommentPlacement.sorted(grouped[path] ?? []))
            }
    }

    private var canCopyPrompt: Bool {
        !bundle.activeComments.isEmpty && visibleComments.contains { draftCommentActions.availability($0).canCopyPrompt }
    }

    private var canSendToAgent: Bool {
        !bundle.activeComments.isEmpty && visibleComments.contains { draftCommentActions.availability($0).canSendToAgent }
    }

    var body: some View {
        VStack(spacing: 0) {
            if collapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .frame(width: collapsed ? 44 : 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(width: 0.5), alignment: .leading)
        .accessibilityIdentifier("review-draft-summary-rail")
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "review-draft-summary-rail",
                label: "Draft review summary"
            )
        )
    }

    private var expandedBody: some View {
        VStack(spacing: 0) {
            expandedHeader
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groupedComments) { group in
                        commentGroup(group)
                    }
                }
                .padding(10)
            }
        }
    }

    private var collapsedBody: some View {
        VStack(spacing: 8) {
            collapseButton
                .padding(.top, 8)
            activeCountPill(compact: true)
            collapsedActionButton(
                id: "review-draft-summary-copy-prompt",
                systemName: "doc.on.doc",
                label: "Copy prompt",
                enabled: canCopyPrompt
            ) {
                draftCommentActions.copyPrompt(bundle)
            }
            collapsedActionButton(
                id: "review-draft-summary-send-agent",
                systemName: "paperplane",
                label: "Send to agent",
                enabled: canSendToAgent
            ) {
                draftCommentActions.sendToAgent(bundle)
            }
            Spacer(minLength: 0)
        }
    }

    private var expandedHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Draft review")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.color("fg"))
                    activeCountPill(compact: false)
                }
                Spacer(minLength: 8)
                collapseButton
            }

            HStack(spacing: 6) {
                Button {
                    draftCommentActions.copyPrompt(bundle)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(canCopyPrompt ? theme.color("fg-muted") : theme.color("fg-faint"))
                        .frame(width: 28, height: 24)
                        .background(theme.color("bg-3"))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!canCopyPrompt)
                .help("Copy prompt")
                .accessibilityIdentifier("review-draft-summary-copy-prompt")
                .accessibilityLabel("Copy prompt")
                .background(
                    ReviewDraftSummaryPressMarker(
                        identifier: "review-draft-summary-copy-prompt",
                        label: "Copy prompt",
                        isEnabled: canCopyPrompt
                    ) {
                        draftCommentActions.copyPrompt(bundle)
                    }
                )

                Button {
                    draftCommentActions.sendToAgent(bundle)
                } label: {
                    Image(systemName: "paperplane")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(canSendToAgent ? theme.color("fg-muted") : theme.color("fg-faint"))
                        .frame(width: 28, height: 24)
                        .background(theme.color("bg-3"))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!canSendToAgent)
                .help("Send to agent")
                .accessibilityIdentifier("review-draft-summary-send-agent")
                .accessibilityLabel("Send to agent")
                .background(
                    ReviewDraftSummaryPressMarker(
                        identifier: "review-draft-summary-send-agent",
                        label: "Send to agent",
                        isEnabled: canSendToAgent
                    ) {
                        draftCommentActions.sendToAgent(bundle)
                    }
                )

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    private var collapseButton: some View {
        Button {
            collapsed.toggle()
        } label: {
            Image(systemName: collapsed ? "sidebar.right" : "sidebar.trailing")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
                .frame(width: 26, height: 24)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Expand draft review rail" : "Collapse draft review rail")
        .accessibilityIdentifier("review-draft-summary-collapse-toggle")
    }

    private func activeCountPill(compact: Bool) -> some View {
        Text(compact ? "\(activeCount)" : "\(activeCount) active")
            .font(.system(size: compact ? 11 : 10.5, weight: .semibold, design: .monospaced))
            .foregroundColor(activeCount > 0 ? theme.color("warn") : theme.color("fg-faint"))
            .padding(.horizontal, compact ? 0 : 7)
            .frame(width: compact ? 26 : nil, height: compact ? 22 : 20)
            .background((activeCount > 0 ? theme.color("warn") : theme.color("fg-muted")).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 5))
            .accessibilityLabel("\(activeCount) active draft comments")
    }

    private func collapsedActionButton(
        id: String,
        systemName: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(enabled ? theme.color("fg-muted") : theme.color("fg-faint"))
                .frame(width: 26, height: 24)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .background(
            ReviewDraftSummaryPressMarker(identifier: id, label: label, isEnabled: enabled) {
                action()
            }
        )
    }

    private func commentGroup(_ group: CommentGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.path)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.middle)

            ForEach(group.comments) { comment in
                summaryCard(comment)
            }
        }
    }

    private func summaryCard(_ comment: ReviewDraftComment) -> some View {
        let availability = draftCommentActions.availability(comment)
        let isFocused = comment.id == focusedDraftCommentID

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                onSelectDraftComment(comment)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(lineDescription(for: comment))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(statusColor(for: comment))
                        if let stateLabel = stateLabel(for: comment) {
                            Text(stateLabel)
                                .font(.system(size: 10))
                                .foregroundColor(theme.color("fg-faint"))
                        }
                        Spacer(minLength: 0)
                    }

                    Text(DiffReviewInlineFeedbackMarkdown.render(comment.bodyMarkdown))
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("review-draft-summary-comment-\(comment.id)")
            .accessibilityLabel(accessibilityLabel(for: comment))

            if availability.canEdit || availability.canDelete || availability.canResolve || availability.canDismiss {
                HStack(spacing: 5) {
                    Spacer(minLength: 0)
                    if availability.canEdit {
                        commentActionButton(id: "edit", commentID: comment.id, systemName: "pencil", tooltip: "Edit") {
                            draftCommentActions.edit(comment)
                        }
                    }
                    if availability.canResolve {
                        commentActionButton(id: "resolve", commentID: comment.id, systemName: "checkmark", tooltip: "Resolve") {
                            draftCommentActions.resolve(comment)
                        }
                    }
                    if availability.canDismiss {
                        commentActionButton(id: "dismiss", commentID: comment.id, systemName: "xmark", tooltip: "Dismiss") {
                            draftCommentActions.dismiss(comment)
                        }
                    }
                    if availability.canDelete {
                        commentActionButton(id: "delete", commentID: comment.id, systemName: "trash", tooltip: "Delete") {
                            draftCommentActions.delete(comment)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(isFocused ? theme.color("accent-soft") : theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? theme.color("accent") : theme.color("line"), lineWidth: isFocused ? 1 : 0.5)
        )
        .background(
            ReviewDraftSummaryPressMarker(
                identifier: "review-draft-summary-comment-\(comment.id)",
                label: accessibilityLabel(for: comment)
            ) {
                onSelectDraftComment(comment)
            }
        )
    }

    private func commentActionButton(
        id: String,
        commentID: String,
        systemName: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
                .frame(width: 22, height: 20)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityIdentifier("review-draft-summary-\(id)-\(commentID)")
        .accessibilityLabel(tooltip)
        .background(
            ReviewDraftSummaryPressMarker(
                identifier: "review-draft-summary-\(id)-\(commentID)",
                label: tooltip,
                isEnabled: true,
                action: action
            )
        )
    }

    private func lineDescription(for comment: ReviewDraftComment) -> String {
        let range = comment.normalizedLineRange
        if range.lowerBound == range.upperBound {
            return "\(sideLabel(for: comment.side)) line \(range.lowerBound)"
        }
        return "\(sideLabel(for: comment.side)) lines \(range.lowerBound)-\(range.upperBound)"
    }

    private func accessibilityLabel(for comment: ReviewDraftComment) -> String {
        [
            "Draft comment",
            comment.path,
            lineDescription(for: comment),
            stateLabel(for: comment),
            DiffReviewInlineFeedbackMarkdown.plainText(comment.bodyMarkdown),
        ]
        .compactMap { part in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
            .joined(separator: ", ")
    }

    private func stateLabel(for comment: ReviewDraftComment) -> String? {
        switch comment.state {
        case .active:
            nil
        case .resolved:
            "resolved"
        case .dismissed:
            "dismissed"
        }
    }

    private func sideLabel(for side: DiffReviewInlineFeedbackSide) -> String {
        switch side {
        case .old:
            "old"
        case .new:
            "new"
        case .unknown:
            "unknown"
        }
    }

    private func statusColor(for comment: ReviewDraftComment) -> Color {
        switch comment.state {
        case .active:
            theme.color("warn")
        case .resolved:
            theme.color("add")
        case .dismissed:
            theme.color("fg-muted")
        }
    }
}

private struct CommentGroup: Identifiable {
    let path: String
    let comments: [ReviewDraftComment]

    var id: String { path }
}

private struct ReviewDraftSummaryPressMarker: NSViewRepresentable {
    let identifier: String
    let label: String?
    var isEnabled = true
    let action: () -> Void

    func makeNSView(context: Context) -> ReviewDraftSummaryPressView {
        let view = ReviewDraftSummaryPressView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityRole(.button)
        view.setAccessibilityEnabled(isEnabled)
        view.isEnabled = isEnabled
        view.action = action
        return view
    }

    func updateNSView(_ view: ReviewDraftSummaryPressView, context: Context) {
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityRole(.button)
        view.setAccessibilityEnabled(isEnabled)
        view.isEnabled = isEnabled
        view.action = action
    }
}

private final class ReviewDraftSummaryPressView: NSView {
    var isEnabled = true
    var action: () -> Void = {}

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action()
        return true
    }
}
