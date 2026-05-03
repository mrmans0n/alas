import SwiftUI

struct CenterPlaceholder: View {
    @Environment(\.theme) var theme
    var body: some View {
        ZStack {
            theme.color("bg-1").ignoresSafeArea()
            Text("Center")
                .foregroundColor(theme.color("fg-dim"))
        }
    }
}
