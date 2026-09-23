import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct RemoteServerPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    @State private var pairingCode: String?
    @State private var peerLink = ""
    @State private var peerError: String?
    @State private var isAddingPeer = false
    /// The nearby instance selected for approval or legacy code entry.
    @State private var selectedNearbyId: String?
    @State private var selectedNearbyName = ""
    @State private var nearbyCode = ""
    /// Rotates the displayed pairing code well within its 120s TTL so the QR on
    /// screen is never stale. Prior codes stay valid until they expire, so a
    /// device that scanned just before a rotation still pairs.
    private let rotateTimer = Timer.publish(every: 45, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Remote").font(.system(size: 18, weight: .semibold))
                Text("Watch sessions and answer permission prompts from another device.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Remote access") {
                    SettingsRow(
                        name: "Enable remote control",
                        desc: "Serve a web client on your network so you can watch sessions and answer permission prompts from your phone. Off by default. Only enable on trusted networks; use Tailscale for access away from home."
                    ) {
                        AlasToggle(on: Binding(
                            get: { state.config.remote.enabled },
                            set: {
                                state.config.remote.enabled = $0
                                state.saveConfig()
                                state.syncRemoteServer()
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
                                        .font(.system(size: 12, weight: .medium))
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
                                        .font(.system(size: 12, weight: .medium))
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
                                .font(.system(size: 14))
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
                        if state.config.remote.federationEnabled {
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
                                .padding(.top, 8)
                            if state.config.remote.federationEnabled {
                                Text(code)
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(.top, 6)
                                AlasButton(title: "Copy code", style: .subtle) {
                                    copyAddress(code)
                                }
                                .padding(.top, 6)
                            }
                            AlasButton(title: "Copy pairing link", style: .subtle) {
                                copyAddress(link)
                            }
                            .padding(.top, 6)
                            Text(state.config.remote.federationEnabled
                                 ? "Refreshes automatically — scan it, paste the copied link into Alas remote on another device, or type the code into a nearby Mac's Peers list."
                                 : "Refreshes automatically — scan it, or paste the copied link into Alas remote on another device to add this Mac.")
                                .font(.system(size: 11))
                                .foregroundColor(theme.color("fg-dim"))
                                .padding(.bottom, 8)
                        }
                    }
                }

                SettingsGroup(title: "Paired devices") {
                    if state.remotePairing.devices.isEmpty {
                        SettingsRow(name: "No devices", desc: "Pair a device to see it here.") {
                            EmptyView()
                        }
                    } else {
                        let connected = state.remoteConnectedDeviceCounts()
                        ForEach(state.remotePairing.devices) { device in
                            let liveCount = connected[device.id] ?? 0
                            let seen = device.lastSeenAt.map { "Last seen \($0.formatted())" } ?? "Never connected"
                            let desc = liveCount > 0 ? "Connected now (\(liveCount)); \(seen)" : seen
                            let prefix = device.kind == .alasInstance ? "Alas peer. " : ""
                            SettingsRow(
                                name: device.name,
                                desc: prefix + desc
                            ) {
                                Button {
                                    state.revokeRemoteDevice(device.id)
                                } label: {
                                    Text("Revoke")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(theme.color("warn"))
                                        .padding(.horizontal, 12)
                                        .frame(height: 28)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(theme.color("warn").opacity(0.4), lineWidth: 0.5)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        SettingsRow(
                            name: "All devices",
                            desc: "Revoke every paired browser and close active remote sockets."
                        ) {
                            Button {
                                pairingCode = nil
                                state.revokeAllRemoteDevices()
                            } label: {
                                Text("Revoke All")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.color("warn"))
                                    .padding(.horizontal, 12)
                                    .frame(height: 28)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(theme.color("warn").opacity(0.4), lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if state.config.remote.enabled, state.config.remote.federationEnabled {
                    SettingsGroup(title: "Peers") {
                        if state.remotePeers.peers.isEmpty {
                            SettingsRow(name: "No peers", desc: "Pick a nearby Mac or paste another Mac's pairing link below. Both Macs end up paired with each other.") {
                                EmptyView()
                            }
                        }
                        ForEach(state.remotePeers.peers) { peer in
                            SettingsRow(name: peer.name, desc: peerStatus(peer)) {
                                AlasButton(title: "Forget", style: .subtle) {
                                    state.remotePeers.forget(peerId: peer.id)
                                }
                            }
                        }
                        if state.config.remote.discoverable {
                            let nearby = state.remotePeerBrowser.instances
                            if nearby.isEmpty {
                                SettingsRow(name: "Nearby", desc: state.remotePeerBrowser.lastError.map { "Can't browse the local network: \($0)" }
                                            ?? "Looking for other Macs running Alas on this network…") {
                                    EmptyView()
                                }
                            }
                            ForEach(nearby) { instance in
                                SettingsRow(name: String(ApprovalWire.displayName(instance.name).prefix(200)), desc: nearbyDescription(instance)) {
                                    nearbyAction(instance)
                                }
                            }
                        } else {
                            SettingsRow(name: "Nearby", desc: "Turn on Discoverable on this network above to see other Macs running Alas.") {
                                EmptyView()
                            }
                        }
                        nearbyApprovalStatus
                        SettingsRow(name: "Add peer", desc: "Copy the pairing link from the other Mac's Remote settings and paste it here.") {
                            HStack(spacing: 8) {
                                AlasField(text: $peerLink, placeholder: "http://…/?code=…&hosts=…")
                                    .frame(minWidth: 260)
                                AlasButton(title: isAddingPeer ? "Adding…" : "Add", style: .subtle) {
                                    addPeer()
                                }
                                .disabled(isAddingPeer || peerLink.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        if let peerError {
                            Text(peerError)
                                .font(.system(size: 11))
                                .foregroundColor(theme.color("warn"))
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                        }
                    }
                    .task(id: state.config.remote.discoverable) {
                        // Browse only while this section is on screen and discovery is on;
                        // leaving the pane or turning the toggle off cancels this task.
                        guard state.config.remote.discoverable else {
                            state.remotePeerBrowser.stop()
                            return
                        }
                        state.remotePeerBrowser.start()
                        defer { state.remotePeerBrowser.stop() }
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(60))
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .onChange(of: state.config.remote.enabled) { _, enabled in
            if !enabled { pairingCode = nil }   // don't show a stale code after re-enabling
        }
        .onReceive(rotateTimer) { _ in
            // While a QR is on screen, keep it fresh by minting a new code.
            if pairingCode != nil { pairingCode = state.remotePairing.beginPairing() }
        }
        .onDisappear { state.cancelNearbyApproval() }
    }

    private func addressLabel(_ address: RemoteAdvertisedAddress) -> String {
        switch address.kind {
        case .tailnet: return "Tailnet"
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

    private func peerStatus(_ peer: RemotePeer) -> String {
        let status: String
        switch state.remotePeers.states[peer.id] ?? .idle {
        case .online: status = "Online via \(peer.lastOrigin ?? peer.origins.first ?? "")"
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
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
        } else if state.remotePeers.peers.contains(where: { $0.serverId == instance.id }) {
            Text("Paired")
                .font(.system(size: 12))
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
        guard case .legacy(let instanceID, let origins) = state.nearbyApprovalState,
              instanceID == instance.id else { return }
        isAddingPeer = true
        peerError = nil
        // Codes are minted uppercase; accept however the user typed it.
        let code = nearbyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        Task { @MainActor in
            defer { isAddingPeer = false }
            if let error = await state.remotePeers.addPeer(code: code, origins: origins) {
                peerError = describe(error, viaLink: false)
            } else {
                selectedNearbyId = nil
                nearbyCode = ""
                state.cancelNearbyApproval()
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
                        .font(.system(size: 12))
                        .foregroundStyle(theme.color("fg-dim"))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if nearbyApprovalIsActive {
                        AlasButton(title: "Cancel", style: .subtle) { state.cancelNearbyApproval() }
                            .accessibilityLabel("Cancel nearby pairing request")
                    }
                }
                .padding(12)
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
