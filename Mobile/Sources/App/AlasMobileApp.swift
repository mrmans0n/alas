import SwiftUI

@main
struct AlasMobileApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    NavigationLink("Transcript spike") { SpikeScreen() }
                }
                .navigationTitle("Alas")
            }
        }
    }
}
