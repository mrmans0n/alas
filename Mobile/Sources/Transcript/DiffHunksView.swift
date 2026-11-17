import AlasRemoteKit
import SwiftUI

/// The phone's `InlineDiffView`: each hunk's header, then its lines with old and new numbers, a
/// +/−/space gutter and tinted adds and deletes. Lines past `maxLines`, counted across hunks, are
/// cut, with "Show all N lines" below. Long lines do not wrap; a hunk scrolls sideways instead.
struct DiffHunksView: View {
    let diff: ParsedDiff
    let maxLines: Int
    /// The owner keeps the expanded state, so the transcript cell re-measures when it changes.
    let onShowAll: () -> Void

    // ponytail: every shown line is a view in one self-sizing cell, so "Show all" stops here;
    // render lines lazily (virtualized) to lift the ceiling.
    static let expandedLineLimit = 2000

    private var lineCount: Int { diff.hunks.reduce(0) { $0 + $1.lines.count } }

    private var shownLines: Int { min(maxLines, Self.expandedLineLimit) }

    private var visibleHunks: [ParsedDiff.Hunk] {
        var remaining = shownLines
        var result: [ParsedDiff.Hunk] = []
        for hunk in diff.hunks where remaining > 0 {
            let lines = Array(hunk.lines.prefix(remaining))
            result.append(.init(header: hunk.header, oldStart: hunk.oldStart, newStart: hunk.newStart, lines: lines))
            remaining -= lines.count
        }
        return result
    }

    var body: some View {
        let hunks = visibleHunks
        // Wide enough for the largest number shown; the font is monospaced, so padding aligns them.
        let digits = String(hunks.flatMap(\.lines).map { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0).count
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
                Text(hunk.header)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill))
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // At least as wide as the card, so short lines' tints reach its edge.
                        Color.clear.frame(height: 0).containerRelativeFrame(.horizontal)
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            Self.row(line, digits: digits)
                        }
                    }
                }
            }
            if lineCount > shownLines {
                if maxLines > shownLines {
                    Text("\(lineCount - shownLines) more lines not shown")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                } else {
                    Button("Show all \(lineCount) lines", action: onShowAll)
                        .font(.footnote)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .font(.system(.footnote, design: .monospaced))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private static func row(_ line: ParsedDiff.Hunk.Line, digits: Int) -> some View {
        let (sign, tint, spoken): (String, Color?, String) = switch line.kind {
        case .add: ("+", .green, "Added \(line.text)")
        case .delete: ("\u{2212}", .red, "Removed \(line.text)")
        case .context: (" ", nil, line.text)
        }
        return HStack(spacing: 6) {
            Text("\(pad(line.oldNumber, digits)) \(pad(line.newNumber, digits))").foregroundStyle(.secondary)
            Text(sign).foregroundStyle(tint ?? .secondary)
            Text(line.text)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint?.opacity(0.15) ?? .clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private static func pad(_ number: Int?, _ digits: Int) -> String {
        let text = number.map(String.init) ?? ""
        return String(repeating: " ", count: max(0, digits - text.count)) + text
    }
}
