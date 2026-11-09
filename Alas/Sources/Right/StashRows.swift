import SwiftUI

struct StashSummaryRow: View {
    let stash: GitStash
    let open: Bool
    let loading: Bool
    let onToggle: () -> Void
    let onApply: () -> Void
    let onPop: () -> Void
    let onDrop: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Icon(name: open ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
                    .frame(width: 14, height: 14)
                Text(stash.subject.isEmpty ? stash.ref : stash.subject)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(stash.ref)
                    .font(scale.caption.font(weight: .regular, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                Spacer()
                if loading { Spinner(lineWidth: 1.2, duration: 0.7).frame(width: 10, height: 10) }
                Menu {
                    Button("Apply", action: onApply)
                    Button("Pop", action: onPop)
                    Divider()
                    Button("Drop…", role: .destructive, action: onDrop)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(scale.meta.font(weight: .semibold))
                        .foregroundColor(theme.color("fg-muted"))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Stash actions")
            }
            .padding(.horizontal, scale.space[3])
            .padding(.vertical, scale.space[1])
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Apply", action: onApply)
            Button("Pop", action: onPop)
            Divider()
            Button("Drop…", role: .destructive, action: onDrop)
        }
    }
}

struct StashFileRow: View {
    let file: GitStashFile
    let onSelect: () -> Void
    let dragPayload: () -> DragOutPayload?

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                FileTypeIconView(filename: (file.path as NSString).lastPathComponent, size: 16)
                Text((file.path as NSString).lastPathComponent)
                    .font(scale.metaFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if file.add > 0 { Text("+\(file.add)").foregroundColor(theme.color("add")) }
                if file.del > 0 { Text("-\(file.del)").foregroundColor(theme.color("del")) }
                StatusBadge(status: file.status)
            }
            .font(scale.meta.font(weight: .regular, design: .monospaced))
            .padding(.leading, scale.space[5] + scale.space[2])
            .padding(.trailing, scale.space[3])
            .padding(.vertical, scale.space[1])
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dragOut(dragPayload)
    }
}

struct StashEmptyRow: View {
    let loading: Bool
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            if loading { Spinner(lineWidth: 1.2, duration: 0.7).frame(width: 10, height: 10) }
            Text(loading ? "Loading stash files…" : "no files")
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-faint"))
        }
        .padding(.leading, scale.space[5] + scale.space[2])
        .padding(.vertical, scale.space[2])
    }
}
