import SwiftUI

struct SidebarPlaceholder: View {
    @Environment(\.theme) var theme
    var body: some View {
        ZStack {
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            VStack(alignment: .leading, spacing: 8) {
                Text("Sidebar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .padding(.horizontal, 12).padding(.top, 12)
                Spacer()
            }
        }
    }
}
