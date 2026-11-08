import SwiftUI

struct LoadingProjectView: View {
    var body: some View {
        ForestLoadingView(message: "Loading repository…")
    }
}

/// The flock circles like a spinner above the message.
struct ForestLoadingView: View {
    @Environment(\.designScale) private var scale
    let message: String

    var body: some View {
        ForestScene(mode: .loading) {
            Text(message)
                .font(scale.emphasisFont)
                .shadow(color: .black.opacity(0.25), radius: 6)
                .offset(y: 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
