import SwiftUI

struct Icon: View {
    let name: String
    var size: CGFloat = 12
    var color: Color? = nil
    @Environment(\.theme) var theme

    var body: some View {
        Image(systemName: Self.symbol(for: name))
            .font(.system(size: size))
            .foregroundColor(color ?? theme.color("fg-muted"))
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
        default:           return "questionmark"
        }
    }
}
