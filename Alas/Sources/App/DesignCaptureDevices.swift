#if DEBUG
import AlasCore
import AppKit
import IOSurface
import SwiftUI

/// Design-capture targets for the Devices tab. The real tab lists the Mac's simulators through
/// `simctl`, streams a booted one over XPC and reads VM state from the VM manager, none of which a
/// capture may touch. Each target draws a gallery of tab states in a panel over the main window,
/// from the tab's own views (`DevicesSwitcher`, `DevicesActions`, `DeviceStage`, `VMDeviceCard`,
/// `DevicesEmptyState`, `DeviceSettingsPopover`) and the same `DevicesTabState` resolver, over
/// scripted devices and an in-memory `DeviceAgentControl`. A scripted simulator's screen is a
/// painted placeholder (`DesignCaptureDevices.demoScreen`); no frame is streamed, no simulator is
/// booted, no VM is read. Debug builds only, and only on a capture profile.
///
/// - devices: a simulator an agent drives while an app launches, one you drive with an agent
///   waiting and a failed app install, a running macOS VM an agent drives, a paused Linux VM.
/// - devices-empty: loading, no Xcode, no simulators, a shut-down simulator with a boot error,
///   booting, a VM that is not set up.
/// - devices-settings: the simulator settings popover over scripted values.
@MainActor
enum DesignCaptureDevices {
    static let targets: Set<String> = ["devices", "devices-empty", "devices-settings"]

    /// A scripted simulator's UDID starts with this; no real one does.
    static let demoUDIDPrefix = "DEMO-SIM-"

    static func isDemoUDID(_ udid: String) -> Bool {
        DesignCaptureWorkspace.isCaptureInstance && udid.hasPrefix(demoUDIDPrefix)
    }

    private static let phone = SimulatorDevice(
        udid: demoUDIDPrefix + "PHONE", name: "iPhone 17 Pro", runtimeName: "iOS 26.5", state: .booted,
        deviceTypeIdentifier: "demo.phone")
    private static let air = SimulatorDevice(
        udid: demoUDIDPrefix + "AIR", name: "iPhone Air", runtimeName: "iOS 26.5", state: .shutdown,
        deviceTypeIdentifier: "demo.phone")
    private static let pad = SimulatorDevice(
        udid: demoUDIDPrefix + "PAD", name: "iPad Pro 13-inch (M5)", runtimeName: "iOS 26.5", state: .shutdown,
        deviceTypeIdentifier: "demo.pad")
    private static let shape = DeviceScreenShape(widthPoints: 402, heightPoints: 874, cornerRadiusPoints: 62)

    static func open(_ target: String, state: AppState) {
        guard DesignCaptureWorkspace.isCaptureInstance, targets.contains(target) else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while state.projects.isEmpty {
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            let theme = state.themeStore.current
            let scale = DesignScale.resolved(for: state.config.density)
            if target == "devices-settings" {
                let popover = SettingsPanel(control: makeControl())
                    .environment(\.theme, theme).environment(\.designScale, scale)
                DesignCaptureWorkspace.present(popover)
                return
            }
            let control = makeControl()
            var cells: [Cell] = []
            if target == "devices" {
                cells = await driverCells(control: control)
            } else {
                cells = emptyCells()
            }
            let gallery = Gallery(cells: cells, columns: target == "devices" ? 4 : 3)
                .environment(\.theme, theme).environment(\.designScale, scale)
            DesignCaptureWorkspace.present(gallery)
        }
    }

    // MARK: - Scripted collaborators

    @MainActor
    private final class FakeInput: DeviceInput {
        func subscribe(
            udid: String, onFrame: @escaping @MainActor (IOSurface) -> Void, onStop: @escaping @MainActor (String) -> Void
        ) -> UUID { UUID() }
        func unsubscribe(udid: String, token: UUID) {}
        func touch(udid: String, phase: String, point: DeviceScreenPoint) {}
        func key(udid: String, usage: UInt32, down: Bool) {}
        func button(udid: String, name: String) {}
        func describe(udid: String) async throws -> Data { Data() }
        func lastFrame(udid: String) -> IOSurface? { nil }
    }

    private struct FakeSettings: SimulatorSettingsControl {
        private static let display = SimulatorDisplaySettings(
            appearance: .value(.dark), textSize: .value(.large), increaseContrast: .value(false))
        func display(udid: String) async throws -> SimulatorDisplaySettings { Self.display }
        func setDisplay(
            udid: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?
        ) async throws -> SimulatorDisplaySettings { Self.display }
        func setPermission(udid: String, bundleID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws {}
        func setLocation(udid: String, _ location: SimulatorLocation?) async throws {}
        func push(udid: String, bundleID: String, payload: Data) async throws {}
        func openURL(udid: String, url: String) async throws {}
        func userApps(udid: String) async throws -> [SimulatorApp] {
            [SimulatorApp(bundleID: "io.example.lantern", name: "Lantern"), SimulatorApp(bundleID: "io.example.lantern.beta", name: "Lantern Beta")]
        }
        func isInstalled(udid: String, bundleID: String) async -> Bool { true }
    }

