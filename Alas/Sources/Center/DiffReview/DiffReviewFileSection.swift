import AppKit
import SwiftUI

private struct PendingContextExpansion {
    let key: DiffContextExpansionKey
    let mode: DiffContextExpansionMode
}

struct DiffReviewFileSection: View {
    let file: DiffReviewFileSectionModel
    var inlineFeedback: [DiffReviewInlineFeedback] = []
    var focusedFeedbackID: String? = nil
    var inlineFeedbackScrollTargetID: String? = nil
    var draftComments: [ReviewDraftComment] = []
    var focusedDraftCommentID: String? = nil
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let showsSourceBadge: Bool
    var lspContext: DiffPaneLSPContext? = nil
    var inlineFeedbackActions = DiffReviewInlineFeedbackActions()
    var onSelectInlineFeedback: (DiffReviewInlineFeedback) -> Void = { _ in }
    var draftCommentActions = ReviewDraftCommentActions()
    var onSelectDraftComment: (ReviewDraftComment) -> Void = { _ in }
    var onSaveDraftComment: (DiffReviewLineAnchor, String) -> Void = { _, _ in }
    var allowsDraftCommentCreation: Bool = true
    var onContextExpansionActivated: () -> Void = {}
    var reviewFeedbackTarget: ReviewFeedbackTarget?

