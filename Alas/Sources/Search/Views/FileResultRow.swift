import SwiftUI

/// Maps a file extension to a small colored 2-3 letter label, mirroring
/// the design's `.fs-ext` element. Unknown extensions get a neutral label.
private func extLabel(_ ext: String, theme: Theme) -> (Color, String) {
    switch ext {
    case "rs":        return (theme.color("del"),  "RS")
    case "toml":      return (theme.color("info").opacity(0.85), "TOML")
    case "md":        return (theme.color("info"), "MD")
    case "swift":     return (theme.color("warn"), "SWFT")
    case "ts", "tsx": return (theme.color("info"), "TS")
    case "js", "jsx": return (theme.color("mod"),  "JS")
    case "rb":        return (theme.color("del"),  "RB")
    case "":          return (theme.color("fg-faint"), "—")
    default:          return (theme.color("fg-faint"), String(ext.prefix(3)).uppercased())
    }
}

struct FileResultRow: View {
    let result: FileSearchResult
    let isSelected: Bool
    let showsRepoBadge: Bool
    let repoName: String?
    let onTap: () -> Void
    let onHover: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let (color, label) = extLabel(result.ext, theme: theme)
        let parts = splitPath(result.relativePath)

        HStack(spacing: 10) {
            ExtBadge(label: label, color: color)
            Highlighted(
                text: parts.name,
                indices: indicesIn(range: parts.dirLength..<result.relativePath.count)
                    .map { $0 - parts.dirLength }
            )
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundColor(theme.color("fg"))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            Highlighted(
                text: parts.dir,
                indices: indicesIn(range: 0..<parts.dirLength)
            )
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(theme.color("fg-faint"))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsRepoBadge, let repoName {
                Text(repoName)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(theme.color("bg-3"))
                    .foregroundColor(theme.color("fg-faint"))
                    .clipShape(Capsule())
            }
            if let badge = result.statusBadge {
                StatusBadgeView(badge: badge)
            }
            if isSelected {
                SearchKbd(label: "↵")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(
            isSelected
                ? theme.color("accent-soft")
                : Color.clear
        )
        .overlay(
            Rectangle()
                .fill(isSelected ? theme.color("accent") : Color.clear)
                .frame(width: 2)
                .frame(maxHeight: .infinity),
            alignment: .leading
        )
        .contentShape(Rectangle())
        .onHover { hovering in if hovering { onHover() } }
        .onTapGesture { onTap() }
    }

    private func indicesIn(range: Range<Int>) -> [Int] {
        result.matchIndices.filter { range.contains($0) }
    }

    private func splitPath(_ p: String) -> (dir: String, name: String, dirLength: Int) {
        if let slash = p.lastIndex(of: "/") {
            let dir = String(p[..<slash]) + "/"
            let name = String(p[p.index(after: slash)...])
            return (dir, name, dir.count)
        }
        return ("", p, 0)
    }
}

private struct ExtBadge: View {
    let label: String
    let color: Color
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.5)
            .frame(width: 36, height: 16)
            .foregroundColor(color)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(color.opacity(0.33), lineWidth: 0.5)
            )
    }
}

private struct StatusBadgeView: View {
    let badge: GitStatusBadge
    @Environment(\.theme) private var theme
    var body: some View {
        let color: Color = {
            switch badge {
            case .modified: return theme.color("mod")
            case .added:    return theme.color("add")
            case .deleted:  return theme.color("del")
            case .renamed:  return theme.color("info")
            }
        }()
        return Text(badge.rawValue)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4)
            .frame(height: 14)
            .background(color.opacity(0.20))
            .foregroundColor(color)
            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
    }
}
