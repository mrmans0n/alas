import SwiftUI

struct ChangedRow: View {
    let file: ChangedFile
    let fileContextTarget: FileContextMenuTarget
    var depth: Int = 0
    let onSelect: () -> Void
    var onStage: (() -> Void)? = nil
    var stageState: StageChip.DisplayState? = nil
    var displayAdd: Int? = nil
    var displayDel: Int? = nil
    var onStageEntries: (() -> Void)? = nil
    var onUnstageEntries: (() -> Void)? = nil
    var onOpenFile:       (() -> Void)? = nil
    var onCopyRelative:   (() -> Void)? = nil
    var onCopyFull:       (() -> Void)? = nil
    var onCopyDiff:       (() -> Void)? = nil
    var onViewAtHEAD:     (() -> Void)? = nil
    var onCompareWithHEAD: (() -> Void)? = nil
    var onFileHistory:    (() -> Void)? = nil
    var onDiscard:        (() -> Void)? = nil
    var openFileEnabled:  Bool = true
    var viewAtHEADEnabled: Bool = true
    var ignoreMenu:       AnyView? = nil
    @Environment(\.theme) var theme

    nonisolated static func rowLeadingPadding(depth: Int) -> CGFloat {
        12 + CGFloat(depth * 14)
    }

    var body: some View {
        let basename = file.path.split(separator: "/").last.map(String.init) ?? file.path
        let add = displayAdd ?? file.add
        let del = displayDel ?? file.del
        let resolvedStageState = stageState ?? (file.stage == .staged ? .staged : .unstaged)
        return Button(action: onSelect) {
            HStack(spacing: 6) {
                if let onStage {
                    StageChip(state: resolvedStageState, action: onStage)
                }
                FileTypeIconView(filename: basename, size: 18)
                Text(basename)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if add > 0 { Text("+\(add)").foregroundColor(theme.color("add")) }
                if del > 0 { Text("−\(del)").foregroundColor(theme.color("del")) }
                StatusBadge(status: file.status)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.leading, Self.rowLeadingPadding(depth: depth))
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            FileContextMenuActions(
                configuration: .workingTreeFile(target: fileContextTarget),
                onOpenInAlas: onOpenFile,
                openInAlasEnabled: openFileEnabled,
                onViewAtHEAD: onViewAtHEAD,
                viewAtHEADEnabled: viewAtHEADEnabled,
                onCompareWithHEAD: onCompareWithHEAD,
                onFileHistory: onFileHistory,
                onCopyRelativePath: onCopyRelative,
                onCopyFullPath: onCopyFull
            )
            Divider()
            Button("Copy Diff") { onCopyDiff?() }
            Divider()
            if onStageEntries != nil || onUnstageEntries != nil {
                if let onStageEntries {
                    Button("Stage") { onStageEntries() }
                }
                if let onUnstageEntries {
                    Button("Unstage") { onUnstageEntries() }
                }
            } else if onStage != nil {
                Button(file.stage == .staged ? "Unstage" : "Stage") { onStage?() }
            }
            Button("Discard Changes…", role: .destructive) { onDiscard?() }
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
