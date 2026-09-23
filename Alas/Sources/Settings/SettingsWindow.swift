import SwiftUI

struct SettingsWindow: View {
    @Bindable var state: AppState
    @State private var section: SettingsSection = .agents
    @State private var showsDebug = AdvancedSettingsVisibility.isEnabled()

    var body: some View {
        let theme = state.themeStore.current

        VStack(spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [theme.color("bg-3"), theme.color("bg-2")],
                    startPoint: .top, endPoint: .bottom
                )
                HStack {
                    TrafficLights()
                    Spacer()
                }
                .padding(.leading, 16)
                Text("Settings")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
            }
            .frame(height: 44)
            .overlay(Divider().opacity(0.5), alignment: .bottom)

            HStack(spacing: 0) {
                SettingsNavView(selection: $section, showsDebug: showsDebug)
                Group {
                    switch section {
                    case .general:    GeneralPane(state: state)
                    case .remote:     RemoteServerPane(state: state)
                    case .debug:      AdvancedPane(state: state)
                    case .agents:     AgentsPane(state: state) { section = $0 }
                    case .appearance: AppearancePane(state: state)
                    case .changes:    ChangesPane(state: state)
                    case .chat:       ChatPane(state: state)
                    case .code:       CodePane(state: state)
                    case .shortcuts:  ShortcutsPane(state: state)
                    case .spaces:     SpacesPane(state: state)
                    case .terminal:   TerminalPane(state: state)
                    case .worktrees:  WorktreesPane(state: state)
                    }
                }
                .frame(width: 680)
                .frame(maxHeight: .infinity)
                .background(theme.color("bg-1"))
                .clipped()
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                Spacer()
                AlasButton(title: "Cancel", style: .subtle, action: closeWindow)
                AlasButton(title: "Done", style: .primary, action: closeWindow)
            }
            .padding(.horizontal, 32).padding(.vertical, 12)
            .background(theme.color("bg-2"))
            .overlay(Divider().opacity(0.5), alignment: .top)
        }
        .frame(width: 880)
        .frame(maxHeight: .infinity)
        .background(theme.color("bg-1"))
        .background(WindowConfigurator())
        .background(SettingsPairingCloseObserver { state.cancelNearbyApproval() })
        .overlay(alignment: .bottomTrailing) {
            RemotePairingApprovalStack(coordinator: state.remotePairingApprovals)
                .frame(maxWidth: 380)
                .padding(16)
        }
        .environment(\.theme, theme)
        .ignoresSafeArea()
        .onAppear {
            showsDebug = AdvancedSettingsVisibility.isEnabled()
            consumePendingSettingsSection()
            if !showsDebug, section == .debug {
                section = .agents
            }
            state.rescanAgents()
        }
        .onChange(of: state.pendingSettingsSection) {
            consumePendingSettingsSection()
        }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }

    private func consumePendingSettingsSection() {
        guard let pending = state.pendingSettingsSection else { return }
        section = pending
        state.pendingSettingsSection = nil
    }
}

/// A Settings scene can keep its view alive after its window closes.
private struct SettingsPairingCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> SettingsPairingCloseView {
        let view = SettingsPairingCloseView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: SettingsPairingCloseView, context: Context) {
        view.onClose = onClose
    }
}

private final class SettingsPairingCloseView: NSView {
    var onClose: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification, object: window)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) { onClose?() }
}
