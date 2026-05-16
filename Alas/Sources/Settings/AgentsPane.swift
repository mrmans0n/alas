import SwiftUI

struct AgentsPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Agents").font(.system(size: 18, weight: .semibold))
                Text("CLI agents Alas can detect, launch on worktree create, and use for AI commit messages.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)
                // Fleshed out in subsequent tasks.
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }
}
