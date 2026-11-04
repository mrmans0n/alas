import AlasCore
import SwiftUI

/// The right pane's Device tab: pick, boot and use an iOS simulator.
struct DeviceTabView: View {
    @Bindable var model: DevicePaneModel
    let client: SimulatorStreamClient
    @Environment(\.theme) private var theme
    @State private var streamError: String?
    @State private var streamGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
            if let bootError = model.bootError {
                message(bootError, tone: "warn")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.pollWhileVisible() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .unavailable(let error):
            message("iOS simulators need Xcode. Install it, or select it with `sudo xcode-select -s /Applications/Xcode.app`.")
            message(error, tone: "fg-dim")
        case .noDevices:
            message("No iOS simulators. Create one in Xcode under Window › Devices and Simulators.")
        case .choose:
            picker(title: "Choose a simulator")
        case .shutDown(let device):
            picker(title: device.name)
            AlasButton(title: "Boot", icon: "power", style: .primary) {
                Task { await model.boot(device) }
            }
        case .booting(let device):
            picker(title: device.name)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                message("Booting…", tone: "fg-dim")
            }
        case .streaming(let device):
            picker(title: device.name)
            screen(device)
        }
    }

    private func picker(title: String) -> some View {
        Menu(title) {
            ForEach(model.devices ?? []) { device in
                Button("\(device.name) · \(device.runtimeName)\(device.state == .booted ? " · Booted" : "")") {
                    model.selectedUDID = device.udid
                    streamError = nil
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func screen(_ device: SimulatorDevice) -> some View {
        VStack(spacing: 8) {
            ZStack {
                DeviceScreenView(udid: device.udid, client: client, onStopped: { streamError = $0 })
                    // A new identity unsubscribes and subscribes again, which restarts the stream.
                    .id("\(device.udid):\(streamGeneration)")
                if let streamError {
                    VStack(spacing: 8) {
                        message(streamError)
                        AlasButton(title: "Retry", style: .normal) {
                            self.streamError = nil
                            streamGeneration += 1
                        }
                    }
                    .padding(12)
                    .background(theme.color("field-bg"), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            AlasButton(title: "Home", icon: "house", style: .normal, compact: true) {
                client.button(udid: device.udid, name: "home")
            }
        }
    }

    private func message(_ text: String, tone: String = "fg") -> some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 12))
            .foregroundStyle(theme.color(tone))
            .fixedSize(horizontal: false, vertical: true)
    }
}
