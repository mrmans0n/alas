import SwiftUI

private enum AppTab { case worktrees, inbox, peers, search }

@main
struct AlasMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var hub = HostHub()
    @State private var worktrees = WorktreesModel()
    @State private var selection = AppTab.worktrees

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selection) {
                Tab("Worktrees", systemImage: "folder", value: AppTab.worktrees) {
                    WorktreesView(hub: hub, model: worktrees) { selection = .peers }
                }
                Tab("Inbox", systemImage: "tray", value: AppTab.inbox) {
                    NavigationStack {
                        ContentUnavailableView("Nothing needs you", systemImage: "tray",
                                               description: Text("Permission requests and questions from your agents arrive here in a later build."))
                            .navigationTitle("Inbox")
                    }
                }
                Tab("Peers", systemImage: "laptopcomputer", value: AppTab.peers) {
                    PeersView(hub: hub)
                }
                Tab(value: AppTab.search, role: .search) {
                    WorktreesView(hub: hub, model: worktrees, title: "Search", searchActive: selection == .search) { selection = .peers }
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
