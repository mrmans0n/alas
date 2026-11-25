import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct RemoteServerPane: View {
    @Bindable var state: AppState
    @Environment(\.designScale) private var scale
    @Environment(\.theme) var theme
    @State private var pairingCode: String?
    @State private var peerLink = ""
    @State private var peerError: String?
    @State private var isAddingPeer = false
    @State private var showingHostSSHSetup = false
    /// The peer whose host update awaits confirmation.
    @State private var confirmingHostUpdate: RemotePeer?
    /// Progress of a running host update or log read, shown in place of the peer's status.
    @State private var hostActivity: [String: String] = [:]
    @State private var hostLog: HostLog?
    /// The nearby instance selected for approval or legacy code entry.
    @State private var selectedNearbyId: String?
    @State private var selectedNearbyName = ""
    @State private var nearbyCode = ""
    /// The sheet open over the pane: one paired Mac's, one device's, or Add Mac.
    @State private var activeSheet: RemoteSheet?
    @State private var confirmingForget = false
    @State private var addMacTab: AddMacTab = .nearby
    /// What to do once the open sheet has closed: one sheet cannot present
    /// another, and the pane's alerts don't show over a sheet.
    @State private var afterSheet: AfterSheet?
    /// Rotates the displayed pairing code well within its 120s TTL so the QR on
    /// screen is never stale. Prior codes stay valid until they expire, so a
    /// device that scanned just before a rotation still pairs.
    private let rotateTimer = Timer.publish(every: 45, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Remote").font(SettingsPaneStyle.titleFont)
                Text("Watch sessions and answer permission prompts from another device.")
                    .font(scale.metaFont).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, scale.space[3])

                iPhoneBetaCard
                    .padding(.bottom, scale.space[4])

                SettingsGroup(title: "Remote access") {
                    SettingsRow(
                        name: "Enable remote control",
                        desc: "Serve a web client on your network so you can watch sessions and answer permission prompts from your phone. Off by default. Only enable on trusted networks; use Tailscale for access away from home."
                    ) {
                        AlasToggle(on: Binding(
                            get: { state.config.remote.enabled },
                            set: { state.setRemoteEnabled($0) }
                        ))
                    }

                    SettingsRow(
                        name: "Keep awake on power",
                        desc: "Prevent idle sleep while remote control is running and this Mac is plugged in. The display can still sleep. Closing the lid or choosing Sleep still puts the Mac to sleep."
                    ) {
                        AlasToggle(on: Binding(
                            get: { state.config.remote.keepAwake },
                            set: {
                                state.config.remote.keepAwake = $0
                                state.saveConfig()
                                state.syncRemoteKeepAwake()
                            }
                        ))
                    }

                    if let error = state.lastRemoteError {
                        SettingsRow(name: "Error", desc: error) {
                            Icon(name: "alert", size: 14, color: theme.color("warn"))
                        }
                    }

                    if state.config.remote.enabled, let port = state.remotePort {
                        if state.remoteAdvertisedAddresses.isEmpty {
                            let fallbackURL = "http://localhost:\(port)"
                            SettingsRow(name: "Localhost", desc: fallbackURL) {
                                Button {
                                    copyAddress(fallbackURL)
                                } label: {
                                    Text("Copy")
                                        .font(scale.meta.font(weight: .medium))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        ForEach(state.remoteAdvertisedAddresses) { address in
                            SettingsRow(
                                name: addressLabel(address),
                                desc: addressDescription(address)
                            ) {
                                Button {
                                    copyAddress(address.url)
                                } label: {
                                    Text("Copy")
                                        .font(scale.meta.font(weight: .medium))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if let selected = selectedAddress(), !state.remoteAdvertisedAddresses.isEmpty {
                            SettingsRow(
                                name: "Pairing QR address",
                                desc: "QR will use \(addressLabel(selected)): \(selected.url)"
                            ) {
                                Picker("Pairing QR address", selection: selectedAddressBinding()) {
                                    ForEach(state.remoteAdvertisedAddresses) { address in
                                        Text(pickerAddressLabel(address)).tag(address.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .settingsDropdownFrame()
                            }
                        }
                        SettingsRow(
                            name: "PWA install",
                            desc: "Live remote access works over a trusted LAN or tailnet. Full browser install and offline shell behavior can require HTTPS, depending on the phone browser."
                        ) {
                            Image(systemName: "info.circle")
                                .font(scale.bodyFont)
                                .foregroundColor(theme.color("fg-dim"))
                        }
                        SettingsRow(
                            name: "Server name",
                            desc: "Shown on paired devices. Leave empty to use this Mac's name."
                        ) {
                            AlasField(
                                text: Binding(
                                    get: { state.config.remote.displayName },
                                    set: { value in
                                        state.config.remote.displayName = value
                                        state.saveConfig()
                                        // Clients only learn the name from hello — push a fresh
                                        // one so connected browsers don't show a stale name until
                                        // their next reconnect. The Bonjour name follows too.
                                        state.remoteServer?.broadcastHello()
                                        state.syncRemoteDiscovery()
                                    }
                                ),
                                placeholder: state.remoteDisplayName
                            )
                        }
                        SettingsRow(
                            name: "Icon",
                            desc: "Shown beside this Mac's name on paired devices."
                        ) {
                            PeerIconPicker(icon: Binding(
                                get: { PeerIcon(wireValue: state.config.remote.icon) ?? state.config.remote.resolvedIcon(default: .laptop) },
                                set: { icon in
                                    state.config.remote.icon = icon.rawValue
                                    state.saveConfig()
                                    // Same path as a rename: clients and the
                                    // Bonjour record only learn it from these.
                                    state.remoteServer?.broadcastHello()
                                    state.syncRemoteDiscovery()
                                }
                            ))
                        }
                        SettingsRow(
                            name: "Discoverable on this network",
                            desc: "Advertise this Mac with Bonjour and list other Macs running Alas nearby. Allow pairing requests on the receiving Mac."
                        ) {
                            AlasToggle(on: Binding(
                                get: { state.config.remote.discoverable },
                                set: {
                                    state.config.remote.discoverable = $0
                                    state.saveConfig()
                                    state.syncRemoteDiscovery()
                                }
                            ))
                        }
                        SettingsRow(
                            name: "Allowed origins",
                            desc: "Comma-separated. Add an address here if a hub reports \"doesn't allow this address\" — e.g. a reverse-proxied hostname the automatic checks don't already trust."
                        ) {
                            AlasField(
                                text: Binding(
                                    get: { state.config.remote.allowedOrigins.joined(separator: ", ") },
                                    set: { value in
                                        state.config.remote.allowedOrigins = value.split(separator: ",")
                                            .map { $0.trimmingCharacters(in: .whitespaces) }
                                            .filter { !$0.isEmpty }
                                        state.saveConfig()
                                        state.refreshRemoteAccessState()
                                    }
                                ),
                                monospaced: true
                            )
                        }
                        SettingsRow(name: "Pair a device", desc: "Show a QR code to pair a new phone or tablet.") {
                            AlasButton(
                                title: pairingCode == nil ? "Show pairing QR" : "New code",
                                style: .subtle
                            ) {
                                pairingCode = state.remotePairing.beginPairing()
                            }
                        }
                        if let code = pairingCode {
                            let link = pairingLink(code: code, port: port)
                            QRView(text: link)
                                .frame(width: 180, height: 180)
                                .padding(.top, scale.space[2])
                            Text(code)
                                .font(scale.body.font(weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.top, scale.space[2])
                            AlasButton(title: "Copy code", style: .subtle) {
                                copyAddress(code)
                            }
                            .padding(.top, scale.space[2])
                            AlasButton(title: "Copy pairing link", style: .subtle) {
                                copyAddress(link)
                            }
                            .padding(.top, scale.space[2])
                            Text("Refreshes automatically — scan it, paste the copied link into Alas remote on another device, or type the code into a nearby Mac's Peers list.")
                                .font(scale.metaFont)
                                .foregroundColor(theme.color("fg-dim"))
                                .padding(.bottom, scale.space[2])
                        }
                    }
                }

                // Stay visible while either setting is on, even with Tailscale
                // stopped, so a loopback-only bind can always be turned off.
                if state.config.remote.enabled,
                   state.remoteTailscale != nil || state.config.remote.tailscaleServe || state.config.remote.tailscaleOnly {
                    tailscaleGroup(state.remoteTailscale)
                }

                if state.config.remote.enabled, state.androidPane.control != nil {
                    RemoteDeviceSharingSettings(state: state)
                }

                pairedMacsGroup
                phonesAndBrowsersGroup
            }
            .padding(.horizontal, scale.space[5]).padding(.vertical, scale.space[5])
        }
        // Tailscale may log in or out, or gain HTTPS certificates, while the
        // pane is open; re-check until it closes.
        .task {
            while !Task.isCancelled {
                state.syncRemoteTailscale()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onChange(of: state.config.remote.enabled) { _, enabled in
            if !enabled { pairingCode = nil }   // don't show a stale code after re-enabling
        }
        .onReceive(rotateTimer) { _ in
            // While a QR is on screen, keep it fresh by minting a new code.
            if pairingCode != nil { pairingCode = state.remotePairing.beginPairing() }
        }
        .onDisappear { state.cancelNearbyApproval() }
        .onAppear(perform: openPendingMac)
        .onChange(of: state.pendingPairedMacServerId) { openPendingMac() }
        .sheet(isPresented: $showingHostSSHSetup) {
            HostSSHSetupSheet(
                peers: state.remotePeers,
                describeAddError: { describe($0, viaLink: true) },
                onDismiss: { showingHostSSHSetup = false }
            )
        }
        .sheet(item: $hostLog) { log in
            HostLogSheet(log: log, onDismiss: { hostLog = nil })
        }
        .alert(
            "Update this host?",
            isPresented: Binding(
                get: { confirmingHostUpdate != nil },
                set: { if !$0 { confirmingHostUpdate = nil } }
            ),
            presenting: confirmingHostUpdate
        ) { peer in
            Button("Update") { updateHost(peer) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Updating restarts the host and ends its running sessions.")
        }
        .sheet(item: $activeSheet, onDismiss: runAfterSheet) { sheet in
            switch sheet {
            case .mac(let id):
                if let entry = pairedMacEntries.first(where: { $0.id == id }) {
                    pairedMacSheet(entry)
                }
            case .device(let id):
                if let device = state.remotePairing.devices.first(where: { $0.id == id }) {
                    deviceSheet(device)
                }
            case .addMac:
                addMacSheet
            }
        }
    }

    static let testFlightURL = "https://testflight.apple.com/join/npVHNyMD"

    /// Invites people to the iPhone app beta. Shows the QR until an iPhone
    /// app has paired, then shrinks to one line so it stays out of the way.
    @ViewBuilder private var iPhoneBetaCard: some View {
        let hasPhone = state.remotePairing.devices.contains { $0.kind == .phone }
        let actions = HStack(spacing: scale.space[2]) {
            AlasButton(title: "Open TestFlight", style: hasPhone ? .subtle : .primary) {
                if let url = URL(string: Self.testFlightURL) { NSWorkspace.shared.open(url) }
            }
            AlasButton(title: "Copy link", style: .subtle) {
                copyAddress(Self.testFlightURL)
            }
        }
        HStack(alignment: .center, spacing: scale.space[4]) {
            if hasPhone {
                Text("Alas for iPhone beta")
                    .font(scale.body.font(weight: .medium))
                Spacer(minLength: 0)
                actions
            } else {
                QRView(text: Self.testFlightURL)
                    .frame(width: 96, height: 96)
                    .padding(6)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: scale.radius.medium))
                    .accessibilityLabel("TestFlight invite QR code")
                VStack(alignment: .leading, spacing: scale.space[1]) {
                    Text("Alas for iPhone is in beta")
                        .font(scale.body.font(weight: .semibold))
                    Text("Scan with your iPhone camera to join on TestFlight, or open the link on this Mac.")
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg-dim"))
                        .fixedSize(horizontal: false, vertical: true)
                    actions.padding(.top, scale.space[1])
                }
                Spacer(minLength: 0)
            }
        }
        .padding(scale.space[3])
        .background(theme.color("accent-soft"), in: RoundedRectangle(cornerRadius: scale.radius.medium))
    }

    private func updatesOverPeer(_ peer: RemotePeer) -> Bool {
        state.canUpdateHostOverPeer(peerId: peer.id, serverId: peer.serverId)
    }

    private func updateHost(_ peer: RemotePeer) {
        if updatesOverPeer(peer) {
            peerError = nil
            hostActivity[peer.id] = "Updating the host with Homebrew…"
            Task { @MainActor in
                defer { hostActivity[peer.id] = nil }
                if let message = await state.updateHostOverPeer(serverId: peer.serverId) {
                    peerError = "\(peer.name): " + message
                }
            }
            return
        }
        guard let destination = peer.sshDestination else { return }
        let setup = HostSSHSetup(destination: destination, bundleResources: HostSSHSetupSheet.bundleResources)
        peerError = nil
        hostActivity[peer.id] = "Connecting to \(destination)…"
        Task { @MainActor in
            defer { hostActivity[peer.id] = nil }
            do {
                let probe = try await setup.probe()
                // Hashes the bundled host binary; keep it off the main thread.
                let install = await Task.detached { setup.decision(for: probe) }.value
                hostActivity[peer.id] = HostSSHSetupSheet.summary(install) + "…"
                let host = try await setup.install(probe, progress: { note in
                    Task { @MainActor in hostActivity[peer.id] = note + "…" }
                })
                hostActivity[peer.id] = "Restarting the host…"
                try await setup.start(host: host)
            } catch {
                peerError = "\(peer.name): " + HostSSHSetupSheet.describe(error, destination: destination)
            }
        }
    }

    private func readHostLog(_ peer: RemotePeer) {
        guard let destination = peer.sshDestination else { return }
        let setup = HostSSHSetup(destination: destination, bundleResources: HostSSHSetupSheet.bundleResources)
        peerError = nil
        hostActivity[peer.id] = "Reading the host log…"
        Task { @MainActor in
            defer { hostActivity[peer.id] = nil }
            do {
                let text = try await setup.log()
                hostLog = HostLog(name: peer.name, text: text)
            } catch {
                peerError = "\(peer.name): " + HostSSHSetupSheet.describe(error, destination: destination)
            }
        }
    }

    @ViewBuilder
    private func tailscaleGroup(_ tailscale: RemoteTailscaleStatus?) -> some View {
        let serving: Bool = if case .serving = state.remoteTailscaleServe { true } else { false }
        SettingsGroup(title: "Tailscale") {
            SettingsRow(name: "Status", desc: tailscaleStatusDescription(tailscale)) {
                Text(tailscale == nil ? "Not running" : "Connected")
                    .font(scale.meta.font(weight: .medium))
                    .foregroundColor(theme.color(tailscale == nil ? "warn" : "add"))
            }
            SettingsRow(
                name: "Serve over HTTPS",
                desc: "Runs tailscale serve while Alas is open so devices on your tailnet get an HTTPS address. Enables PWA install, the offline shell, and notifications."
            ) {
                AlasToggle(on: remoteBinding(\.tailscaleServe))
                    .disabled(tailscale?.httpsEnabled != true && !state.config.remote.tailscaleServe)
            }
            if case .failed(let reason) = state.remoteTailscaleServe {
                SettingsRow(name: "Can't serve", desc: reason + " Turn Serve over HTTPS off and on to retry.") {
                    Icon(name: "alert", size: 14, color: theme.color("warn"))
                }
            }
            if let error = state.remoteTailscaleError {
                SettingsRow(name: "Error", desc: error) {
                    Icon(name: "alert", size: 14, color: theme.color("warn"))
                }
            }
            SettingsRow(
                name: "Tailscale only",
                desc: "Stop listening on the local network; accept connections only through Tailscale Serve. Turns off Bonjour discovery."
            ) {
                AlasToggle(on: remoteBinding(\.tailscaleOnly)).disabled(!serving && !state.config.remote.tailscaleOnly)
            }
        }
    }

    private func tailscaleStatusDescription(_ tailscale: RemoteTailscaleStatus?) -> String {
        guard let tailscale else {
            return "Tailscale isn't installed, running, or logged in. Turn these off to listen on the local network again."
        }
        return tailscale.httpsEnabled
            ? "Connected as \(tailscale.dnsName) · HTTPS certificates enabled"
            : "Connected as \(tailscale.dnsName) · Enable HTTPS certificates in the Tailscale admin console to serve over HTTPS"
    }

    private func remoteBinding(_ keyPath: WritableKeyPath<AppConfig.Remote, Bool>) -> Binding<Bool> {
        Binding(
            get: { state.config.remote[keyPath: keyPath] },
            set: {
                state.config.remote[keyPath: keyPath] = $0
                state.saveConfig()
                state.syncRemoteServer()
                state.syncRemoteDiscovery()
            }
        )
    }

    private func addressLabel(_ address: RemoteAdvertisedAddress) -> String {
        switch address.kind {
        case .tailnet: return address.isSecure ? "Tailnet HTTPS" : "Tailnet"
        case .lan: return "LAN"
        case .localhost: return "Localhost"
        case .custom: return "Custom"
        }
    }

    private func addressDescription(_ address: RemoteAdvertisedAddress) -> String {
        if let interface = address.interfaceName {
            return "\(address.url) on \(interface)"
        }
        return address.url
    }

    private func pickerAddressLabel(_ address: RemoteAdvertisedAddress) -> String {
        let label = addressLabel(address)
        let matching = state.remoteAdvertisedAddresses.filter { addressLabel($0) == label }
        guard matching.count > 1 else { return label }

        if let interfaceName = address.interfaceName,
           matching.filter({ $0.interfaceName == interfaceName }).count == 1 {
            return "\(label) \(interfaceName)"
        }
        return "\(label) \(address.host)"
    }

    private func selectedAddressBinding() -> Binding<String> {
        Binding(
            get: { selectedAddress()?.id ?? "" },
            set: { id in
                guard let address = state.remoteAdvertisedAddresses.first(where: { $0.id == id }) else { return }
                chooseAddress(address)
            }
        )
    }

    private func copyAddress(_ url: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    /// What the paired Mac's agents may do here: nil when it can't be allowed,
    /// for a device that never proved its identity. Acts on the device the
    /// peer reaches this Mac with, or, for a host that paired here
    /// inbound-only and has none, on its record.
    private func agentAccess(of entry: PairedMacEntry) -> RemoteDeviceAgentAccess? {
        if let peer = entry.peer { return state.remotePeers.agentAccess(of: peer) }
        guard let device = entry.devices.first(where: PeerDelegationGate.isProven) else { return nil }
        return device.agentAccess
    }

    private func setAgentAccess(_ access: RemoteDeviceAgentAccess, of entry: PairedMacEntry) {
        if let peer = entry.peer {
            _ = state.remotePeers.setAgentAccess(access, peerId: peer.id)
            return
        }
        for device in entry.devices where access == .off || PeerDelegationGate.isProven(device) {
            _ = state.remotePairing.setAgentAccess(access, deviceId: device.id)
        }
    }

    private func agentAccessControl(for entry: PairedMacEntry) -> some View {
        let access = agentAccess(of: entry)
        return VStack(alignment: .leading, spacing: scale.space[1]) {
            HStack {
                Text("\(entry.name)'s agents on this Mac")
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-dim"))
                Spacer(minLength: scale.space[3])
                Picker("Agent access for \(entry.name)", selection: Binding(
                    get: { access ?? .off },
                    set: { setAgentAccess($0, of: entry) }
                )) {
                    Text("Off").tag(RemoteDeviceAgentAccess.off)
                    Text("Ask for approval").tag(RemoteDeviceAgentAccess.ask)
                    Text("Allow auto-run").tag(RemoteDeviceAgentAccess.autoRun)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 180)
                .disabled(access == nil)
            }
            if let note = access == nil ? "Pair again to allow this."
                : access == .autoRun ? "They can run commands here as you, without asking." : nil {
                Text(note)
                    .font(scale.caption.font(weight: .regular))
                    .foregroundColor(theme.color(access == .autoRun ? "warn" : "fg-faint"))
            }
        }
        .padding(.vertical, scale.space[1])
    }

    /// The release a headless host runs, and whether it is older than this app.
    nonisolated static func hostVersionNote(_ hostVersion: String?, appVersion: SemanticVersion) -> String? {
        guard let hostVersion else { return nil }
        let isOlder = SemanticVersion(parsing: hostVersion).map { $0 < appVersion } ?? false
        return " · alas-host \(hostVersion)" + (isOlder ? ", older than this Mac's Alas" : "")
    }

    private func peerStatus(_ peer: RemotePeer) -> String {
        let status: String
        switch state.remotePeers.states[peer.id] ?? .idle {
        case .online:
            status = "Online via \(peer.lastOrigin ?? peer.origins.first ?? "")"
                + (Self.hostVersionNote(state.remotePeers.hostVersions[peer.serverId], appVersion: BuildIdentity.current().version) ?? "")
        case .connecting: status = "Connecting…"
        case .offline: status = "Offline. Retrying."
        case .unauthorized: status = "This Mac's token was revoked there. Forget and pair again."
        case .incompatible(let version): status = "Needs a matching Alas version (protocol \(version))."
        case .identityMismatch:
            status = "A different Mac answered at that address. Forget this peer and pair again."
        case .identityUnproven:
            // Deliberately worded apart from "offline" and from "token
            // revoked": something IS answering as this peer, and it cannot
            // prove it holds the key this record was paired with.
            status = "That Mac couldn't prove it holds this peer's key. Forget this peer and pair again."
        case .idle: status = "Not connected"
        }
        guard !peer.isVerified else { return status }
        // Records paired before identity verification shipped. They still
        // connect, but nothing binds them to the Mac they name, so say so
        // rather than let them look the same as a verified peer.
        return status + " · Unverified pairing — forget and pair again to secure it."
    }

    private func addPeer() {
        isAddingPeer = true
        peerError = nil
        let link = peerLink
        Task { @MainActor in
            let error = await state.remotePeers.addPeer(link: link)
            isAddingPeer = false
            if let error {
                peerError = describe(error, viaLink: true)
            } else {
                peerLink = ""
            }
        }
    }

    private func nearbyDescription(_ instance: RemoteDiscoveredInstance) -> String {
        var parts: [String] = []
        if let model = instance.model { parts.append(String(ApprovalWire.displayName(model).prefix(200))) }
        if instance.protocolVersion != RemoteProtocolVersion.current {
            parts.append("Needs a matching Alas version (protocol \(instance.protocolVersion)).")
        }
        return parts.isEmpty ? "Found on this network" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func nearbyAction(_ instance: RemoteDiscoveredInstance) -> some View {
        if selectedNearbyId == instance.id, nearbyApprovalIsActive {
            Text("Pairing…")
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-dim"))
        } else if state.remotePeers.peers.contains(where: { $0.serverId == instance.id }) {
            Text("Paired")
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-dim"))
        } else if case .legacy(let instanceID, _) = state.nearbyApprovalState,
                  instanceID == instance.id, selectedNearbyId == instance.id {
            HStack(spacing: 8) {
                AlasField(text: $nearbyCode, placeholder: "Code shown on that Mac", monospaced: true)
                    .frame(width: 170)
                AlasButton(title: isAddingPeer ? "Pairing…" : "Pair", style: .subtle) {
                    pairNearby(instance)
                }
                .disabled(isAddingPeer || nearbyCode.trimmingCharacters(in: .whitespaces).isEmpty)
                AlasButton(title: "Cancel", style: .subtle) {
                    selectedNearbyId = nil
                    nearbyCode = ""
                    state.cancelNearbyApproval()
                }
                .disabled(isAddingPeer)
            }
        } else {
            AlasButton(title: "Pair", style: .subtle) {
                selectedNearbyId = instance.id
                selectedNearbyName = String(ApprovalWire.displayName(instance.name).prefix(200))
                nearbyCode = ""
                peerError = nil
                state.startNearbyApproval(instance)
            }
            .disabled(isAddingPeer || nearbyApprovalIsActive)
        }
    }

    private func pairNearby(_ instance: RemoteDiscoveredInstance) {
        guard case .legacy(let instanceID, _) = state.nearbyApprovalState,
              instanceID == instance.id else { return }
        isAddingPeer = true
        peerError = nil
        // Codes are minted uppercase; accept however the user typed it.
        let code = nearbyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        Task { @MainActor in
            defer { isAddingPeer = false }
            switch await state.pairLegacyNearby(instance, code: code) {
            case .paired:
                selectedNearbyId = nil
                nearbyCode = ""
            case .pairing(let error):
                peerError = describe(error, viaLink: false)
            case .failed:
                break
            case .cancelled:
                selectedNearbyId = nil
                nearbyCode = ""
            }
        }
    }

    private var nearbyApprovalIsActive: Bool {
        switch state.nearbyApprovalState {
        case .resolving, .waiting, .completing: true
        default: false
        }
    }

    @ViewBuilder private var nearbyApprovalStatus: some View {
        if state.nearbyApprovalState != .idle, selectedNearbyId != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(alignment: .top, spacing: 8) {
                    Text(nearbyApprovalMessage(now: context.date))
                        .font(scale.metaFont)
                        .foregroundStyle(theme.color("fg-dim"))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if nearbyApprovalIsActive {
                        AlasButton(title: "Cancel", style: .subtle) { state.cancelNearbyApproval() }
                            .accessibilityLabel("Cancel nearby pairing request")
                    }
                }
                .padding(scale.space[3])
            }
        }
    }

    private func nearbyApprovalMessage(now: Date) -> String {
        switch state.nearbyApprovalState {
        case .idle: return ""
        case .resolving: return "Connecting to \(selectedNearbyName)…"
        case .waiting(_, let expiresAt):
            let seconds = max(0, Int(ceil(expiresAt.timeIntervalSince(now))))
            return "Waiting for approval on \(selectedNearbyName)… \(seconds)s remaining."
        case .completing: return "Pairing with \(selectedNearbyName)…"
        case .legacy:
            return "Open Remote settings on \(selectedNearbyName), choose Show pairing QR, and paste its code here."
        case .paired: return "Paired with \(selectedNearbyName)."
        case .declined: return "\(selectedNearbyName) declined the request. Click Pair to try again."
        case .cancelled: return "Pairing request cancelled."
        case .expired: return "Pairing request expired. Click Pair to try again."
        case .failed(let failure):
            switch failure {
            case .resolution(.identityMismatch):
                return "A different Mac answered at that address. Refresh the nearby list and try again."
            case .resolution(.unreachable):
                return "Couldn't reach that Mac. Check its remote access settings and network, then click Pair to try again."
            case .pairing(let error): return describe(error, viaLink: false)
            case .approval(.throttled), .approval(.capacity):
                return "That Mac has too many pairing requests. Wait a moment, then click Pair to try again."
            case .approval(.disabled): return "Pairing approval is unavailable. Check remote access settings on both Macs."
            case .approval(.expired): return "Pairing request expired. Click Pair to try again."
            case .approval:
                return "Couldn't verify the pairing request. Click Pair to try again."
            }
        }
    }

    private func describe(_ error: RemotePeerManager.AddError, viaLink: Bool) -> String {
        switch error {
        case .invalidLink:
            return viaLink ? "That doesn't look like an Alas pairing link." : "Type the code shown under the pairing QR on the other Mac."
        case .expiredCode:
            return viaLink
                ? "That code expired. Tap Pair a device on the other Mac and copy a fresh link."
                : "That code wasn't accepted. Check it against the other Mac's screen — it refreshes every 45 seconds."
        case .originRejected:
            return "That Mac doesn't accept peers. Turn on Remote peers in its Advanced settings."
        case .approvalExpired:
            return "That pairing request expired. Click Pair to try again."
        case .approvalDisabled:
            return "Pairing approval is no longer available on that Mac."
        case .unreachable:
            return "Couldn't reach that Mac at any of its addresses."
        case .noLocalAddress:
            return "This Mac has no address the other Mac could reach it at. Check the addresses above in Remote settings."
        case .reciprocalPairingFailed:
            return "That Mac couldn't pair back to confirm pairing. Try again after checking it can reach this Mac at one of the addresses above."
        case .cancelled:
            return "Cancelled — that peer was forgotten while pairing was still in progress."
        case .identityUnproven:
            return "That Mac answered with a key it couldn't prove it holds. Nothing was paired."
        case .identityRebindRefused:
            return "You're already paired with that Mac under different key material, so nothing was changed. If it was reinstalled, forget the existing peer first, then pair again."
        case .scopeUnsupported:
            return "That Mac's Alas is too old to grant the limited access asked for. Update Alas there, then pair again."
        }
    }

    private func chooseAddress(_ address: RemoteAdvertisedAddress) {
        state.config.remote.preferredAdvertisedHost = address.host
        state.saveConfig()
        state.refreshRemoteAccessState()
    }

    private func pairingURL(port: UInt16) -> String {
        let selected = selectedAddress()
        return selected?.url ?? "http://localhost:\(port)"
    }

    private func pairingLink(code: String, port: UInt16) -> String {
        RemotePairingLink.build(
            base: pairingURL(port: port),
            code: code,
            addresses: state.remoteAdvertisedAddresses
        )
    }

    private func selectedAddress() -> RemoteAdvertisedAddress? {
        let addresses = state.remoteAdvertisedAddresses
        if let preferred = state.config.remote.preferredAdvertisedHost,
           let match = addresses.first(where: {
               RemoteNetwork.normalizedHost($0.host) == RemoteNetwork.normalizedHost(preferred)
           }) {
            return match
        }
        return addresses.first(where: \.isRecommended) ?? addresses.first
    }
}

private enum AddMacTab: Hashable {
    case nearby, link, ssh
}

private enum RemoteSheet: Hashable, Identifiable {
    case mac(String)
    case device(String)
    case addMac

    var id: Self { self }
}

private enum AfterSheet {
    case sshSetup
    case hostLog(RemotePeer)
    case updateHost(RemotePeer)
}

// MARK: - Paired Macs, phones and browsers

extension RemoteServerPane {
    /// Only while remote control is on. The outbound records live in the lazy
    /// peer manager, which nothing loads while it is off; listing a Mac from
    /// its inbound devices alone would describe it wrongly, and its Forget
    /// would leave the outbound record to reconnect once remote control is
    /// back on.
    private var pairedMacEntries: [PairedMacEntry] {
        guard state.config.remote.enabled else { return [] }
        return PairedMacEntry.entries(peers: state.remotePeers.peers, devices: state.remotePairing.devices)
    }

    @ViewBuilder fileprivate var pairedMacsGroup: some View {
        let entries = pairedMacEntries
        if state.config.remote.enabled {
            SettingsGroup(title: "Paired Macs") {
                if entries.isEmpty {
                    SettingsRow(name: "No Macs yet", desc: "Pair another Mac running Alas to open its worktrees from your sidebar.") {
                        EmptyView()
                    }
                }
                ForEach(entries) { entry in
                    RemoteEntryRow(
                        name: entry.name,
                        summary: entry.peer.flatMap { hostActivity[$0.id] } ?? summary(of: entry),
                        chips: chips(of: entry),
                        onEdit: { activeSheet = .mac(entry.id) }
                    ) {
                        PeerIconTile(icon: entry.icon, presenceToken: presence(of: entry).colorToken, side: 30)
                    }
                }
                if state.config.remote.enabled {
                    SettingsRow(name: "Add a Mac", desc: "Pick one nearby, paste its pairing link, or set one up over SSH.") {
                        AlasButton(title: "Add Mac…", icon: "plus", style: .normal) {
                            peerError = nil
                            addMacTab = state.config.remote.discoverable ? .nearby : .link
                            activeSheet = .addMac
                        }
                    }
                }
                if let peerError, activeSheet != .addMac {
                    errorText(peerError)
                }
            }
        }
    }

    @ViewBuilder fileprivate var phonesAndBrowsersGroup: some View {
        let devices = state.remotePairing.devices.filter { $0.kind != .alasInstance }
        let connected = state.remoteConnectedDeviceCounts()
        SettingsGroup(title: "Phones and browsers") {
            if devices.isEmpty {
                SettingsRow(
                    name: "None yet",
                    desc: state.config.remote.enabled
                        ? "Show the pairing QR above and scan it with a phone, or open its link in a browser."
                        : "Turn on remote control to pair a phone or a browser."
                ) {
                    EmptyView()
                }
            }
            ForEach(devices) { device in
                let live = connected[device.id] ?? 0
                RemoteEntryRow(
                    name: device.name,
                    summary: summary(of: device, live: live),
                    chips: device.kind == .browser && device.allowsTerminals ? [RemoteEntryChip(text: "Terminals", isWarning: true)] : [],
                    onEdit: { activeSheet = .device(device.id) }
                ) {
                    SymbolTile(symbol: Self.symbol(for: device), presenceToken: live > 0 ? "add" : nil, side: 30)
                }
            }
            if devices.count > 1 {
                SettingsRow(name: "All phones and browsers", desc: "Revoke every one and close its connection. Paired Macs keep theirs.") {
                    AlasButton(title: "Revoke All", style: .subtle, tint: theme.color("warn")) {
                        pairingCode = nil
                        for device in devices { state.revokeRemoteDevice(device.id) }
                    }
                }
            }
        }
    }

    private static func symbol(for device: RemoteDevice) -> String {
        switch device.kind {
        case .phone: "iphone"
        case .browser: "globe"
        case .alasInstance: "desktopcomputer"
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(scale.metaFont)
            .foregroundColor(theme.color("warn"))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, scale.space[2])
    }

    // MARK: Summaries

    private func presence(of entry: PairedMacEntry) -> PairedMacPresence {
        if let peer = entry.peer, !peer.isInboundOnly {
            return PairedMacPresence(state.remotePeers.states[peer.id], isVerified: peer.isVerified)
        }
        let connected = state.remoteConnectedDeviceCounts()
        return entry.devices.contains { (connected[$0.id] ?? 0) > 0 }
            ? PairedMacPresence(.online, isVerified: true)
            : PairedMacPresence(.idle, isVerified: true)
    }

    /// One line: state, then where and what it runs.
    private func summary(of entry: PairedMacEntry) -> String {
        var parts = [presence(of: entry).label]
        if let peer = entry.peer, !peer.isInboundOnly {
            if state.remotePeers.states[peer.id] == .online,
               let host = (peer.lastOrigin ?? peer.origins.first).flatMap({ URL(string: $0)?.host() }) {
                parts.append(host)
            }
            if let version = state.remotePeers.hostVersions[peer.serverId] { parts.append("alas-host \(version)") }
        } else {
            parts.append("Reaches this Mac only")
        }
        return parts.joined(separator: " · ")
    }

    private func chips(of entry: PairedMacEntry) -> [RemoteEntryChip] {
        var chips: [RemoteEntryChip] = []
        if let peer = entry.peer, hostIsOlder(peer) {
            chips.append(RemoteEntryChip(text: "Update available", isWarning: true))
        }
        switch agentAccess(of: entry) {
        case .ask: chips.append(RemoteEntryChip(text: "Agents: ask"))
        case .autoRun: chips.append(RemoteEntryChip(text: "Agents: auto-run", isWarning: true))
        case .off, nil: break
        }
        return chips
    }

    private func hostIsOlder(_ peer: RemotePeer) -> Bool {
        guard let version = state.remotePeers.hostVersions[peer.serverId],
              let host = SemanticVersion(parsing: version) else { return false }
        return host < BuildIdentity.current().version
    }

    private func summary(of device: RemoteDevice, live: Int) -> String {
        var parts = [device.kind == .phone ? "iPhone app" : "Browser"]
        if live > 0 {
            parts.append(live == 1 ? "Connected now" : "Connected now (\(live))")
        } else if let seen = device.lastSeenAt {
            parts.append("Last seen \(seen.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("Never connected")
        }
        if device.pushRelay != nil { parts.append("Notifications on") }
        return parts.joined(separator: " · ")
    }

    /// Which way the pairing goes, in words.
    private func direction(of entry: PairedMacEntry) -> String {
        if entry.isPairedBothWays { return "Both ways" }
        if entry.peer.map({ !$0.isInboundOnly }) == true { return "This Mac reaches it; it can't reach this Mac" }
        return "It reaches this Mac; this Mac doesn't reach it"
    }

    // MARK: Sheets

    fileprivate func pairedMacSheet(_ entry: PairedMacEntry) -> some View {
        let peer = entry.peer.flatMap { $0.isInboundOnly ? nil : $0 }
        return RemoteEntrySheet(
            title: entry.name,
            subtitle: peer.map(peerStatus) ?? presence(of: entry).label,
            destructiveTitle: "Forget \(entry.name)…",
            onDestructive: { confirmingForget = true },
            onDone: { activeSheet = nil }
        ) {
            if let peer {
                PeerIconTileButton(
                    icon: entry.icon, presenceToken: presence(of: entry).colorToken, side: 40,
                    peerName: entry.name, isOverridden: peer.iconOverride != nil,
                    onPick: { state.remotePeers.setIconOverride($0, peerId: peer.id) }
                )
            } else {
                PeerIconTile(icon: entry.icon, presenceToken: presence(of: entry).colorToken, side: 40)
            }
        } content: {
            RemoteEntrySheetSection(title: "Connection") {
                if let peer {
                    RemoteEntryFact(
                        label: peer.origins.count > 1 ? "Addresses" : "Address",
                        value: peer.origins.isEmpty ? "None" : peer.origins.joined(separator: "\n")
                    )
                    if let version = state.remotePeers.hostVersions[peer.serverId] {
                        RemoteEntryFact(label: "Host", value: "alas-host \(version)" + (hostIsOlder(peer) ? ", older than this Mac's Alas" : ""))
                    }
                    RemoteEntryFact(label: "Identity", value: peer.isVerified ? "Key verified" : "Unverified. Forget and pair again to secure it.")
                    RemoteEntryFact(label: "Paired", value: peer.addedAt.formatted(date: .abbreviated, time: .omitted))
                }
                RemoteEntryFact(label: "Direction", value: direction(of: entry))
                if let seen = entry.lastSeenAt {
                    RemoteEntryFact(label: "Last here", value: seen.formatted(.relative(presentation: .named)))
                }
            }
            RemoteEntrySheetSection(title: "Access") {
                agentAccessControl(for: entry)
            }
            if let peer, peer.sshDestination != nil || updatesOverPeer(peer) {
                RemoteEntrySheetSection(title: "Host") {
                    HStack(spacing: scale.space[2]) {
                        AlasButton(title: "Update Host…", style: .normal) {
                            afterSheet = .updateHost(peer)
                            activeSheet = nil
                        }
                        if peer.sshDestination != nil {
                            AlasButton(title: "View Log", style: .subtle) {
                                afterSheet = .hostLog(peer)
                                activeSheet = nil
                            }
                        }
                    }
                    .disabled(hostActivity[peer.id] != nil)
                    .padding(.top, scale.space[1])
                }
            }
        }
        .alert("Forget \(entry.name)?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { forget(entry) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac stops connecting to it, and it can no longer reach this Mac. Pair again to undo.")
        }
    }

    private func forget(_ entry: PairedMacEntry) {
        activeSheet = nil
        if let peer = entry.peer { state.remotePeers.forget(peerId: peer.id) }
        for device in entry.devices where state.remotePairing.device(id: device.id) != nil {
            state.revokeRemoteDevice(device.id)
        }
    }

    fileprivate func deviceSheet(_ device: RemoteDevice) -> some View {
        let live = state.remoteConnectedDeviceCounts()[device.id] ?? 0
        return RemoteEntrySheet(
            title: device.name,
            subtitle: summary(of: device, live: live),
            destructiveTitle: "Revoke",
            onDestructive: {
                activeSheet = nil
                state.revokeRemoteDevice(device.id)
            },
            onDone: { activeSheet = nil }
        ) {
            SymbolTile(symbol: Self.symbol(for: device), presenceToken: live > 0 ? "add" : nil, side: 40)
        } content: {
            RemoteEntrySheetSection(title: "Details") {
                RemoteEntryFact(label: "Kind", value: device.kind == .phone ? "Alas for iPhone" : "Web client in a browser")
                RemoteEntryFact(label: "Paired", value: device.createdAt.formatted(date: .abbreviated, time: .omitted))
                RemoteEntryFact(label: "Notifications", value: device.pushRelay != nil ? "On" : "Off")
            }
            if device.kind == .browser {
                RemoteEntrySheetSection(title: "Access") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow terminals").font(scale.metaFont)
                            Text("Lets this browser open shells here. Only for a browser you trust.")
                                .font(scale.caption.font(weight: .regular))
                                .foregroundColor(theme.color("fg-faint"))
                        }
                        Spacer(minLength: scale.space[3])
                        AlasToggle(on: Binding(
                            get: { device.allowsTerminals },
                            set: { state.remotePairing.setAllowsTerminals($0, deviceId: device.id) }
                        ))
                    }
                    .padding(.vertical, scale.space[1])
                }
            }
        }
    }

    fileprivate var addMacSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a Mac")
                .font(.system(size: 15, weight: .semibold)) // design-literal: the one dialog title
                .padding(.bottom, scale.space[3])
            AlasSegmentedControl(
                selection: addMacTab,
                options: [
                    AlasSegmentedOption(id: AddMacTab.nearby, label: "Nearby"),
                    AlasSegmentedOption(id: AddMacTab.link, label: "Pairing link"),
                    AlasSegmentedOption(id: AddMacTab.ssh, label: "Over SSH"),
                ],
                onSelect: { addMacTab = $0 }
            )
            .padding(.bottom, scale.space[3])
            switch addMacTab {
            case .nearby: nearbyTab
            case .link: linkTab
            case .ssh: sshTab
            }
            if let peerError {
                errorText(peerError)
            }
            HStack {
                Spacer(minLength: 0)
                AlasButton(title: "Done", style: .primary) { activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, scale.space[4])
        }
        .padding(scale.space[5])
        .frame(width: 520)
        .background(theme.color("bg-1"))
        .onDisappear { state.cancelNearbyApproval() }
    }

    @ViewBuilder private var nearbyTab: some View {
        if state.config.remote.discoverable {
            let nearby = state.remotePeerBrowser.instances
            VStack(alignment: .leading, spacing: 0) {
                if nearby.isEmpty {
                    dimNote(state.remotePeerBrowser.lastError.map { "Can't browse the local network: \($0)" }
                            ?? "Looking for other Macs running Alas on this network…")
                }
                ForEach(nearby) { instance in
                    SettingsRow(name: String(ApprovalWire.displayName(instance.name).prefix(200)), icon: instance.icon ?? .laptop,
                                desc: nearbyDescription(instance)) {
                        nearbyAction(instance)
                    }
                }
                nearbyApprovalStatus
                dimNote("The other Mac shows a request to accept. It needs Discoverable on too.")
            }
            .task {
                // Browse only while this tab is on screen.
                state.remotePeerBrowser.start()
                defer { state.remotePeerBrowser.stop() }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        } else {
            dimNote("Turn on Discoverable to list other Macs running Alas on this network, and to let them find this one.")
            AlasButton(title: "Turn On Discoverable", style: .normal) {
                state.config.remote.discoverable = true
                state.saveConfig()
                state.syncRemoteDiscovery()
            }
            .padding(.top, scale.space[2])
        }
    }

    @ViewBuilder private var linkTab: some View {
        dimNote("On the other Mac, open Remote settings, choose Show pairing QR and copy its link. Paste it here.")
        HStack(spacing: scale.space[2]) {
            AlasField(text: $peerLink, placeholder: "http://…/?code=…&hosts=…", onSubmit: addPeer)
            AlasButton(title: isAddingPeer ? "Adding…" : "Add", style: .normal, action: addPeer)
                .disabled(isAddingPeer || peerLink.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, scale.space[2])
    }

    @ViewBuilder private var sshTab: some View {
        dimNote("Installs alas-host on a Mac this Mac can reach with key-based SSH, starts it at login, and pairs with it.")
        AlasButton(title: "Set Up…", style: .normal) {
            peerError = nil
            afterSheet = .sshSetup
            activeSheet = nil
        }
        .padding(.top, scale.space[2])
    }

    private func dimNote(_ text: String) -> some View {
        Text(text)
            .font(scale.metaFont)
            .foregroundColor(theme.color("fg-dim"))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, scale.space[1])
    }

    fileprivate func runAfterSheet() {
        guard let action = afterSheet else { return }
        afterSheet = nil
        switch action {
        case .sshSetup: showingHostSSHSetup = true
        case .hostLog(let peer): readHostLog(peer)
        case .updateHost(let peer): confirmingHostUpdate = peer
        }
    }

    /// Opens the sheet of the Mac a sidebar page asked for.
    fileprivate func openPendingMac() {
        guard let serverId = state.pendingPairedMacServerId else { return }
        state.pendingPairedMacServerId = nil
        if let entry = pairedMacEntries.first(where: { $0.serverId == serverId }) {
            activeSheet = .mac(entry.id)
        }
    }
}

/// Renders a QR code for arbitrary text using CoreImage, scaled up with
/// nearest-neighbor so the small generated bitmap stays crisp.
struct QRView: View {
    let text: String
    private static let context = CIContext()

    var body: some View {
        if let image = Self.makeImage(from: text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
        } else {
            Color.clear
        }
    }

    private static func makeImage(from text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scale: CGFloat = 12
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
