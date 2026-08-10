import AppKit
import SwiftUI

struct ReviewDraftSummaryRailStatus: Equatable {
    var handoffs: [ReviewFeedbackHandoff] = []
    var lastSendError: String?

    init(handoffs: [ReviewFeedbackHandoff] = [], lastSendError: String? = nil) {
        self.handoffs = handoffs
        self.lastSendError = lastSendError
    }

    init(record: ReviewSessionRecord?) {
        self.handoffs = record?.handoffs ?? []
        self.lastSendError = record?.lastSendError
    }

    var latestHandoff: ReviewFeedbackHandoff? {
        handoffs.max { lhs, rhs in lhs.createdAt < rhs.createdAt }
    }

    var visibleSendError: String? {
        guard let lastSendError,
              !lastSendError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return lastSendError
    }
}

private struct ReviewDraftSummaryRailStatusKey: EnvironmentKey {
    static let defaultValue = ReviewDraftSummaryRailStatus()
}

extension EnvironmentValues {
    var reviewDraftSummaryRailStatus: ReviewDraftSummaryRailStatus {
        get { self[ReviewDraftSummaryRailStatusKey.self] }
        set { self[ReviewDraftSummaryRailStatusKey.self] = newValue }
    }
}

struct ReviewDraftSummaryRail: View {
    let comments: [ReviewDraftComment]
    let bundle: ReviewFeedbackBundle
    @Binding var collapsed: Bool
    var focusedDraftCommentID: String?
    var draftCommentActions = ReviewDraftCommentActions()
    var onSelectDraftComment: (ReviewDraftComment) -> Void = { _ in }
    var inlineFeedbackByFileID: [DiffReviewFileID: [DiffReviewInlineFeedback]] = [:]
    var focusedFeedbackID: String?
    var onSelectInlineFeedback: (DiffReviewInlineFeedback) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @Environment(\.reviewDraftSummaryRailStatus) private var sendStatus
    @State private var editingCommentID: String?
    @State private var editingBody = ""

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

