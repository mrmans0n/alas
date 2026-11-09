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
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(group.hits.enumerated()), id: \.element.id) { offset, hit in
                let absIndex = baseIndex + offset
                hitRow(hit: hit, absIndex: absIndex, isSelected: absIndex == selectedIndex)
                    // Keep identity and keyboard scroll targets tied to the hit.
                    .id(hit.id)
            }
        }
        .padding(.vertical, scale.space[2])
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
                .font(scale.emphasisFont)
                .foregroundColor(theme.color("fg"))
            Text(parts.dir)
                .font(scale.meta.font(weight: .regular, design: .monospaced))
                .foregroundColor(theme.color("fg-faint"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text("\(group.hits.count)")
                .font(scale.caption.font(weight: .semibold))
                .padding(.horizontal, scale.space[2])
                .padding(.vertical, scale.space[0])
                .background(theme.color("bg-3"))
                .foregroundColor(theme.color("fg-dim"))
                .clipShape(Capsule())
        }
        .padding(.horizontal, scale.space[4])
        .padding(.vertical, scale.space[1])
    }

    private func hitRow(hit: ContentSearchHit, absIndex: Int, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: Self.lineNumberLabel(for: hit.line))
                .font(scale.caption.font(weight: .regular, design: .monospaced).monospacedDigit())
                .foregroundColor(theme.color("fg-faint"))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 32, alignment: .trailing)
            snippet(for: hit)
                .font(scale.meta.font(weight: .regular, design: .monospaced))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 56) // design-literal: indent that clears the file header's left edge
        .padding(.trailing, scale.space[4])
        .padding(.vertical, scale.space[1])
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