    @Environment(\.theme) private var theme
    @StateObject private var copyFeedback = CopyFeedbackState()
    @State private var pendingDraftAnchor: DiffReviewLineAnchor?
    @State private var pendingDraftBody = ""
    @State private var expandedCollapsedRowIDs: Set<String> = []
    @State private var contextSnapshot: DiffReviewFileContextSnapshot?
    @State private var contextExpansion = DiffContextExpansionState()
    @State private var contextLoadTask: Task<Void, Never>?
    @State private var contextLoadFileID: DiffReviewFileID?
    @State private var contextLoadSignature: String?
    @State private var contextLoadGeneration = 0
    @State private var contextLoadError: String?
    @State private var pendingContextExpansions: [PendingContextExpansion] = []
    @FocusState private var draftComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            contextLoadErrorRow
            fileLevelDraftCommentStack
            fileLevelInlineFeedbackStack
            content
        }
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .copyFeedbackOverlay(message: copyFeedback.message)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.color("line"), lineWidth: 0.75)
        )
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-file-section-\(file.id.rawValue)",
                label: file.summary.path
            )
        )
        .background(copyFeedbackMarker)
        .onChange(of: draftCommentDisplaySignature) { _, _ in
            clearPendingDraft()
        }
        .onChange(of: file.id) { _, _ in
            resetContextState()
        }
        .onChange(of: contextStateSignature) { _, _ in
            resetContextState()
        }
        .onChange(of: pendingDraftAnchor) { _, anchor in
            guard anchor != nil else { return }
            Task { @MainActor in
                draftComposerFocused = true
            }
        }
    }

    @ViewBuilder
    private var copyFeedbackMarker: some View {
        if let message = copyFeedback.message {
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-copy-feedback-\(file.id.rawValue)",
                label: message
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(file.summary.status.glyph)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(statusColor(file.summary.status))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.summary.path)
                    .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let originalPath = file.summary.originalPath {
                    Text("from \(originalPath)")
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            sourceBadge
            Spacer(minLength: 12)
            if shouldShowChangeSummary(additions: file.summary.additions, deletions: file.summary.deletions) {
                HStack(spacing: 9) {
                    Text("+\(file.summary.additions)")
                        .foregroundColor(theme.color("add"))
                    Text("-\(file.summary.deletions)")
                        .foregroundColor(theme.color("del"))
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            if let openFile = file.openFile,
               let openFileTitle = DiffReviewFileSectionActions.openFileButtonTitle(for: file) {
                Button(action: openFile) {
                    Text(openFileTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.color("fg-muted"))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(theme.color("bg-3"))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(openFileTitle)
                .accessibilityIdentifier("diff-review-open-file-\(file.id.rawValue)")
                .accessibilityLabel(openFileTitle)
            }
            if let unstageFile = file.stagedMutationActions?.unstageFile {
                Button("Unstage") {
                    unstageFile()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("diff-review-unstage-file-\(file.id.rawValue)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    private var effectiveReviewFeedbackTarget: ReviewFeedbackTarget {
        if let reviewFeedbackTarget {
            return reviewFeedbackTarget
        }
        return ReviewFeedbackTarget(
            title: file.summary.path,
            repositoryPath: nil,
            providerDescription: nil,
            sourceDescription: "Local draft comment"
        )
    }

    private var feedbackDraftCommentActions: ReviewDraftCommentActions {
        ReviewDraftCommentActions(
            availability: draftCommentActions.availability,
            edit: draftCommentActions.edit,
            delete: draftCommentActions.delete,
            resolve: draftCommentActions.resolve,
            dismiss: draftCommentActions.dismiss,
            copyPrompt: { bundle in
                draftCommentActions.copyPrompt(bundle)
                copyFeedback.show("Copied prompt")
            },
            publishProvider: draftCommentActions.publishProvider,
            agentTargets: draftCommentActions.agentTargets,
            sendToAgent: draftCommentActions.sendToAgent
        )
    }

    @ViewBuilder
    private var contextLoadErrorRow: some View {
        if let contextLoadError {
            Text("Could not load surrounding context: \(contextLoadError)")
                .font(.system(size: 11))
                .foregroundColor(theme.color("warn"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.color("bg-2"))
                .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
                .background(
                    DiffReviewAccessibilityMarker(
                        identifier: "diff-review-context-error-\(file.id.rawValue)",
                        label: "Could not load surrounding context: \(contextLoadError)"
                    )
                )
        }
    }

    @ViewBuilder
    private var fileLevelDraftCommentStack: some View {
        let fileLevel = draftCommentPlacement.fileLevel
        if !fileLevel.isEmpty {
            draftCommentStack(fileLevel)
        }
    }

    @ViewBuilder
    private func draftCommentStack(_ comments: [ReviewDraftComment]) -> some View {
        if !comments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(comments) { comment in
                    ReviewDraftCommentCard(
                        comment: comment,
                        file: file.summary,
                        isFocused: comment.id == focusedDraftCommentID,
                        actions: feedbackDraftCommentActions,
                        reviewFeedbackTarget: effectiveReviewFeedbackTarget,
                        onSelect: onSelectDraftComment
                    )
                    .id(DiffReviewDraftCommentTargetID.targetID(commentID: comment.id, fileID: file.id))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.color("bg-1"))
            .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
        }
    }

    @ViewBuilder
    private var fileLevelInlineFeedbackStack: some View {
        let fileLevel = inlineFeedbackPlacement.fileLevel
        if !fileLevel.isEmpty {
            inlineFeedbackStack(fileLevel, file: file.summary)
        }
    }

    @ViewBuilder
    private func inlineFeedbackStack(_ items: [DiffReviewInlineFeedback], file: DiffReviewFileSummary) -> some View {
        if !items.isEmpty {
            let display = DiffReviewInlineFeedbackDisplayPolicy.display(
                for: items,
                includingRequiredIDs: requiredInlineFeedbackIDs
            )
            VStack(alignment: .leading, spacing: 6) {
                ForEach(display.visibleItems) { item in
                    DiffReviewInlineFeedbackCard(
                        item: item,
                        file: file,
                        isFocused: item.id == focusedFeedbackID,
                        actions: inlineFeedbackActions,
                        onSelect: onSelectInlineFeedback
                    )
                    .id(DiffReviewInlineFeedbackTargetID.targetID(feedbackID: item.id, fileID: file.id))
                }
                if display.hiddenCount > 0 {
                    DiffReviewInlineFeedbackMoreRow(hiddenCount: display.hiddenCount)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.color("bg-1"))
            .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
        }
    }

    private var requiredInlineFeedbackIDs: Set<String> {
        Set([focusedFeedbackID, inlineFeedbackScrollTargetID].compactMap(\.self))
    }

    private var inlineFeedbackPlacement: DiffReviewInlineFeedbackPlacement.Result {
        guard let groups = derivedDisplayGroups else {
            return DiffReviewInlineFeedbackPlacement.Result(fileLevel: inlineFeedback, byGroupID: [:])
        }
        return DiffReviewInlineFeedbackPlacement.position(inlineFeedback, in: groups)
    }

    private var draftCommentPlacement: ReviewDraftCommentPlacement.Result {
        guard let groups = derivedDisplayGroups else {
            return ReviewDraftCommentPlacement.position(draftComments, in: [])
        }
        return ReviewDraftCommentPlacement.position(draftComments, in: groups)
    }

    private var derivedDisplayGroups: [DiffDisplayGroup]? {
        guard let displayModel = file.displayModel else { return nil }
        return DiffContextExpandedDisplayBuilder.derive(
            groups: displayModel.groups,
            snapshot: contextSnapshot,
            providerAvailable: file.contextProvider != nil,
            expansion: contextExpansion,
            filePath: displayModel.filePath,
            chunkSize: 10
        )
    }

    @ViewBuilder
    private var content: some View {
        if let displayModel = file.displayModel, let groups = derivedDisplayGroups {
            let inlinePlacement = inlineFeedbackPlacement
            let draftPlacement = draftCommentPlacement
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    if let groupFeedback = inlinePlacement.byGroupID[group.id], !groupFeedback.isEmpty {
                        inlineFeedbackStack(groupFeedback, file: file.summary)
                    }
                    reviewGroup(group, displayModel: displayModel, placement: draftPlacement)
                }
            }
        } else {
            let message = file.placeholderMessage ?? "This file cannot be rendered in the review view."
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 18)
                .background(theme.color("bg-1"))
                .background(
                    DiffReviewAccessibilityMarker(
                        identifier: "diff-review-placeholder-\(file.id.rawValue)",
                        label: message
                    )
                )
        }
    }

    @ViewBuilder
    private func reviewGroup(
        _ group: DiffDisplayGroup,
        displayModel: DiffDisplayModel,
        placement: ReviewDraftCommentPlacement.Result
    ) -> some View {
        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: placement,
            pendingAnchor: pendingDraftAnchor
        )
        if segments.containsLocalAccessories {
            VStack(alignment: .leading, spacing: 0) {
                segmentedHunkHeader(group)
                ForEach(segments.items) { segment in
                    if !segment.rows.isEmpty {
                        DiffPaneTextDocumentView(
                            group: DiffDisplayGroup(
                                id: segment.id,
                                header: group.header,
                                sourceHunk: group.sourceHunk,
                                rows: segment.rows
                            ),
                            expandedCollapsedRowIDs: expandedCollapsedRowIDs,
                            layoutMode: layoutMode,
                            wrapLines: wrapLines,
                            showWhitespace: showWhitespace,
                            fileExtension: LanguageRegistry.highlighterExtension(forPath: file.summary.path),
                            codeFontFamily: codeFontFamily,
                            codeFontSize: codeFontSize,
                            theme: theme,
                            lspContext: lspContext,
                            allowsReviewLineSelection: allowsDraftCommentCreation,
                            onReviewLineSelected: { anchor in
                                pendingDraftAnchor = anchor
                                pendingDraftBody = ""
                            },
                            onContextExpansion: loadContextAndExpand
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if !segment.draftComments.isEmpty {
                        draftCommentStack(segment.draftComments)
                    }
                    if segment.showsComposer {
                        draftComposer
                    }
                }
            }
            .background(theme.color("bg-1"))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(theme.color("line"), lineWidth: 0.75)
            )
            .padding(.bottom, 10)
        } else {
            DiffPaneView(
                model: DiffDisplayModel(filePath: displayModel.filePath, groups: [group]),
                fileExtension: LanguageRegistry.highlighterExtension(forPath: file.summary.path),
                layoutMode: $layoutMode,
                wrapLines: $wrapLines,
                showWhitespace: $showWhitespace,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                showsToolbar: false,
                verticalScrollMode: .staticHeight,
                lspContext: lspContext,
                allowsReviewLineSelection: allowsDraftCommentCreation,
                onReviewLineSelected: { anchor in
                    pendingDraftAnchor = anchor
                    pendingDraftBody = ""
                },
                onContextExpansion: loadContextAndExpand,
                hunkActions: { hunk in
                    let enabled = file.stagedMutationActions?.isHunkUnstageEnabled?(hunk) ?? false
                    return DiffPaneHunkActions(
                        dropFromCommit: enabled ? { file.stagedMutationActions?.unstageHunk?(hunk) } : nil
                    )
                }
            )
        }
    }

    private func segmentedHunkHeader(_ group: DiffDisplayGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.header)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 1))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
            Spacer(minLength: 12)
            if !DiffCollapsedContextController.collapsedRowIDs(in: group).isEmpty {
                let expanded = DiffCollapsedContextController.isExpanded(group, expandedIDs: expandedCollapsedRowIDs)
                Button {
                    expandedCollapsedRowIDs = DiffCollapsedContextController.toggled(
                        group,
                        expandedIDs: expandedCollapsedRowIDs
                    )
                } label: {
                    Image(systemName: expanded ? "minus.square" : "plus.square")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.color("fg-muted"))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse context" : "Expand context")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var draftComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReviewDraftComposerTextEditor(
                text: $pendingDraftBody,
                theme: theme,
                isFocused: $draftComposerFocused,
                onSave: savePendingDraft,
                onCancel: clearPendingDraft
            )
            .frame(minHeight: 76, maxHeight: 104)
            .background(focusedComposerMarker)
            .onAppear {
                draftComposerFocused = true
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(theme.color("accent").opacity(0.65), lineWidth: 0.75)
            )
            .accessibilityIdentifier("diff-review-draft-composer")

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel") {
                    clearPendingDraft()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityIdentifier("diff-review-draft-composer-cancel")

                Button("Save") {
                    savePendingDraft()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color("bg-1"))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(theme.color("accent"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityIdentifier("diff-review-draft-composer-save")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.color("bg-1"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-composer-marker",
                label: "Draft comment composer"
            )
        )
    }

    @ViewBuilder
    private var focusedComposerMarker: some View {
        if draftComposerFocused {
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-composer-focused",
                label: "Draft comment composer focused"
            )
        }
    }

    private func savePendingDraft() {
        guard let pendingDraftAnchor else { return }
        let body = pendingDraftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard currentDraftRowKeys.contains(ReviewDraftCommentPlacement.RowKey(
            side: pendingDraftAnchor.side,
            line: pendingDraftAnchor.draftPlacementLine
        )) else {
            clearPendingDraft()
            return
        }

        onSaveDraftComment(pendingDraftAnchor, body)
        clearPendingDraft()
    }

    private func clearPendingDraft() {
        pendingDraftAnchor = nil
        pendingDraftBody = ""
        draftComposerFocused = false
    }

    private var currentDraftRowKeys: Set<ReviewDraftCommentPlacement.RowKey> {
        guard let groups = derivedDisplayGroups else { return [] }
        return Set(groups.flatMap(ReviewDraftCommentPlacement.allRowKeys))
    }

    private var displayGroupSignature: String {
        let groupSignature = file.displayModel?.groups.map { group in
            let rowSignature = group.rows.map { row in
                [
                    row.id,
                    row.old?.lineNumber.map { "o\($0)" } ?? "o-",
                    row.new?.lineNumber.map { "n\($0)" } ?? "n-",
                    "\(row.collapsedRows.count)",
                ].joined(separator: ":")
            }.joined(separator: ",")
            return "\(group.id)[\(rowSignature)]"
        }.joined(separator: "|") ?? "placeholder"
        return groupSignature
    }

    private var draftCommentDisplaySignature: String {
        "\(file.id.rawValue)|\(displayGroupSignature)"
    }

    private var contextStateSignature: String {
        [
            file.id.rawValue,
            file.contextProvider?.id.uuidString ?? "no-context-provider",
            displayGroupSignature,
        ].joined(separator: "|")
    }

    private func loadContextAndExpand(_ key: DiffContextExpansionKey, mode: DiffContextExpansionMode) {
        guard let provider = file.contextProvider else { return }
        onContextExpansionActivated()
        if contextSnapshot != nil {
            applyContextExpansion(key, mode: mode)
            return
        }
        pendingContextExpansions.append(PendingContextExpansion(key: key, mode: mode))
        guard contextLoadTask == nil else { return }
        let fileID = file.id
        let loadSignature = contextStateSignature
        contextLoadGeneration += 1
        let loadGeneration = contextLoadGeneration
        contextLoadError = nil
        contextLoadFileID = fileID
        contextLoadSignature = loadSignature
        contextLoadTask = Task {
            do {
                let snapshot = try await provider.snapshot()
                try Task.checkCancellation()
                await MainActor.run {
                    guard contextLoadGeneration == loadGeneration,
                          contextLoadFileID == fileID,
                          contextLoadSignature == loadSignature
                    else { return }
                    contextSnapshot = snapshot
                    contextLoadTask = nil
                    contextLoadFileID = nil
                    contextLoadSignature = nil
                    let pendingExpansions = pendingContextExpansions
                    pendingContextExpansions = []
                    for expansion in pendingExpansions {
                        applyContextExpansion(expansion.key, mode: expansion.mode)
                    }
                }
            } catch {
                await MainActor.run {
                    guard contextLoadGeneration == loadGeneration,
                          contextLoadFileID == fileID,
                          contextLoadSignature == loadSignature
                    else { return }
                    contextLoadError = error.localizedDescription
                    contextLoadTask = nil
                    contextLoadFileID = nil
                    contextLoadSignature = nil
                    pendingContextExpansions = []
                }
            }
        }
    }

    private func applyContextExpansion(_ key: DiffContextExpansionKey, mode: DiffContextExpansionMode) {
        guard let displayModel = file.displayModel else { return }
        let available = DiffContextExpandedDisplayBuilder.availableLineCount(
            key: key,
            groups: displayModel.groups,
            snapshot: contextSnapshot
        )
        contextExpansion.expand(key, available: available, mode: mode)
    }

    private func resetContextState() {
        contextLoadTask?.cancel()
        contextLoadGeneration += 1
        contextSnapshot = nil
        contextExpansion = DiffContextExpansionState()
        contextLoadTask = nil
        contextLoadFileID = nil
        contextLoadSignature = nil
        contextLoadError = nil
        pendingContextExpansions = []
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if showsSourceBadge, let title = file.summary.groupTitle {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(sourceColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(sourceColor.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .background(
                    DiffReviewAccessibilityMarker(
                        identifier: "diff-review-source-badge-\(file.id.rawValue)",
                        label: title.uppercased()
                    )
                )
        }
    }

    private var sourceColor: Color {
        switch file.summary.groupID ?? file.summary.namespace {
        case "unstaged":
            theme.color("warn")
        case "staged":
            theme.color("info")
        default:
            theme.color("accent")
        }
    }

    private func statusColor(_ status: DiffReviewFileStatus) -> Color {
        switch status {
        case .added:
            theme.color("add")
        case .deleted:
            theme.color("del")
        case .renamed, .copied:
            theme.color("accent")
        case .conflicted:
            theme.color("warn")
        case .modified, .unknown:
            theme.color("fg-dim")
        }
    }
}

enum ReviewDraftComposerKeyboardAction: Equatable {
    case save
    case cancel

    static func resolve(key: String, modifiers: NSEvent.ModifierFlags) -> Self? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if key == "\r", flags.contains(.command) {
            return .save
        }
        if key == "\u{1b}" {
            return .cancel
        }
        return nil
    }
}

private struct ReviewDraftComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let theme: Theme
    let isFocused: FocusState<Bool>.Binding
    let onSave: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        let textView = ReviewDraftComposerNSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 9)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.onKeyboardAction = context.coordinator.perform
        scrollView.documentView = textView
        context.coordinator.textView = textView
        applyTheme(to: scrollView, textView: textView)
        requestFocusIfNeeded(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ReviewDraftComposerNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onKeyboardAction = context.coordinator.perform
        applyTheme(to: scrollView, textView: textView)
        requestFocusIfNeeded(textView)
    }

    private func applyTheme(to scrollView: NSScrollView, textView: NSTextView) {
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = NSColor(theme.color("bg-2")).cgColor
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = NSColor(theme.color("fg"))
        textView.insertionPointColor = NSColor(theme.color("accent"))
    }

    private func requestFocusIfNeeded(_ textView: NSTextView) {
        guard isFocused.wrappedValue else { return }
        DispatchQueue.main.async {
            guard let window = textView.window,
                  window.firstResponder !== textView
            else { return }
            window.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReviewDraftComposerTextEditor
        weak var textView: NSTextView?

        init(_ parent: ReviewDraftComposerTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = false
        }

        @MainActor
        func perform(_ action: ReviewDraftComposerKeyboardAction) {
            switch action {
            case .save:
                parent.onSave()
            case .cancel:
                parent.onCancel()
            }
        }
    }
}

private final class ReviewDraftComposerNSTextView: NSTextView {
    var onKeyboardAction: (@MainActor (ReviewDraftComposerKeyboardAction) -> Void)?

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers ?? event.characters ?? ""
        if let action = ReviewDraftComposerKeyboardAction.resolve(key: key, modifiers: event.modifierFlags) {
            onKeyboardAction?(action)
            return
        }
        super.keyDown(with: event)
    }
}

