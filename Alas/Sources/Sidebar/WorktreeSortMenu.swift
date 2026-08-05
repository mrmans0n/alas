import AppKit
import SwiftUI

enum WorktreeSortPresentation {
    nonisolated static let modes: [AppConfig.WorktreeSortMode] = [
        .lastUpdateDesc,
        .lastUpdateAsc,
        .creationDesc,
        .creationAsc,
        .branchAsc,
        .manual,
    ]

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
    @State private var hovering = false
    @State private var menuTracking = false

    nonisolated static func isVisible(
        headerHovered: Bool,
        menuTracking: Bool
    ) -> Bool {
        headerHovered || menuTracking
    }

    private var visible: Bool {
        Self.isVisible(
            headerHovered: headerHovered,
            menuTracking: menuTracking
        )
    }

    var body: some View {
        Menu {
            ForEach(WorktreeSortPresentation.modes, id: \.self) { mode in
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
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture().onEnded { menuTracking = true })
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuTracking = false
        }
        .animation(.easeOut(duration: 0.12), value: visible)
        .accessibilityHidden(true)
        .background(
            WorktreeSortAccessibilityButton(
                selection: selection,
                onSelect: onSelect,
                onTrackingChanged: { menuTracking = $0 }
            )
        )
        .help("Sort worktrees")
    }
}

private struct WorktreeSortAccessibilityButton: NSViewRepresentable {
    let selection: AppConfig.WorktreeSortMode
    let onSelect: (AppConfig.WorktreeSortMode) -> Void
    let onTrackingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let button = PointerTransparentMenuButton(frame: .zero)
        button.title = ""
        button.isBordered = false
        button.menu = context.coordinator.makeMenu()
        button.setAccessibilityLabel("Sort worktrees")
        button.setAccessibilityHelp("Sort worktrees")
        return button
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.onTrackingChanged = onTrackingChanged
        context.coordinator.updateSelection(selection)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onTrackingChanged: onTrackingChanged)
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var onSelect: (AppConfig.WorktreeSortMode) -> Void
        var onTrackingChanged: (Bool) -> Void
        private weak var menu: NSMenu?

        init(
            onSelect: @escaping (AppConfig.WorktreeSortMode) -> Void,
            onTrackingChanged: @escaping (Bool) -> Void
        ) {
            self.onSelect = onSelect
            self.onTrackingChanged = onTrackingChanged
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            for mode in WorktreeSortPresentation.modes {
                let item = NSMenuItem(
                    title: WorktreeSortPresentation.title(for: mode),
                    action: #selector(select(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = mode.rawValue
                menu.addItem(item)
            }
            self.menu = menu
            return menu
        }

        func updateSelection(_ selection: AppConfig.WorktreeSortMode) {
            menu?.items.forEach { item in
                item.state = item.representedObject as? String == selection.rawValue ? .on : .off
            }
        }

        @objc private func select(_ sender: NSMenuItem) {
            guard let rawValue = sender.representedObject as? String,
                  let mode = AppConfig.WorktreeSortMode(rawValue: rawValue)
            else { return }
            onSelect(mode)
        }

        func menuWillOpen(_ menu: NSMenu) {
            onTrackingChanged(true)
        }

        func menuDidClose(_ menu: NSMenu) {
            onTrackingChanged(false)
        }
    }
}

private final class PointerTransparentMenuButton: NSButton {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityActionNames() -> [NSAccessibility.Action] {
        [.press]
    }

    override func accessibilityPerformPress() -> Bool {
        guard let menu else { return false }
        menu.popUp(positioning: nil, at: .zero, in: self)
        return true
    }
}
