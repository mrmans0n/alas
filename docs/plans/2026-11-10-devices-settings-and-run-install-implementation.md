# Devices settings and run-script installs: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change a booted simulator's display settings, permissions, location, notifications and URLs from a Devices-tab popover and through five agent tools, and install and launch a run script's app when the script succeeds.

**Architecture:** AlasCore gains typed simctl settings (`SimulatorSettings.swift`), their `SimulatorControl` wrappers, and one `SimulatorSettingsControl` protocol with a live implementation. `DeviceAgentControl` runs the five new `device_*` commands through that protocol. The popover calls the same protocol directly. A `# alas-app:` run-script header is handed from `runScriptFinished` to a new `AppState.installRunScriptApp`, which picks a simulator with `SimulatorTarget.choose` and reuses `DevicePaneModel.installAndLaunch`.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing, Rust (`AlasCLI`), `xcrun simctl`.

**Spec:** `docs/plans/2026-11-10-devices-settings-and-run-install-design.md`

## Global Constraints

- English everywhere; Conventional Commits; no agent attribution.
- Swift Testing only; follow AGENTS.md's testing policy (extend existing suites, parameterize, no fixed sleeps, reuse `eventually(_:within:_:)` for polling).
- AlasCore must not import AppKit or SwiftUI; anything the app uses is `public`.
- Error codes, verbatim: `device_settings_failed`, `device_app_not_installed`, plus the existing `device_*` codes.
- Push payloads: a JSON object with an `aps` object, at most 4096 bytes encoded.
- Coordinates: latitude −90…90, longitude −180…180.
- Run `xcodegen` after adding app files.

## Changes from the spec

- **The popover keeps its own state; nothing is stored in `DevicePaneModel`.** It reads values each time it opens and nothing outlives it, so per-UDID model state would only duplicate it.
- **"No simulator" is an in-app notification (`inAppNotifications.post`, `.error`), not a macOS one.** The user just ran the script in Alas, and the in-app store is what `runScriptFinished` already uses for a run's success.

## Review Focus

1. A run whose script declares `# alas-app:` but fails, stops, or runs in a remote worktree installs nothing. Test: Task 4's `SimulatorTarget` tests don't reach this; the guard is a single condition in `installRunScriptApp`, checked by hand in Task 5.
2. The worktree's selection is a simulator that no longer exists: `SimulatorTarget.choose` falls back to a booted one. Test in Task 4.
3. `device_set_appearance` with no setting at all is refused, not a silent no-op. Tests in Task 2 (Swift decode and Rust parse).
4. A push payload over 4096 bytes, or without an `aps` object, is refused before simctl runs. Tests in Task 1 (`SimulatorPushPayload`) and Task 2 (Rust).
5. A runtime that answers `unsupported` for a setting gives the agent `"unsupported"` for that field, not an error. Test in Task 1 (read-back parsing) and Task 2 (`DeviceAgentControl`).

---

### Task 1: Simulator settings in AlasCore

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorSettings.swift`
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorControl.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/SimulatorSettingsTests.swift`

**Interfaces:**
- Produces:

```swift
public enum SimulatorAppearance: String, CaseIterable, Sendable { case light, dark }
public enum SimulatorTextSize: String, CaseIterable, Sendable { /* 12 simctl names */; public var label: String }
public enum SimulatorReadBack<Value: Equatable & Sendable>: Equatable, Sendable { case value(Value), unsupported, unknown }
public struct SimulatorDisplaySettings: Equatable, Sendable {
    public var appearance: SimulatorReadBack<SimulatorAppearance>
    public var textSize: SimulatorReadBack<SimulatorTextSize>
    public var increaseContrast: SimulatorReadBack<Bool>
    public static func parse(appearance: String, contentSize: String, increaseContrast: String) -> SimulatorDisplaySettings
    public var json: [String: Any]   // "appearance", "text_size", "increase_contrast"
}
public enum SimulatorPrivacyService: String, CaseIterable, Sendable { /* 13 */; public var label: String }
public enum SimulatorPrivacyAction: String, CaseIterable, Sendable { case grant, revoke, reset }
public struct SimulatorApp: Equatable, Sendable, Identifiable { public let bundleID: String; public let name: String }
public enum SimulatorAppList { public static func parse(_ plist: Data) -> [SimulatorApp] }
public enum SimulatorPushPayload { public static func problem(_ data: Data) -> String? }
public struct SimulatorLocation: Equatable, Sendable { public let latitude: Double; public let longitude: Double }
public protocol SimulatorSettingsControl: Sendable {
    func display(udid: String) async throws -> SimulatorDisplaySettings
    func setDisplay(udid: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?) async throws -> SimulatorDisplaySettings
    func setPermission(udid: String, bundleID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws
    func setLocation(udid: String, _ location: SimulatorLocation?) async throws
    func push(udid: String, bundleID: String, payload: Data) async throws
    func openURL(udid: String, url: String) async throws
    func userApps(udid: String) async throws -> [SimulatorApp]
    func isInstalled(udid: String, bundleID: String) async -> Bool
}
public struct LiveSimulatorSettings: SimulatorSettingsControl { public init() }
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import AlasCore

struct SimulatorSettingsTests {
    @Test(arguments: [
        ("dark", "accessibility-large", "enabled",
         SimulatorDisplaySettings(appearance: .value(.dark), textSize: .value(.accessibilityLarge), increaseContrast: .value(true))),
        ("unsupported", "unsupported", "unsupported",
         SimulatorDisplaySettings(appearance: .unsupported, textSize: .unsupported, increaseContrast: .unsupported)),
        ("unknown", "nonsense", "", SimulatorDisplaySettings(appearance: .unknown, textSize: .unknown, increaseContrast: .unknown)),
    ] as [(String, String, String, SimulatorDisplaySettings)])
    func readBackParsesValuesUnsupportedAndUnknown(appearance: String, size: String, contrast: String, expected: SimulatorDisplaySettings) {
        #expect(SimulatorDisplaySettings.parse(appearance: appearance + "\n", contentSize: size, increaseContrast: contrast) == expected)
    }

    @Test func readBackJSONReportsUnsupportedFields() {
        let settings = SimulatorDisplaySettings(appearance: .value(.light), textSize: .unsupported, increaseContrast: .value(false))
        let data = try! JSONSerialization.data(withJSONObject: settings.json, options: .sortedKeys)
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"appearance":"light","increase_contrast":false,"text_size":"unsupported"}"#)
    }

    @Test func appListKeepsOnlyTheUsersAppsByName() throws {
        let plist: [String: Any] = [
            "com.apple.Preferences": ["ApplicationType": "System", "CFBundleDisplayName": "Settings"],
            "com.example.zeta": ["ApplicationType": "User", "CFBundleName": "Zeta"],
            "com.example.hello": ["ApplicationType": "User", "CFBundleDisplayName": "Hello"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(SimulatorAppList.parse(data) == [
            SimulatorApp(bundleID: "com.example.hello", name: "Hello"),
            SimulatorApp(bundleID: "com.example.zeta", name: "Zeta"),
        ])
    }

    @Test(arguments: [
        (#"{"aps":{"alert":"hi"}}"#, nil as String?),
        (#"[1]"#, "The payload must be a JSON object."),
        (#"{"alert":"hi"}"#, "The payload needs an \"aps\" object."),
        (#"{"aps":"hi"}"#, "The payload needs an \"aps\" object."),
        ("{\"aps\":{},\"x\":\"" + String(repeating: "a", count: 4100) + "\"}", "The payload is over 4096 bytes."),
    ] as [(String, String?)])
    func pushPayloadsAreCheckedBeforeSending(payload: String, problem: String?) {
        #expect(SimulatorPushPayload.problem(Data(payload.utf8)) == problem)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path Packages/AlasCore --filter SimulatorSettingsTests`
