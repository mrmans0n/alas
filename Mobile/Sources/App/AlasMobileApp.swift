import SwiftUI

@main
struct AlasMobileApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    NavigationLink("Transcript spike") { SpikeCountView() }
                }
                .navigationTitle("Alas")
            }
        }
    }
}

/// Placeholder destination until the real spike screen replaces it.
private struct SpikeCountView: View {
    @State private var model = SpikeTranscriptModel(totalCount: 5000)

    var body: some View {
        Text("Decoded 5000 rows, window \(model.rows.count)")
            .navigationTitle("Transcript spike")
    }
}