enum ReviewDraftCommentPlacement {
    struct RowKey: Hashable, Equatable {
        let side: DiffReviewInlineFeedbackSide
        let line: Int
    }

    struct Result: Equatable {
        let fileLevel: [ReviewDraftComment]
        let byRowAnchor: [RowKey: [ReviewDraftComment]]
        let groupIDByCommentID: [String: String]
    }

    static func position(
        _ comments: [ReviewDraftComment],
        in groups: [DiffDisplayGroup]
    ) -> Result {
        let visibleKeys = Set(groups.flatMap(allRowKeys))
        let groupIDByKey = firstGroupIDByRowKey(in: groups)
        var fileLevel: [ReviewDraftComment] = []
        var byRowAnchor: [RowKey: [ReviewDraftComment]] = [:]
        var groupIDByCommentID: [String: String] = [:]

        for comment in comments where comment.state != .dismissed {
            let key = RowKey(side: comment.side, line: comment.normalizedLineRange.upperBound)
            if visibleKeys.contains(key) {
                byRowAnchor[key, default: []].append(comment)
                if let groupID = groupIDByKey[key] {
                    groupIDByCommentID[comment.id] = groupID
                }
            } else {
                fileLevel.append(comment)
            }
        }

        return Result(
            fileLevel: sorted(fileLevel),
            byRowAnchor: byRowAnchor.mapValues(sorted),
            groupIDByCommentID: groupIDByCommentID
        )
    }

