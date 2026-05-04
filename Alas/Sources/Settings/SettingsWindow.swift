import SwiftUI

struct SettingsWindow: View {
    @Bindable var state: AppState
    @State private var section: SettingsSection = .general
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [theme.color("bg-3"), theme.color("bg-2")],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 38)
                Text("Settings")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
            }
            .overlay(Divider().opacity(0.5), alignment: .bottom)

            HStack(spacing: 0) {
                SettingsNavView(selection: $section)
                Group {
                    switch section {
                    case .general:    GeneralPane(state: state)
                    case .worktrees:  WorktreesPane(state: state)
                    case .terminal:   TerminalPane(state: state)
                    case .appearance: AppearancePane(state: state)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 8) {
                Spacer()
                AlasButton(title: "Cancel", style: .subtle, action: closeWindow)
                AlasButton(title: "Done", style: .primary, action: closeWindow)
            }
            .padding(.horizontal, 32).padding(.vertical, 12)
            .background(theme.color("bg-2"))
            .overlay(Divider().opacity(0.5), alignment: .top)
        }
        .frame(width: 880, height: 580)
        .environment(\.theme, state.themeStore.current)
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}
