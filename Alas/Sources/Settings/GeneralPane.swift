import SwiftUI

struct GeneralPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("General").font(.system(size: 18, weight: .semibold))
                Text("Application behavior and updates.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Updates") {
                    SettingsRow(
                        name: "Automatically check for updates",
                        desc: "Check GitHub for new releases on launch, at most once a day."
                    ) {
                        AlasToggle(on: state.bind(\.general.autoUpdate))
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }
}
