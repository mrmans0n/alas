import AlasCore
import SwiftUI

/// The selected device's settings: display, accessibility (iOS), network
/// (Android), an app's permissions and notifications (iOS) or data (Android),
/// location and URLs. Reads its values each time it opens. Changes take the
/// device's input turn, so they never land in the middle of an agent's call.
struct DeviceSettingsPopover: View {
    let udid: String
    let backend: any DeviceBackend
    let control: DeviceAgentControl
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    @State private var display: SimulatorDisplaySettings?
    @State private var displayError: String?
    @State private var accessibility: SimulatorAccessibility?
    @State private var accessibilityError: String?
    @State private var network: AndroidNetworkState?
    @State private var networkError: String?
    @State private var confirmsClear = false
    @State private var apps: [SimulatorApp] = []
    @State private var appID: String?
    @State private var service = SimulatorPrivacyService.photos
    @State private var appMessage: String?
    @State private var payload = #"{"aps":{"alert":{"title":"Hello","body":"From Alas"}}}"#
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var url = ""
    @State private var deviceMessage: String?
    @State private var slim: SimulatorSlimState?
    @State private var slimMissing = false
    @State private var slimApplying = false
    @State private var slimError: String?
    @State private var simslimInstall = HomebrewInstallController.simslim()

    private static let places: [(name: String, location: SimulatorLocation)] = [
        ("Apple Park", .init(latitude: 37.3349, longitude: -122.0090)),
        ("London", .init(latitude: 51.5072, longitude: -0.1276)),
        ("Tokyo", .init(latitude: 35.6762, longitude: 139.6503)),
        ("Barcelona", .init(latitude: 41.3874, longitude: 2.1686)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[4]) {
            section("Display") { displayRows }
            Divider()
            if platform == .ios {
                section("Accessibility") { accessibilityRows }
                Divider()
                section("Memory") { slimRows }
                Divider()
            }
            if platform == .android {
                section("Network") { networkRows }
                Divider()
            }
            section("App") { appRows }
            Divider()
            section("Device") { deviceRows }
        }
        .font(scale.meta.font)
        .padding(scale.space[4])
        .frame(width: 340)
        .task { await load() }
        .onChange(of: simslimInstall.phase) { _, phase in
            if phase == .succeeded { Task { await loadSlim() } }
        }
    }