Expected: build errors (`cannot find 'SimulatorDisplaySettings'`).

- [ ] **Step 3: Implement `SimulatorSettings.swift`**

```swift
import Foundation

public enum SimulatorAppearance: String, CaseIterable, Sendable {
    case light, dark
}

/// simctl's preferred content size categories, smallest first.
public enum SimulatorTextSize: String, CaseIterable, Sendable {
    case extraSmall = "extra-small", small, medium, large
    case extraLarge = "extra-large", extraExtraLarge = "extra-extra-large"
    case extraExtraExtraLarge = "extra-extra-extra-large"
    case accessibilityMedium = "accessibility-medium", accessibilityLarge = "accessibility-large"
    case accessibilityExtraLarge = "accessibility-extra-large"
    case accessibilityExtraExtraLarge = "accessibility-extra-extra-large"
    case accessibilityExtraExtraExtraLarge = "accessibility-extra-extra-extra-large"

    public var label: String {
        switch self {
        case .extraSmall: "Extra Small"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        case .extraExtraLarge: "XXL"
        case .extraExtraExtraLarge: "XXXL"
        case .accessibilityMedium: "Accessibility M"
        case .accessibilityLarge: "Accessibility L"
        case .accessibilityExtraLarge: "Accessibility XL"
        case .accessibilityExtraExtraLarge: "Accessibility XXL"
        case .accessibilityExtraExtraExtraLarge: "Accessibility XXXL"
        }
    }
}

/// What simctl read back for a setting.
public enum SimulatorReadBack<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    /// The runtime doesn't have this setting.
    case unsupported
    /// simctl couldn't tell.
    case unknown

    init(_ output: String, parse: (String) -> Value?) {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "unsupported" { self = .unsupported } else { self = parse(text).map { .value($0) } ?? .unknown }
    }

    var jsonValue: Any {
        switch self {
        case .value(let value as SimulatorAppearance): value.rawValue
        case .value(let value as SimulatorTextSize): value.rawValue
        case .value(let value): value
        case .unsupported: "unsupported"
        case .unknown: "unknown"
        }
    }
}

public struct SimulatorDisplaySettings: Equatable, Sendable {
    public var appearance: SimulatorReadBack<SimulatorAppearance>
    public var textSize: SimulatorReadBack<SimulatorTextSize>
    public var increaseContrast: SimulatorReadBack<Bool>

    public init(appearance: SimulatorReadBack<SimulatorAppearance>, textSize: SimulatorReadBack<SimulatorTextSize>, increaseContrast: SimulatorReadBack<Bool>) {
        self.appearance = appearance
        self.textSize = textSize
        self.increaseContrast = increaseContrast
    }

    /// From the output of `simctl ui <udid> appearance|content_size|increase_contrast`.
    public static func parse(appearance: String, contentSize: String, increaseContrast: String) -> SimulatorDisplaySettings {
        SimulatorDisplaySettings(
            appearance: .init(appearance, parse: SimulatorAppearance.init(rawValue:)),
            textSize: .init(contentSize, parse: SimulatorTextSize.init(rawValue:)),
            increaseContrast: .init(increaseContrast) { $0 == "enabled" ? true : $0 == "disabled" ? false : nil }
        )
    }

    /// What `device_set_appearance` returns.
    public var json: [String: Any] {
        ["appearance": appearance.jsonValue, "text_size": textSize.jsonValue, "increase_contrast": increaseContrast.jsonValue]
    }
}

/// simctl privacy's services.
public enum SimulatorPrivacyService: String, CaseIterable, Sendable {
    case all, calendar
    case contactsLimited = "contacts-limited", contacts, location
    case locationAlways = "location-always"
    case photosAdd = "photos-add", photos
    case mediaLibrary = "media-library", microphone, motion, reminders, siri

    public var label: String {
        switch self {
        case .all: "All Services"
        case .calendar: "Calendar"
        case .contactsLimited: "Contacts (Limited)"
        case .contacts: "Contacts"
        case .location: "Location (In Use)"
        case .locationAlways: "Location (Always)"
        case .photosAdd: "Photos (Add Only)"
        case .photos: "Photos"
        case .mediaLibrary: "Media Library"
        case .microphone: "Microphone"
        case .motion: "Motion & Fitness"
        case .reminders: "Reminders"
        case .siri: "Siri"
        }
    }
}

public enum SimulatorPrivacyAction: String, CaseIterable, Sendable {
    case grant, revoke, reset
}

public struct SimulatorApp: Equatable, Sendable, Identifiable {
    public let bundleID: String
    public let name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public enum SimulatorAppList {
    /// The user's apps in `simctl listapps` output, by name.
    public static func parse(_ plist: Data) -> [SimulatorApp] {
        guard let apps = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: [String: Any]] else {
            return []
        }
        return apps.compactMap { bundleID, info in
            guard info["ApplicationType"] as? String == "User" else { return nil }
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID
            return SimulatorApp(bundleID: bundleID, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public enum SimulatorPushPayload {
    public static let maxBytes = 4096

    /// Why simctl would refuse the payload, or nil.
    public static func problem(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "The payload must be a JSON object."
        }
        guard object["aps"] is [String: Any] else { return "The payload needs an \"aps\" object." }
        guard data.count <= maxBytes else { return "The payload is over \(maxBytes) bytes." }
        return nil
    }
}

public struct SimulatorLocation: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// simctl's settings commands, behind a protocol so `DeviceAgentControl` can be tested with a fake.
public protocol SimulatorSettingsControl: Sendable {
    func display(udid: String) async throws -> SimulatorDisplaySettings
    func setDisplay(
        udid: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?
    ) async throws -> SimulatorDisplaySettings
    func setPermission(udid: String, bundleID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws
    func setLocation(udid: String, _ location: SimulatorLocation?) async throws
    func push(udid: String, bundleID: String, payload: Data) async throws
    func openURL(udid: String, url: String) async throws
    func userApps(udid: String) async throws -> [SimulatorApp]
    func isInstalled(udid: String, bundleID: String) async -> Bool
}

public struct LiveSimulatorSettings: SimulatorSettingsControl {
    public init() {}

    public func display(udid: String) async throws -> SimulatorDisplaySettings {
        try await SimulatorControl.display(udid: udid)
    }

    public func setDisplay(
        udid: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?
    ) async throws -> SimulatorDisplaySettings {
        if let appearance { try await SimulatorControl.ui(udid: udid, "appearance", appearance.rawValue) }
        if let textSize { try await SimulatorControl.ui(udid: udid, "content_size", textSize.rawValue) }
        if let increaseContrast {
            try await SimulatorControl.ui(udid: udid, "increase_contrast", increaseContrast ? "enabled" : "disabled")
        }
        return try await SimulatorControl.display(udid: udid)
    }

    public func setPermission(udid: String, bundleID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws {
        try await SimulatorControl.privacy(udid: udid, action: action, service: service, bundleID: bundleID)
    }

    public func setLocation(udid: String, _ location: SimulatorLocation?) async throws {
        try await SimulatorControl.location(udid: udid, location)
    }

    public func push(udid: String, bundleID: String, payload: Data) async throws {
        try await SimulatorControl.push(udid: udid, bundleID: bundleID, payload: payload)
    }

    public func openURL(udid: String, url: String) async throws {
        try await SimulatorControl.openURL(udid: udid, url: url)
    }

    public func userApps(udid: String) async throws -> [SimulatorApp] {
        try await SimulatorControl.userApps(udid: udid)
    }

    public func isInstalled(udid: String, bundleID: String) async -> Bool {
        await SimulatorControl.isInstalled(udid: udid, bundleID: bundleID)
    }
}
```

