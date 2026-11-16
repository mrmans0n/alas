import AlasCore
import AlasPlatform
import Foundation

/// Android emulators and phones for the `device_*` tools: adb for the device
/// and its settings, the scrcpy stream for input and frames.
@MainActor
final class AndroidBackend: DeviceBackend {
    let platform = AgentDevice.Platform.android
    var input: DeviceInput { streams }
    private let pane: AndroidPaneModel
    private let streams: AndroidStreamClient
    /// `wm density` by serial; it doesn't change while a device runs.
    private var densities: [String: Double] = [:]
    /// `wm size` by serial: the display's natural size in pixels.
    private var displaySizes: [String: (width: Double, height: Double)] = [:]

    init(pane: AndroidPaneModel, streams: AndroidStreamClient) {
        self.pane = pane
        self.streams = streams
    }

    private func control() throws -> AndroidControl {
        guard let control = pane.control else { throw DeviceToolError(message: "device_unavailable: \(AndroidPaneModel.noSDK).") }
        return control
    }

    func devices() async throws -> [AgentDevice] {
        guard pane.control != nil else { return [] }
        await pane.refresh()
        // A failed refresh leaves the last list in place, which may not be true any more.
        if let error = pane.listError { throw DeviceToolError(message: "device_unavailable: adb failed: \(error)") }
        let devices = pane.devices ?? []
        let running = Set(devices.compactMap(\.avdName))
        let connected = devices.map { device in
            let state = switch device.state {
            case .ready: "booted"
            case .unauthorized: "unauthorized"
            case .offline: "offline"
            }
            return AgentDevice(
                id: device.serial, name: device.title, platform: .android,
                runtime: device.release.map { "Android \($0)" } ?? "Android", state: state,
                alias: device.avdName.map(AndroidListing.avdID)
            )
        }
        let avds = pane.avds.filter { !running.contains($0) }.map { name in
            AgentDevice(
                id: AndroidListing.avdID(name), name: name.replacingOccurrences(of: "_", with: " "), platform: .android,
                runtime: "Android", state: pane.bootingAVDs.contains(name) ? "booting" : "shutdown"
            )
        }
        return connected + avds
    }

    func boot(_ id: String) async throws -> String {
        guard id.hasPrefix("avd:") else { return id }
        let name = String(id.dropFirst(4))
        await pane.boot(avd: name)
        if let error = pane.errors[id] { throw DeviceToolError(message: "device_not_booted: \(error)") }
        guard let serial = pane.devices?.first(where: { $0.avdName == name })?.serial else {
            throw DeviceToolError(message: "device_not_booted: \(name) didn't come up.")
        }
        return serial
    }

