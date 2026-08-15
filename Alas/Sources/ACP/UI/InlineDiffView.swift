import SwiftUI

struct InlineDiffView: View {
    let diff: ParsedDiff
    let relativePath: String
    let maxLines: Int
    let onShowAll: () -> Void
    @Environment(\.theme) private var theme

    private static let codeFontSize: CGFloat = 11
    private static let codeFontFamily: String = ""

    private var allLines: [ParsedDiff.Hunk.Line] {
        diff.hunks.flatMap(\.lines)
    }

    private var truncated: Bool {
        allLines.count > maxLines
    }

    private var visibleHunks: [ParsedDiff.Hunk] {
        guard truncated else { return diff.hunks }

        var remaining = maxLines
        var result: [ParsedDiff.Hunk] = []

        for hunk in diff.hunks {
            if remaining <= 0 { break }
            if hunk.lines.count <= remaining {
                result.append(hunk)
                remaining -= hunk.lines.count
            } else {
                let trimmed = ParsedDiff.Hunk(
                    header: hunk.header,
                    oldStart: hunk.oldStart,
                    newStart: hunk.newStart,
                    lines: Array(hunk.lines.prefix(remaining))
                )
                result.append(trimmed)
                remaining = 0
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleHunks.enumerated()), id: \.offset) { (_, hunk) in
                VStack(alignment: .leading, spacing: 0) {
                    Text(hunk.header)
                        .font(.system(size: Self.codeFontSize * 0.85, design: .monospaced))
                        .foregroundStyle(theme.color("fg-dim"))
                        .padding(.horizontal, 14).padding(.vertical, 4)
                        .background(theme.color("bg-2"))
                        .overlay(Divider().opacity(0.5), alignment: .bottom)

                    DiffSelectableTextView(
                        hunk: hunk,
                        fileExtension: fileExtension,
                        codeFontFamily: Self.codeFontFamily,
                        codeFontSize: Self.codeFontSize,
                        theme: theme
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if truncated {
                Button(action: onShowAll) {
                    HStack(spacing: 4) {
                        Text("Show all \(allLines.count) lines")
                        Image(systemName: "arrow.forward")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("accent"))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.plain)
                .background(theme.color("bg-2"))
                .overlay(Divider().opacity(0.5), alignment: .top)
            }
        }
    }

    private var fileExtension: String {
        LanguageRegistry.highlighterExtension(forPath: relativePath)
    }
}
