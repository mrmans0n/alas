import SwiftUI

struct ReviewChangesTabView: View {
    let worktree: Worktree
    let tabState: ReviewChangesTabState
    let appState: AppState

    @Environment(\.theme) private var theme

    var body: some View {
        Text("Review Changes")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(theme.color("fg"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.color("bg-1"))
    }
}