- [ ] **Step 4: Add the simctl wrappers to `SimulatorControl`**

After `launchedPID`:

```swift
    /// Runs `simctl ui <udid> <option> <value>`.
    static func ui(udid: String, _ option: String, _ value: String) async throws {
        let result = try await Process.run(xcrun, args: ["simctl", "ui", udid, option, value])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    public static func display(udid: String) async throws -> SimulatorDisplaySettings {
        func read(_ option: String) async throws -> String {
            let result = try await Process.run(xcrun, args: ["simctl", "ui", udid, option])
            guard result.exitCode == 0 else { throw SimulatorControlError(result) }
            return result.stdout
        }
        return SimulatorDisplaySettings.parse(
            appearance: try await read("appearance"),
            contentSize: try await read("content_size"),
            increaseContrast: try await read("increase_contrast")
        )
    }

    public static func privacy(
        udid: String, action: SimulatorPrivacyAction, service: SimulatorPrivacyService, bundleID: String
    ) async throws {
        let result = try await Process.run(xcrun, args: ["simctl", "privacy", udid, action.rawValue, service.rawValue, bundleID])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    /// Sets the simulated location, or clears it when `location` is nil.
    public static func location(udid: String, _ location: SimulatorLocation?) async throws {
        let args = location.map { ["simctl", "location", udid, "set", "\($0.latitude),\($0.longitude)"] }
            ?? ["simctl", "location", udid, "clear"]
        let result = try await Process.run(xcrun, args: args)
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    public static func push(udid: String, bundleID: String, payload: Data) async throws {
        let result = try await Process.run(
            xcrun, args: ["simctl", "push", udid, bundleID, "-"], stdin: String(decoding: payload, as: UTF8.self)
        )
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    public static func openURL(udid: String, url: String) async throws {
        let result = try await Process.run(xcrun, args: ["simctl", "openurl", udid, url])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    public static func userApps(udid: String) async throws -> [SimulatorApp] {
        let result = try await Process.run(xcrun, args: ["simctl", "listapps", udid])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
        return SimulatorAppList.parse(Data(result.stdout.utf8))
    }

    public static func isInstalled(udid: String, bundleID: String) async -> Bool {
        (try? await Process.run(xcrun, args: ["simctl", "get_app_container", udid, bundleID]))?.exitCode == 0
    }
```

Make `launch(udid:bundleID:)` use `isInstalled` for its not-installed check instead of its own `get_app_container` call.

- [ ] **Step 5: Run the tests to see them pass**

Run: `swift test --package-path Packages/AlasCore --filter 'SimulatorSettingsTests|SimulatorAppBundleTests'`
Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/AlasCore
git commit -m "feat(devices): read and change simulator settings with simctl"
```

---

### Task 2: The five agent tools

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Harness/DeviceCommand.swift`, `Packages/AlasCore/Tests/AlasCoreTests/DeviceCommandTests.swift`
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift` (`builtInToolNames`, the device paragraph), `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift` (tool inventory)
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift`, `Alas/Sources/App/AppState.swift` (`deviceControl`), `AlasTests/DeviceAgentControlTests.swift`
- Modify: `AlasCLI/crates/alas/src/mcp.rs`, `AlasCLI/crates/alas-client/src/lib.rs`

**Interfaces:**
- Consumes: Task 1's types and `SimulatorSettingsControl`.
- Produces:

```swift
// DeviceCommand
case setAppearance(udid: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?)
case setPermission(udid: String, bundleID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction)
case setLocation(udid: String, location: SimulatorLocation?)   // nil clears
case push(udid: String, bundleID: String, payload: String)      // JSON text, sorted keys
case openURL(udid: String, url: String)
// DeviceAgentControl.init(..., settings: any SimulatorSettingsControl, ...) after `launch:`
```

```rust
// alas_client::DeviceCommand
SetAppearance { udid: String, appearance: Option<String>, text_size: Option<String>, increase_contrast: Option<bool> },
SetPermission { udid: String, bundle_id: String, service: String, action: String },
SetLocation { udid: String, location: Option<(f64, f64)> },
Push { udid: String, bundle_id: String, payload: serde_json::Value },
OpenUrl { udid: String, url: String },
```

- [ ] **Step 1: Failing Swift decode tests**

