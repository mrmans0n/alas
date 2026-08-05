import SwiftUI

struct LoadingProjectView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Spinner()
                .frame(width: 32, height: 32)
            Text("Loading repository…")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
    }
}