    private var platform: AgentDevice.Platform { backend.platform }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("fg-dim"))
            content()
        }
    }

    // MARK: Display

    @ViewBuilder
    private var displayRows: some View {
        if let display {
            row("Appearance", supported: display.appearance) {
                Picker("", selection: Binding(
                    get: { if case .value(let value) = display.appearance { value } else { .light } },
                    set: { value in
                        change { try await backend.setDisplay(udid, appearance: value, textSize: nil, increaseContrast: nil) }
                    }
                )) {
                    Text("Light").tag(SimulatorAppearance.light)
                    Text("Dark").tag(SimulatorAppearance.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
            row("Text size", supported: display.textSize) {
                if case .value(let size) = display.textSize, let index = SimulatorTextSize.allCases.firstIndex(of: size) {
                    Stepper(size.label, onIncrement: { step(from: index, by: 1) }, onDecrement: { step(from: index, by: -1) })
                } else {
                    Text("Unknown").foregroundStyle(theme.color("fg-faint"))
                }
            }
            row("Increase contrast", supported: display.increaseContrast) {
                Toggle("", isOn: Binding(
                    get: { display.increaseContrast == .value(true) },
                    set: { value in
                        change { try await backend.setDisplay(udid, appearance: nil, textSize: nil, increaseContrast: value) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
        } else if displayError == nil {
            ProgressView().controlSize(.small)
        }
        if let displayError { note(displayError, tone: "warn") }
    }

    private func row<Value>(
        _ title: String, supported: SimulatorReadBack<Value>, @ViewBuilder _ control: () -> some View
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            switch supported {
            case .unsupported:
                Text("Not on this runtime").foregroundStyle(theme.color("fg-faint"))
            case .unknown:
                // Not a control: it would show, and could overwrite, a value nobody read.
                Text("Unknown").foregroundStyle(theme.color("fg-faint"))
            case .value:
                control()
            }
        }
    }

    private func step(from index: Int, by delta: Int) {
        let sizes = SimulatorTextSize.allCases
        let next = index + delta
        guard sizes.indices.contains(next) else { return }
        change { try await backend.setDisplay(udid, appearance: nil, textSize: sizes[next], increaseContrast: nil) }
    }

    /// Applies a display change and shows what simctl read back.
    private func change(_ body: @escaping () async throws -> SimulatorDisplaySettings) {
        mutate(report: { displayError = $0 }) {
            do {
                display = try await body()
                displayError = nil
            } catch {
                displayError = error.localizedDescription
            }
        }
    }

    /// Runs a change in the simulator's input turn: after agent input already
    /// queued, and before any that starts meanwhile. Refused while an agent drives.
    private func mutate(report: @escaping (String) -> Void, _ body: @escaping () async -> Void) {
        Task {
            let ran = await control.whileUserHoldsInput(udid: udid) { await body() }
            if !ran { report("An agent is driving this simulator. Take over to change it.") }
        }
    }

    // MARK: Accessibility

    @ViewBuilder
    private var accessibilityRows: some View {
        if let accessibility {
            toggleRow("VoiceOver", accessibility.voiceOver) { SimulatorAccessibilityChange(voiceOver: $0) }
            toggleRow("Reduce Motion", accessibility.reduceMotion) { SimulatorAccessibilityChange(reduceMotion: $0) }
            toggleRow("Button Shapes", accessibility.buttonShapes) { SimulatorAccessibilityChange(buttonShapes: $0) }
            toggleRow("Reduce Transparency", accessibility.reduceTransparency) {
                SimulatorAccessibilityChange(reduceTransparency: $0)
            }
            row("Color filter", supported: accessibility.colorFilter) {
                Picker("", selection: Binding(
                    get: { if case .value(let value) = accessibility.colorFilter { value } else { .none } },
                    set: { value in changeAccessibility(SimulatorAccessibilityChange(colorFilter: value)) }
                )) {
                    ForEach(SimulatorColorFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            row("Liquid Glass", supported: accessibility.liquidGlass) {
                Picker("", selection: Binding(
                    get: { if case .value(let value) = accessibility.liquidGlass { value } else { .clear } },
                    set: { value in changeAccessibility(SimulatorAccessibilityChange(liquidGlass: value)) }
                )) {
                    Text("Clear").tag(SimulatorLiquidGlass.clear)
                    Text("Tinted").tag(SimulatorLiquidGlass.tinted)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
        } else if accessibilityError == nil {
            ProgressView().controlSize(.small)
        }
        if let accessibilityError { note(accessibilityError, tone: "warn") }
    }

    private func toggleRow(
        _ title: String, _ value: SimulatorReadBack<Bool>, change: @escaping (Bool) -> SimulatorAccessibilityChange
    ) -> some View {
        row(title, supported: value) {
            Toggle("", isOn: Binding(get: { value == .value(true) }, set: { changeAccessibility(change($0)) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    /// Applies an accessibility change and shows what the helper read back.
    private func changeAccessibility(_ change: SimulatorAccessibilityChange) {
        mutate(report: { accessibilityError = $0 }) {
            do {
                accessibility = try await backend.setAccessibility(udid, change)
                accessibilityError = nil
            } catch {
                accessibilityError = error.localizedDescription
            }
        }
    }

    // MARK: Memory

    @ViewBuilder
    private var slimRows: some View {
        if slimMissing {
            HStack {
                Text("Slim simulator")
                Spacer()
                Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(true)
            }
            note("Install simslim to cut this simulator's memory about 4x.", tone: "fg-dim")
            note("Installs via Homebrew: \(SimulatorSlim.installCommand)", tone: "fg-faint")
            simslimInstallControl
        } else if let slim {
            HStack {
                Text("Slim simulator")
                Spacer()
                if slimApplying { ProgressView().controlSize(.small) }
                // A closure, not `set: setSlim`: the method reference crashes Swift 6.3's IRGen.
                Toggle("", isOn: Binding(get: { slim.isSlim }, set: { setSlim($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(slimApplying)
            }
            note(Self.slimSummary(slim), tone: "fg-dim")
            if slim.isSlim, !slim.persistent {
                note("Lasts until the simulator restarts on this iOS version.", tone: "fg-faint")
            }
        } else if slimError == nil {
            ProgressView().controlSize(.small)
        }
        if let slimError { note(slimError, tone: "warn") }
    }

    /// Settings › Changes' gg install control, for simslim.
    @ViewBuilder
    private var simslimInstallControl: some View {
        switch simslimInstall.phase {
        case .running:
            HStack(spacing: 6) {
                Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 10, height: 10)
                Text("Installing…").foregroundStyle(theme.color("fg-dim"))
            }
        case .failed(let message):
            note(message, tone: "warn")
            AlasButton(title: "Retry", compact: true) { simslimInstall.install() }
        case .idle, .succeeded:
            AlasButton(title: "Install simslim…", compact: true) { simslimInstall.install() }
        }
    }

    private static func slimSummary(_ slim: SimulatorSlimState) -> String {
        let memory = slim.memoryBytes.map { bytes in
            let gigabytes = (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(2)))
            return slim.processes.map { "\(gigabytes) GB in \($0) processes. " } ?? "\(gigabytes) GB. "
        } ?? ""
        let services = slim.isSlim ? "\(slim.servicesOff) of \(slim.services) background services are off." : "All background services run."
        return memory + services
    }

    private func setSlim(_ on: Bool) {
        slimApplying = true
        mutate(report: { message in
            slimError = message
            slimApplying = false
        }) {
            do {
                slim = try await backend.setSlim(udid, on: on)
                slimError = nil
            } catch {
                slimError = error.localizedDescription
            }
            slimApplying = false
        }
    }

    /// After the other sections: `measure` can take a moment.
    private func loadSlim() async {
        do {
            slim = try await backend.slim(udid)
            slimMissing = false
            slimError = nil
        } catch SimulatorSlimError.notInstalled {
            slimMissing = true
        } catch {
            slimError = error.localizedDescription
        }
    }

    // MARK: App

    @ViewBuilder
    private var appRows: some View {
        if apps.isEmpty {
            note("None of your apps are installed on this device.", tone: "fg-faint")
        } else {
            Picker("App", selection: $appID) {
                ForEach(apps) { Text($0.name).tag(Optional($0.bundleID)) }
            }
            HStack(spacing: 6) {
                Picker("", selection: $service) {
                    ForEach(SimulatorPrivacyService.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                ForEach(SimulatorPrivacyAction.allCases, id: \.self) { action in
                    Button(action.rawValue.capitalized) { setPermission(action) }
                }
            }
            .controlSize(.small)
            if platform == .ios {
                TextEditor(text: $payload)
                    .font(scale.meta.font(design: .monospaced))
                    .frame(height: 54)
                    .overlay(RoundedRectangle(cornerRadius: scale.radius.small).strokeBorder(theme.color("line"), lineWidth: 0.5))
                HStack {
                    Spacer()
                    Button("Send Notification", action: sendPush).controlSize(.small)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Clear Data…") { confirmsClear = true }.controlSize(.small)
                }
                .confirmationDialog("Clear the data of \(appName)?", isPresented: $confirmsClear) {
                    Button("Clear Data", role: .destructive, action: clearData)
                } message: {
                    Text("The app starts over as freshly installed, and stops if it's running.")
                }
            }
            if let appMessage { note(appMessage, tone: "fg-dim") }
        }
    }

    private var appName: String { apps.first { $0.bundleID == appID }?.name ?? "" }

    private func setPermission(_ action: SimulatorPrivacyAction) {
        guard let appID else { return }
        let service = service
        mutate(report: { appMessage = $0 }) {
            do {
                try await backend.setPermission(udid, appID: appID, service: service, action: action)
                let verb = switch action {
                case .grant: "Granted"
                case .revoke: "Revoked"
                case .reset: "Reset"
                }
                appMessage = "\(verb) \(service.label) for \(appName). A change may end the running app."
            } catch {
                appMessage = error.localizedDescription
            }
        }
    }

    private func clearData() {
        guard let appID else { return }
        mutate(report: { appMessage = $0 }) {
            do {
                try await backend.clearData(udid, appID: appID)
                appMessage = "Cleared the data of \(appName)."
            } catch {
                appMessage = error.localizedDescription
            }
        }
    }

    private func sendPush() {
        guard let appID else { return }
        let data = Data(payload.utf8)
        if let problem = SimulatorPushPayload.problem(data) {
            appMessage = problem
            return
        }
        mutate(report: { appMessage = $0 }) {
            do {
                try await backend.push(udid, appID: appID, payload: data)
                appMessage = "Sent a notification to \(appName)."
            } catch {
                appMessage = error.localizedDescription
            }
        }
    }

    // MARK: Network

    @ViewBuilder
    private var networkRows: some View {
        if let network {
            networkRow("Wi-Fi", network.wifi) { SetNetwork(wifi: $0) }
            networkRow("Mobile data", network.data) { SetNetwork(data: $0) }
        } else if networkError == nil {
            ProgressView().controlSize(.small)
        }
        if let networkError { note(networkError, tone: "warn") }
    }

    /// Which switch a network change turns.
    private struct SetNetwork {
        var wifi: Bool?
        var data: Bool?
    }

    private func networkRow(_ title: String, _ value: SimulatorReadBack<Bool>, change: @escaping (Bool) -> SetNetwork) -> some View {
        row(title, supported: value) {
            Toggle("", isOn: Binding(get: { value == .value(true) }, set: { on in
                let set = change(on)
                mutate(report: { networkError = $0 }) {
                    do {
                        network = try await backend.setNetwork(udid, wifi: set.wifi, data: set.data)
                        networkError = nil
                    } catch {
                        networkError = error.localizedDescription
                    }
                }
            }))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    // MARK: Device

    @ViewBuilder
    private var deviceRows: some View {
        HStack(spacing: 6) {
            TextField("Latitude", text: $latitude).frame(width: 84)
            TextField("Longitude", text: $longitude).frame(width: 84)
            Menu("Places") {
                ForEach(Self.places, id: \.name) { place in
                    Button(place.name) {
                        latitude = String(place.location.latitude)
                        longitude = String(place.location.longitude)
                        setLocation(place.location)
                    }
                }
            }
            .fixedSize()
        }
        HStack(spacing: 6) {
            Button("Set Location") {
                guard let lat = Double(latitude), let lon = Double(longitude),
                      (-90...90).contains(lat), (-180...180).contains(lon) else {
                    deviceMessage = "Latitude goes from -90 to 90, and longitude from -180 to 180."
                    return
                }
                setLocation(SimulatorLocation(latitude: lat, longitude: lon))
            }
            Button("Clear") { setLocation(nil) }
        }
        .controlSize(.small)
        HStack(spacing: 6) {
            TextField("URL or deep link", text: $url)
                .onSubmit(openURL)
            Button("Open", action: openURL).controlSize(.small)
        }
        if let deviceMessage { note(deviceMessage, tone: "fg-dim") }
    }

    private func setLocation(_ location: SimulatorLocation?) {
        mutate(report: { deviceMessage = $0 }) {
            do {
                try await backend.setLocation(udid, location)
                deviceMessage = location.map { "Location set to \($0.latitude), \($0.longitude)." } ?? "Location cleared."
            } catch {
                deviceMessage = error.localizedDescription
            }
        }
    }

    private func openURL() {
        let target = url.trimmingCharacters(in: .whitespaces)
        guard let scheme = URLComponents(string: target)?.scheme, !scheme.isEmpty else {
            deviceMessage = "Add a scheme, such as https:// or myapp://."
            return
        }
        mutate(report: { deviceMessage = $0 }) {
            do {
                try await backend.openURL(udid, target)
                deviceMessage = "Opened \(target)."
            } catch {
                deviceMessage = error.localizedDescription
            }
        }
    }

    private func note(_ text: String, tone: String) -> some View {
        Text(text)
            .font(scale.meta.font)
            .foregroundStyle(theme.color(tone))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func load() async {
        do {
            display = try await backend.display(udid)
        } catch {
            displayError = error.localizedDescription
        }
        // Separately, so a missing helper doesn't hide the display settings.
        if platform == .ios {
            do {
                accessibility = try await backend.accessibility(udid)
            } catch {
                accessibilityError = error.localizedDescription
            }
        } else {
            do {
                network = try await backend.network(udid)
            } catch {
                networkError = error.localizedDescription
            }
        }
        apps = (try? await backend.userApps(udid)) ?? []
        if appID == nil || !apps.contains(where: { $0.bundleID == appID }) { appID = apps.first?.bundleID }
        if platform == .ios { await loadSlim() }
    }
}