In `DeviceCommandTests.decodesEachActionWithDefaults`, add rows:

```swift
        ("device_set_appearance", #"{"udid":"U","appearance":"dark","text_size":"large"}"#,
         .setAppearance(udid: "U", appearance: .dark, textSize: .large, increaseContrast: nil)),
        ("device_set_permission", #"{"udid":"U","bundle_id":"b","service":"photos","action":"grant"}"#,
         .setPermission(udid: "U", bundleID: "b", service: .photos, action: .grant)),
        ("device_set_location", #"{"udid":"U","latitude":41.3874,"longitude":2.1686}"#,
         .setLocation(udid: "U", location: SimulatorLocation(latitude: 41.3874, longitude: 2.1686))),
        ("device_set_location", #"{"udid":"U","clear":true}"#, .setLocation(udid: "U", location: nil)),
        ("device_push", #"{"udid":"U","bundle_id":"b","payload":{"aps":{"alert":"hi"}}}"#,
         .push(udid: "U", bundleID: "b", payload: #"{"aps":{"alert":"hi"}}"#)),
        ("device_open_url", #"{"udid":"U","url":"myapp://home"}"#, .openURL(udid: "U", url: "myapp://home")),
```

In `refusesWhatAnActionDoesNotTake`:

```swift
        ("device_set_appearance", #"{"udid":"U"}"#),
        ("device_set_appearance", #"{"udid":"U","text_size":"huge"}"#),
        ("device_set_permission", #"{"udid":"U","bundle_id":"b","service":"camera","action":"grant"}"#),
        ("device_set_location", #"{"udid":"U","latitude":91,"longitude":0}"#),
        ("device_set_location", #"{"udid":"U","latitude":1,"longitude":2,"clear":true}"#),
        ("device_push", #"{"udid":"U","bundle_id":"b","payload":{"alert":"hi"}}"#),
        ("device_open_url", #"{"udid":"U","url":"no scheme"}"#),
```

Run `swift test --package-path Packages/AlasCore --filter DeviceCommandTests`: build errors.

- [ ] **Step 2: Implement the Swift commands**

In `DeviceCommand.swift`, add `import AlasFeatures`, the five cases above, `toolName` entries (`device_set_appearance`, `device_set_permission`, `device_set_location`, `device_push`, `device_open_url`) and their `udid`. Add `Params` fields `appearance`, `text_size`, `increase_contrast: Bool?`, `bundle_id` (exists), `service`, `action`, `latitude: Double?`, `longitude: Double?`, `clear: Bool?`, `url`. Allowed keys:

```swift
        "device_set_appearance": ["udid", "appearance", "text_size", "increase_contrast"],
        "device_set_permission": ["udid", "bundle_id", "service", "action"],
        "device_set_location": ["udid", "latitude", "longitude", "clear"],
        "device_push": ["udid", "bundle_id", "payload"],
        "device_open_url": ["udid", "url"],
```

Decoding, before `default:`:

```swift
        case "device_set_appearance":
            let appearance = try params.appearance.map { try enumValue(SimulatorAppearance.self, $0) }
            let textSize = try params.text_size.map { try enumValue(SimulatorTextSize.self, $0) }
            guard appearance != nil || textSize != nil || params.increase_contrast != nil else { throw AlasCLIRequestError.malformed }
            return .setAppearance(udid: try udid(), appearance: appearance, textSize: textSize, increaseContrast: params.increase_contrast)
        case "device_set_permission":
            guard let service = params.service.flatMap(SimulatorPrivacyService.init(rawValue:)),
                  let action = params.action.flatMap(SimulatorPrivacyAction.init(rawValue:)) else { throw AlasCLIRequestError.malformed }
            return .setPermission(udid: try udid(), bundleID: try bundleID(), service: service, action: action)
        case "device_set_location":
            switch (params.latitude, params.longitude, params.clear) {
            case (let latitude?, let longitude?, nil) where (-90...90).contains(latitude) && (-180...180).contains(longitude):
                return .setLocation(udid: try udid(), location: SimulatorLocation(latitude: latitude, longitude: longitude))
            case (nil, nil, true?):
                return .setLocation(udid: try udid(), location: nil)
            default:
                throw AlasCLIRequestError.malformed
            }
        case "device_push":
            guard let payload = (raw?["params"] as? [String: Any])?["payload"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys),
                  SimulatorPushPayload.problem(data) == nil else { throw AlasCLIRequestError.malformed }
            return .push(udid: try udid(), bundleID: try bundleID(), payload: String(decoding: data, as: UTF8.self))
        case "device_open_url":
            guard let url = params.url, url.utf8.count <= 4096, let scheme = URLComponents(string: url)?.scheme, !scheme.isEmpty else {
                throw AlasCLIRequestError.malformed
            }
            return .openURL(udid: try udid(), url: url)
```

with helpers next to `udid()`:

```swift
        func bundleID() throws -> String {
            guard let bundleID = params.bundle_id, !bundleID.isEmpty, bundleID.utf8.count <= 255 else { throw AlasCLIRequestError.malformed }
            return bundleID
        }
        func enumValue<E: RawRepresentable>(_: E.Type, _ raw: String) throws -> E where E.RawValue == String {
            guard let value = E(rawValue: raw) else { throw AlasCLIRequestError.malformed }
            return value
        }
```

