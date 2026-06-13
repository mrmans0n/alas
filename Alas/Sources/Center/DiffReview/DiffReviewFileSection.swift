import SwiftUI

struct DiffReviewFileSection: View {
    let file: DiffReviewFileSectionModel
    var inlineFeedback: [DiffReviewInlineFeedback] = []
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let showsSourceBadge: Bool
    var lspContext: DiffPaneLSPContext? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
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
    private var fileLevelInlineFeedbackStack: some View {
        let fileLevel = inlineFeedbackPlacement.fileLevel
        if !fileLevel.isEmpty {
            inlineFeedbackStack(fileLevel)
        }
    }

    @ViewBuilder
    private func inlineFeedbackStack(_ items: [DiffReviewInlineFeedback]) -> some View {
        if !items.isEmpty {
            let display = DiffReviewInlineFeedbackDisplayPolicy.display(for: items)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(display.visibleItems) { item in
                    DiffReviewInlineFeedbackCard(item: item)
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

    private var inlineFeedbackPlacement: DiffReviewInlineFeedbackPlacement.Result {
        guard let displayModel = file.displayModel else {
            return DiffReviewInlineFeedbackPlacement.Result(fileLevel: inlineFeedback, byGroupID: [:])
        }
        return DiffReviewInlineFeedbackPlacement.position(inlineFeedback, in: displayModel.groups)
    }

    @ViewBuilder
    private var content: some View {
        if let displayModel = file.displayModel {
            let placement = inlineFeedbackPlacement
            VStack(spacing: 0) {
                ForEach(displayModel.groups) { group in
                    if let groupFeedback = placement.byGroupID[group.id], !groupFeedback.isEmpty {
                        inlineFeedbackStack(groupFeedback)
                    }
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
                        hunkActions: { _ in DiffPaneHunkActions() }
                    )
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

enum DiffReviewInlineFeedbackDisplayPolicy {
    static let maximumVisibleCards = 3
    static let cardEstimatedHeight: CGFloat = 78
    static let moreRowEstimatedHeight: CGFloat = 20
    private static let stackVerticalPadding: CGFloat = 20
    private static let rowSpacing: CGFloat = 6

    struct Display {
        let visibleItems: [DiffReviewInlineFeedback]
        let hiddenCount: Int
    }

    static func display(for items: [DiffReviewInlineFeedback]) -> Display {
        let visibleItems = Array(items.prefix(maximumVisibleCards))
        return Display(
            visibleItems: visibleItems,
            hiddenCount: max(0, items.count - visibleItems.count)
        )
    }

    static func estimatedHeight(for itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }

        let visibleCount = min(itemCount, maximumVisibleCards)
        let hiddenCount = max(0, itemCount - visibleCount)
        let rowCount = visibleCount + (hiddenCount > 0 ? 1 : 0)
        let rowHeights = CGFloat(visibleCount) * cardEstimatedHeight
            + (hiddenCount > 0 ? moreRowEstimatedHeight : 0)
        let spacingHeight = CGFloat(max(0, rowCount - 1)) * rowSpacing

        return stackVerticalPadding + rowHeights + spacingHeight
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

private struct DiffReviewInlineFeedbackCard: View {
    let item: DiffReviewInlineFeedback

    @Environment(\.theme) private var theme

    var body: some View {
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
                    .lineLimit(3)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(height: DiffReviewInlineFeedbackDisplayPolicy.cardEstimatedHeight, alignment: .top)
        .background(theme.color("bg-2"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.color("line"), lineWidth: 0.5)
        )
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-inline-feedback-\(item.id)",
                label: accessibilityLabel
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
