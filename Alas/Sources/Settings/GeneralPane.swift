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

                // Launch-at-login, close/quit behavior, automatic updates,
                // and telemetry toggles will land alongside their backing
                // implementations. They were previously rendered as decorative
                // controls; codex flagged them (correctly) as misleading
                // because nothing in the app consumed the persisted values.
                // The pane is intentionally sparse until those features ship.
                VStack(alignment: .leading, spacing: 6) {
                    Text("No settings here yet.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.color("fg-muted"))
                    Text("Launch, updates, and telemetry controls will appear once the app actually honors them.")
                        .font(.system(size: 12))
                        .foregroundColor(theme.color("fg-dim"))
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }
}
