import AlasCore
import SwiftUI

/// The selected simulator's settings: display, an app's permissions and
/// notifications, location and URLs. Reads its values each time it opens.
struct DeviceSettingsPopover: View {
    let udid: String
    let settings: any SimulatorSettingsControl
    @Environment(\.theme) private var theme

    @State private var display: SimulatorDisplaySettings?
    @State private var displayError: String?
    @State private var apps: [SimulatorApp] = []
    @State private var appID: String?
    @State private var service = SimulatorPrivacyService.photos
    @State private var appMessage: String?
    @State private var payload = #"{"aps":{"alert":{"title":"Hello","body":"From Alas"}}}"#
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var url = ""
    @State private var deviceMessage: String?

    private static let places: [(name: String, location: SimulatorLocation)] = [
        ("Apple Park", .init(latitude: 37.3349, longitude: -122.0090)),
        ("London", .init(latitude: 51.5072, longitude: -0.1276)),
        ("Tokyo", .init(latitude: 35.6762, longitude: 139.6503)),
        ("Barcelona", .init(latitude: 41.3874, longitude: 2.1686)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Display") { displayRows }
            Divider()
            section("App") { appRows }
            Divider()
            section("Device") { deviceRows }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 340)
        .task { await load() }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
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
                        change { try await settings.setDisplay(udid: udid, appearance: value, textSize: nil, increaseContrast: nil) }
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
                        change { try await settings.setDisplay(udid: udid, appearance: nil, textSize: nil, increaseContrast: value) }
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
            if supported == .unsupported {
                Text("Not on this runtime").foregroundStyle(theme.color("fg-faint"))
            } else {
                control()
            }
        }
    }

    private func step(from index: Int, by delta: Int) {
        let sizes = SimulatorTextSize.allCases
        let next = index + delta
        guard sizes.indices.contains(next) else { return }
        change { try await settings.setDisplay(udid: udid, appearance: nil, textSize: sizes[next], increaseContrast: nil) }
    }

    /// Applies a display change and shows what simctl read back.
    private func change(_ body: @escaping () async throws -> SimulatorDisplaySettings) {
        Task {
            do {
                display = try await body()
                displayError = nil
            } catch {
                displayError = error.localizedDescription
            }
        }
    }

    // MARK: App

    @ViewBuilder
    private var appRows: some View {
        if apps.isEmpty {
            note("None of your apps are installed on this simulator.", tone: "fg-faint")
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
            TextEditor(text: $payload)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 54)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.color("line"), lineWidth: 0.5))
            HStack {
                Spacer()
                Button("Send Notification", action: sendPush).controlSize(.small)
            }
            if let appMessage { note(appMessage, tone: "fg-dim") }
        }
    }

    private var appName: String { apps.first { $0.bundleID == appID }?.name ?? "" }

    private func setPermission(_ action: SimulatorPrivacyAction) {
        guard let appID else { return }
        let service = service
        Task {
            do {
                try await settings.setPermission(udid: udid, bundleID: appID, service: service, action: action)
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

    private func sendPush() {
        guard let appID else { return }
        let data = Data(payload.utf8)
        if let problem = SimulatorPushPayload.problem(data) {
            appMessage = problem
            return
        }
        Task {
            do {
                try await settings.push(udid: udid, bundleID: appID, payload: data)
                appMessage = "Sent a notification to \(appName)."
            } catch {
                appMessage = error.localizedDescription
            }
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
        Task {
            do {
                try await settings.setLocation(udid: udid, location)
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
        Task {
            do {
                try await settings.openURL(udid: udid, url: target)
                deviceMessage = "Opened \(target)."
            } catch {
                deviceMessage = error.localizedDescription
            }
        }
    }

    private func note(_ text: String, tone: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(theme.color(tone))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func load() async {
        do {
            display = try await settings.display(udid: udid)
        } catch {
            displayError = error.localizedDescription
        }
        apps = (try? await settings.userApps(udid: udid)) ?? []
        if appID == nil || !apps.contains(where: { $0.bundleID == appID }) { appID = apps.first?.bundleID }
    }
}
