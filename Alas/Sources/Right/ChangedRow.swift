import SwiftUI

struct ChangedRow: View {
    let file: ChangedFile
    let onSelect: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        let basename = file.path.split(separator: "/").last.map(String.init) ?? file.path
        return Button(action: onSelect) {
            HStack(spacing: 6) {
                FileTypeIconView(filename: basename, size: 13)
                Text(basename)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if file.add > 0 { Text("+\(file.add)").foregroundColor(theme.color("add")) }
                if file.del > 0 { Text("−\(file.del)").foregroundColor(theme.color("del")) }
                StatusBadge(status: file.status)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StatusBadge: View {
    let status: String
    @Environment(\.theme) var theme
    var body: some View {
        Text(status)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 4)
            .background(badgeBg)
            .foregroundColor(badgeFg)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    private var badgeBg: Color {
        switch status {
        case "A": return theme.color("add").opacity(0.18)
        case "D": return theme.color("del").opacity(0.18)
        case "R": return theme.color("info").opacity(0.18)
        default:  return theme.color("mod").opacity(0.20)
        }
    }
    private var badgeFg: Color {
        switch status {
        case "A": return theme.color("add")
        case "D": return theme.color("del")
        case "R": return theme.color("info")
        default:  return theme.color("mod")
        }
    }
}