    func ready(_ id: String) async -> Bool {
        // Input sent before the stream connects would be dropped.
        let deadline = ContinuousClock.now + .seconds(10)
        while streams.lastFrame(udid: id) == nil {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    func snapshot(_ id: String, generation: Int) async throws -> DeviceSnapshot {
        let control = try control()
        let density = try await density(id, control: control)
        let displaySize = try await displaySize(id, control: control)
        // uiautomator can't read a window still coming up; one retry covers an app that just launched.
        for attempt in 0..<2 {
            let dump = try await Process.runData(
                control.sdk.adb, args: ["-s", id, "exec-out", "uiautomator", "dump", "/dev/tty"], timeout: 20
            )
            if dump.exitCode == 0,
               let snapshot = try? AndroidUIDump.parse(dump.stdout, density: density, displaySize: displaySize, generation: generation) {
                return snapshot
            }
            if attempt == 0 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        throw DeviceToolError(message: "device_unavailable: Android didn't describe its screen. Try again in a moment.")
    }

    private func displaySize(_ id: String, control: AndroidControl) async throws -> (width: Double, height: Double)? {
        if let known = displaySizes[id] { return known }
        let size = AndroidUIDump.displaySize(try await control.adb(id, ["shell", "wm", "size"]))
        if let size { displaySizes[id] = size }
        return size
    }

    private func density(_ id: String, control: AndroidControl) async throws -> Double {
        if let known = densities[id] { return known }
        // "Physical density: 420", and "Override density: 360" when someone changed it.
        let output = try await control.adb(id, ["shell", "wm", "density"])
        let values = output.split(whereSeparator: \.isNewline).compactMap { line in
            line.split(separator: ":").last.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        let density = values.last ?? 160
        densities[id] = density
        return density
    }

    func press(_ id: String, _ button: DeviceCommand.Button) -> Bool {
        let name: String? = switch button {
        case .home: "home"
        case .back: "back"
        case .appSwitcher: "app_switch"
        case .lock, .sideButton: "power"
        case .volumeUp: "volume_up"
        case .volumeDown: "volume_down"
        case .siri: nil
        }
        guard let name else { return false }
        streams.button(udid: id, name: name)
        return true
    }

    func rotate(_ id: String, to orientation: DeviceScreenOrientation) async throws -> DeviceScreenOrientation {
        let rotation = switch orientation {
        case .portrait: 0
        case .landscapeLeft: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        }
        let control = try control()
        try await control.setRotation(serial: id, rotation)
        // The display's own rotation, which an app locked to one orientation keeps.
        var actual: Int?
        for _ in 0..<20 {
            actual = AndroidRotation.parseDisplay(try await control.adb(id, ["shell", "dumpsys", "display"]))
            if actual == rotation { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return switch actual {
        case 1: .landscapeLeft
        case 2: .portraitUpsideDown
        case 3: .landscapeRight
        default: .portrait
        }
    }

    func beginPaste(_ id: String) async throws -> any DevicePasteSession {
        // Without the old text the paste would replace the clipboard for good.
        guard let before = await streams.readClipboard(udid: id) else {
            throw DeviceToolError(message: "The device's clipboard couldn't be read, so it couldn't be put back after pasting.")
        }
        return AndroidPasteSession(serial: id, streams: streams, before: before)
    }

    func readClipboard(_ id: String) async throws -> String {
        // Read without an agent's lease too: hold the stream for the read.
        let token = streams.subscribe(udid: id, onFrame: { _ in }, onStop: { _ in })
        defer { streams.unsubscribe(udid: id, token: token) }
        guard await ready(id), let text = await streams.readClipboard(udid: id) else {
            throw DeviceToolError(message: "device_clipboard_failed: The device didn't answer.")
        }
        return text
    }

    func writeClipboard(_ id: String, _ text: String) async throws {
        streams.setClipboard(udid: id, text: text, paste: false)
    }

    func install(_ id: String, path: String) async throws -> (appID: String, name: String) {
        let apk = URL(fileURLWithPath: path)
        guard apk.pathExtension.lowercased() == "apk" else {
            throw DeviceToolError(message: "device_app_invalid: \(path) isn't an .apk.")
        }
        let control = try control()
        guard let package = await control.packageName(apk: apk) else {
            throw DeviceToolError(
                message: "device_app_invalid: Alas couldn't read the package of \(apk.lastPathComponent); install the Android SDK build-tools."
            )
        }
        try await control.install(serial: id, apk: apk)
        return (package, apk.deletingPathExtension().lastPathComponent)
    }

    func launch(_ id: String, appID: String) async throws -> Int {
        guard await isInstalled(id, appID: appID) else { throw DeviceAppNotInstalled(appID: appID) }
        let control = try control()
        _ = try await control.adb(id, ["shell", "am", "force-stop", appID])
        try await control.launch(serial: id, package: appID)
        for _ in 0..<40 {
            let pid = (try? await control.adb(id, ["shell", "pidof", appID]))?
                .split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
            if let pid { return pid }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw DeviceToolError(message: "device_launch_failed: \(appID) didn't start.")
    }

    func isInstalled(_ id: String, appID: String) async -> Bool {
        guard let control = pane.control else { return false }
        return (try? await control.adb(id, ["shell", "pm", "path", appID])) != nil
    }

    func openURL(_ id: String, _ url: String) async throws {
        _ = try await control().adb(id, ["shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", url])
    }

    func setDisplay(
        _ id: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?
    ) async throws -> SimulatorDisplaySettings {
        let control = try control()
        if let appearance {
            _ = try await control.adb(id, ["shell", "cmd", "uimode", "night", appearance == .dark ? "yes" : "no"])
        }
        if let textSize {
            _ = try await control.adb(id, ["shell", "settings", "put", "system", "font_scale", String(AndroidFontScale.scale(for: textSize))])
        }
        if let increaseContrast {
            _ = try await control.adb(id, ["shell", "settings", "put", "secure", "high_text_contrast_enabled", increaseContrast ? "1" : "0"])
        }
        return try await readDisplay(id, control: control)
    }

    func display(_ id: String) async throws -> SimulatorDisplaySettings {
        try await readDisplay(id, control: control())
    }

    private func readDisplay(_ id: String, control: AndroidControl) async throws -> SimulatorDisplaySettings {
        let night = try await control.adb(id, ["shell", "cmd", "uimode", "night"])
        let scale = try await control.adb(id, ["shell", "settings", "get", "system", "font_scale"])
        let contrast = try await control.adb(id, ["shell", "settings", "get", "secure", "high_text_contrast_enabled"])
        let mode = night.trimmingCharacters(in: .whitespacesAndNewlines)
        return SimulatorDisplaySettings(
            appearance: mode == "Night mode: yes" ? .value(.dark) : mode == "Night mode: no" ? .value(.light) : .unknown,
            textSize: AndroidFontScale.textSize(for: scale),
            increaseContrast: .value(contrast.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        )
    }

    func setAccessibility(_ id: String, _ change: SimulatorAccessibilityChange) async throws -> SimulatorAccessibility {
        throw DeviceToolError.unsupported("device_set_accessibility")
    }

    func accessibility(_ id: String) async throws -> SimulatorAccessibility {
        throw DeviceToolError.unsupported("device_set_accessibility")
    }

    func userApps(_ id: String) async throws -> [SimulatorApp] {
        let output = try await control().adb(id, ["shell", "pm", "list", "packages", "-3"])
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("package:") else { return nil }
            let package = String(line.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces)
            return SimulatorApp(bundleID: package, name: package)
        }.sorted { $0.bundleID < $1.bundleID }
    }

    func network(_ id: String) async throws -> AndroidNetworkState {
        let control = try control()
        return AndroidNetworkState(
            wifi: AndroidNetwork.wifi(try await control.adb(id, ["shell", "cmd", "wifi", "status"])),
            data: AndroidNetwork.data(try await control.adb(id, ["shell", "settings", "get", "global", "mobile_data"]))
        )
    }

    func setNetwork(_ id: String, wifi: Bool?, data: Bool?) async throws -> AndroidNetworkState {
        let control = try control()
        if let wifi { _ = try await control.adb(id, ["shell", "svc", "wifi", wifi ? "enable" : "disable"]) }
        if let data { _ = try await control.adb(id, ["shell", "svc", "data", data ? "enable" : "disable"]) }
        return try await network(id)
    }

    func clearData(_ id: String, appID: String) async throws {
        let output = try await control().adb(id, ["shell", "pm", "clear", appID])
        guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "Success" else {
            throw DeviceToolError(message: "device_clear_data_failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    func setPermission(_ id: String, appID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws {
        guard let permissions = AndroidPermissions.permissions(for: service) else {
            throw DeviceToolError(message: "device_unsupported: \(service.rawValue) has no Android permission.")
        }
        let control = try control()
        for permission in permissions {
            let commands: [[String]] = switch action {
            case .grant: [["pm", "grant", appID, permission]]
            case .revoke: [["pm", "revoke", appID, permission]]
            case .reset: [["pm", "revoke", appID, permission], ["pm", "clear-permission-flags", appID, permission, "user-set", "user-fixed"]]
            }
            for command in commands {
                do {
                    _ = try await control.adb(id, ["shell"] + command)
                } catch {
                    // `all` names permissions an app may not request.
                    if service != .all { throw error }
                }
            }
        }
    }

    func setLocation(_ id: String, _ location: SimulatorLocation?) async throws {
        let control = try control()
        guard let location else {
            _ = try? await control.adb(id, ["shell", "cmd", "location", "providers", "remove-test-provider", "gps"])
            _ = try await control.adb(id, ["shell", "appops", "set", "com.android.shell", "android:mock_location", "default"])
            return
        }
        // The test provider changes what apps read, on emulators and phones alike.
        _ = try await control.adb(id, ["shell", "appops", "set", "com.android.shell", "android:mock_location", "allow"])
        _ = try? await control.adb(id, ["shell", "cmd", "location", "providers", "add-test-provider", "gps"])
        _ = try await control.adb(id, ["shell", "cmd", "location", "providers", "set-test-provider-enabled", "gps", "true"])
        _ = try await control.adb(id, [
            "shell", "cmd", "location", "providers", "set-test-provider-location", "gps",
            "--location", "\(location.latitude),\(location.longitude)",
        ])
    }

    func push(_ id: String, appID: String, payload: Data) async throws {
        throw DeviceToolError.unsupported("device_push")
    }

    func logs(
        _ id: String, name: String, since: Int, appID: String?, level: SimulatorLogLevel, includeApple: Bool,
        query: String?, limit: Int
    ) async throws -> [String: Any] {
        let control = try control()
        var app = appID
        if app == nil {
            app = AndroidLogcat.frontmostPackage(try await control.adb(id, ["shell", "dumpsys", "activity", "activities"]))
        }
        guard let app else { throw DeviceToolError(message: "device_no_app: No app is in front on \(name). Pass bundle_id.") }
        guard await isInstalled(id, appID: app) else { throw DeviceAppNotInstalled(appID: app) }
        let year = Calendar.current.component(.year, from: Date())
        // Lines since `since` seconds ago by the device's own clock.
        let start = "\"$(date -d @$(( $(date +%s) - \(since) )) '+%m-%d %H:%M:%S.000')\""
        let pid = (try? await control.adb(id, ["shell", "pidof", app]))?
            .split(whereSeparator: \.isWhitespace).first.map(String.init)
        var lines: [SimulatorLogLine] = []
        if let pid {
            let output = try await control.adb(id, [
                "shell", "logcat -d -v threadtime --pid=\(pid) -T \(start) '*:\(AndroidLogcat.filter(level))'",
            ])
            lines = AndroidLogcat.parse(output, year: year)
        }
        let matching = query.map { query in lines.filter { $0.matches(query) } } ?? lines
        let crashOutput = (try? await control.adb(id, ["shell", "logcat -d -b crash -v threadtime -T \(start)"])) ?? ""
        let crashes = AndroidLogcat.crashes(AndroidLogcat.parse(crashOutput, year: year), package: app)
        var reply: [String: Any] = [
            "app": app,
            "lines": matching.suffix(limit).map(\.json),
            "truncated": matching.count > limit,
            "crashes": crashes.map(\.json),
        ]
        if pid == nil { reply["note"] = "\(app) isn't running." }
        return reply
    }
}

/// An Android paste: the clipboard set and pasted for each run, then put back.
@MainActor
private final class AndroidPasteSession: DevicePasteSession {
    private let serial: String
    private let streams: AndroidStreamClient
    private let before: String

    init(serial: String, streams: AndroidStreamClient, before: String) {
        self.serial = serial
        self.streams = streams
        self.before = before
    }

    func paste(_ text: String) async throws {
        streams.setClipboard(udid: serial, text: text, paste: true)
        // The device pastes asynchronously; give it a moment before the next run or the restore.
        try? await Task.sleep(for: .milliseconds(150))
    }

    func end() async {
        streams.setClipboard(udid: serial, text: before, paste: false)
    }
}