Use `bundleID()` in `device_launch` too. `payload` is not in `Params` (it's an object); it is read from `raw`.

Add the five names after `"device_launch",` in `builtInToolNames`, and in the device paragraph after the install sentence:
`"To test dark mode, Dynamic Type, permissions, location, notifications or deep links, use device_set_appearance, device_set_permission, device_set_location, device_push and device_open_url. "`.
Update `ACPMCPPromptPreambleTests.toolNameInventory` to match.

Run `swift test --package-path Packages/AlasCore --filter DeviceCommandTests`: pass.

- [ ] **Step 3: Failing `DeviceAgentControl` tests**

Add a fake to `DeviceAgentControlTests`:

```swift
    final class FakeSettings: SimulatorSettingsControl, @unchecked Sendable {
        var calls: [String] = []
        var installed: Set<String> = ["com.example.hello"]
        var read = SimulatorDisplaySettings(appearance: .value(.light), textSize: .value(.large), increaseContrast: .unsupported)

        func display(udid: String) async throws -> SimulatorDisplaySettings { read }
        func setDisplay(udid: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?) async throws -> SimulatorDisplaySettings {
            calls.append("display \(appearance?.rawValue ?? "-")")
            if let appearance { read.appearance = .value(appearance) }
            return read
        }
        func setPermission(udid: String, bundleID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws {
            calls.append("privacy \(action.rawValue) \(service.rawValue) \(bundleID)")
        }
        func setLocation(udid: String, _ location: SimulatorLocation?) async throws { calls.append("location") }
        func push(udid: String, bundleID: String, payload: Data) async throws { calls.append("push \(bundleID)") }
        func openURL(udid: String, url: String) async throws { calls.append("open \(url)") }
        func userApps(udid: String) async throws -> [SimulatorApp] { [] }
        func isInstalled(udid: String, bundleID: String) async -> Bool { installed.contains(bundleID) }
    }
```

Give `control(_:installs:sleep:)` a `settings: FakeSettings = FakeSettings()` parameter passed as `settings:`, and pass `settings: FakeSettings()` in the suite's other `DeviceAgentControl(...)` calls. Then:

```swift
    @Test func settingsAreHeldDuringATakeoverAndReturnWhatSimctlReadBack() async throws {
        let settings = FakeSettings()
        let control = control(FakeInput(), settings: settings, sleep: Self.untilCancelled)
        control.takeOver(udid: "on")
        async let changed = control.perform(
            .setAppearance(udid: "on", appearance: .dark, textSize: nil, increaseContrast: nil), sessionID: "s"
        )
        try await eventually("call is held") { control.waitingSessions(udid: "on") == ["s"] }
        #expect(settings.calls.isEmpty)
        control.handBack(udid: "on")
        #expect(await changed == .text([#"{"appearance":"dark","increase_contrast":"unsupported","text_size":"large"}"#]))
    }

    @Test(arguments: [
        DeviceCommand.setPermission(udid: "on", bundleID: "com.example.gone", service: .photos, action: .grant),
        .push(udid: "on", bundleID: "com.example.gone", payload: #"{"aps":{}}"#),
    ])
    func permissionsAndPushNeedTheAppInstalled(command: DeviceCommand) async {
        let settings = FakeSettings()
        let response = await control(FakeInput(), settings: settings).perform(command, sessionID: "s")
        #expect(error(response) == "device_app_not_installed: com.example.gone isn't installed on iPhone.")
        #expect(settings.calls.isEmpty)
    }
```

Run the suite (`xcodebuild … -only-testing AlasTests/DeviceAgentControlTests test`): build errors.

- [ ] **Step 4: Implement them in `DeviceAgentControl`**

Store `@ObservationIgnored private let settings: any SimulatorSettingsControl`, an init parameter `settings: any SimulatorSettingsControl` after `launch:`. All five commands are input calls:

```swift
        case .tap, .swipe, .type, .button, .install, .launch,
             .setAppearance, .setPermission, .setLocation, .push, .openURL: true
```

Cases in the `switch command`:

```swift
        case .setAppearance(_, let appearance, let textSize, let increaseContrast):
            return await settingsCall {
                .text([Self.json(try await settings.setDisplay(
                    udid: udid, appearance: appearance, textSize: textSize, increaseContrast: increaseContrast
                ).json)])
            }
        case .setPermission(_, let bundleID, let service, let action):
            guard await settings.isInstalled(udid: udid, bundleID: bundleID) else { return Self.notInstalled(bundleID, on: device) }
            return await settingsCall {
                try await settings.setPermission(udid: udid, bundleID: bundleID, service: service, action: action)
                return .text([Self.json(["ok": true])])
            }
        case .setLocation(_, let location):
            return await settingsCall {
                try await settings.setLocation(udid: udid, location)
                return .text([Self.json(["ok": true])])
            }
        case .push(_, let bundleID, let payload):
            guard await settings.isInstalled(udid: udid, bundleID: bundleID) else { return Self.notInstalled(bundleID, on: device) }
            return await settingsCall {
                try await settings.push(udid: udid, bundleID: bundleID, payload: Data(payload.utf8))
                return .text([Self.json(["ok": true])])
            }
        case .openURL(_, let url):
            return await settingsCall {
                try await settings.openURL(udid: udid, url: url)
                return .text([Self.json(["ok": true])])
            }
```

with:

```swift
    private func settingsCall(_ body: () async throws -> AlasCLIResponse) async -> AlasCLIResponse {
        do { return try await body() } catch { return .error("device_settings_failed: \(error.localizedDescription)") }
    }

    private static func notInstalled(_ bundleID: String, on device: SimulatorDevice) -> AlasCLIResponse {
        .error("device_app_not_installed: \(bundleID) isn't installed on \(device.name).")
    }
```

Use `notInstalled` in the existing `.launch` case too. In `AppState.deviceControl`, pass `settings: LiveSimulatorSettings()`.

Run `DeviceAgentControlTests` and `ACPMCPPromptPreambleTests`: pass.

- [ ] **Step 5: Failing Rust tests**

In `mcp.rs` `device_tools_validate_arguments_and_map_to_commands`, before the error loop:

```rust
        assert_eq!(
            map("device_set_appearance", json!({ "udid": "U", "appearance": "dark" })).unwrap(),
            Command::Device(DeviceCommand::SetAppearance {
                udid: "U".into(),
                appearance: Some("dark".into()),
                text_size: None,
                increase_contrast: None
            })
        );
        assert_eq!(
            map("device_set_location", json!({ "udid": "U", "clear": true })).unwrap(),
            Command::Device(DeviceCommand::SetLocation { udid: "U".into(), location: None })
        );
        assert_eq!(
            map("device_push", json!({ "udid": "U", "bundle_id": "b", "payload": { "aps": { "alert": "hi" } } })).unwrap(),
            Command::Device(DeviceCommand::Push {
                udid: "U".into(),
                bundle_id: "b".into(),
                payload: json!({ "aps": { "alert": "hi" } })
            })
        );
```

and to the error table:

```rust
            ("device_set_appearance", json!({ "udid": "U" }), "pass at least one of appearance, text_size, increase_contrast"),
            ("device_set_permission", json!({ "udid": "U", "bundle_id": "b", "service": "camera", "action": "grant" }), "service must be one of all, calendar, contacts-limited, contacts, location, location-always, photos-add, photos, media-library, microphone, motion, reminders, siri"),
            ("device_set_location", json!({ "udid": "U", "latitude": 91, "longitude": 0 }), "latitude must be a number from -90 to 90"),
            ("device_set_location", json!({ "udid": "U" }), "pass latitude and longitude, or clear: true"),
            ("device_push", json!({ "udid": "U", "bundle_id": "b", "payload": { "alert": "hi" } }), "payload must be a JSON object with an 'aps' object, at most 4096 bytes"),
            ("device_open_url", json!({ "udid": "U", "url": "nothing" }), "url must have a scheme, such as https: or myapp:"),
```

Add the five names after `"device_launch",` in the tool-inventory assertion and the destructive-hint list. In `alas-client`, extend `device_commands_serialize_as_params_only_requests`:

```rust
        assert_eq!(
            build(DeviceCommand::SetLocation { udid: udid(), location: Some((41.5, 2.0)) }),
            ("device_set_location".into(), serde_json::json!({ "udid": "U-1", "latitude": 41.5, "longitude": 2.0 }))
        );
        assert_eq!(
            build(DeviceCommand::SetLocation { udid: udid(), location: None }).1,
            serde_json::json!({ "udid": "U-1", "clear": true })
        );
```

Run `cargo test --manifest-path AlasCLI/Cargo.toml -p alas -p alas-client`: build errors.

- [ ] **Step 6: Implement the Rust side**

`alas-client`: the five variants above; `includes_screenshot` returns false for them; `device_request`:

```rust
        DeviceCommand::SetAppearance { udid, appearance, text_size, increase_contrast } => {
            let mut params = json!({ "udid": udid });
            if let Some(value) = appearance { params["appearance"] = json!(value); }
            if let Some(value) = text_size { params["text_size"] = json!(value); }
            if let Some(value) = increase_contrast { params["increase_contrast"] = json!(value); }
            ("device_set_appearance", params)
        }
        DeviceCommand::SetPermission { udid, bundle_id, service, action } => (
            "device_set_permission",
            json!({ "udid": udid, "bundle_id": bundle_id, "service": service, "action": action }),
        ),
        DeviceCommand::SetLocation { udid, location } => match location {
            Some((latitude, longitude)) => (
                "device_set_location",
                json!({ "udid": udid, "latitude": latitude, "longitude": longitude }),
            ),
            None => ("device_set_location", json!({ "udid": udid, "clear": true })),
        },
        DeviceCommand::Push { udid, bundle_id, payload } => {
            ("device_push", json!({ "udid": udid, "bundle_id": bundle_id, "payload": payload }))
        }
        DeviceCommand::OpenUrl { udid, url } => ("device_open_url", json!({ "udid": udid, "url": url })),
```

`mcp.rs`: constants

```rust
const DEVICE_TEXT_SIZES: &[&str] = &["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large", "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large"];
const DEVICE_PRIVACY_SERVICES: &[&str] = &["all", "calendar", "contacts-limited", "contacts", "location", "location-always", "photos-add", "photos", "media-library", "microphone", "motion", "reminders", "siri"];
const DEVICE_PUSH_MAX_BYTES: usize = 4096;
```

Five definitions after `device_launch`, each `destructiveHint: true` and ending with `{DEVICE_DRIVING_NOTE}`:
- `device_set_appearance`: "Change the simulator's appearance (light or dark), text size (Dynamic Type) and Increase Contrast; pass at least one. Returns the three values read back; a value is \"unsupported\" when the runtime lacks that setting." Properties: `appearance` enum `["light","dark"]`, `text_size` enum `DEVICE_TEXT_SIZES`, `increase_contrast` boolean.
- `device_set_permission`: "Grant, revoke or reset a privacy permission for an installed app without the system prompt. Changing a permission may end the running app." Properties: `bundle_id`, `service` enum, `action` enum `["grant","revoke","reset"]`; all required.
- `device_set_location`: "Set the simulated location, or clear it." Properties: `latitude` (−90…90), `longitude` (−180…180), `clear` boolean.
- `device_push`: "Deliver a push notification to an installed app. payload is the notification's JSON, with an aps object, at most 4096 bytes." Properties: `bundle_id`, `payload` object; required.
- `device_open_url`: "Open a URL on the simulator: a web page in Safari, or a deep link into an app." Property `url` (maxLength 4096).

Parsing, after `"device_launch"`:

```rust
        "device_set_appearance" => {
            reject_arguments(args, name, &["udid", "appearance", "text_size", "increase_contrast"])?;
            let appearance = optional_enum(args, "appearance", &["light", "dark"])?.map(String::from);
            let text_size = optional_enum(args, "text_size", DEVICE_TEXT_SIZES)?.map(String::from);
            let increase_contrast = optional_bool(args, "increase_contrast")?;
            if appearance.is_none() && text_size.is_none() && increase_contrast.is_none() {
                return Err("pass at least one of appearance, text_size, increase_contrast".into());
            }
            Ok(Command::Device(alas_client::DeviceCommand::SetAppearance {
                udid: required_limited_string(args, "udid", 64)?, appearance, text_size, increase_contrast,
            }))
        }
        "device_set_permission" => {
            reject_arguments(args, name, &["udid", "bundle_id", "service", "action"])?;
            Ok(Command::Device(alas_client::DeviceCommand::SetPermission {
                udid: required_limited_string(args, "udid", 64)?,
                bundle_id: required_limited_string(args, "bundle_id", 255)?,
                service: optional_enum(args, "service", DEVICE_PRIVACY_SERVICES)?
                    .ok_or_else(|| "missing required argument 'service'".to_string())?.into(),
                action: optional_enum(args, "action", &["grant", "revoke", "reset"])?
                    .ok_or_else(|| "missing required argument 'action'".to_string())?.into(),
            }))
        }
        "device_set_location" => {
            reject_arguments(args, name, &["udid", "latitude", "longitude", "clear"])?;
            let clear = optional_bool(args, "clear")?.unwrap_or(false);
            let location = match (args.get("latitude"), args.get("longitude"), clear) {
                (Some(_), Some(_), false) => Some((
                    required_bounded_f64(args, "latitude", -90.0, 90.0)?,
                    required_bounded_f64(args, "longitude", -180.0, 180.0)?,
                )),
                (None, None, true) => None,
                _ => return Err("pass latitude and longitude, or clear: true".into()),
            };
            Ok(Command::Device(alas_client::DeviceCommand::SetLocation {
                udid: required_limited_string(args, "udid", 64)?, location,
            }))
        }
        "device_push" => {
            reject_arguments(args, name, &["udid", "bundle_id", "payload"])?;
            let payload = args.get("payload").cloned().unwrap_or(Value::Null);
            let fits = payload.get("aps").is_some_and(Value::is_object)
                && serde_json::to_vec(&payload).map_or(false, |bytes| bytes.len() <= DEVICE_PUSH_MAX_BYTES);
            if !payload.is_object() || !fits {
                return Err(format!("payload must be a JSON object with an 'aps' object, at most {DEVICE_PUSH_MAX_BYTES} bytes"));
            }
            Ok(Command::Device(alas_client::DeviceCommand::Push {
                udid: required_limited_string(args, "udid", 64)?,
                bundle_id: required_limited_string(args, "bundle_id", 255)?,
                payload,
            }))
        }
        "device_open_url" => {
            reject_arguments(args, name, &["udid", "url"])?;
            let url = required_limited_string(args, "url", 4096)?;
            let has_scheme = url.split_once(':').is_some_and(|(scheme, _)| {
                !scheme.is_empty()
                    && scheme.starts_with(|c: char| c.is_ascii_alphabetic())
                    && scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
            });
            if !has_scheme {
                return Err("url must have a scheme, such as https: or myapp:".into());
            }
            Ok(Command::Device(alas_client::DeviceCommand::OpenUrl {
                udid: required_limited_string(args, "udid", 64)?, url,
            }))
        }
```

Fix any other exhaustive `match` over `DeviceCommand` the compiler reports.

- [ ] **Step 7: Run all affected tests**

```bash
swift test --package-path Packages/AlasCore --filter 'DeviceCommandTests|SimulatorSettingsTests'
cargo test --manifest-path AlasCLI/Cargo.toml -p alas -p alas-client
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/DeviceAgentControlTests -only-testing AlasTests/ACPMCPPromptPreambleTests test
```

- [ ] **Step 8: Commit** `feat(devices): let agents change simulator settings`

---

### Task 3: The settings popover

**Files:**
- Create: `Alas/Sources/Devices/DeviceSettingsPopover.swift`
- Modify: `Alas/Sources/Devices/DevicesSwitcher.swift` (`DevicesActions`), `Alas/Sources/Right/RightPaneView.swift` (`devicesActions`)

**Interfaces:**
- Consumes: Task 1's types; `LiveSimulatorSettings`.
- Produces: `DeviceSettingsPopover(udid: String, settings: any SimulatorSettingsControl)`; `DevicesActions` gains `canChangeSettings: Bool`.

No automated test: view composition over Task 1's tested pieces.

- [ ] **Step 1: The popover**

```swift
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

    private static let places: [(String, SimulatorLocation)] = [
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
        .frame(width: 320)
        .task { await load() }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.color("fg-dim"))
            content()
        }
    }

    @ViewBuilder
    private var displayRows: some View {
        if let display {
            row("Appearance", supported: display.appearance) {
                Picker("", selection: Binding(
                    get: { if case .value(let value) = display.appearance { value } else { .light } },
                    set: { value in change { try await settings.setDisplay(udid: udid, appearance: value, textSize: nil, increaseContrast: nil) } }
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
                    Stepper(size.label, onIncrement: { step(index, by: 1) }, onDecrement: { step(index, by: -1) })
                }
            }
            row("Increase contrast", supported: display.increaseContrast) {
                Toggle("", isOn: Binding(
                    get: { display.increaseContrast == .value(true) },
                    set: { value in change { try await settings.setDisplay(udid: udid, appearance: nil, textSize: nil, increaseContrast: value) } }
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

    private func row<Value>(_ title: String, supported: SimulatorReadBack<Value>, @ViewBuilder _ control: () -> some View) -> some View {
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

    private func step(_ index: Int, by delta: Int) {
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

    @ViewBuilder
    private var appRows: some View {
        if apps.isEmpty {
            note("No apps of yours are installed.", tone: "fg-faint")
        } else {
            Picker("App", selection: $appID) {
                ForEach(apps) { Text($0.name).tag(Optional($0.bundleID)) }
            }
            HStack {
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
        Task {
            do {
                try await settings.setPermission(udid: udid, bundleID: appID, service: service, action: action)
                let verb = switch action { case .grant: "Granted"; case .revoke: "Revoked"; case .reset: "Reset" }
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

    @ViewBuilder
    private var deviceRows: some View {
        HStack {
            TextField("Latitude", text: $latitude).frame(width: 80)
            TextField("Longitude", text: $longitude).frame(width: 80)
            Menu("Places") {
                ForEach(Self.places, id: \.0) { name, place in
                    Button(name) {
                        latitude = String(place.latitude)
                        longitude = String(place.longitude)
                        setLocation(place)
                    }
                }
            }
            .fixedSize()
        }
        HStack {
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
        HStack {
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
        Text(text).font(.system(size: 11)).foregroundStyle(theme.color(tone)).fixedSize(horizontal: false, vertical: true)
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
```

- [ ] **Step 2: The toolbar button**

In `DevicesActions`, add `let canChangeSettings: Bool` and `@State private var showsSettings = false`. Before the screenshot button:

```swift
            ToolbarBtn(icon: "slider.horizontal.3", tooltip: "Simulator settings") { showsSettings = true }
                .disabled(!canChangeSettings)
                .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                    DeviceSettingsPopover(udid: device.udid, settings: LiveSimulatorSettings())
                }
```

In `RightPaneView.devicesActions`, pass
`canChangeSettings: stage == .booted && VMDriver.allowsViewInput(state.deviceControl.driver(udid: device.udid))`.

- [ ] **Step 3:** `xcodegen`, then build (`xcodebuild … -quiet build`); no errors.
- [ ] **Step 4: Commit** `feat(devices): change a simulator's settings from the Devices tab`

---

### Task 4: Install a run script's app

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasFeatures/RunScripts/RunScript.swift`, `RunScriptStore.swift`
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorTarget.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/RunScriptMetadataTests.swift`, `Packages/AlasCore/Tests/AlasCoreTests/DevicesTabStateTests.swift` (the target choice joins the Devices selection suite)
- Create: `Alas/Sources/Devices/AppState+RunScriptApp.swift`
- Modify: `Alas/Sources/App/AppState+RunScripts.swift` (`runScriptFinished`), `Alas/Sources/Devices/DevicePaneModel.swift`

**Interfaces:**
- Produces: `RunScript.appPath: String?`; `RunScriptMetadata.parse` returns `appPath` too; `SimulatorTarget.choose(selection: DevicesTarget?, simulators: [SimulatorDevice]) -> SimulatorDevice?`; `DevicePaneModel.failAppInstall(udid: String, message: String)`; `AppState.installRunScriptApp(_ appPath: String, worktree: Worktree) async`.

- [ ] **Step 1: Failing tests**

`RunScriptMetadataTests`:

```swift
    @Test func appHeaderNamesTheBuiltApp() {
        let meta = RunScriptMetadata.parse(fileName: "run-ios.sh", contents: "# alas-app: build/Debug-iphonesimulator/Hello.app\n")
        #expect(meta.appPath == "build/Debug-iphonesimulator/Hello.app")
        #expect(RunScriptMetadata.parse(fileName: "a.sh", contents: "echo\n").appPath == nil)
    }
```

`DevicesTabStateTests`:

```swift
    @Test(arguments: [
        (DevicesTarget.simulator("off"), "off"),
        (.simulator("gone"), "on"),
        (.vm(.macOS), "on"),
        (nil, "on"),
    ] as [(DevicesTarget?, String)])
    func aRunScriptsAppGoesToTheSelectedSimulatorElseABootedOne(selection: DevicesTarget?, udid: String) {
        #expect(SimulatorTarget.choose(selection: selection, simulators: [Self.off, Self.on])?.udid == udid)
    }

    @Test func withNothingBootedARunScriptsAppGoesToTheFirstSimulator() {
        #expect(SimulatorTarget.choose(selection: nil, simulators: [Self.off])?.udid == "off")
        #expect(SimulatorTarget.choose(selection: nil, simulators: []) == nil)
    }
```

Run `swift test --package-path Packages/AlasCore --filter 'RunScriptMetadataTests|DevicesTabStateTests'`: build errors.

- [ ] **Step 2: Implement the AlasCore pieces**

`RunScript.swift`: add `|app` to the pattern's key group; `var appPath: String?` to `parse`, `case "app": appPath = value`, and a sixth tuple element `appPath: String?`. Add `public var appPath: String?` to `RunScript` with an `appPath: String? = nil` init parameter after `console`, documented as "The `.app` the script builds (`# alas-app:`), relative to the worktree root or absolute; installed on a simulator when a run succeeds." `RunScriptStore.script(...)`: pass `appPath: meta.appPath`.

`SimulatorTarget.swift`:

```swift
/// Which simulator a run script's app goes to.
public enum SimulatorTarget {
    /// The selected simulator, else the first booted one, else the first one; nil when there are none.
    public static func choose(selection: DevicesTarget?, simulators: [SimulatorDevice]) -> SimulatorDevice? {
        if case .simulator(let udid)? = selection, let selected = simulators.first(where: { $0.udid == udid }) {
            return selected
        }
        return simulators.first { $0.state == .booted } ?? simulators.first
    }
}
```

Run the tests: pass.

- [ ] **Step 3: The app hand-off**

`DevicePaneModel`:

```swift
    func failAppInstall(udid: String, message: String) {
        appInstalls[udid] = .failed(message)
    }
```

`AppState+RunScriptApp.swift`:

```swift
import AlasCore
import Foundation

extension AppState {
    /// Installs and launches the app a run script declares (`# alas-app:`)
    /// after a successful run, on the worktree's simulator, and shows it.
    func installRunScriptApp(_ appPath: String, worktree: Worktree) async {
        guard !RemotePath.isReserved(worktree.id), webPreviewRemoteHost(for: worktree) == nil else { return }
        await devicePane.checkTools()
        guard devicePane.simulatorToolsFound == true else { return }
        await devicePane.refresh()
        let app = appPath.hasPrefix("/")
            ? URL(fileURLWithPath: appPath)
            : worktree.path.appendingPathComponent(appPath)
        let appName = app.deletingPathExtension().lastPathComponent
        let pane = rightPaneStore.activeState(worktreeId: worktree.id)
        guard let device = SimulatorTarget.choose(selection: pane?.devicesSelection, simulators: devicePane.devices ?? []) else {
            inAppNotifications.post("No iOS simulator to open \(appName) on", severity: .error, worktreeID: worktree.id)
            return
        }
        if let pane {
            pane.devicesSelection = .simulator(device.udid)
            pane.activeTab = .device
        }
        if !config.rightPaneVisible {
            config.rightPaneVisible = true
            saveConfig()
        }
        if case .agent(let sessionID, _, _) = deviceControl.driver(udid: device.udid) {
            devicePane.failAppInstall(
                udid: device.udid,
                message: "\(computerUseAgentName(sessionID)) is driving \(device.name). Take over to install \(appName)."
            )
            return
        }
        if device.state != .booted {
            await devicePane.boot(device)
            guard devicePane.devices?.first(where: { $0.udid == device.udid })?.state == .booted else { return }
        }
        await devicePane.installAndLaunch(app, on: device)
    }
}
```

In `runScriptFinished`, inside the success branch (`guard let failureID = record.failureID else {`), before `return`:

```swift
            if let appPath = script.appPath {
                Task { await installRunScriptApp(appPath, worktree: worktree) }
            }
```

- [ ] **Step 4:** `xcodegen`; build; run `swift test --package-path Packages/AlasCore --filter 'RunScriptMetadataTests|DevicesTabStateTests'` and the app's `RunEndpointTests` (it calls `RunScriptMetadata.parse`).
- [ ] **Step 5: Commit** `feat(devices): install and launch a run script's app on a simulator`

---

### Task 5: Docs and checking it end to end

**Files:** `docs/devices.md`; `docs/plans/2026-11-04-device-panel-design.md`.

- [ ] **Step 1: Through simctl.** Write a throwaway AlasCore test or app-host test (deleted after) that calls `LiveSimulatorSettings` on the booted simulator:
  - `setDisplay` to dark, `accessibility-large` and contrast on;
  - `setPermission` grant photos on `com.example.hello`;
  - `setLocation` Barcelona, then `nil`;
  - `push` the default payload;
  - `openURL("https://example.com")`.

  Print each result, take a `simctl io screenshot` after the push and after the URL, and look at them. Then put appearance, text size and contrast back to what was read first.
- [ ] **Step 2: Docs.**
  - `docs/devices.md`:
    - a paragraph on the settings popover;
    - the five tools in the agent table;
    - a "Run scripts" paragraph with a `# alas-app:` example (`xcodebuild … -derivedDataPath build` plus `# alas-app: build/Build/Products/Debug-iphonesimulator/MyApp.app`), saying which simulator it goes to and where errors show.
  - Design doc follow-ups:
    - tick "Settings drawer" and "Permissions, simulated location, push notifications, open URL";
    - append "Run scripts too, with `# alas-app:`." to the install item.
- [ ] **Step 3: Commit** `docs(devices): describe simulator settings and run-script installs`
- [ ] **Step 4: Manual pass in Alas Dev (the user):**
  1. Open the popover: switch dark mode, change the text size and contrast; grant a permission; send a notification; set a location from Places; open a URL.
  2. Ask an agent to test dark mode and a deep link with the new tools.
  3. Add a repo run script with `# alas-app:` that builds `/tmp/alas-hello` or a real app, run it, and watch the Devices tab come forward and the app launch.
