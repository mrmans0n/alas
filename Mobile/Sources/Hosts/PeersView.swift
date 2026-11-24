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
    @State private var forgetting: PairedHost?
    @State private var viewingDevices: PairedHost?

    var body: some View {
        NavigationStack {
            List {
                if !hub.hosts.isEmpty {
                    Section {
                        ForEach(hub.hosts) { host in
                            PeerRow(
                                host: host,
                                state: hub.state(of: host.id),
                                sessionCount: hub.sessions(of: host.id).count,
                                openDevices: hub.state(of: host.id) == .online && hub.supports(PeerDeviceCapability.v1, on: host.id)
                                    ? { viewingDevices = host } : nil
                            ) {
                                pairRequest = PairRequest(origins: host.origins)
                            }
                            .swipeActions {
                                Button("Forget", systemImage: "trash", role: .destructive) { forgetting = host }
                            }
                        }
                    }
                }
                if let registrar = hub.registrar, !hub.hosts.isEmpty, !PushRegistrar.relayURL.isEmpty {
                    NotificationKindsSection(registrar: registrar)
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
                        Label("No machines yet", systemImage: "laptopcomputer")
                    } description: {
                        Text("Pair a machine running Alas to see its worktrees and sessions here.")
                    } actions: {
                        Button("Pair a machine") { pairRequest = PairRequest() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Peers")
            .navigationSubtitle(summary)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Pair a machine", systemImage: "plus") { pairRequest = PairRequest() }
                }
            }
            .sheet(item: $pairRequest) { request in
                PairHostView(hub: hub, prefilledOrigins: request.origins)
            }
            .fullScreenCover(item: $viewingDevices) { host in
                PeerDevicesView(hub: hub, host: host)
            }
            .confirmationDialog(
                "Forget \(forgetting?.name ?? "this machine")?",
                isPresented: Binding { forgetting != nil } set: { if !$0 { forgetting = nil } },
                titleVisibility: .visible, presenting: forgetting
            ) { host in
                Button("Forget", role: .destructive) { hub.forget(host.id) }
            } message: { _ in
                Text("You'll need to pair again from that machine.")
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
    let openDevices: (() -> Void)?
    let pairAgain: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            PeerIconView(icon: host.icon ?? .laptop)
                .font(.title2)
                .foregroundStyle(state == .online ? Color.accentColor : .secondary)
                .frame(width: 44, height: 44)
                .background(.fill.tertiary, in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(host.name).font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Text(state.label)
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
                if let openDevices {
                    Button("Devices", systemImage: "iphone", action: openDevices)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Devices on \(host.name)")
                        .frame(minHeight: 44, alignment: .leading)
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

    private var dotColor: Color {
        switch state {
        case .online: .green
        case .connecting: .orange
        case .idle, .offline: .gray
        case .unauthorized, .incompatible, .identityMismatch, .identityUnproven: .red
        }
    }
}

/// Says which paired machines are offline, with a manual redial in place of
/// waiting out the backoff. Only `.offline`: an idle or connecting link is
/// already on its way, and the other states need pairing, not a retry.
struct ConnectionBanner: View {
    let hub: HostHub
    /// Just this machine, as on a session's screen; every one when nil.
    var hostID: UUID?

    var body: some View {
        let down = hub.hosts.filter { (hostID == nil || $0.id == hostID) && hub.state(of: $0.id) == .offline }
        if let first = down.first {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                Text(down.count == 1 ? "\(first.name) is offline" : "\(down.count) machines are offline")
                    .font(.footnote)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Reconnect") { hub.connectAll() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }
}

extension PhoneConnection.State {
    /// How a host's connection reads in a status line.
    var label: String {
        switch self {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .online: "Online"
        case .offline: "Offline"
        case .unauthorized: "No longer paired"
        case .incompatible: "Needs a newer Alas"
        case .identityMismatch: "A different machine answered"
        case .identityUnproven: "Couldn't verify this machine"
        }
    }
}

/// Which alerts this phone gets; every paired Mac honours the same choice.
private struct NotificationKindsSection: View {
    @Bindable var registrar: PushRegistrar

    var body: some View {
        Section {
            toggle("Permission requests", systemImage: "hand.raised", kind: RemotePushKind.permission)
            toggle("Questions and plans", systemImage: "questionmark.bubble", kind: RemotePushKind.input)
            toggle("Finished turns", systemImage: "checkmark.circle", kind: RemotePushKind.finished)
            toggle("Mac inbox", systemImage: "tray", kind: RemotePushKind.inbox)
        } header: {
            Text("Notify me about")
        } footer: {
            Text("Questions and plans include forms and visuals waiting for an answer. Mac inbox covers failed runs, conflicts, CI and review feedback.")
        }
    }

    private func toggle(_ title: String, systemImage: String, kind: String) -> some View {
        Toggle(isOn: Binding(
            get: { registrar.kinds.contains(kind) },
            set: { on in if on { registrar.kinds.insert(kind) } else { registrar.kinds.remove(kind) } }
        )) {
            Label(title, systemImage: systemImage)
        }
    }
}
