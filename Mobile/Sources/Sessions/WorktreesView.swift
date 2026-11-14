import AlasRemoteKit
import SwiftUI

/// Every paired Mac's sessions, grouped by repo and worktree.
struct WorktreesView: View {
    let hub: HostHub
    var onPairMac: () -> Void = {}

    @State private var filter = RemoteSessionFilter.all
    @State private var query = ""

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
        NavigationStack {
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
                    ContentUnavailableView.search(text: query)
                } else {
                    list(visible)
                }
            }
            .navigationTitle("Worktrees")
            .searchable(text: $query)
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
                            // Task 6 swaps this for TranscriptScreen(hub:hostID:session:).
                            let _ = item.host.id
                            Text(session.title)
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
        Picker("Filter", selection: $filter) {
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
