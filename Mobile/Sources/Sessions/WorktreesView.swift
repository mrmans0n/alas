import AlasRemoteKit
import SwiftUI

/// List choices shared by the Worktrees and Search tabs.
@MainActor @Observable
final class WorktreesModel {
    var query = ""
    var filter = RemoteSessionFilter.all
    var selectedHost: RemoteSessionCatalog.HostID?
    var collapsedHosts: Set<RemoteSessionCatalog.HostID> = []
}

/// Where a tapped session lives: enough to resolve it from the hub later.
struct SessionRoute: Hashable {
    let hostID: UUID
    let sessionId: String
}

/// Sessions grouped by their owning Mac, then repo and worktree.
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

    private struct HostGroup: Identifiable {
        let host: RemoteSessionCatalog.Host
        let sections: [RemoteRepoSection]
        var id: RemoteSessionCatalog.HostID { host.id }

        var rows: [CatalogRow] {
            sections.flatMap { section in
                [CatalogRow(id: .project(section.id), content: .project(section.title))]
                    + section.worktrees.map {
                        CatalogRow(id: .worktree(section.id, $0.id), content: .worktree($0))
                    }
            }
        }
    }

    private struct CatalogRow: Identifiable {
        enum ID: Hashable { case project(String), worktree(String, String) }
        enum Content { case project(String), worktree(RemoteWorktreeEntry) }
        let id: ID
        let content: Content
    }

    private var allHosts: [RemoteSessionCatalog.Host] {
        RemoteSessionCatalog.hosts(from: hub.sessionSources)
    }

    var body: some View {
        let hosts = allHosts
        let scoped = hosts.filter { model.selectedHost == nil || $0.id == model.selectedHost }
        let all = scoped.flatMap(\.sections)
        let counts = RemoteSessionDirectory.counts(all)
        let visible = scoped.map {
            HostGroup(host: $0, sections: RemoteSessionDirectory.filter($0.sections, by: filter, query: query))
        }.filter { !$0.sections.isEmpty }
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    directory(hosts: hosts, all: all, counts: counts, visible: visible)
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
                    directory(hosts: hosts, all: all, counts: counts, visible: visible)
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
    private func directory(hosts: [RemoteSessionCatalog.Host], all: [RemoteRepoSection],
                           counts: [RemoteSessionFilter: Int], visible: [HostGroup]) -> some View {
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
                if hosts.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        hostPicker(hosts)
                    }
                }
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
            .onChange(of: hosts.map(\.id), initial: true) { _, ids in
                if let selected = model.selectedHost, !ids.contains(selected) { model.selectedHost = nil }
                model.collapsedHosts.formIntersection(ids)
            }
            .safeAreaInset(edge: .bottom) {
                if !all.isEmpty { filterBar(counts) }
            }
    }

    private var revealingMatches: Bool {
        filter != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func list(_ visible: [HostGroup]) -> some View {
        return List {
            ForEach(visible) { group in
                Section {
                    if revealingMatches || !model.collapsedHosts.contains(group.id) {
                        ForEach(group.rows) { row in
                            VStack(alignment: .leading) {
                                switch row.content {
                                case .project(let title):
                                    HStack(spacing: 10) {
                                        RepoTile(name: title)
                                        Text(title).font(.headline)
                                    }
                                    .padding(.top, 8)
                                    .accessibilityAddTraits(.isHeader)
                                case .worktree(let entry):
                                    WorktreeRow(entry: entry, selectedSessionId: selectedSessionID(in: entry, on: group.host)) { session in
                                        guard let target = group.host.route(for: session.id) else { return }
                                        open(SessionRoute(hostID: target.hostID, sessionId: target.sessionId))
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Button {
                        if !model.collapsedHosts.insert(group.id).inserted {
                            model.collapsedHosts.remove(group.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "laptopcomputer")
                            Text(group.host.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(group.host.worktreeCount) worktrees")
                                .font(.caption).foregroundStyle(.secondary)
                            Image(systemName: model.collapsedHosts.contains(group.id) && !revealingMatches
                                  ? "chevron.right" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(revealingMatches)
                    .accessibilityValue(model.collapsedHosts.contains(group.id) && !revealingMatches ? "Collapsed" : "Expanded")
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.bottom, 56, for: .scrollContent)
    }

    private func hostPicker(_ hosts: [RemoteSessionCatalog.Host]) -> some View {
        Menu {
            Picker("Host", selection: $model.selectedHost) {
                Text("All hosts").tag(RemoteSessionCatalog.HostID?.none)
                ForEach(hosts) { host in
                    Text(host.name).tag(Optional(host.id))
                }
            }
        } label: {
            Label(hosts.first { $0.id == model.selectedHost }?.name ?? "All hosts",
                  systemImage: "line.3.horizontal.decrease")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .accessibilityLabel("Filter by host")
        .accessibilityValue(hosts.first { $0.id == model.selectedHost }?.name ?? "All hosts")
    }

    private func selectedSessionID(in entry: RemoteWorktreeEntry, on host: RemoteSessionCatalog.Host) -> String? {
        guard let selected else { return nil }
        return entry.activeSessions.first { session in
            guard let route = host.route(for: session.id) else { return false }
            return selected == SessionRoute(hostID: route.hostID, sessionId: route.sessionId)
        }?.id
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