    private static func makeControl() -> DeviceAgentControl {
        DeviceAgentControl(
            input: FakeInput(), devices: { [phone, air, pad] }, boot: { _ in }, install: { _, _ in },
            launch: { _, _ in 0 }, settings: FakeSettings())
    }

    // MARK: - Gallery

    private struct Cell: Identifiable {
        let id = UUID()
        let label: String
        let content: AnyView
        init(_ label: String, _ content: some View) {
            self.label = label
            self.content = AnyView(content)
        }
    }

    private struct Gallery: View {
        let cells: [Cell]
        let columns: Int
        @Environment(\.theme) private var theme

        var body: some View {
            let rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
            VStack(spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 12) { ForEach(row) { cell($0) } }
                }
            }
            .padding(14)
            .background(theme.color("bg-0"))
        }

        private func cell(_ cell: Cell) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(cell.label)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                VStack(spacing: 0) { cell.content }
                    .frame(width: columns == 4 ? 340 : 360, height: columns == 4 ? 560 : 300)
                    .background(theme.color("bg-1"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
            }
        }
    }

    private struct SettingsPanel: View {
        let control: DeviceAgentControl
        @Environment(\.theme) private var theme

        var body: some View {
            DeviceSettingsPopover(udid: DesignCaptureDevices.phone.udid, settings: FakeSettings(), control: control)
                .frame(height: 560, alignment: .top)
                .background(theme.color("bg-2"))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color("line"), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The tab's toolbar chip and actions over a resolved state, then its stage.
    private static func tab(
        _ resolved: DevicesTabState, control: DeviceAgentControl, @ViewBuilder stage: () -> some View
    ) -> some View {
        var booted = false
        var device: SimulatorDevice?
        if case .simulator(let simulator, let simulatorStage) = resolved.stage {
            device = simulator
            booted = simulatorStage == .booted
        }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                DevicesSwitcher(state: resolved, onSelect: { _ in })
                Spacer(minLength: 0)
                if let device {
                    DevicesActions(
                        device: device, booted: booted, client: SimulatorStreamClient(), control: control,
                        canChangeSettings: booted, onShutDown: {})
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            Divider()
            stage()
        }
    }

    private static func resolve(
        simulators: [SimulatorDevice]?, listError: String? = nil, vms: [VMGuestOS: VMDeviceStatus] = [:],
        selection: DevicesTarget?, booting: Set<String> = [], driving: Set<DevicesTarget> = []
    ) -> DevicesTabState {
        .resolve(
            simulators: simulators, listError: listError, vms: vms, selection: selection, bootingUDIDs: booting,
            agentDriving: driving)
    }

    // MARK: - devices

    private static func driverCells(control: DeviceAgentControl) async -> [Cell] {
        let phoneUDID = phone.udid
        let air = Self.air
        // An agent's call is what makes it the driver, so run one through the in-memory control.
        _ = await control.perform(.button(udid: phoneUDID, name: .home, includeScreenshot: false), sessionID: "demo-agent")
        // A second simulator the user drives: the agent's call waits for the hand back.
        let userDevice = SimulatorDevice(
            udid: demoUDIDPrefix + "USER", name: "iPhone 17", runtimeName: "iOS 26.5", state: .booted, deviceTypeIdentifier: "demo.phone")
        let userControl = DeviceAgentControl(
            input: FakeInput(), devices: { [userDevice] }, boot: { _ in }, install: { _, _ in },
            launch: { _, _ in 0 }, settings: FakeSettings())
        userControl.takeOver(udid: userDevice.udid)
        Task { _ = await userControl.perform(.button(udid: userDevice.udid, name: .home, includeScreenshot: false), sessionID: "demo-agent") }
        try? await Task.sleep(for: .milliseconds(300))

        let now = Date()
        let client = SimulatorStreamClient()
        func stage(_ device: SimulatorDevice, control: DeviceAgentControl, install: DevicePaneModel.AppInstall?) -> some View {
            DeviceStage(
                device: device, shape: shape, client: client, control: control, agentName: { _ in "Claude" }, now: now,
                appInstall: install, onDropApp: { _ in }, onDismissAppInstall: {})
        }
        let agentVMDriver = VMDriverStatus.make(
            driver: .agent(sessionID: "demo-agent", tool: "computer_click", at: now.addingTimeInterval(-4)), agentName: "Claude", now: now)
        let macOS = DevicesTarget.vm(.macOS)
        return [
            Cell("simulator: agent driving, app launching", tab(
                resolve(simulators: [phone, air, pad], vms: [.macOS: .running, .linux: .stopped], selection: .simulator(phoneUDID), driving: [.simulator(phoneUDID)]),
                control: control
            ) { stage(phone, control: control, install: .launching("Lantern")) }),
            Cell("simulator: you drive, agent waiting, install failed", tab(
                resolve(simulators: [userDevice, air], selection: .simulator(userDevice.udid)),
                control: userControl
            ) {
                stage(userDevice, control: userControl, install: .failed("Couldn't open Lantern: the app was built for a device."))
            }),
            Cell("VM: macOS running, agent driving", tab(
                resolve(simulators: [phone, air], vms: [.macOS: .running, .linux: .stopped], selection: macOS, driving: [macOS]),
                control: control
            ) {
                VMDeviceCard(
                    guest: .macOS, status: .running, driver: agentVMDriver, now: now,
                    onOpen: {}, onTakeOver: {}, onHandBack: {})
            }),
            Cell("VM: Linux paused", tab(
                resolve(simulators: [phone, air], vms: [.macOS: .stopped, .linux: .paused(savedAt: now.addingTimeInterval(-7_200))], selection: .vm(.linux)),
                control: control
            ) {
                VMDeviceCard(
                    guest: .linux, status: .paused(savedAt: now.addingTimeInterval(-7_200)), driver: nil, now: now,
                    onOpen: {}, onTakeOver: {}, onHandBack: {})
            }),
        ]
    }

    // MARK: - devices-empty

    private static func emptyCells() -> [Cell] {
        let control = makeControl()
        let now = Date()
        let shutDown = SimulatorDevice(
            udid: demoUDIDPrefix + "OFF", name: "iPhone 17 Pro", runtimeName: "iOS 26.5", state: .shutdown, deviceTypeIdentifier: "demo.phone")
        return [
            Cell("loading", tab(resolve(simulators: nil, selection: nil), control: control) {
                DevicesEmptyState(title: "Looking for devices…")
            }),
            Cell("no Xcode", tab(resolve(simulators: nil, listError: "x", selection: nil), control: control) {
                DevicesEmptyState(
                    symbol: "iphone.slash", title: "iOS simulators need Xcode",
                    detail: "Install it, or select it with `sudo xcode-select -s /Applications/Xcode.app`.")
            }),
            Cell("no simulators", tab(resolve(simulators: [], selection: nil), control: control) {
                DevicesEmptyState(
                    symbol: "iphone", title: "No iOS simulators",
                    detail: "Create one in Xcode under Window › Devices and Simulators.")
            }),
            Cell("simulator shut down, boot failed", tab(resolve(simulators: [shutDown, air], selection: .simulator(shutDown.udid)), control: control) {
                DevicesEmptyState(
                    symbol: "iphone", title: "\(shutDown.name) is shut down",
                    detail: "Unable to boot device in current state: Booting", detailTone: "warn",
                    action: .init(title: "Boot", icon: "power") {})
            }),
            Cell("simulator booting", tab(
                resolve(simulators: [shutDown, air], selection: .simulator(shutDown.udid), booting: [shutDown.udid]), control: control
            ) {
                DevicesEmptyState(title: "Booting \(shutDown.name)…", detail: "The first boot can take a minute.")
            }),
            Cell("VM not set up", tab(
                resolve(simulators: [], vms: [.macOS: .notCreated, .linux: .notCreated], selection: .vm(.macOS)), control: control
            ) {
                VMDeviceCard(guest: .macOS, status: .notCreated, driver: nil, now: now, onOpen: {}, onTakeOver: {}, onHandBack: {})
            }),
        ]
    }

    // MARK: - Painted screen

    /// What a scripted simulator shows instead of a stream: a wallpaper and a grid of app icons.
    static let demoScreen: CGImage? = {
        let size = CGSize(width: 804, height: 1748)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [
                NSColor(red: 0.10, green: 0.16, blue: 0.34, alpha: 1), NSColor(red: 0.42, green: 0.26, blue: 0.55, alpha: 1),
                NSColor(red: 0.93, green: 0.55, blue: 0.42, alpha: 1),
            ])?.draw(in: rect, angle: -80)
            let palette: [NSColor] = [
                .systemTeal, .systemOrange, .systemPink, .systemGreen, .systemIndigo, .systemYellow, .systemBlue, .systemRed,
            ]
            let icon: CGFloat = 132, gap: CGFloat = 60, left = (size.width - 4 * icon - 3 * gap) / 2
            for index in 0..<20 {
                let column = CGFloat(index % 4), row = CGFloat(index / 4)
                let frame = NSRect(x: left + column * (icon + gap), y: size.height - 320 - row * (icon + 96), width: icon, height: icon)
                palette[index % palette.count].withAlphaComponent(0.92).setFill()
                NSBezierPath(roundedRect: frame, xRadius: 30, yRadius: 30).fill()
            }
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: 40, y: 56, width: size.width - 80, height: 170), xRadius: 56, yRadius: 56).fill()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()
}
#endif
