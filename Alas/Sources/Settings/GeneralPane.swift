import SwiftUI

struct GeneralPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("General").font(.system(size: 18, weight: .semibold))
                Text("App-wide behavior, launch options, and updates.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Launch") {
                    SettingsRow(name: "Launch at login",
                                desc: "Open Alas automatically when you log into macOS.") {
                        AlasToggle(on: bind(\.general.launchAtLogin))
                    }
                    SettingsRow(name: "Close button",
                                desc: "What happens when you click the red traffic-light?") {
                        Seg(value: bind(\.general.closeToTray), options: [
                            (true, "Hide to menu bar"),
                            (false, "Quit"),
                        ])
                    }
                    SettingsRow(name: "Confirm before quitting",
                                desc: "Ask before quitting when terminals are running.") {
                        AlasToggle(on: bind(\.general.confirmQuit))
                    }
                }
                SettingsGroup(title: "Updates") {
                    SettingsRow(name: "Automatic updates",
                                desc: "Check for updates on launch and in the background.") {
                        AlasToggle(on: bind(\.general.autoUpdate))
                    }
                    SettingsRow(name: "Channel", desc: "Stable releases or early access.") {
                        Seg(value: bind(\.general.updateChannel), options: [
                            ("Stable", "Stable"), ("Beta", "Beta"), ("Nightly", "Nightly")
                        ])
                    }
                }
                SettingsGroup(title: "Telemetry") {
                    SettingsRow(name: "Crash reports",
                                desc: "Send anonymized crash reports to help fix bugs.") {
                        AlasToggle(on: bind(\.general.crashReports))
                    }
                    SettingsRow(name: "Usage analytics",
                                desc: "Share aggregated, anonymous usage statistics.") {
                        AlasToggle(on: bind(\.general.usageAnalytics))
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }

    private func bind<T>(_ kp: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { state.config[keyPath: kp] },
            set: { state.config[keyPath: kp] = $0; state.saveConfig() }
        )
    }
}