    private static func firstGroupIDByRowKey(in groups: [DiffDisplayGroup]) -> [RowKey: String] {
        var output: [RowKey: String] = [:]
        for group in groups {
            for key in allRowKeys(in: group) where output[key] == nil {
                output[key] = group.id
            }
        }
        return output
    }

    static func visibleRowKeys(in group: DiffDisplayGroup) -> [RowKey] {
        group.rows.flatMap { row -> [RowKey] in
            visibleRowKeys(in: row)
        }
    }

    static func allRowKeys(in group: DiffDisplayGroup) -> [RowKey] {
        group.rows.flatMap(allRowKeys)
    }

    static func visibleRowKeys(in row: DiffDisplayRow) -> [RowKey] {
        var keys: [RowKey] = []
        if let oldLine = row.old?.lineNumber {
            keys.append(RowKey(side: .old, line: oldLine))
        }
        if let newLine = row.new?.lineNumber {
            keys.append(RowKey(side: .new, line: newLine))
        }
        for line in Set([row.old?.lineNumber, row.new?.lineNumber].compactMap(\.self)).sorted() {
            keys.append(RowKey(side: .unknown, line: line))
        }
        return keys
    }

    static func allRowKeys(in row: DiffDisplayRow) -> [RowKey] {
        visibleRowKeys(in: row) + row.collapsedRows.flatMap(allRowKeys)
    }

