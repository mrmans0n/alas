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

    @Environment(\.theme) private var theme
    @State private var hovering = false
    /// `Menu` does not expose press state to its label, so it is tracked by a
    /// simultaneous gesture — the same approach the tab bar's menus use.
    @GestureState private var isPressed = false

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
            .toolbarControlSurface(
                isLit: ToolbarMenuControlPresentation.isLit(hovering: hovering, isPressed: isPressed),
                metrics: .sidebarHeader
            )
            .toolbarMenuControlPressFeedback(isPressed: isPressed)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).updating($isPressed) { _, state, _ in state = true }
        )
        .accessibilityHidden(true)
        .background(
            WorktreeSortAccessibilityButton(selection: selection, onSelect: onSelect)
        )
        .help("Sort worktrees")
    }
}

private struct WorktreeSortAccessibilityButton: NSViewRepresentable {
    let selection: AppConfig.WorktreeSortMode
    let onSelect: (AppConfig.WorktreeSortMode) -> Void

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
        context.coordinator.updateSelection(selection)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    final class Coordinator: NSObject {
        var onSelect: (AppConfig.WorktreeSortMode) -> Void
        private weak var menu: NSMenu?

        init(onSelect: @escaping (AppConfig.WorktreeSortMode) -> Void) {
            self.onSelect = onSelect
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
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

extension View {
    /// - Parameter mountsWhileHovered: Mount the AppKit host only while the
    ///   pointer is over the view, or while VoiceOver runs (the host is its
    ///   "Show Menu" element). For long lists: every mounted host is an
    ///   AppKit hit-test target that SwiftUI re-checks on each scroll frame.
    func nativeContextMenu<MenuItems: View>(
        mountsWhileHovered: Bool = false,
        @ViewBuilder menuItems: () -> MenuItems
    ) -> some View {
        modifier(NativeContextMenuModifier(mountsWhileHovered: mountsWhileHovered, menuItems: menuItems()))
    }
}

private struct NativeContextMenuModifier<MenuItems: View>: ViewModifier {
    let mountsWhileHovered: Bool
    let menuItems: MenuItems
    @State private var hovering = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    func body(content: Content) -> some View {
        if mountsWhileHovered {
            content
                .onHover { hovering = $0 }
                .overlay { if hovering || voiceOverEnabled { host } }
        } else {
            content.overlay { host }
        }
    }

    private var host: some View {
        NativeContextMenuHost(menuItems: menuItems)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NativeContextMenuHost<MenuItems: View>: NSViewRepresentable {
    let menuItems: MenuItems

    func makeNSView(context: Context) -> NativeContextMenuView<MenuItems> {
        NativeContextMenuView(menuItems: menuItems)
    }

    func updateNSView(_ nsView: NativeContextMenuView<MenuItems>, context: Context) {
        nsView.update(menuItems: menuItems)
    }
}

private final class NativeContextMenuView<MenuItems: View>: NSView {
    private var menuItems: MenuItems

    init(menuItems: MenuItems) {
        self.menuItems = menuItems
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuButton)
        setAccessibilityLabel("Context menu")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(menuItems: MenuItems) {
        self.menuItems = menuItems
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), let event = NSApp.currentEvent else { return nil }
        guard event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        else { return nil }
        return self
    }

    override func accessibilityActionNames() -> [NSAccessibility.Action] {
        [.showMenu]
    }

    override func accessibilityPerformShowMenu() -> Bool {
        let menu = makeMenu()
        menu.popUp(positioning: nil, at: .zero, in: self)
        return true
    }

    private func makeMenu() -> NSMenu {
        NSHostingMenu(rootView: Group { menuItems })
    }
}
