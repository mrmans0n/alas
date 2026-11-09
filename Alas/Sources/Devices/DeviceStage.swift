import AlasCore
import SwiftUI

/// A booted simulator's screen, framed at its real shape, with the hardware
/// buttons in a gutter on the right and who drives it on top.
struct DeviceStage: View {
    let device: SimulatorDevice
    let shape: DeviceScreenShape?
    let client: SimulatorStreamClient
    let control: DeviceAgentControl
    /// Names the agent session driving the device.
    let agentName: (String) -> String
    let now: Date
    @Environment(\.theme) private var theme
    @State private var streamError: String?
    @State private var streamGeneration = 0
    @State private var pulse = false

    private static let margin: CGFloat = 12
    private static let gutter: CGFloat = 44
    private static let bezel: CGFloat = 4

    var body: some View {
        let driver = control.driver(udid: device.udid, at: now)
        let allowsInput = VMDriver.allowsViewInput(driver)
        GeometryReader { geometry in
            let area = CGSize(
                width: max(0, geometry.size.width - Self.margin * 2 - Self.gutter - Self.bezel * 2),
                height: max(0, geometry.size.height - Self.margin * 2 - Self.bezel * 2)
            )
            let size = Self.fit(shape, in: area)
            let radius = shape?.cornerRadius(forFittedWidth: size.width) ?? 0
            HStack(spacing: 0) {
                screen(allowsInput: allowsInput, driver: driver)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .padding(Self.bezel)
                    .background(
                        RoundedRectangle(cornerRadius: radius + Self.bezel, style: .continuous)
                            .fill(Color(white: 0.067))
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls(enabled: allowsInput)
                    .frame(width: Self.gutter)
            }
            .padding(Self.margin)
        }
    }

    /// The largest size of the screen's shape that fits `area`; all of it without a shape.
    private static func fit(_ shape: DeviceScreenShape?, in area: CGSize) -> CGSize {
        guard let shape, shape.widthPoints > 0, shape.heightPoints > 0 else { return area }
        let scale = min(area.width / shape.widthPoints, area.height / shape.heightPoints)
        return CGSize(width: shape.widthPoints * scale, height: shape.heightPoints * scale)
    }

    private func screen(allowsInput: Bool, driver: VMDriver) -> some View {
        ZStack(alignment: .top) {
            DeviceScreenView(
                udid: device.udid, client: client, onStopped: { streamError = $0 },
                allowsInput: allowsInput, onBlockedClick: pulsePill
            )
            // A new identity unsubscribes and subscribes again, which restarts the stream.
            .id("\(device.udid):\(streamGeneration)")
            if let streamError {
                theme.color("bg-2").opacity(0.92)
                DevicesEmptyState(
                    symbol: "exclamationmark.triangle", title: "The screen stopped", detail: streamError,
                    action: .init(title: "Retry", icon: "arrow.clockwise") {
                        self.streamError = nil
                        streamGeneration += 1
                    }
                )
            } else if driver != .idle {
                driverPill(driver)
                    .padding(.top, 8)
            }
        }
    }

    private func driverPill(_ driver: VMDriver) -> some View {
        HStack(spacing: 6) {
            switch driver {
            case .agent(let sessionID, _, _):
                Circle().fill(theme.color(DevicesSwitcher.colorToken(.busy))).frame(width: 6, height: 6)
                Text("\(agentName(sessionID)) is driving")
                    .foregroundStyle(theme.color("fg"))
                Button("Take over") { control.takeOver(udid: device.udid) }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.color("accent"))
            case .user, .idle:
                Text("You're driving")
                    .foregroundStyle(theme.color("fg"))
                if let waiting = control.waitingSessions(udid: device.udid).first {
                    Text("· \(agentName(waiting)) is waiting")
                        .foregroundStyle(theme.color("fg-dim"))
                }
                Button("Hand back") { control.handBack(udid: device.udid) }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.color("accent"))
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.ultraThinMaterial, in: Capsule())
        .background(theme.color("bg-2").opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.color("line"), lineWidth: 0.5))
        .scaleEffect(pulse ? 1.06 : 1)
        .animation(.easeOut(duration: 0.2), value: pulse)
    }

    /// A click while an agent drives: draw the eye to Take over.
    private func pulsePill() {
        pulse = true
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            pulse = false
        }
    }

    private func controls(enabled: Bool) -> some View {
        VStack(spacing: 2) {
            hardwareButton("house", help: "Home", name: "home")
            hardwareButton("square.stack", help: "App switcher", name: "app_switcher")
            hardwareButton("lock", help: "Lock", name: "lock")
            hardwareButton("mic", help: "Siri", name: "siri")
        }
        .padding(4)
        .background(theme.color("bg-2"), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.color("line"), lineWidth: 0.5))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .frame(maxHeight: .infinity)
    }

    private func hardwareButton(_ symbol: String, help: String, name: String) -> some View {
        ToolbarBtn(
            icon: symbol, tooltip: help, metrics: ToolbarControlMetrics(width: 28, height: 28, cornerRadius: 14)
        ) {
            client.button(udid: device.udid, name: name)
        }
    }
}