    static func sorted(_ comments: [ReviewDraftComment]) -> [ReviewDraftComment] {
        comments.sorted { lhs, rhs in
            if lhs.path != rhs.path {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            if lhs.normalizedLineRange.lowerBound != rhs.normalizedLineRange.lowerBound {
                return lhs.normalizedLineRange.lowerBound < rhs.normalizedLineRange.lowerBound
            }
            if lhs.normalizedLineRange.upperBound != rhs.normalizedLineRange.upperBound {
                return lhs.normalizedLineRange.upperBound < rhs.normalizedLineRange.upperBound
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    static func comments(
        matching keys: [RowKey],
        in placement: Result,
        groupID: String? = nil,
        excludingIDs excludedIDs: Set<String> = []
    ) -> [ReviewDraftComment] {
        var seenIDs = excludedIDs
        var comments: [ReviewDraftComment] = []
        for key in keys {
            for comment in placement.byRowAnchor[key] ?? [] {
                if let groupID, placement.groupIDByCommentID[comment.id] != groupID {
                    continue
                }
                guard seenIDs.insert(comment.id).inserted else { continue }
                comments.append(comment)
            }
        }
        return sorted(comments)
    }
}

enum ReviewDraftCommentRowSegmentation {
    struct Segment: Equatable, Identifiable {
        let id: String
        let rows: [DiffDisplayRow]
        let draftComments: [ReviewDraftComment]
        let showsComposer: Bool
    }

    struct Result: Equatable {
        let items: [Segment]

        var containsLocalAccessories: Bool {
            items.contains { !$0.draftComments.isEmpty || $0.showsComposer }
        }
    }

    static func segments(
        for group: DiffDisplayGroup,
        placement: ReviewDraftCommentPlacement.Result,
        pendingAnchor: DiffReviewLineAnchor?
    ) -> Result {
        let pendingKey = pendingAnchor.map {
            ReviewDraftCommentPlacement.RowKey(side: $0.side, line: $0.draftPlacementLine)
        }
        var segments: [Segment] = []
        var bufferedRows: [DiffDisplayRow] = []
        var emittedCommentIDs: Set<String> = []

        for row in group.rows {
            bufferedRows.append(row)
            let keys = ReviewDraftCommentPlacement.allRowKeys(in: row)
            let comments = ReviewDraftCommentPlacement.comments(
                matching: keys,
                in: placement,
                groupID: group.id,
                excludingIDs: emittedCommentIDs
            )
            emittedCommentIDs.formUnion(comments.map(\.id))
            let showsComposer = pendingKey.map { keys.contains($0) } ?? false
            guard !comments.isEmpty || showsComposer else { continue }

            segments.append(Segment(
                id: "\(group.id)-segment-\(segments.count)",
                rows: bufferedRows,
                draftComments: comments,
                showsComposer: showsComposer
            ))
            bufferedRows = []
        }

        if !bufferedRows.isEmpty {
            segments.append(Segment(
                id: "\(group.id)-segment-\(segments.count)",
                rows: bufferedRows,
                draftComments: [],
                showsComposer: false
            ))
        }

        return Result(items: segments)
    }
}

enum DiffReviewInlineFeedbackPlacement {
    struct Result: Equatable {
        let fileLevel: [DiffReviewInlineFeedback]
        let byGroupID: [String: [DiffReviewInlineFeedback]]
    }

    static func position(
        _ items: [DiffReviewInlineFeedback],
        in groups: [DiffDisplayGroup]
    ) -> Result {
        var fileLevel: [DiffReviewInlineFeedback] = []
        var byGroupID: [String: [DiffReviewInlineFeedback]] = [:]

        for item in items {
            guard let line = item.anchor.line,
                  let group = groups.first(where: { contains(line: line, side: item.anchor.side, in: $0) })
            else {
                fileLevel.append(item)
                continue
            }
            byGroupID[group.id, default: []].append(item)
        }

        return Result(fileLevel: fileLevel, byGroupID: byGroupID)
    }

    private static func contains(
        line: Int,
        side: DiffReviewInlineFeedbackSide,
        in group: DiffDisplayGroup
    ) -> Bool {
        group.rows.contains { row in
            contains(line: line, side: side, in: row)
        }
    }

    private static func contains(
        line: Int,
        side: DiffReviewInlineFeedbackSide,
        in row: DiffDisplayRow
    ) -> Bool {
        if rowMatches(line: line, side: side, row: row) {
            return true
        }
        return row.collapsedRows.contains { collapsedRow in
            contains(line: line, side: side, in: collapsedRow)
        }
    }

    private static func rowMatches(
        line: Int,
        side: DiffReviewInlineFeedbackSide,
        row: DiffDisplayRow
    ) -> Bool {
        switch side {
        case .new:
            return row.new?.lineNumber == line
        case .old:
            return row.old?.lineNumber == line
        case .unknown:
            return row.new?.lineNumber == line || row.old?.lineNumber == line
        }
    }
}

enum ReviewDraftCommentDisplayPolicy {
    static let cardMinimumHeight: CGFloat = 86
    private static let estimatedBodyCharactersPerLine = 86
    private static let estimatedBodyLineHeight: CGFloat = 15.5
    private static let cardNonBodyHeight: CGFloat = 52
    private static let stackVerticalPadding: CGFloat = 20
    private static let rowSpacing: CGFloat = 6

    static func estimatedHeight(for comments: [ReviewDraftComment]) -> CGFloat {
        guard !comments.isEmpty else { return 0 }

        let visibleHeights = comments.reduce(CGFloat(0)) { total, comment in
            total + estimatedCardHeight(for: comment)
        }
        let spacingHeight = CGFloat(max(0, comments.count - 1)) * rowSpacing
        return stackVerticalPadding + visibleHeights + spacingHeight
    }

    static func estimatedCardHeight(for comment: ReviewDraftComment) -> CGFloat {
        let bodyLineCount = estimatedLineCount(for: comment.bodyMarkdown)
        let bodyHeight = CGFloat(bodyLineCount) * estimatedBodyLineHeight

        return max(cardMinimumHeight, cardNonBodyHeight + bodyHeight)
    }

    private static func estimatedLineCount(for source: String) -> Int {
        let logicalLines = source.split(separator: "\n", omittingEmptySubsequences: false)
        return logicalLines.reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / Double(estimatedBodyCharactersPerLine))))
        }
    }
}

