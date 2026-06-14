import SwiftUI

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

    @Environment(\.theme) private var theme
    @State private var pendingDraftAnchor: DiffReviewLineAnchor?
    @State private var pendingDraftBody = ""
    @State private var expandedCollapsedRowIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            fileLevelDraftCommentStack
            fileLevelInlineFeedbackStack
            content
        }
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
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
                        actions: draftCommentActions,
                        onSelect: onSelectDraftComment
                    )
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
        guard let displayModel = file.displayModel else {
            return DiffReviewInlineFeedbackPlacement.Result(fileLevel: inlineFeedback, byGroupID: [:])
        }
        return DiffReviewInlineFeedbackPlacement.position(inlineFeedback, in: displayModel.groups)
    }

    private var draftCommentPlacement: ReviewDraftCommentPlacement.Result {
        guard let displayModel = file.displayModel else {
            return ReviewDraftCommentPlacement.position(draftComments, in: [])
        }
        return ReviewDraftCommentPlacement.position(draftComments, in: displayModel.groups)
    }

    @ViewBuilder
    private var content: some View {
        if let displayModel = file.displayModel {
            let inlinePlacement = inlineFeedbackPlacement
            let draftPlacement = draftCommentPlacement
            VStack(spacing: 0) {
                ForEach(displayModel.groups) { group in
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
                            onReviewLineSelected: { anchor in
                                pendingDraftAnchor = anchor
                                pendingDraftBody = ""
                            }
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
                onReviewLineSelected: { anchor in
                    pendingDraftAnchor = anchor
                    pendingDraftBody = ""
                },
                hunkActions: { _ in DiffPaneHunkActions() }
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
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $pendingDraftBody)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg"))
                .frame(minHeight: 64, maxHeight: 90)
                .background(theme.color("bg-2"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.color("line"), lineWidth: 0.5)
                )
                .accessibilityIdentifier("diff-review-draft-composer")

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel") {
                    pendingDraftAnchor = nil
                    pendingDraftBody = ""
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.color("bg-1"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-composer-marker",
                label: "Draft comment composer"
            )
        )
    }

    private func savePendingDraft() {
        guard let pendingDraftAnchor else { return }
        let body = pendingDraftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        onSaveDraftComment(pendingDraftAnchor, body)
        self.pendingDraftAnchor = nil
        pendingDraftBody = ""
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

enum ReviewDraftCommentPlacement {
    struct RowKey: Hashable, Equatable {
        let side: DiffReviewInlineFeedbackSide
        let line: Int
    }

    struct Result: Equatable {
        let fileLevel: [ReviewDraftComment]
        let byRowAnchor: [RowKey: [ReviewDraftComment]]
    }

    static func position(
        _ comments: [ReviewDraftComment],
        in groups: [DiffDisplayGroup]
    ) -> Result {
        let visibleKeys = Set(groups.flatMap(visibleRowKeys))
        var fileLevel: [ReviewDraftComment] = []
        var byRowAnchor: [RowKey: [ReviewDraftComment]] = [:]

        for comment in comments where comment.state != .dismissed {
            let key = RowKey(side: comment.side, line: comment.normalizedLineRange.upperBound)
            if visibleKeys.contains(key) {
                byRowAnchor[key, default: []].append(comment)
            } else {
                fileLevel.append(comment)
            }
        }

        return Result(
            fileLevel: sorted(fileLevel),
            byRowAnchor: byRowAnchor.mapValues(sorted)
        )
    }

    static func visibleRowKeys(in group: DiffDisplayGroup) -> [RowKey] {
        group.rows.flatMap { row -> [RowKey] in
            visibleRowKeys(in: row)
        }
    }

    static func visibleRowKeys(in row: DiffDisplayRow) -> [RowKey] {
        var keys: [RowKey] = []
        if let oldLine = row.old?.lineNumber {
            keys.append(RowKey(side: .old, line: oldLine))
        }
        if let newLine = row.new?.lineNumber {
            keys.append(RowKey(side: .new, line: newLine))
        }
        return keys
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
            ReviewDraftCommentPlacement.RowKey(side: $0.side, line: $0.line)
        }
        var segments: [Segment] = []
        var bufferedRows: [DiffDisplayRow] = []

        for row in group.rows {
            bufferedRows.append(row)
            let keys = ReviewDraftCommentPlacement.visibleRowKeys(in: row)
            let comments = ReviewDraftCommentPlacement.sorted(keys.flatMap { placement.byRowAnchor[$0] ?? [] })
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

private struct ReviewDraftCommentCard: View {
    let comment: ReviewDraftComment
    let file: DiffReviewFileSummary
    let isFocused: Bool
    let actions: ReviewDraftCommentActions
    let onSelect: (ReviewDraftComment) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                onSelect(comment)
            } label: {
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

                        Text(DiffReviewInlineFeedbackMarkdown.render(comment.bodyMarkdown))
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
            .accessibilityIdentifier("diff-review-draft-comment-select-\(comment.id)")

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
            || availability.canCopyPrompt
            || availability.canSendToAgent
        {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if availability.canEdit {
                    actionButton(id: "edit", title: "Edit") {
                        actions.edit(comment)
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
                if availability.canCopyPrompt {
                    actionButton(id: "copy", title: "Copy") {
                        actions.copyPrompt(feedbackBundle)
                    }
                }
                if availability.canSendToAgent {
                    actionButton(id: "send", title: "Send") {
                        actions.sendToAgent(feedbackBundle)
                    }
                }
            }
        }
    }

    private func actionButton(id: String, title: String, action: @escaping () -> Void) -> some View {
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
        .accessibilityIdentifier("diff-review-draft-comment-\(id)-\(comment.id)")
        .accessibilityLabel(title)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-comment-action-\(id)-\(comment.id)",
                label: title
            )
        )
    }

    private var feedbackBundle: ReviewFeedbackBundle {
        ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: file.path,
                repositoryPath: nil,
                providerDescription: nil,
                sourceDescription: "Local draft comment"
            ),
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
            DiffReviewInlineFeedbackMarkdown.plainText(comment.bodyMarkdown),
        ]
        .compactMap { part in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        .joined(separator: ", ")
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

private struct DiffReviewInlineFeedbackCard: View {
    let item: DiffReviewInlineFeedback
    let file: DiffReviewFileSummary
    let isFocused: Bool
    let actions: DiffReviewInlineFeedbackActions
    let onSelect: (DiffReviewInlineFeedback) -> Void

    @Environment(\.theme) private var theme

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
        if availability.canOpenProvider || availability.canCopyContext || availability.canSendToAgent {
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
