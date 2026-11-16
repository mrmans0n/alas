import AlasCore
import Foundation

/// iOS simulators: simctl, AlasSimService's input, and the settings, logs and
/// pasteboard controls.
@MainActor
final class SimulatorBackend: DeviceBackend {
    let platform = AgentDevice.Platform.ios
    let input: DeviceInput
    private let listDevices: () async throws -> [SimulatorDevice]
    private let bootDevice: (String) async throws -> Void
    private let installApp: (String, URL) async throws -> Void
    private let launchApp: (String, String) async throws -> Int32
    private let settings: any SimulatorSettingsControl
    private let logControl: any SimulatorLogsControl
    private let pasteboard: DevicePasteboard
    /// The route each simulator was last sent; simctl doesn't report its progress.
    private var playing: [String: DeviceRoute] = [:]
    private let now: () -> Date
    private let sleep: @MainActor (Duration) async -> Void

    init(
        input: DeviceInput,
        devices: @escaping () async throws -> [SimulatorDevice],
        boot: @escaping (String) async throws -> Void,
        install: @escaping (String, URL) async throws -> Void,
        launch: @escaping (String, String) async throws -> Int32,
        settings: any SimulatorSettingsControl,
        logs: any SimulatorLogsControl,
        pasteboard: DevicePasteboard,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.input = input
        listDevices = devices
        bootDevice = boot
        installApp = install
        launchApp = launch
        self.settings = settings
        logControl = logs
        self.pasteboard = pasteboard
        self.now = now
        self.sleep = sleep
    }

    func devices() async throws -> [AgentDevice] {
        try await listDevices().map { device in
            let state: String = switch device.state {
            case .booted: "booted"
            case .booting: "booting"
            case .shutdown: "shutdown"
            case .shuttingDown: "shutting_down"
            case .other(let value): value
            }
            return AgentDevice(id: device.udid, name: device.name, platform: .ios, runtime: device.runtimeName, state: state)
        }
    }

    func boot(_ id: String) async throws -> String {
        try await bootDevice(id)
        return id
    }

    /// AlasSimService takes input before the first frame.
    func ready(_ id: String) async -> Bool {
        true
    }

    func snapshot(_ id: String, generation: Int) async throws -> DeviceSnapshot {
        try DeviceSnapshot.parse(try await input.describe(udid: id), generation: generation)
    }

    func press(_ id: String, _ button: DeviceCommand.Button) -> Bool {
        switch button {
        case .home, .lock, .siri, .sideButton, .appSwitcher:
            input.button(udid: id, name: button.rawValue)
            return true
        case .back, .volumeUp, .volumeDown:
            return false
        }
    }

    /// Turns the device, then waits up to 2 s for a frame in the new
    /// orientation; an app that supports only portrait never sends one.
    func rotate(_ id: String, to orientation: DeviceScreenOrientation) async throws -> DeviceScreenOrientation {
        // The service rotates through the device's stream, which the lease just started.
        for _ in 0..<100 where input.lastFrame(udid: id) == nil {
            await sleep(.milliseconds(50))
        }
        try await input.rotate(udid: id, to: orientation)
        for _ in 0..<40 where input.lastFrame(udid: id)?.orientation != orientation {
            await sleep(.milliseconds(50))
        }
        return input.lastFrame(udid: id)?.orientation ?? .portrait
    }

    func beginPaste(_ id: String) async throws -> any DevicePasteSession {
        SimulatorPasteSession(pasteboard: pasteboard, paste: try await pasteboard.open(udid: id, keepText: true))
    }

    func readClipboard(_ id: String) async throws -> String {
        try await pasteboard.read(udid: id)
    }

    func writeClipboard(_ id: String, _ text: String) async throws {
        try await pasteboard.write(udid: id, text: text)
    }

    func install(_ id: String, path: String) async throws -> (appID: String, name: String) {
        let app: SimulatorAppBundle
        do {
            app = try SimulatorAppBundle.read(URL(fileURLWithPath: path))
        } catch let problem as SimulatorAppBundle.Problem {
            throw DeviceToolError(message: problem.message(udid: id))
        } catch {
            throw DeviceToolError(message: "device_app_invalid: \(error.localizedDescription)")
        }
        try await installApp(id, app.url)
        return (app.bundleID, app.name)
    }

    func launch(_ id: String, appID: String) async throws -> Int {
        do {
            return Int(try await launchApp(id, appID))
        } catch SimulatorLaunchError.notInstalled {
            throw DeviceAppNotInstalled(appID: appID)
        }
    }

