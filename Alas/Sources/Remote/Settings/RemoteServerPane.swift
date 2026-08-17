import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct RemoteServerPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    @State private var pairingCode: String?
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
                        SettingsRow(name: "Pair a device", desc: "Show a QR code to pair a new phone or tablet.") {
                            AlasButton(
                                title: pairingCode == nil ? "Show pairing QR" : "New code",
                                style: .subtle
                            ) {
                                pairingCode = state.remotePairing.beginPairing()
                            }
                        }
                        if let code = pairingCode {
                            QRView(text: "\(pairingURL(port: port))/?code=\(code)")
                                .frame(width: 180, height: 180)
                                .padding(.top, 8)
                            Text("Refreshes automatically — scan anytime.")
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
                            SettingsRow(
                                name: device.name,
                                desc: desc
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

    private func chooseAddress(_ address: RemoteAdvertisedAddress) {
        state.config.remote.preferredAdvertisedHost = address.host
        state.saveConfig()
        state.refreshRemoteAccessState()
    }

    private func pairingURL(port: UInt16) -> String {
        let selected = selectedAddress()
        return selected?.url ?? "http://localhost:\(port)"
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