    private var feedbackGroups: [FeedbackGroup] {
        inlineFeedbackByFileID
            .filter { !$0.value.isEmpty }
            .map { FeedbackGroup(fileID: $0.key, items: $0.value) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var hasFeedback: Bool {
        !feedbackGroups.isEmpty
    }

    private var canCopyPrompt: Bool {
        !bundle.activeComments.isEmpty && visibleComments.contains { draftCommentActions.availability($0).canCopyPrompt }
    }

    private var canSendToAgent: Bool {
        !bundle.activeComments.isEmpty && visibleComments.contains { draftCommentActions.availability($0).canSendToAgent }
    }

    private var canPublishReview: Bool {
        draftCommentActions.canPublishReview()
    }

    private var shouldShowSendToAgent: Bool {
        visibleComments.contains { draftCommentActions.availability($0).canShowSendToAgent }
    }

    private var agentTargets: [ReviewFeedbackAgentTarget] {
        draftCommentActions.agentTargets()
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
                VStack(alignment: .leading, spacing: 10) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(groupedComments) { group in
                            commentGroup(group)
                        }
                    }
                    if hasFeedback {
                        feedbackSection
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
            if canPublishReview {
                collapsedActionButton(
                    id: "review-draft-summary-publish-review",
                    systemName: "arrow.up.doc",
                    label: "Publish review",
                    enabled: true
                ) {
                    draftCommentActions.publishReview()
                }
            }
            if shouldShowSendToAgent {
                collapsedSendToAgentControl
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

                if canPublishReview {
                    Button {
                        draftCommentActions.publishReview()
                    } label: {
                        summaryActionIcon(systemName: "arrow.up.doc", enabled: true)
                    }
                    .buttonStyle(.plain)
                    .help("Publish review")
                    .accessibilityIdentifier("review-draft-summary-publish-review")
                    .accessibilityLabel("Publish review")
                    .background(
                        ReviewDraftSummaryPressMarker(
                            identifier: "review-draft-summary-publish-review",
                            label: "Publish review",
                            isEnabled: true
                        ) {
                            draftCommentActions.publishReview()
                        }
                    )
                }

                if shouldShowSendToAgent {
                    expandedSendToAgentControl
                }

                Spacer(minLength: 0)
            }

            sendStateView
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

    @ViewBuilder
    private var sendStateView: some View {
        if let error = sendStatus.visibleSendError {
            Text(error)
                .font(.system(size: 10.5))
                .foregroundColor(theme.color("del").opacity(0.75))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("review-draft-summary-send-error")
                .background(
                    DiffReviewAccessibilityMarker(
                        identifier: "review-draft-summary-send-error",
                        label: error
                    )
                )
        } else if let latestHandoff = sendStatus.latestHandoff {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(theme.color("add"))
                Text("Sent to agent")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                Text(latestHandoff.createdAt, style: .time)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("fg-faint"))
            }
            .lineLimit(1)
            .accessibilityIdentifier("review-draft-summary-send-state")
            .accessibilityLabel("Sent to agent")
            .background(
                DiffReviewAccessibilityMarker(
                    identifier: "review-draft-summary-send-state",
                    label: "Sent to agent"
                )
            )
        }
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

    @ViewBuilder
    private var collapsedSendToAgentControl: some View {
        if agentTargets.count > 1 {
            Menu {
                let existingTargets = agentTargets.filter { !$0.isNewChat }
                let newChatTargets = agentTargets.filter { $0.isNewChat }
                ForEach(existingTargets) { target in
                    Button {
                        draftCommentActions.sendToAgent(bundle, target)
                    } label: {
                        sendToAgentTargetLabel(target)
                    }
                }
                if !existingTargets.isEmpty, !newChatTargets.isEmpty {
                    Divider()
                }
                ForEach(newChatTargets) { target in
                    Button {
                        draftCommentActions.sendToAgent(bundle, target)
                    } label: {
                        sendToAgentTargetLabel(target)
                    }
                }
            } label: {
                summaryActionIcon(systemName: "paperplane", enabled: canSendToAgent)
            }
            .menuStyle(.borderlessButton)
            .disabled(!canSendToAgent)
            .help("Send to agent")
            .accessibilityIdentifier("review-draft-summary-send-agent")
            .accessibilityLabel("Send to agent")
        } else {
            collapsedActionButton(
                id: "review-draft-summary-send-agent",
                systemName: "paperplane",
                label: "Send to agent",
                enabled: canSendToAgent
            ) {
                guard let target = agentTargets.first else { return }
                draftCommentActions.sendToAgent(bundle, target)
            }
        }
    }

    @ViewBuilder
    private var expandedSendToAgentControl: some View {
        if agentTargets.count > 1 {
            Menu {
                let existingTargets = agentTargets.filter { !$0.isNewChat }
                let newChatTargets = agentTargets.filter { $0.isNewChat }
                ForEach(existingTargets) { target in
                    Button {
                        draftCommentActions.sendToAgent(bundle, target)
                    } label: {
                        sendToAgentTargetLabel(target)
                    }
                }
                if !existingTargets.isEmpty, !newChatTargets.isEmpty {
                    Divider()
                }
                ForEach(newChatTargets) { target in
                    Button {
                        draftCommentActions.sendToAgent(bundle, target)
                    } label: {
                        sendToAgentTargetLabel(target)
                    }
                }
            } label: {
                summaryActionIcon(systemName: "paperplane", enabled: canSendToAgent)
            }
            .menuStyle(.borderlessButton)
            .disabled(!canSendToAgent)
            .help("Send to agent")
            .accessibilityIdentifier("review-draft-summary-send-agent")
            .accessibilityLabel("Send to agent")
        } else {
            Button {
                guard let target = agentTargets.first else { return }
                draftCommentActions.sendToAgent(bundle, target)
            } label: {
                summaryActionIcon(systemName: "paperplane", enabled: canSendToAgent)
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
                    guard let target = agentTargets.first else { return }
                    draftCommentActions.sendToAgent(bundle, target)
                }
            )
        }
    }

    private func sendToAgentTargetLabel(_ target: ReviewFeedbackAgentTarget) -> some View {
        Label {
            Text(target.title)
        } icon: {
            if let agent = draftCommentActions.agent(target) {
                Image(nsImage: AgentLogoView.menuImage(for: agent, size: 14))
            } else {
                Image(systemName: "sparkle")
            }
        }
    }

    private func summaryActionIcon(systemName: String, enabled: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(enabled ? theme.color("fg-muted") : theme.color("fg-faint"))
            .frame(width: 28, height: 24)
            .background(theme.color("bg-3"))
            .clipShape(RoundedRectangle(cornerRadius: 6))
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

    @ViewBuilder
    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GitHub feedback")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.color("fg"))
                .accessibilityIdentifier("review-summary-feedback-header")
                .background(
                    DiffReviewAccessibilityMarker(
                        identifier: "review-summary-feedback-header",
                        label: "GitHub feedback"
                    )
                )
            ForEach(feedbackGroups) { group in
                feedbackGroupView(group)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func feedbackGroupView(_ group: FeedbackGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.path)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.middle)
            ForEach(group.items) { item in
                feedbackCard(item)
            }
        }
    }

