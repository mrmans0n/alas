import SwiftUI

struct Icon: View {
    let name: String
    var size: CGFloat = 12
    var color: Color? = nil
    @Environment(\.theme) var theme

    @ViewBuilder
    var body: some View {
        let resolved: Color = color ?? theme.color("fg-muted")
        if name == "commit" {
            CommitGlyph()
                .stroke(style: StrokeStyle(
                    lineWidth: max(1, size * (1.6 / 16.0)),
                    lineCap: .round,
                    lineJoin: .round
                ))
                .foregroundColor(resolved)
                .frame(width: size, height: size)
        } else {
            Image(systemName: Self.symbol(for: name))
                .font(.system(size: size))
                .foregroundColor(resolved)
        }
    }

    static func symbol(for name: String) -> String {
        switch name {
        case "branch":     return "arrow.triangle.branch"
        case "terminal":   return "terminal"
        case "code":       return "chevron.left.forwardslash.chevron.right"
        case "diff":       return "plus.forwardslash.minus"
        case "image":      return "photo"
        case "gear":       return "gearshape"
        case "search":     return "magnifyingglass"
        case "plus":       return "plus"
        case "x":          return "xmark"
        case "check":      return "checkmark"
        case "chev-down":  return "chevron.down"
        case "chev-right": return "chevron.right"
        case "folder":     return "folder"
        case "folder-plus": return "folder.badge.plus"
        case "file":       return "doc"
        case "menu":       return "ellipsis"
        case "split":      return "rectangle.split.2x1"
        case "split-down": return "rectangle.split.1x2"
        case "palette":    return "paintpalette"
        case "keyboard":   return "keyboard"
        case "github":     return "circle.hexagongrid"
        case "alert":      return "exclamationmark.triangle"
        case "sparkle":    return "sparkle"
        default:           return name
        }
    }
}

/// Git commit glyph: a stroked circle with two short vertical stems above
/// and below — matches the design's 16x16 viewbox spec.
struct CommitGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let s = min(rect.width, rect.height)
        let unit = s / 16.0
        let cx = rect.midX
        let cy = rect.midY
        let r = 2.5 * unit
        p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        // Top stem: y = 1.5 → 4.5 (in 16-unit coords)
        p.move(to: CGPoint(x: cx, y: rect.minY + 1.5 * unit))
        p.addLine(to: CGPoint(x: cx, y: rect.minY + 4.5 * unit))
        // Bottom stem: y = 11.5 → 14.5
        p.move(to: CGPoint(x: cx, y: rect.minY + 11.5 * unit))
        p.addLine(to: CGPoint(x: cx, y: rect.minY + 14.5 * unit))
        return p
    }
}