enum DiffReviewInlineFeedbackDisplayPolicy {
    static let maximumVisibleCards = 3
    static let cardMinimumHeight: CGFloat = 78
    static let moreRowEstimatedHeight: CGFloat = 20
    private static let estimatedBodyCharactersPerLine = 86
    private static let estimatedBodyLineHeight: CGFloat = 15.5
    private static let cardNonBodyHeight: CGFloat = 46
    private static let stackVerticalPadding: CGFloat = 20
    private static let rowSpacing: CGFloat = 6

    struct Display {
        let visibleItems: [DiffReviewInlineFeedback]
        let hiddenCount: Int
    }

    static func display(for items: [DiffReviewInlineFeedback]) -> Display {
        display(for: items, includingRequiredIDs: [])
    }

    static func display(
        for items: [DiffReviewInlineFeedback],
        includingRequiredIDs requiredIDs: Set<String>
    ) -> Display {
        let visibleItems = Array(items.prefix(maximumVisibleCards))
        let visibleIDs = Set(visibleItems.map(\.id))
        let requiredItems = items.filter { requiredIDs.contains($0.id) && !visibleIDs.contains($0.id) }
        let visible = visibleItems + requiredItems
        return Display(
            visibleItems: visible,
            hiddenCount: max(0, items.count - visible.count)
        )
    }

    static func estimatedHeight(for itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }

        let visibleCount = min(itemCount, maximumVisibleCards)
        let hiddenCount = max(0, itemCount - visibleCount)
        let rowCount = visibleCount + (hiddenCount > 0 ? 1 : 0)
        let rowHeights = CGFloat(visibleCount) * cardMinimumHeight
            + (hiddenCount > 0 ? moreRowEstimatedHeight : 0)
        let spacingHeight = CGFloat(max(0, rowCount - 1)) * rowSpacing

        return stackVerticalPadding + rowHeights + spacingHeight
    }

    static func estimatedHeight(for items: [DiffReviewInlineFeedback]) -> CGFloat {
        guard !items.isEmpty else { return 0 }

        let display = display(for: items)
        let visibleHeights = display.visibleItems.reduce(CGFloat(0)) { total, item in
            total + estimatedCardHeight(for: item)
        }
        let rowCount = display.visibleItems.count + (display.hiddenCount > 0 ? 1 : 0)
        let moreHeight = display.hiddenCount > 0 ? moreRowEstimatedHeight : 0
        let spacingHeight = CGFloat(max(0, rowCount - 1)) * rowSpacing

        return stackVerticalPadding + visibleHeights + moreHeight + spacingHeight
    }

    static func estimatedCardHeight(for item: DiffReviewInlineFeedback) -> CGFloat {
        let bodyLineCount = estimatedLineCount(for: item.bodyPreview)
        let bodyHeight = CGFloat(bodyLineCount) * estimatedBodyLineHeight

        return max(cardMinimumHeight, cardNonBodyHeight + bodyHeight)
    }

    private static func estimatedLineCount(for source: String) -> Int {
        let logicalLines = source.split(separator: "\n", omittingEmptySubsequences: false)
        return logicalLines.reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / Double(estimatedBodyCharactersPerLine))))
        }
    }
}

enum DiffReviewInlineFeedbackMarkdown {
    @MainActor
    static func render(_ source: String) -> AttributedString {
        ACPMarkdownText.inlineMarkdown(source)
    }

    @MainActor
    static func plainText(_ source: String) -> String {
        NSAttributedString(render(source)).string
    }
}

struct ReviewDraftCommentCard: View {
    let comment: ReviewDraftComment
    let file: DiffReviewFileSummary
    let isFocused: Bool
    let actions: ReviewDraftCommentActions
    let reviewFeedbackTarget: ReviewFeedbackTarget
    let onSelect: (ReviewDraftComment) -> Void