    private func feedbackCard(_ item: DiffReviewInlineFeedback) -> some View {
        let isFocused = item.id == focusedFeedbackID
        return Button {
            onSelectInlineFeedback(item)
        } label: {
            feedbackCardContent(item)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review-summary-feedback-\(item.id)")
        .accessibilityLabel(feedbackAccessibilityLabel(for: item))
        .padding(8)
        .background(isFocused ? theme.color("accent-soft") : theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? theme.color("accent") : theme.color("line"), lineWidth: isFocused ? 1 : 0.5)
        )
        .background(
            ReviewDraftSummaryPressMarker(
                identifier: "review-summary-feedback-\(item.id)",
                label: feedbackAccessibilityLabel(for: item),
                isEnabled: true
            ) {
                onSelectInlineFeedback(item)
            }
        )
    }

    private func feedbackCardContent(_ item: DiffReviewInlineFeedback) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(item.providerName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.color("accent"))
                if let author = item.author, !author.isEmpty {
                    Text(author)
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("fg-muted"))
                }
                if let line = item.anchor.line {
                    Text("line \(line)")
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("fg-faint"))
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)

            DiffReviewInlineFeedbackMarkdown.view(item.bodyPreview)
                .lineLimit(6)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func feedbackAccessibilityLabel(for item: DiffReviewInlineFeedback) -> String {
        [
            item.providerName,
            item.author,
            item.anchor.line.map { "line \($0)" },
            DiffReviewInlineFeedbackMarkdown.plainText(item.bodyPreview),
        ]
        .compactMap { part in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        .joined(separator: ", ")
    }

    private func summaryCard(_ comment: ReviewDraftComment) -> some View {
        let availability = draftCommentActions.availability(comment)
        let isFocused = comment.id == focusedDraftCommentID

        return VStack(alignment: .leading, spacing: 6) {
            if editingCommentID == comment.id {
                summaryCardContent(comment)
            } else {
                Button {
                    onSelectDraftComment(comment)
                } label: {
                    summaryCardContent(comment)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("review-draft-summary-comment-\(comment.id)")
                .accessibilityLabel(accessibilityLabel(for: comment))
            }

            if availability.canEdit || availability.canDelete || availability.canResolve || availability.canDismiss {
                HStack(spacing: 5) {
                    Spacer(minLength: 0)
                    if editingCommentID == comment.id {
                        commentActionButton(id: "save", commentID: comment.id, systemName: "checkmark", tooltip: "Save") {
                            draftCommentActions.edit(comment, editingBody)
                            editingCommentID = nil
                            editingBody = ""
                        }
                        commentActionButton(id: "cancel", commentID: comment.id, systemName: "xmark", tooltip: "Cancel") {
                            editingCommentID = nil
                            editingBody = ""
                        }
                    } else if availability.canEdit {
                        commentActionButton(id: "edit", commentID: comment.id, systemName: "pencil", tooltip: "Edit") {
                            editingCommentID = comment.id
                            editingBody = comment.bodyMarkdown
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
                label: accessibilityLabel(for: comment),
                isEnabled: editingCommentID != comment.id
            ) {
                onSelectDraftComment(comment)
            }
        )
    }

    private func summaryCardContent(_ comment: ReviewDraftComment) -> some View {
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
                ForEach(providerStateLabels(for: comment).indices, id: \.self) { index in
                    let label = providerStateLabels(for: comment)[index]
                    Text(label.text)
                        .font(.system(size: 10))
                        .foregroundColor(label.color)
                }
                Spacer(minLength: 0)
            }

            if editingCommentID == comment.id {
                TextEditor(text: $editingBody)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.color("fg"))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 62)
                    .background(theme.color("bg-2"))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityIdentifier("review-draft-summary-editor-\(comment.id)")
            } else {
                DiffReviewInlineFeedbackMarkdown.view(comment.bodyMarkdown)
                    .frame(maxHeight: 80, alignment: .top)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            providerStateLabels(for: comment).map(\.text).joined(separator: ", "),
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

    private func providerStateLabels(for comment: ReviewDraftComment) -> [(text: String, color: Color)] {
        var labels: [(text: String, color: Color)] = []
        if let publish = comment.providerPublish {
            labels.append(("published to \(publish.provider.displayName)", theme.color("fg-faint")))
        }
        if let error = comment.providerError {
            labels.append(("\(error.provider.displayName) error: \(error.message)", theme.color("warn")))
        }
        return labels
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

private struct FeedbackGroup: Identifiable {
    let fileID: DiffReviewFileID
    let items: [DiffReviewInlineFeedback]

    var id: String { fileID.id }
    var path: String { fileID.path }
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
