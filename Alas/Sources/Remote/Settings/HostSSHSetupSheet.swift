import SwiftUI

/// Installs, configures, starts and pairs `alas-host` on another Mac over SSH.
struct HostSSHSetupSheet: View {
    let peers: RemotePeerManager
    let describeAddError: (RemotePeerManager.AddError) -> String
    let onDismiss: () -> Void
    @Environment(\.theme) var theme

    private indirect enum Phase {
        case destination
        case options(HostSSHProbe, HostSSHInstall)
        case running
        case done(peerName: String, warnings: [String])
        /// `back` is where Back returns, with the entered values kept.
        case failed(String, back: Phase)
    }

    @State private var phase: Phase = .destination
    @State private var destination = ""
    @State private var isConnecting = false
    @State private var reachability = "lan"
    @State private var agents: [HostSSHAgent] = []
    @State private var projects = ""
    @State private var steps: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set up a host over SSH")
                .font(.system(size: 16, weight: .semibold))
                .padding(.bottom, 8)
            content
        }
        .padding(24)
        .frame(width: 520)
        .background(theme.color("bg-1"))
        .interactiveDismissDisabled(isBusy)
    }

    private var isBusy: Bool {
        if case .running = phase { return true }
        return isConnecting
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .destination:
            dimText("Installs or updates alas-host on another Mac, starts it at login, and pairs with it. "
                + "This Mac needs key-based SSH access to it.")
            AlasField(text: $destination, placeholder: "user@host.local", monospaced: true, onSubmit: connect)
                .padding(.vertical, 12)
            buttons {
                AlasButton(title: isConnecting ? "Connecting…" : "Connect", style: .primary, action: connect)
                    .disabled(isConnecting || trimmedDestination.isEmpty)
            }
        case .options(let probe, let install):
            dimText(Self.summary(install))
            SettingsRow(name: "Reachability", desc: "Tailscale needs Tailscale running on both Macs.") {
                AlasSegmentedControl(
                    selection: reachability,
                    options: [
                        AlasSegmentedOption(id: "lan", label: "LAN"),
                        AlasSegmentedOption(id: "tailscale", label: "Tailscale"),
                    ],
                    onSelect: { reachability = $0 }
                )
            }
            ForEach($agents, id: \.id) { $agent in
                SettingsRow(name: agent.id, desc: "Agent on the host") {
                    AlasToggle(on: $agent.enabled)
                }
            }
            SettingsRow(name: "Projects", desc: "Paths on the host, one per line.") {
                TextEditor(text: $projects)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 72)
                    .padding(8)
                    .background(theme.color("bg-0"))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5))
            }
            buttons {
                AlasButton(title: "Back", style: .subtle) { phase = .destination }
                AlasButton(title: "Set up", style: .primary) { runSetup(probe, install) }
                    .disabled(Self.isUnsupported(install))
            }
        case .running:
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                dimText(index == steps.count - 1 ? step + "…" : step)
            }
        case .done(let peerName, let warnings):
            Text("Paired with \(peerName).")
                .font(.system(size: 12.5))
                .padding(.bottom, 8)
            ForEach(warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Icon(name: "alert", size: 12, color: theme.color("warn"))
                    dimText(warning)
                }
            }
            buttons {
                AlasButton(title: "Done", style: .primary, action: onDismiss)
            }
        case .failed(let message, let back):
            failureMessage(message)
            buttons {
                AlasButton(title: "Copy", style: .subtle) { Clipboard.copy(message) }
                AlasButton(title: "Back", style: .subtle) { phase = back }
            }
        }
    }

    /// A failing step can return pages of remote stderr (a Homebrew stack
    /// trace): short messages size to fit, long ones scroll inside a bounded box.
    private func failureMessage(_ message: String) -> some View {
        let text = Text(message)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundColor(theme.color("warn"))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        return ViewThatFits(in: .vertical) {
            text.fixedSize(horizontal: false, vertical: true)
            ScrollView { text }
        }
        .frame(maxHeight: 320)
        .background(theme.color("bg-0"))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(theme.color("line"), lineWidth: 0.5))
    }

    private func dimText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(theme.color("fg-dim"))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
    }

    private func buttons<Trailing: View>(@ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Spacer()
            AlasButton(title: "Cancel", style: .subtle, action: onDismiss)
                .disabled(isBusy)
            trailing()
        }
        .padding(.top, 16)
    }

    private var trimmedDestination: String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        guard !isConnecting, !trimmedDestination.isEmpty else { return }
        let setup = HostSSHSetup(destination: trimmedDestination, bundleResources: Self.bundleResources)
        isConnecting = true
        Task { @MainActor in
            defer { isConnecting = false }
            do {
                let probe = try await setup.probe()
                // Hashes the bundled host binary; keep it off the main thread.
                let install = await Task.detached { setup.decision(for: probe) }.value
                reachability = probe.reachability == "tailscale" ? "tailscale" : "lan"
                agents = probe.agents
                phase = .options(probe, install)
            } catch {
                phase = .failed(Self.describe(error, destination: setup.destination), back: .destination)
            }
        }
    }

    private func runSetup(_ probe: HostSSHProbe, _ install: HostSSHInstall) {
        let setup = HostSSHSetup(destination: trimmedDestination, bundleResources: Self.bundleResources)
        let options = HostSSHSetupOptions(
            reachability: reachability,
            agents: Dictionary(agents.map { ($0.id, $0.enabled) }, uniquingKeysWith: { $1 }),
            projects: projects.split(separator: "\n").map(String.init)
        )
        let back = Phase.options(probe, install)
        steps = [Self.summary(install)]
        phase = .running
        Task { @MainActor in
            do {
                // Checked again: a retry follows whatever was fixed on the host
                // since the sheet connected.
                let current = try await setup.probe()
                let plan = setup.decision(for: current)
                if plan != install { steps.append(Self.summary(plan)) }
                let host = try await setup.install(current, progress: { note in
                    Task { @MainActor in steps.append(note) }
                })
                steps.append("Configuring the host")
                try await setup.configure(host: host, options: options)
                steps.append("Starting the host")
                try await setup.start(host: host)
                steps.append("Pairing")
                let link = try await setup.pair(host: host)
                let before = Set(peers.peers.map(\.id))
                if let error = await peers.addPeer(link: link) {
                    phase = .failed(describeAddError(error), back: back)
                    return
                }
                // Re-pairing an already paired host adds no new peer; find it by address.
                let origin = RemotePairingLink.parse(link)?.origins.first
                let peer = peers.peers.first { !before.contains($0.id) }
                    ?? origin.flatMap { origin in peers.peers.first { $0.origins.contains(origin) } }
                if let peer {
                    peers.setSSHDestination(setup.destination, peerId: peer.id)
                }
                steps.append("Checking the host")
                let warnings = await setup.check(host: host)
                phase = .done(peerName: peer?.name ?? setup.destination, warnings: warnings)
            } catch {
                phase = .failed(Self.describe(error, destination: setup.destination), back: back)
            }
        }
    }

    static var bundleResources: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }

    static func summary(_ install: HostSSHInstall) -> String {
        switch install {
        case .brewUpgrade: "Updates alas-host with Homebrew"
        case .brewInstall: "Installs alas-host with Homebrew"
        case .existing: "Uses the alas-host inside Alas.app on that Mac"
        case .copy: "Copies alas-host from this app"
        case .unsupported(let reason): reason
        }
    }

    private static func isUnsupported(_ install: HostSSHInstall) -> Bool {
        if case .unsupported = install { return true }
        return false
    }

    static func describe(_ error: Error, destination: String) -> String {
        guard let failure = error as? HostSSHSetup.Failure else { return error.localizedDescription }
        if failure.connectionFailed {
            return "Couldn't connect. Run `ssh \(destination)` once in Terminal to trust the host "
                + "and check that key login works without a password."
        }
        return "\(failure.step) failed: \(failure.message)"
    }
}

/// The tail of a host's log, read over SSH.
struct HostLog: Identifiable {
    let id = UUID()
    let name: String
    let text: String
}

struct HostLogSheet: View {
    let log: HostLog
    let onDismiss: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(log.name) host log")
                .font(.system(size: 16, weight: .semibold))
                .padding(.bottom, 8)
            ScrollView {
                Text(log.text.isEmpty ? "The log is empty." : log.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: 420)
            .background(theme.color("bg-0"))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5))
            HStack {
                Spacer()
                AlasButton(title: "Close", style: .primary, action: onDismiss)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 720)
        .background(theme.color("bg-1"))
    }
}