    @Environment(\.theme) private var theme
    @State private var isEditing = false
    @State private var editingBody = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                cardContent
            } else {
                Button {
                    onSelect(comment)
                } label: {
                    cardContent
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("diff-review-draft-comment-select-\(comment.id)")
            }

            actionRow
        }
        .padding(8)
        .frame(minHeight: ReviewDraftCommentDisplayPolicy.cardMinimumHeight, alignment: .top)
        .background(isFocused ? theme.color("accent-soft") : theme.color("bg-2"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? theme.color("accent") : statusColor.opacity(0.65), lineWidth: isFocused ? 1 : 0.75)
        )
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-comment-\(comment.id)",
                label: accessibilityLabel
            )
        )
        .background(focusedMarker)
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Local draft")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(statusColor)

                    Text(lineDescription)
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("fg-faint"))

                    if comment.state == .resolved {
                        Text("resolved")
                            .font(.system(size: 10))
                            .foregroundColor(theme.color("fg-faint"))
                    }
                }
                .lineLimit(1)

                ForEach(providerStateLabels.indices, id: \.self) { index in
                    let label = providerStateLabels[index]
                    Text(label.text)
                        .font(.system(size: 10))
                        .foregroundColor(label.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isEditing {
                    ReviewDraftComposerTextEditor(
                        text: $editingBody,
                        theme: theme,
                        isFocused: $editorFocused,
                        onSave: saveEditingComment,
                        onCancel: cancelEditingComment
                    )
                    .frame(minHeight: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.color("line"), lineWidth: 0.75)
                    )
                    .accessibilityIdentifier("diff-review-draft-comment-editor-\(comment.id)")
                } else {
                    Text(DiffReviewInlineFeedbackMarkdown.render(comment.bodyMarkdown))
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.color("fg"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var focusedMarker: some View {
        if isFocused {
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-comment-focused-\(comment.id)",
                label: accessibilityLabel
            )
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        let availability = actions.availability(comment)
        if availability.canEdit
            || availability.canDelete
            || availability.canResolve
            || availability.canDismiss
            || availability.canCopyPrompt
            || availability.canShowSendToAgent
            || availability.canPublishProvider
        {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if isEditing {
                    actionButton(id: "save", title: "Save") {
                        saveEditingComment()
                    }
                    actionButton(id: "cancel", title: "Cancel") {
                        cancelEditingComment()
                    }
                } else if availability.canEdit {
                    actionButton(id: "edit", title: "Edit") {
                        editingBody = comment.bodyMarkdown
                        isEditing = true
                        editorFocused = true
                    }
                }
                if availability.canDelete {
                    actionButton(id: "delete", title: "Delete") {
                        actions.delete(comment)
                    }
                }
                if availability.canResolve {
                    actionButton(id: "resolve", title: "Resolve") {
                        actions.resolve(comment)
                    }
                }
                if availability.canDismiss {
                    actionButton(id: "dismiss", title: "Dismiss") {
                        actions.dismiss(comment)
                    }
                }
                if availability.canCopyPrompt {
                    actionButton(id: "copy", title: "Copy") {
                        actions.copyPrompt(feedbackBundle)
                    }
                }
                if availability.canPublishProvider {
                    actionButton(id: "publish", title: "Publish") {
                        actions.publishProvider(comment)
                    }
                }
                if availability.canShowSendToAgent {
                    sendToAgentControl(isEnabled: availability.canSendToAgent)
                }
            }
        }
    }

    @ViewBuilder
    private func sendToAgentControl(isEnabled: Bool) -> some View {
        let targets = actions.agentTargets()
        if targets.count > 1 {
            Menu("Send") {
                ForEach(targets) { target in
                    Button(target.title) {
                        actions.sendToAgent(feedbackBundle, target)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .disabled(!isEnabled)
            .help("Send")
            .accessibilityIdentifier("diff-review-draft-comment-action-send-\(comment.id)")
        } else {
            actionButton(id: "send", title: "Send", enabled: isEnabled) {
                guard let target = targets.first else { return }
                actions.sendToAgent(feedbackBundle, target)
            }
        }
    }

    private func actionButton(
        id: String,
        title: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(enabled ? theme.color("fg-muted") : theme.color("fg-faint"))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
        .accessibilityIdentifier(accessibilityIdentifier(forActionID: id))
        .accessibilityLabel(title)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "\(markerIdentifier(forActionID: id))-label",
                label: title
            )
        )
        .background(
            ReviewDraftCommentActionPressMarker(
                identifier: markerIdentifier(forActionID: id),
                label: title,
                isEnabled: enabled,
                action: action
            )
        )
    }

    private func accessibilityIdentifier(forActionID id: String) -> String {
        return "diff-review-draft-comment-button-\(id)-\(comment.id)"
    }

    private func markerIdentifier(forActionID id: String) -> String {
        if id == "publish" {
            return "diff-review-draft-comment-publish-\(comment.id)"
        }
        return "diff-review-draft-comment-action-\(id)-\(comment.id)"
    }

    private func saveEditingComment() {
        actions.edit(comment, editingBody)
        cancelEditingComment()
    }

    private func cancelEditingComment() {
        isEditing = false
        editingBody = ""
        editorFocused = false
    }

    private var feedbackBundle: ReviewFeedbackBundle {
        ReviewFeedbackBundle(
            target: reviewFeedbackTarget,
            comments: [comment]
        )
    }

    private var lineDescription: String {
        let range = comment.normalizedLineRange
        if range.lowerBound == range.upperBound {
            return "line \(range.lowerBound)"
        }
        return "lines \(range.lowerBound)-\(range.upperBound)"
    }

    private var accessibilityLabel: String {
        [
            "Local draft",
            lineDescription,
            comment.state == .resolved ? "resolved" : nil,
            providerStateLabels.map(\.text).joined(separator: ", "),
            DiffReviewInlineFeedbackMarkdown.plainText(comment.bodyMarkdown),
        ]
        .compactMap { part in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        .joined(separator: ", ")
    }

    private var providerStateLabels: [(text: String, color: Color)] {
        var labels: [(text: String, color: Color)] = []
        if let publish = comment.providerPublish {
            labels.append(("published to \(publish.provider.displayName)", theme.color("fg-faint")))
        }
        if let error = comment.providerError {
            labels.append(("\(error.provider.displayName) error: \(error.message)", theme.color("warn")))
        }
        return labels
    }

    private var statusColor: Color {
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

private extension DiffReviewLineAnchor {
    var draftPlacementLine: Int {
        endLine ?? line
    }
}

struct ReviewDraftCommentActionPressMarker: NSViewRepresentable {
    let identifier: String
    let label: String
    var isEnabled = true
    let action: () -> Void

    func makeNSView(context: Context) -> ReviewDraftCommentActionPressView {
        let view = ReviewDraftCommentActionPressView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityRole(.button)
        view.setAccessibilityEnabled(isEnabled)
        view.isEnabled = isEnabled
        view.action = action
        return view
    }

    func updateNSView(_ view: ReviewDraftCommentActionPressView, context: Context) {
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityRole(.button)
        view.setAccessibilityEnabled(isEnabled)
        view.isEnabled = isEnabled
        view.action = action
    }
}

final class ReviewDraftCommentActionPressView: NSView {
    var isEnabled = true
    var action: () -> Void = {}

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action()
        return true
    }
}

private struct DiffReviewInlineFeedbackCard: View {
    let item: DiffReviewInlineFeedback
    let file: DiffReviewFileSummary
    let isFocused: Bool
    let actions: DiffReviewInlineFeedbackActions
    let onSelect: (DiffReviewInlineFeedback) -> Void

    @Environment(\.theme) private var theme
    @State private var replyEditor = DiffReviewInlineFeedbackReplyEditorState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                DiffReviewInlineFeedbackCardInteraction.select(item, onSelect: onSelect)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(statusColor)
                        .frame(width: 3)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.providerName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(statusColor)

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
                        }
                        .lineLimit(1)

                        Text(DiffReviewInlineFeedbackMarkdown.render(item.bodyPreview))
                            .font(.system(size: 11.5))
                            .foregroundColor(theme.color("fg"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("diff-review-inline-feedback-select-\(item.id)")

            actionRow
        }
        .padding(8)
        .frame(minHeight: DiffReviewInlineFeedbackDisplayPolicy.cardMinimumHeight, alignment: .top)
        .background(isFocused ? theme.color("accent-soft") : theme.color("bg-2"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? theme.color("accent") : theme.color("line"), lineWidth: isFocused ? 1 : 0.5)
        )
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-inline-feedback-\(item.id)",
                label: accessibilityLabel
            )
        )
        .background(focusedMarker)
    }

    @ViewBuilder
    private var focusedMarker: some View {
        if isFocused {
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-inline-feedback-focused-\(item.id)",
                label: accessibilityLabel
            )
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        let availability = actions.availability(item, file)
        if replyEditor.isReplying {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Reply", text: $replyEditor.body, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.color("fg"))
                    .padding(7)
                    .background(theme.color("bg-1"))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityIdentifier("diff-review-inline-feedback-reply-\(item.id)")

                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    inlineActionButton(id: "reply-save", title: "Save") {
                        _ = replyEditor.save(item) { feedback, body in
                            actions.replyProvider(feedback, file, body)
                        }
                    }
                    inlineActionButton(id: "reply-cancel", title: "Cancel") {
                        replyEditor.cancel()
                    }
                }
            }
        } else if availability.canOpenProvider
            || availability.canCopyContext
            || availability.canSendToAgent
            || availability.canReplyProvider
            || availability.canResolveProvider
            || availability.canUnresolveProvider {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if availability.canOpenProvider {
                    inlineActionButton(id: "open", title: "Open") {
                        DiffReviewInlineFeedbackCardInteraction.open(item) { feedback in
                            actions.openProvider(feedback, file)
                        }
                    }
                }
                if availability.canCopyContext {
                    inlineActionButton(id: "copy", title: "Copy") {
                        DiffReviewInlineFeedbackCardInteraction.copy(item) { feedback in
                            actions.copyContext(feedback, file)
                        }
                    }
                }
                if availability.canSendToAgent {
                    inlineActionButton(id: "send", title: "Send") {
                        DiffReviewInlineFeedbackCardInteraction.send(item) { feedback in
                            actions.sendToAgent(feedback, file)
                        }
                    }
                }
                if availability.canReplyProvider {
                    inlineActionButton(id: "reply", title: "Reply") {
                        replyEditor.start()
                    }
                }
                if availability.canResolveProvider {
                    inlineActionButton(id: "resolve", title: "Resolve") {
                        actions.resolveProvider(item, file)
                    }
                }
                if availability.canUnresolveProvider {
                    inlineActionButton(id: "unresolve", title: "Unresolve") {
                        actions.unresolveProvider(item, file)
                    }
                }
            }
        }
    }

    private func inlineActionButton(id: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityIdentifier("diff-review-inline-feedback-\(id)-\(item.id)")
        .accessibilityLabel(title)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-inline-feedback-action-\(id)-\(item.id)",
                label: title
            )
        )
        .background(
            ReviewDraftCommentActionPressMarker(
                identifier: "diff-review-inline-feedback-action-\(id)-\(item.id)",
                label: title,
                action: action
            )
        )
    }

    private var accessibilityLabel: String {
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

    private var statusColor: Color {
        switch item.status {
        case .actionable, .pending:
            theme.color("accent")
        case .failed:
            theme.color("del")
        case .passed, .resolved:
            theme.color("add")
        case .cancelled, .unknown:
            theme.color("fg-muted")
        }
    }
}

