import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct RemoteServerPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    @State private var pairingCode: String?

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

                    if state.config.remote.enabled, let port = state.remoteServer?.port {
                        SettingsRow(name: "Address", desc: "Reachable at this address on your LAN/tailnet.") {
                            Text(Self.reachableURL(port: port))
                                .font(.system(size: 12.5, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundColor(theme.color("fg"))
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
                            QRView(text: "\(Self.reachableURL(port: port))/?code=\(code)")
                                .frame(width: 180, height: 180)
                                .padding(.vertical, 8)
                        }
                    }
                }

                SettingsGroup(title: "Paired devices") {
                    if state.remotePairing.devices.isEmpty {
                        SettingsRow(name: "No devices", desc: "Pair a device to see it here.") {
                            EmptyView()
                        }
                    } else {
                        ForEach(state.remotePairing.devices) { device in
                            SettingsRow(
                                name: device.name,
                                desc: device.lastSeenAt.map { "Last seen \($0.formatted())" } ?? "Never connected"
                            ) {
                                Button {
                                    state.remotePairing.revoke(deviceId: device.id)
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
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }

    private static func reachableURL(port: UInt16) -> String {
        "http://\(LocalNetwork.primaryIPv4() ?? "localhost"):\(port)"
    }
}

/// Renders a QR code for arbitrary text using CoreImage, scaled up with
/// nearest-neighbor so the small generated bitmap stays crisp.
struct QRView: View {
    let text: String

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

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

/// Local network introspection for the reachable-address hint.
enum LocalNetwork {
    /// Returns the first non-loopback IPv4 address, preferring `en*`/`utun*`
    /// interfaces. Returns nil if none can be determined.
    static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var preferred: String?
        var fallback: String?

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty else { continue }

            if name.hasPrefix("en") || name.hasPrefix("utun") {
                if preferred == nil { preferred = ip }
            } else if fallback == nil {
                fallback = ip
            }
        }
        return preferred ?? fallback
    }
}
