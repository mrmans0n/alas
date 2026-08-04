import AppKit
import SwiftUI

enum WorktreeSortPresentation {
    nonisolated static func title(for mode: AppConfig.WorktreeSortMode) -> String {
        switch mode {
        case .lastUpdateDesc: "Last update time (most recent first)"
        case .lastUpdateAsc: "Last update time (least recent first)"
        case .creationDesc: "Creation time (newest first)"
        case .creationAsc: "Creation time (oldest first)"
        case .branchAsc: "Branch name"
        case .manual: "Manual"
        }
    }
}

struct WorktreeSortMenu: View {
    let selection: AppConfig.WorktreeSortMode
    let onSelect: (AppConfig.WorktreeSortMode) -> Void
    let headerHovered: Bool

    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var menuTracking = false

    nonisolated static func isVisible(
        headerHovered: Bool,
        focused: Bool,
        menuTracking: Bool
    ) -> Bool {
        headerHovered || focused || menuTracking
    }

    private var visible: Bool {
        Self.isVisible(
            headerHovered: headerHovered,
            focused: focused,
            menuTracking: menuTracking
        )
    }

    var body: some View {
        Menu {
            ForEach(AppConfig.WorktreeSortMode.allCases, id: \.self) { mode in
                Toggle(
                    WorktreeSortPresentation.title(for: mode),
                    isOn: Binding(
                        get: { selection == mode },
                        set: { selected in
                            if selected { onSelect(mode) }
                        }
                    )
                )
            }
        } label: {
            Icon(
                name: "arrow.up.arrow.down",
                size: 13,
                color: hovering ? theme.color("fg") : theme.color("fg-muted")
            )
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
            .background(hovering ? theme.color("bg-3") : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("Sort worktrees")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .focusable()
        .focused($focused)
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture().onEnded { menuTracking = true })
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuTracking = false
        }
        .animation(.easeOut(duration: 0.12), value: visible)
        .background(WorktreeSortAccessibilityAnchor())
        .accessibilityLabel("Sort worktrees")
        .help("Sort worktrees")
    }
}

private struct WorktreeSortAccessibilityAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Sort worktrees")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
