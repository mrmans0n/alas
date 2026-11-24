import AlasRemoteKit
import SwiftUI

/// A paired Mac's chosen icon. Decorative: the Mac's name always sits beside it.
struct PeerIconView: View {
    let icon: PeerIcon

    var body: some View {
        Image(systemName: icon.symbolName)
            .accessibilityHidden(true)
    }
}
