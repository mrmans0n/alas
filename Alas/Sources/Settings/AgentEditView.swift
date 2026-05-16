import SwiftUI

struct AgentEditView: View {
    @Bindable var state: AppState
    let target: AgentsPane.EditTarget
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Agent editor goes here.")
            AlasButton(title: "Close", style: .primary, action: onDismiss)
        }
        .padding(32)
        .frame(width: 480)
    }
}
