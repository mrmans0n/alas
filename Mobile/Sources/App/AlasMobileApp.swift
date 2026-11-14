import SwiftUI

@main
struct AlasMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var hub = HostHub()
    @State private var searchText = ""

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Worktrees", systemImage: "folder") {
                    NavigationStack {
                        ContentUnavailableView("Worktrees", systemImage: "folder",
                                               description: Text("Sessions from your Macs will show here."))
                            .navigationTitle("Worktrees")
                    }
                }
                Tab("Inbox", systemImage: "tray") {
                    NavigationStack {
                        ContentUnavailableView("Nothing needs you", systemImage: "tray",
                                               description: Text("Permission requests and questions from your agents arrive here in a later build."))
                            .navigationTitle("Inbox")
                    }
                }
                Tab("Peers", systemImage: "laptopcomputer") {
                    PeersView(hub: hub)
                }
                Tab(role: .search) {
                    NavigationStack {
                        ContentUnavailableView.search(text: searchText)
                            .navigationTitle("Search")
                    }
                    .searchable(text: $searchText)
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active: hub.connectAll()
                case .background: hub.disconnectAll()
                default: break
                }
            }
        }
    }
}
