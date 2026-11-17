import AlasRemoteKit
import SwiftUI

/// How the list groups worktrees once more than one machine is paired.
enum WorktreeGrouping: String, CaseIterable {
    /// Machine, then its projects: the machine's own sidebar.
    case machine
    /// Project, merging one repository's worktrees from every machine.
    case project
}

/// List choices shared by the Worktrees and Search tabs.
@MainActor @Observable
final class WorktreesModel {
    private static let groupingKey = "worktreesGrouping"

    var query = ""
    var filter = RemoteSessionFilter.all
    var selectedHost: RemoteSessionCatalog.HostID?
    var collapsedHosts: Set<RemoteSessionCatalog.HostID> = []
    var grouping = UserDefaults.standard.string(forKey: groupingKey).flatMap(WorktreeGrouping.init) ?? .machine {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: Self.groupingKey) }
    }
}

/// Where a tapped session lives: enough to resolve it from the hub later.
struct SessionRoute: Hashable {
    let hostID: UUID
    let sessionId: String
}

/// Sessions grouped by their owning machine, then repo and worktree, or by
/// project across machines.
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
    /// Where the sheet starts: a project header's machines, or none for the toolbar's.
    @State private var newSessionPresets: [NewSessionPreset] = []

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
    }

    /// What the list shows, under the grouping in effect.
    private enum Listing {
        case machines([HostGroup])
        case projects([RemoteSessionCatalog.ProjectGroup], hosts: [RemoteSessionCatalog.HostID: RemoteSessionCatalog.Host])

        var isEmpty: Bool {
            switch self {
            case .machines(let groups): groups.isEmpty
            case .projects(let groups, _): groups.isEmpty
            }
        }
    }

    private var allHosts: [RemoteSessionCatalog.Host] {
        RemoteSessionCatalog.hosts(from: hub.sessionSources)
    }

    var body: some View {
        let hosts = allHosts
        // One machine has nothing to merge; its list reads the same either way.
        let scoped = hosts.filter { model.selectedHost == nil || $0.id == model.selectedHost }
        let all = scoped.flatMap(\.sections)
        let (counts, visible) = listing(scoped, grouping: hosts.count > 1 ? model.grouping : .machine)
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

    /// The scoped machines' worktrees under `grouping`, with the filter
    /// counts that grouping reports.
    private func listing(_ scoped: [RemoteSessionCatalog.Host],
                         grouping: WorktreeGrouping) -> ([RemoteSessionFilter: Int], Listing) {
        switch grouping {
        case .project:
            let projects = RemoteSessionCatalog.projects(from: scoped)
            return (RemoteSessionDirectory.counts(projects),
                    .projects(RemoteSessionDirectory.filter(projects, by: filter, query: query),
                              hosts: Dictionary(uniqueKeysWithValues: scoped.map { ($0.id, $0) })))
        case .machine:
            let sections = scoped.flatMap(\.sections)
            return (RemoteSessionDirectory.counts(sections), .machines(scoped.map {
                HostGroup(host: $0, sections: RemoteSessionDirectory.filter($0.sections, by: filter, query: query))
            }.filter { !$0.sections.isEmpty }))
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
                           counts: [RemoteSessionFilter: Int], visible: Listing) -> some View {
            Group {
                if hub.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No machines paired", systemImage: "laptopcomputer")
                    } description: {
                        Text("Pair a machine running Alas to see its worktrees and sessions here.")
                    } actions: {
                        Button("Pair a machine", action: onPairMac).buttonStyle(.borderedProminent)
                    }
                } else if all.isEmpty {
                    ContentUnavailableView("No sessions", systemImage: "folder",
                                           description: Text("Open sessions on your machines will show here."))
                } else if visible.isEmpty {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView(filter == .running ? "No running worktrees" : "No worktrees with changes",
                                               systemImage: filter == .running ? "bolt.slash" : "checkmark.circle")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    switch visible {
                    case .machines(let groups): list(groups)
                    case .projects(let groups, let hosts): projectList(groups, hosts: hosts)
                    }
                }
            }
            .navigationTitle(title)
            .modifier(SearchField(enabled: isSearch, text: $model.query, presented: $searchPresented))
            .toolbar {
                if hosts.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        listOptions(hosts)
                    }
                }
                if !hub.hosts.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New session", systemImage: "plus") { startNewSession(in: []) }
                    }
                }
            }
            .sheet(isPresented: $newSessionPresented) {
                NewSessionSheet(hub: hub, presets: newSessionPresets) { route in
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
        // One Mac needs no header of its own; with several, each gets a
        // collapsible one above its repos.
        let showsHosts = allHosts.count > 1
        return List {
            ForEach(visible) { group in
                if showsHosts {
                    Section { EmptyView() } header: { hostHeader(group) }
                }
                if !showsHosts || revealingMatches || !model.collapsedHosts.contains(group.id) {
                    ForEach(group.sections) { section in
                        Section {
                            ForEach(RemoteSessionDirectory.attentionFirst(section.worktrees)) { entry in
                                WorktreeRow(entry: entry,
                                            isSelected: selectedSessionID(in: entry, on: group.host) != nil) { session in
                                    guard let target = group.host.route(for: session.id) else { return }
                                    open(SessionRoute(hostID: target.hostID, sessionId: target.sessionId))
                                }
                            }
                        } header: {
                            repoHeader(section, presets: presets([(hostID: group.host.id, projectId: section.worktrees.lazy.compactMap(\.projectId).first,
                                                                    worktreeId: section.worktrees.first?.id)]))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, 56, for: .scrollContent)
    }

    private func projectList(_ groups: [RemoteSessionCatalog.ProjectGroup],
                             hosts: [RemoteSessionCatalog.HostID: RemoteSessionCatalog.Host]) -> some View {
        List {
            ForEach(groups) { group in
                // A project on one machine names it once, in its header; one
                // on several names each row's.
                let spansMachines = group.hostIDs.count > 1
                Section {
                    ForEach(RemoteSessionDirectory.attentionFirst(group.rows)) { row in
                        let host = hosts[row.hostID]
                        WorktreeRow(entry: row.worktree,
                                    machine: spansMachines ? row.hostName : nil,
                                    isSelected: host.flatMap { selectedSessionID(in: row.worktree, on: $0) } != nil) { session in
                            guard let target = host?.route(for: session.id) else { return }
                            open(SessionRoute(hostID: target.hostID, sessionId: target.sessionId))
                        }
                    }
                } header: {
                    repoHeader(group.title, count: group.rows.count,
                               detail: spansMachines ? "\(group.hostIDs.count) machines" : group.rows.first?.hostName,
                               presets: presets(group.placements.map { (hostID: $0.hostID, projectId: Optional($0.projectId), worktreeId: Optional($0.worktreeId)) }))
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, 56, for: .scrollContent)
    }

    private func repoHeader(_ section: RemoteRepoSection, presets: [NewSessionPreset]) -> some View {
        repoHeader(section.title, count: section.worktrees.count, detail: nil, presets: presets)
    }

    private func startNewSession(in presets: [NewSessionPreset]) {
        newSessionPresets = presets
        newSessionPresented = true
    }

    /// A project's machines as the paired connections the sheet talks to;
    /// one reached only through a relay can't start sessions from here.
    private func presets(_ placements: [(hostID: RemoteSessionCatalog.HostID, projectId: String?, worktreeId: String?)]) -> [NewSessionPreset] {
        placements.compactMap { placement in
            guard let projectId = placement.projectId else { return nil }
            let paired: UUID? = switch placement.hostID {
            case .pairing(let id): hub.hosts.contains { $0.id == id } ? id : nil
            case .server(let serverId): hub.hosts.first { $0.serverId == serverId }?.id
            }
            return paired.map { NewSessionPreset(hostID: $0, projectId: projectId, worktreeId: placement.worktreeId) }
        }
    }

    private func repoHeader(_ title: String, count: Int, detail: String?, presets: [NewSessionPreset]) -> some View {
        HStack(spacing: 8) {
            RepoTile(name: title, size: 22)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("·").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) worktrees")
            if !presets.isEmpty {
                Button("New session in \(title)", systemImage: "plus.circle") { startNewSession(in: presets) }
                    .labelStyle(.iconOnly)
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .buttonStyle(.borderless)
                    // Offered as the header's action instead, since the header reads as one element.
                    .accessibilityHidden(true)
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityActions {
            if !presets.isEmpty {
                Button("New session in \(title)") { startNewSession(in: presets) }
            }
        }
    }

    private func hostHeader(_ group: HostGroup) -> some View {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(revealingMatches)
        .accessibilityValue(model.collapsedHosts.contains(group.id) && !revealingMatches ? "Collapsed" : "Expanded")
        .textCase(nil)
    }

    /// How to group, and which machines to show.
    private func listOptions(_ hosts: [RemoteSessionCatalog.Host]) -> some View {
        let shown = hosts.first { $0.id == model.selectedHost }?.name ?? "All machines"
        return Menu {
            Picker("Group by", selection: $model.grouping) {
                Label("Machine", systemImage: "desktopcomputer").tag(WorktreeGrouping.machine)
                Label("Project", systemImage: "folder").tag(WorktreeGrouping.project)
            }
            .pickerStyle(.inline)
            Picker("Show", selection: $model.selectedHost) {
                Text("All machines").tag(RemoteSessionCatalog.HostID?.none)
                ForEach(hosts) { host in
                    Text(host.name).tag(Optional(host.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(shown, systemImage: "line.3.horizontal.decrease")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .accessibilityLabel("List options")
        .accessibilityValue("Grouped by \(model.grouping == .machine ? "machine" : "project"), \(shown)")
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