    func isInstalled(_ id: String, appID: String) async -> Bool {
        await settings.isInstalled(udid: id, bundleID: appID)
    }

    func openURL(_ id: String, _ url: String) async throws {
        try await settings.openURL(udid: id, url: url)
    }

    func setDisplay(
        _ id: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?
    ) async throws -> SimulatorDisplaySettings {
        try await settings.setDisplay(udid: id, appearance: appearance, textSize: textSize, increaseContrast: increaseContrast)
    }

    func setAccessibility(_ id: String, _ change: SimulatorAccessibilityChange) async throws -> SimulatorAccessibility {
        try await settings.setAccessibility(udid: id, change)
    }

    func display(_ id: String) async throws -> SimulatorDisplaySettings {
        try await settings.display(udid: id)
    }

    func accessibility(_ id: String) async throws -> SimulatorAccessibility {
        try await settings.accessibility(udid: id)
    }

    func userApps(_ id: String) async throws -> [SimulatorApp] {
        try await settings.userApps(udid: id)
    }

    func network(_ id: String) async throws -> AndroidNetworkState {
        throw Self.unsupported("device_set_network")
    }

    func setNetwork(_ id: String, wifi: Bool?, data: Bool?) async throws -> AndroidNetworkState {
        throw Self.unsupported("device_set_network")
    }

    func clearData(_ id: String, appID: String) async throws {
        throw Self.unsupported("device_clear_data")
    }

    private static func unsupported(_ tool: String) -> DeviceToolError {
        DeviceToolError(message: "device_unsupported: \(tool) isn't available on iOS.")
    }

    func setPermission(_ id: String, appID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws {
        try await settings.setPermission(udid: id, bundleID: appID, service: service, action: action)
    }

    func frontApp(_ id: String) async -> String? {
        await logControl.frontmostApp(udid: id)
    }

    func setLocation(_ id: String, _ location: SimulatorLocation?) async throws {
        try await settings.setLocation(udid: id, location)
        playing[id] = nil
    }

    func startRoute(_ id: String, _ route: DeviceRoute) async throws {
        // `simctl location start` came with iOS 17.
        if let device = try await listDevices().first(where: { $0.udid == id }),
           let major = device.runtimeName.split(separator: " ").last?.split(separator: ".").first.flatMap({ Int($0) }),
           major < 17 {
            throw DeviceToolError(message: "device_unsupported: Routes need iOS 17 or later; \(device.name) runs \(device.runtimeName).")
        }
        try await settings.startRoute(udid: id, route)
        playing[id] = route
    }

    func routeProgress(_ id: String) -> DeviceRouteProgress? {
        playing[id].map { DeviceRouteProgress(name: $0.name, travelled: nil, length: $0.length) }
    }

    func push(_ id: String, appID: String, payload: Data) async throws {
        try await settings.push(udid: id, bundleID: appID, payload: payload)
    }

    func logs(
        _ id: String, name: String, since: Int, appID: String?, level: SimulatorLogLevel, includeApple: Bool,
        query: String?, limit: Int
    ) async throws -> [String: Any] {
        var app = appID
        if app == nil { app = await logControl.frontmostApp(udid: id) }
        guard let app else { throw DeviceToolError(message: "device_no_app: No app is in front on \(name). Pass bundle_id.") }
        guard let executable = try await logControl.executables(udid: id)[app] else { throw DeviceAppNotInstalled(appID: app) }
        let all = try await logControl.logShow(
            udid: id, query: SimulatorLogQuery(executable: executable, level: level, includeApple: includeApple), seconds: since
        )
        let matching = query.map { query in all.filter { $0.matches(query) } } ?? all
        let crashes = await logControl.crashReports(udid: id, bundleID: app, since: now().addingTimeInterval(-Double(since)))
        return [
            "app": app,
            "lines": matching.suffix(limit).map(\.json),
            "truncated": matching.count > limit,
            "crashes": crashes.map(\.json),
        ]
    }
}

/// A simulator paste: the pasteboard taken for the app in front, its old text put back at the end.
@MainActor
private final class SimulatorPasteSession: DevicePasteSession {
    private let pasteboard: DevicePasteboard
    private let open: DevicePasteboard.Paste

    init(pasteboard: DevicePasteboard, paste: DevicePasteboard.Paste) {
        self.pasteboard = pasteboard
        open = paste
    }

    func paste(_ text: String) async throws {
        try await pasteboard.paste(text, in: open)
    }

    func end() async {
        await pasteboard.close(open)
    }
}
