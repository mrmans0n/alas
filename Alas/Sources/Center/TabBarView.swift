import SwiftUI

struct TabBarView: View {
    let tabs: [Tab]
    let activeId: TabID?
    let harnessLookup: (TabID) -> (kind: HarnessKind, state: String)?
    let onActivate: (TabID) -> Void
    let onClose: (TabID) -> Void
    let onNewTerminal: () -> Void
    let onNewEditor: () -> Void
    let onNewDiff: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                TabButton(
                    tab: tab,
                    active: tab.id == activeId,
                    showClose: tabs.count > 1,
                    harnessInfo: harnessLookup(tab.id),
                    onActivate: { onActivate(tab.id) },
                    onClose: { onClose(tab.id) }
                )
            }
            Spacer()
            HStack(spacing: 4) {
                Menu {
                    Button("New terminal", action: onNewTerminal)
                    Button("New editor",   action: onNewEditor)
                    Button("New diff",     action: onNewDiff)
                } label: {
                    Icon(name: "plus", size: 13)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26, height: 22)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 34)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }
}

private struct TabButton: View {
    let tab: Tab
    let active: Bool
    let showClose: Bool
    let harnessInfo: (kind: HarnessKind, state: String)?
    let onActivate: () -> Void
    let onClose: () -> Void
    @Environment(\.theme) var theme
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            Icon(name: tab.iconName, size: 11,
                 color: active ? theme.color("accent") : theme.color("fg-faint"))
            Text(tab.title)
                .font(.system(size: 11.5))
                .foregroundColor(active ? theme.color("fg") : theme.color("fg-dim"))
                .lineLimit(1)
            if let info = harnessInfo {
                Circle().fill(stateColor(info.state)).frame(width: 6, height: 6)
                    .opacity(info.state == "running" ? 0.85 : 1)
            }
            if showClose {
                Button(action: onClose) {
                    Icon(name: "x", size: 9,
                         color: hoveringClose ? theme.color("fg") : theme.color("fg-faint"))
                        .frame(width: 14, height: 14)
                        .background(hoveringClose ? theme.color("bg-4") : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .onHover { hoveringClose = $0 }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(active ? theme.color("bg-1") : .clear)
        .overlay(
            Rectangle()
                .fill(active ? theme.color("accent") : .clear)
                .frame(height: 2),
            alignment: .bottom
        )
        .onTapGesture(perform: onActivate)
    }

    private func stateColor(_ s: String) -> Color {
        switch s {
        case "running":  return theme.color("add")
        case "awaiting": return theme.color("mod")
        default:         return theme.color("fg-faint")
        }
    }
}
