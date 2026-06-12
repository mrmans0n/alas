import SwiftUI

struct ReviewChangesFileSection: View {
    let file: ReviewChangesFileSectionModel
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.color("line"), lineWidth: 0.75)
        )
        .background(
            ReviewChangesAccessibilityMarker(
                identifier: "review-file-section-\(file.id.rawValue)",
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var content: some View {
        if let displayModel = file.displayModel {
            DiffPaneView(
                model: displayModel,
                fileExtension: LanguageRegistry.highlighterExtension(forPath: file.summary.path),
                layoutMode: $layoutMode,
                wrapLines: $wrapLines,
                showWhitespace: $showWhitespace,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                showsToolbar: false,
                verticalScrollMode: .staticHeight,
                hunkActions: { _ in DiffPaneHunkActions() }
            )
        } else {
            Text(file.placeholderMessage ?? "This file cannot be rendered in the review view.")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 18)
                .background(theme.color("bg-1"))
        }
    }

    private var sourceBadge: some View {
        Text(file.summary.source.title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(sourceColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(sourceColor.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var sourceColor: Color {
        switch file.summary.source {
        case .unstaged:
            theme.color("warn")
        case .staged:
            theme.color("info")
        }
    }

    private func statusColor(_ status: ReviewChangesFileStatus) -> Color {
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
