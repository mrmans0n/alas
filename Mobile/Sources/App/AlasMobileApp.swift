import SwiftUI

private enum AppTab { case worktrees, inbox, peers, search }

@main
struct AlasMobileApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var hub: HostHub
    @State private var registry: SessionRegistry
    @State private var worktrees = WorktreesModel()
    @State private var selection = AppTab.worktrees
    @State private var openRoute: SessionRoute?
    private let registrar: PushRegistrar

    init() {
        let hub = HostHub()
        _hub = State(initialValue: hub)
        let registry = SessionRegistry(hub: hub)
        _registry = State(initialValue: registry)
        AppDelegate.registry = registry
        let registrar = PushRegistrar(hub: hub)
        hub.registrar = registrar
        self.registrar = registrar
        AppDelegate.hub = hub
        AppDelegate.registrar = registrar
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selection) {
                Tab("Worktrees", systemImage: "folder", value: AppTab.worktrees) {
                    WorktreesView(hub: hub, model: worktrees) { selection = .peers }
                }
                Tab("Inbox", systemImage: "tray", value: AppTab.inbox) {
                    InboxView(hub: hub, openRoute: $openRoute)
                }
                .badge(InboxModel.entries(in: hub).count)
                Tab("Peers", systemImage: "laptopcomputer", value: AppTab.peers) {
                    PeersView(hub: hub)
                }
                Tab(value: AppTab.search, role: .search) {
                    WorktreesView(hub: hub, model: worktrees, title: "Search", searchActive: selection == .search) { selection = .peers }
                }
            }
            .environment(registry)
            .onAppear {
                AppDelegate.open = { route in
                    selection = .inbox
                    openRoute = route
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    hub.connectAll()
                    registrar.start()
                case .background: hub.disconnectAll()
                default: break
                }
            }
        }
    }
}
