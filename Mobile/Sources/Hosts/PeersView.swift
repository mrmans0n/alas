import AlasRemoteKit
import SwiftUI

/// The paired Macs: how each is reached and whether it is online.
struct PeersView: View {
    let hub: HostHub

    private struct PairRequest: Identifiable {
        let id = UUID()
        var origins: [String] = []
    }

    @State private var pairRequest: PairRequest?

    var body: some View {
        NavigationStack {
            List {
                if !hub.hosts.isEmpty {
                    Section {
                        ForEach(hub.hosts) { host in
                            PeerRow(host: host, state: hub.state(of: host.id), sessionCount: hub.sessions(of: host.id).count) {
                                pairRequest = PairRequest(origins: host.origins)
                            }
                            .swipeActions {
                                Button("Forget", systemImage: "trash", role: .destructive) { hub.forget(host.id) }
                            }
                        }
                    }
                }
                #if DEBUG
                    Section("Developer") {
                        NavigationLink {
                            SpikeScreen()
                        } label: {
                            Label("Transcript benchmark", systemImage: "gauge.with.dots.needle.67percent")
                        }
                    }
                #endif
            }
            .overlay {
                if hub.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Macs yet", systemImage: "laptopcomputer")
                    } description: {
                        Text("Pair a Mac running Alas to see its worktrees and sessions here.")
                    } actions: {
                        Button("Pair a Mac") { pairRequest = PairRequest() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Peers")
            .navigationSubtitle(summary)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Pair a Mac", systemImage: "plus") { pairRequest = PairRequest() }
                }
            }
            .sheet(item: $pairRequest) { request in
                PairHostView(hub: hub, prefilledOrigins: request.origins)
            }
        }
    }

    private var summary: String {
        guard !hub.hosts.isEmpty else { return "" }
        let online = hub.hosts.count { hub.state(of: $0.id) == .online }
        return online == hub.hosts.count ? "All online" : "\(online) of \(hub.hosts.count) online"
    }
}

private struct PeerRow: View {
    let host: PairedHost
    let state: PhoneConnection.State
    let sessionCount: Int
    let pairAgain: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "laptopcomputer")
                .font(.title2)
                .foregroundStyle(state == .online ? Color.accentColor : .secondary)
                .frame(width: 44, height: 44)
                .background(.fill.tertiary, in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(host.name).font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Text(stateLabel)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let route {
                    HStack(spacing: 4) {
                        Image(systemName: route.icon)
                        Text(route.address).monospaced()
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if state == .unauthorized {
                Button("Pair again", action: pairAgain)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if sessionCount > 0 {
                Text("\(sessionCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(sessionCount) sessions")
            }
        }
        .padding(.vertical, 4)
    }

    /// The origin in use, without its scheme; tailnet addresses get a globe.
    private var route: (address: String, icon: String)? {
        guard let origin = host.lastOrigin ?? host.origins.first,
              let url = URL(string: origin), let name = url.host() else { return nil }
        let address = url.port.map { "\(name):\($0)" } ?? name
        let tailnet = name.hasSuffix(".ts.net") || name.hasPrefix("100.")
        return (address, tailnet ? "globe" : "wifi")
    }

    private var stateLabel: String {
        switch state {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .online: "Online"
        case .offline: "Offline"
        case .unauthorized: "No longer paired"
        case .incompatible: "Needs a newer Alas"
        case .identityMismatch: "A different Mac answered"
        case .identityUnproven: "Couldn't verify this Mac"
        }
    }

    private var dotColor: Color {
        switch state {
        case .online: .green
        case .connecting: .orange
        case .idle, .offline: .gray
        case .unauthorized, .incompatible, .identityMismatch, .identityUnproven: .red
        }
    }
}
