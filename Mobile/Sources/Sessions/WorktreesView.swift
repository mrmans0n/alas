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
    /// The Search tab opens with the field active.
    var focusSearchOnAppear = false
    var onPairMac: () -> Void = {}

    @State private var path: [SessionRoute] = []
    @FocusState private var searchFocused: Bool

    private var filter: RemoteSessionFilter { model.filter }
    private var query: String { model.query }

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
        NavigationStack(path: $path) {
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
            .navigationTitle("Worktrees")
            .searchable(text: $model.query)
            .searchFocused($searchFocused)
            .navigationDestination(for: SessionRoute.self) { route in
                // Task 6 swaps this for TranscriptScreen(hub:hostID:session:).
                if let session = hub.sessions(of: route.hostID).first(where: { $0.id == route.sessionId }) {
                    Text(session.title)
                } else {
                    ContentUnavailableView("Session unavailable", systemImage: "bubble.left")
                }
            }
            .task {
                guard focusSearchOnAppear else { return }
                // The field is created by the tab transition, so focus it just after.
                try? await Task.sleep(for: .milliseconds(400))
                searchFocused = true
            }
            .safeAreaInset(edge: .bottom) {
                if !all.isEmpty { filterBar(counts) }
            }
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
                        WorktreeRow(entry: entry) { session in
                            path.append(SessionRoute(hostID: item.host.id, sessionId: session.id))
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
