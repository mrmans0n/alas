import SwiftUI

struct ChangedRow: View {
    let file: ChangedFile
    var depth: Int = 0
    let onSelect: () -> Void
    var onStage: (() -> Void)? = nil
    var onOpenFile:       (() -> Void)? = nil
    var onCopyRelative:   (() -> Void)? = nil
    var onCopyFull:       (() -> Void)? = nil
    var onRevealInFinder: (() -> Void)? = nil
    var onCopyDiff:       (() -> Void)? = nil
    var onDiscard:        (() -> Void)? = nil
    var openFileEnabled:  Bool = true
    var ignoreMenu:       AnyView? = nil
    @Environment(\.theme) var theme

    var body: some View {
        let basename = file.path.split(separator: "/").last.map(String.init) ?? file.path
        return Button(action: onSelect) {
            HStack(spacing: 6) {
                if let onStage {
                    StageChip(staged: file.stage == .staged, action: onStage)
                }
                FileTypeIconView(filename: basename, size: 18)
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
            .padding(.leading, CGFloat(12 + (depth == 0 ? 0 : depth * 14 + 14)))
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open File") { onOpenFile?() }
                .disabled(!openFileEnabled || onOpenFile == nil)
            Button("Copy Relative Path") { onCopyRelative?() }
            Button("Copy Full Path") { onCopyFull?() }
            Button("Reveal in Finder") { onRevealInFinder?() }
            Divider()
            Button("Copy Diff") { onCopyDiff?() }
            Divider()
            if onStage != nil {
                Button(file.stage == .staged ? "Unstage" : "Stage") { onStage?() }
            }
            Button("Discard Changes...") { onDiscard?() }
            if let ignoreMenu {
                Divider()
                ignoreMenu
            }
        }
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
        case "U": return theme.color("warn").opacity(0.20)
        default:  return theme.color("mod").opacity(0.20)
        }
    }
    private var badgeFg: Color {
        switch status {
        case "A": return theme.color("add")
        case "D": return theme.color("del")
        case "R": return theme.color("info")
        case "U": return theme.color("warn")
        default:  return theme.color("mod")
        }
    }
}