enum DiffReviewInlineFeedbackCardInteraction {
    static func select(
        _ item: DiffReviewInlineFeedback,
        onSelect: (DiffReviewInlineFeedback) -> Void
    ) {
        onSelect(item)
    }

    static func open(
        _ item: DiffReviewInlineFeedback,
        action: (DiffReviewInlineFeedback) -> Void
    ) {
        action(item)
    }

    static func copy(
        _ item: DiffReviewInlineFeedback,
        action: (DiffReviewInlineFeedback) -> Void
    ) {
        action(item)
    }

    static func send(
        _ item: DiffReviewInlineFeedback,
        action: (DiffReviewInlineFeedback) -> Void
    ) {
        action(item)
    }

    static func reply(
        _ item: DiffReviewInlineFeedback,
        body: String,
        action: (DiffReviewInlineFeedback, String) -> Void
    ) {
        action(item, body)
    }
}

struct DiffReviewInlineFeedbackReplyEditorState: Equatable {
    var isReplying = false
    var body = ""

    mutating func start() {
        body = ""
        isReplying = true
    }

    mutating func cancel() {
        body = ""
        isReplying = false
    }

    @discardableResult
    mutating func save(
        _ item: DiffReviewInlineFeedback,
        action: (DiffReviewInlineFeedback, String) -> Void
    ) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        DiffReviewInlineFeedbackCardInteraction.reply(item, body: trimmed, action: action)
        body = ""
        isReplying = false
        return true
    }
}

private struct DiffReviewInlineFeedbackMoreRow: View {
    let hiddenCount: Int

    @Environment(\.theme) private var theme

    var body: some View {
        Text("+\(hiddenCount) more feedback")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(theme.color("fg-muted"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(theme.color("bg-2"))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .background(
                DiffReviewAccessibilityMarker(
                    identifier: "diff-review-inline-feedback-more",
                    label: "+\(hiddenCount) more feedback"
                )
            )
    }
}

enum DiffReviewFileSectionActions {
    static func openFileButtonTitle(for file: DiffReviewFileSectionModel) -> String? {
        file.openFile == nil ? nil : "Open File"
    }
}
