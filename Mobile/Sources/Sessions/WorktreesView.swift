import AlasRemoteKit
import SwiftUI

/// Query and filter shared by the Worktrees and Search tabs.
@MainActor @Observable
final class WorktreesModel {
    var query = ""
    var filter = RemoteSessionFilter.all
}

/// Where a tapped session lives: enough to resolve it from the hub later.
struct SessionRoute: Hashable {
    let hostID: UUID
    let sessionId: String
}

/// Every paired Mac's sessions, grouped by repo and worktree.
struct WorktreesView: View {
    let hub: HostHub
    @Bindable var model: WorktreesModel
    var title = "Worktrees"
    /// True while the Search tab is selected: the field is presented, and dismissed when it leaves.
    var searchActive = false
    var onPairMac: () -> Void = {}

    @State private var path: [SessionRoute] = []
    /// The session in the detail column, where there is room for one (iPad).
    @State private var selected: SessionRoute?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var searchPresented: Bool
    @State private var newSessionPresented = false

    init(hub: HostHub, model: WorktreesModel, title: String = "Worktrees", searchActive: Bool = false,
         onPairMac: @escaping () -> Void = {}) {
        self.hub = hub
        self.model = model
        self.title = title
        self.searchActive = searchActive
        self.onPairMac = onPairMac
        // Only the first appearance presents the field; popping back must not.
        _searchPresented = State(initialValue: searchActive)
    }

    private var filter: RemoteSessionFilter { model.filter }
    /// Only the Search tab searches; Worktrees always lists everything, under its filter.
    private var isSearch: Bool { title == "Search" }
    private var query: String { isSearch ? model.query : "" }

    private struct HostSection: Identifiable {
        let host: PairedHost
        let section: RemoteRepoSection
        var id: String { "\(host.id)|\(section.id)" }
    }

    private var allSections: [HostSection] {
        hub.hosts.flatMap { host in
            RemoteSessionDirectory.sections(hub.sessions(of: host.id), localHostName: host.name)
                .map { HostSection(host: host, section: $0) }
        }
    }

    var body: some View {
        let all = allSections
        let counts = RemoteSessionDirectory.counts(all.map(\.section))
        let visible = all.filter {
            !RemoteSessionDirectory.filter([$0.section], by: filter, query: query).isEmpty
        }
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    directory(all: all, counts: counts, visible: visible)
                } detail: {
                    // Its own stack, for the diffs and files a session pushes.
                    NavigationStack {
                        if let selected {
                            TranscriptScreen(hostID: selected.hostID, sessionId: selected.sessionId).id(selected)
                        } else {
                            ContentUnavailableView("No session selected", systemImage: "bubble.left.and.bubble.right",
                                                   description: Text("Choose a session from the list."))
                        }
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    directory(all: all, counts: counts, visible: visible)
                        .navigationDestination(for: SessionRoute.self) { route in
                            TranscriptScreen(hostID: route.hostID, sessionId: route.sessionId)
                        }
                }
            }
        }
        // Split View resizes swap the hierarchy; the open session moves with it.
        .onChange(of: sizeClass) { _, size in
            if size == .regular {
                if let open = path.last { selected = open }
                path = []
            } else if let open = selected {
                path = [open]
                selected = nil
            }
        }
    }

    private func open(_ route: SessionRoute) {
        if sizeClass == .regular {
            selected = route
        } else if path.last != route {
            // A double tap must not push the same transcript twice.
            path.append(route)
        }
    }

    @ViewBuilder
    private func directory(all: [HostSection], counts: [RemoteSessionFilter: Int], visible: [HostSection]) -> some View {
            Group {
                if hub.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Macs paired", systemImage: "laptopcomputer")
                    } description: {
                        Text("Pair a Mac to see its worktrees and sessions here.")
                    } actions: {
                        Button("Pair a Mac", action: onPairMac).buttonStyle(.borderedProminent)
                    }
                } else if all.isEmpty {
                    ContentUnavailableView("No sessions", systemImage: "folder",
                                           description: Text("Open sessions on your Macs will show here."))
                } else if visible.isEmpty {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView(filter == .running ? "No running worktrees" : "No worktrees with changes",
                                               systemImage: filter == .running ? "bolt.slash" : "checkmark.circle")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    list(visible)
                }
            }
            .navigationTitle(title)
            .modifier(SearchField(enabled: isSearch, text: $model.query, presented: $searchPresented))
            .toolbar {
                if !hub.hosts.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New session", systemImage: "plus") { newSessionPresented = true }
                    }
                }
            }
            .sheet(isPresented: $newSessionPresented) {
                NewSessionSheet(hub: hub) { route in
                    newSessionPresented = false
                    open(route)
                }
            }
            .onChange(of: searchActive) { _, active in searchPresented = active }
            // A forgotten Mac's transcripts pop instead of reading as ended.
            .onChange(of: hub.hosts.map(\.id)) { _, ids in
                path.removeAll { !ids.contains($0.hostID) }
                if let selected, !ids.contains(selected.hostID) { self.selected = nil }
            }
            .safeAreaInset(edge: .bottom) {
                if !all.isEmpty { filterBar(counts) }
            }
    }

    private func list(_ visible: [HostSection]) -> some View {
        let showHost = hub.hosts.count > 1
        return List {
            ForEach(visible) { item in
                Section {
                    let entries = RemoteSessionDirectory.filter([item.section], by: filter, query: query)
                        .first?.worktrees ?? []
                    ForEach(entries) { entry in
                        WorktreeRow(entry: entry,
                                    selectedSessionId: selected?.hostID == item.host.id ? selected?.sessionId : nil) { session in
                            open(SessionRoute(hostID: item.host.id, sessionId: session.id))
                        }
                    }
                } header: {
                    HStack(spacing: 10) {
                        RepoTile(name: item.section.title)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.section.title).font(.headline).foregroundStyle(.primary)
                            if showHost || item.section.hostName != nil {
                                Text(item.section.hostName ?? item.host.name)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.bottom, 56, for: .scrollContent)
    }

    private func filterBar(_ counts: [RemoteSessionFilter: Int]) -> some View {
        Picker("Filter", selection: $model.filter) {
            Text("All \(counts[.all] ?? 0)").tag(RemoteSessionFilter.all)
            Text("Running \(counts[.running] ?? 0)").tag(RemoteSessionFilter.running)
            Text("Dirty \(counts[.dirty] ?? 0)").tag(RemoteSessionFilter.dirty)
        }
        .pickerStyle(.segmented)
        .padding(4)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
    }
}

/// `searchable` on the Search tab only: the tab is the app's one search field.
private struct SearchField: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    @Binding var presented: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, isPresented: $presented)
        } else {
            content
        }
    }
}
