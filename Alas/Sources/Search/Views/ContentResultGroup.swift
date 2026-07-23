import SwiftUI

/// One file's worth of content-search hits, rendered as a header + list of
/// snippet rows. Phase 2 ships the layout; Phase 3 makes hits real.
struct ContentResultGroupView: View {
    let group: ContentSearchGroup
    let baseIndex: Int
    let selectedIndex: Int
    let onTap: (ContentSearchHit) -> Void
    let onHover: (Int) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(group.hits.enumerated()), id: \.element.id) { offset, hit in
                let absIndex = baseIndex + offset
                hitRow(hit: hit, absIndex: absIndex, isSelected: absIndex == selectedIndex)
                    // Identity/scroll anchor is the hit id, not the row
                    // position: a stable position id (`.id(absIndex)`) froze
                    // rows against data changes (see FileSearchDialog for the
                    // LazyVStack caching rationale), while a data-based id
                    // changes with the hit and still lets the dialog's
                    // `scrollTo(selected hit id)` reach it during keyboard nav.
                    .id(hit.id)
            }
        }
        .padding(.vertical, 6)
        .overlay(
            Rectangle()
                .fill(theme.color("line-soft"))
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private var header: some View {
        let parts = splitPath(group.relativePath)
        return HStack(spacing: 10) {
            Text(parts.name)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundColor(theme.color("fg"))
            Text(parts.dir)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.color("fg-faint"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text("\(group.hits.count)")
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(theme.color("bg-3"))
                .foregroundColor(theme.color("fg-dim"))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func hitRow(hit: ContentSearchHit, absIndex: Int, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: Self.lineNumberLabel(for: hit.line))
                .font(.system(size: 10.5, design: .monospaced).monospacedDigit())
                .foregroundColor(theme.color("fg-faint"))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 32, alignment: .trailing)
            snippet(for: hit)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 56)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .background(
            isSelected ? theme.color("accent-soft") : Color.clear
        )
        .overlay(
            Rectangle()
                .fill(isSelected ? theme.color("accent") : Color.clear)
                .frame(width: 2),
            alignment: .leading
        )
        .contentShape(Rectangle())
        .onHover { if $0 { onHover(absIndex) } }
        .onTapGesture { onTap(hit) }
    }

    static func lineNumberLabel(for line: Int) -> String {
        String(line)
    }

    @ViewBuilder
    private func snippet(for hit: ContentSearchHit) -> some View {
        if let range = hit.matchCharRange,
           range.lowerBound >= 0,
           range.upperBound <= hit.snippet.count {
            let s = hit.snippet
            let start = s.index(s.startIndex, offsetBy: range.lowerBound)
            let end   = s.index(s.startIndex, offsetBy: range.upperBound)
            Text(String(s[..<start])) +
                Text(String(s[start..<end])).foregroundColor(theme.color("mod")).bold() +
                Text(String(s[end...]))
        } else {
            Text(hit.snippet)
        }
    }

    private func splitPath(_ p: String) -> (dir: String, name: String) {
        if let slash = p.lastIndex(of: "/") {
            return (String(p[..<slash]) + "/", String(p[p.index(after: slash)...]))
        }
        return ("", p)
    }
}
