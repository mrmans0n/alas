import SwiftUI

private enum AppTab { case worktrees, inbox, peers, search }

@main
struct AlasMobileApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgrounded = false
    @State private var hub: HostHub
    @State private var registry: SessionRegistry
    @State private var worktrees = WorktreesModel()
    @State private var attention: AttentionFeed
    @State private var selection = AppTab.worktrees
    @State private var openRoute: SessionRoute?
    private let registrar: PushRegistrar

    init() {
        GrammarPack.install()
        let hub = HostHub()
        _hub = State(initialValue: hub)
        let registry = SessionRegistry(hub: hub)
        _registry = State(initialValue: registry)
        _attention = State(initialValue: AttentionFeed(hub: hub))
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
                    InboxView(hub: hub, attention: attention, openRoute: $openRoute)
                }
                .badge(InboxModel.entries(in: hub).count + attention.entries.count)
                Tab("Peers", systemImage: "laptopcomputer", value: AppTab.peers) {
                    PeersView(hub: hub)
                }
                Tab(value: AppTab.search, role: .search) {
                    WorktreesView(hub: hub, model: worktrees, title: "Search", searchActive: selection == .search) { selection = .peers }
                }
            }
            // A sidebar on the iPad, the tab bar on the iPhone.
            .tabViewStyle(.sidebarAdaptable)
            .environment(registry)
            // A Mac sends no word when its inbox changes; ask whenever a host comes online, and
            // every 30 s while the app is open. ponytail: polling; a pushed list if it ever lags.
            .onChange(of: hub.hosts.map { hub.onlineCount(of: $0.id) }) { attention.refresh() }
            .task {
                while !Task.isCancelled {
                    attention.refresh()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .onAppear {
                AppDelegate.open = { route in
                    selection = .inbox
                    openRoute = route
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    // Links opened in the background, to answer from an alert, died when iOS suspended
                    // the app but still look connecting: dial afresh, or they stay offline.
                    if backgrounded { hub.disconnectAll() }
                    backgrounded = false
                    hub.connectAll()
                    registrar.start()
                case .background:
                    backgrounded = true
                    hub.disconnectAll()
                default: break
                }
            }
        }
    }
}
