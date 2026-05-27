import SwiftUI

struct ACPAutoRunToggle: View {
    @ObservedObject var session: ACPSession
    let manager: ACPSessionManager

    var body: some View {
        Toggle(isOn: Binding(
            get: { session.autoRunEnabled },
            set: { session.autoRunEnabled = $0; manager.persist(session) }
        )) {
            Text("Auto-run").font(.system(size: 11))
        }
        .toggleStyle(.checkbox)
    }
}
