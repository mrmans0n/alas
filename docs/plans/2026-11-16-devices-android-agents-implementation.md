# Devices: agent tools on Android — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents drive Android emulators and phones with the existing `device_*` tools, with held calls, take over and settle-and-diff as on iOS, plus appearance, permissions, location and logs on Android.

**Architecture:** `DeviceAgentControl` keeps everything platform-neutral and talks to a `DeviceBackend` per platform, chosen by the shape of the id (a UUID is a simulator; anything else is Android). `SimulatorBackend` holds exactly what the control calls today, so iOS doesn't change and its tests run unchanged through it. `AndroidBackend` uses G's `AndroidControl`, `AndroidStreamClient` and `AndroidPaneModel`. AlasCore gains the parsers and tables (uiautomator XML, font scale, permissions, logcat, the front app) and `AgentDevice`.

**Tech Stack:** Swift 6 (strict concurrency), AlasCore SwiftPM, Swift Testing, Rust (`alas` MCP server), adb.

**Spec:** `docs/plans/2026-11-16-devices-android-agents-design.md`

## Global Constraints

- English only; Conventional Commits; no agent attribution.
- AlasCore must not import AppKit, SwiftUI, VideoToolbox or Network; anything the app uses from it is `public`.
- New app files: run `xcodegen`, commit only the new-file hunks of the pbxproj.
- `swiftformat Alas AlasTests Packages --lint` passes: no semicolons.
- Swift Testing; extend existing suites; parameterize; no fixed sleeps.
- iOS behaviour must not change: every existing `DeviceAgentControlTests` case passes unchanged except its construction helper.
- Unsupported message: `device_unsupported: <tool> isn't available on Android.` (for a button: `device_unsupported: The <name> button isn't available on <platform>.`).
- Snapshot frames on Android are in dp: px × 160 / density.
- Text-size table (spec): extra-small 0.85, small 0.9, medium 0.95, large 1.0, extra-large 1.1, extra-extra-large 1.2, extra-extra-extra-large 1.3, accessibility-medium 1.5, accessibility-large 1.7, accessibility-extra-large 1.8, accessibility-extra-extra-large 1.9, accessibility-extra-extra-extra-large 2.0.

## Review Focus

1. **An AVD id after it boots**: `device_open avd:X` returns the serial; later calls with `avd:X` answer `device_not_booted` pointing at the serial rather than booting again. Task 4 tests it.
2. **A password field**: its text must not reach the agent. Task 1 tests the parser drops it.
3. **A text size Android reports between table values** (set elsewhere, 1.15): reads `unknown`, not the nearest size. Task 1 tests it.
4. **An Android call while the user drives**: held like iOS; the Android stage shows Take over / Hand back. Task 4 tests the hold through `FakeBackend`.
5. **iOS regressions from the refactor**: the existing 40-odd control tests run through `SimulatorBackend` unchanged (Task 2).

---

### Task 1: Android parsers and tables (AlasCore)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/AndroidUIDump.swift`
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/AndroidSettings.swift`
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/AgentDevice.swift`
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/Scrcpy.swift` (inject text)
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Harness/DeviceCommand.swift` (buttons)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/AndroidControlTests.swift`, `ScrcpyTests.swift`, `DeviceCommandTests.swift`

**Interfaces:**
- Produces:
  - `public enum AndroidUIDump { public static func parse(_ xml: Data, density: Double, generation: Int) throws -> DeviceSnapshot; public static func role(ofClass: String) -> String }`
  - `public enum AndroidFontScale { public static func scale(for: SimulatorTextSize) -> Double; public static func textSize(for scale: String) -> SimulatorReadBack<SimulatorTextSize> }`
  - `public enum AndroidPermissions { public static func permissions(for: SimulatorPrivacyService) -> [String]? }` (nil: unsupported)
  - `public enum AndroidLogcat { public static func parse(_ output: String, year: Int) -> [SimulatorLogLine]; public static func filter(_ level: SimulatorLogLevel) -> String; public static func frontmostPackage(_ dumpsys: String) -> String? }`
  - `public struct AgentDevice: Equatable, Sendable { public enum Platform: String { case ios, android }; public let id, name, runtime, state: String; public let platform: Platform; public var json: [String: Any]; public static func isSimulatorID(_ id: String) -> Bool }`
  - `ScrcpyControl.injectText(_:) -> Data`
  - `DeviceCommand.Button`: `back`, `volumeUp = "volume_up"`, `volumeDown = "volume_down"`.

- [ ] **Step 1: Failing tests**

`AndroidControlTests` (new cases):

```swift
    static let dump = Data(#"""
    <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">
    <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="p" content-desc="" checkable="false" clickable="false" enabled="true" password="false" bounds="[0,0][1080,2400]">
    <node index="0" text="Network &amp; internet" resource-id="android:id/title" class="android.widget.TextView" package="p" content-desc="" checkable="false" clickable="false" enabled="true" password="false" bounds="[189,420][651,483]" />
    <node index="1" text="" resource-id="p:id/save" class="android.widget.Button" package="p" content-desc="Save" checkable="false" clickable="true" enabled="false" password="false" bounds="[0,525][1080,630]" />
    <node index="2" text="hunter2" resource-id="p:id/pw" class="android.widget.EditText" package="p" content-desc="" checkable="false" clickable="true" enabled="true" password="true" bounds="[42,700][1038,826]" />
    <node index="3" text="" resource-id="" class="android.widget.ImageButton" package="p" content-desc="" checkable="false" clickable="true" enabled="true" password="false" bounds="[0,900][126,1026]" />
    </node></hierarchy>UI hierchary dumped to: /dev/tty
    """#.utf8)

    @Test func aUIDumpBecomesASnapshotInDP() throws {
        let snapshot = try AndroidUIDump.parse(Self.dump, density: 420, generation: 3)
        #expect(snapshot.screenWidth == 1080 * 160 / 420)
        #expect(snapshot.elements.map(\.ref) == ["s3e1", "s3e2", "s3e3", "s3e4"])
        #expect(snapshot.elements.map(\.role) == ["text view", "button", "edit text", "image button"])
        #expect(snapshot.elements.map(\.label) == ["Network & internet", "Save", nil, nil])
        #expect(snapshot.elements.map(\.id) == ["android:id/title", "p:id/save", "p:id/pw", nil])
        #expect(snapshot.elements.map(\.isControl) == [false, true, true, true])
        #expect(snapshot.elements[1].enabled == false)
        #expect(snapshot.elements[0].x == 189 * 160 / 420)
    }

    @Test func aPasswordFieldsTextIsLeftOut() throws {
        let snapshot = try AndroidUIDump.parse(Self.dump, density: 420, generation: 1)
        #expect(!snapshot.json(query: nil, limit: 200).contains("hunter2"))
    }

    @Test(arguments: [("1.0", SimulatorReadBack.value(SimulatorTextSize.large)), ("2.0", .value(.accessibilityExtraExtraExtraLarge)),
                      ("1.15", .unknown), ("nonsense", .unknown)])
    func fontScaleReadsBackThroughTheTable(scale: String, size: SimulatorReadBack<SimulatorTextSize>) {
        #expect(AndroidFontScale.textSize(for: scale) == size)
    }

    @Test func everyTextSizeHasItsOwnScale() {
        let scales = SimulatorTextSize.allCases.map(AndroidFontScale.scale(for:))
        #expect(Set(scales).count == SimulatorTextSize.allCases.count)
        #expect(AndroidFontScale.scale(for: .large) == 1.0)
    }

    @Test(arguments: [
        (SimulatorPrivacyService.microphone, ["android.permission.RECORD_AUDIO"] as [String]?),
        (.location, ["android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION"]),
        (.siri, nil), (.photosAdd, nil),
    ])
    func privacyServicesMapToRuntimePermissions(service: SimulatorPrivacyService, permissions: [String]?) {
        #expect(AndroidPermissions.permissions(for: service) == permissions)
    }

    @Test func logcatLinesParseWithTheirLevel() {
        let lines = AndroidLogcat.parse("""
        --------- beginning of main
        11-16 09:39:53.715  9147  9294 D PrefCtrl: Could not find
        11-16 09:39:54.465  9147  9294 E Binder  : failed: code 1
        """, year: 2026)
        #expect(lines.map(\.level) == ["Debug", "Error"])
        #expect(lines.map(\.pid) == [9147, 9147])
        #expect(lines[1].process == "Binder")
        #expect(lines[1].message == "failed: code 1")
        #expect(lines[0].time == "2026-11-16 09:39:53.715")
    }

    @Test func theFrontAppComesFromTheResumedActivity() {
        #expect(AndroidLogcat.frontmostPackage(
            "  topResumedActivity=ActivityRecord{1 u0 com.android.settings/.homepage.SettingsHomepageActivity t7}"
        ) == "com.android.settings")
        #expect(AndroidLogcat.frontmostPackage("nothing") == nil)
    }

    @Test(arguments: [("8CA9B1E8-EE67-49E5-846F-293450990F76", true), ("emulator-5554", false), ("avd:Pixel_9", false)])
    func simulatorIDsAreUUIDs(id: String, isSimulator: Bool) {
        #expect(AgentDevice.isSimulatorID(id) == isSimulator)
    }
```

`ScrcpyTests`: in `controlMessagesMatchScrcpysOwnEncoding`, add
`#expect(ScrcpyControl.injectText("hello, world!") == Self.bytes([0x01, 0, 0, 0, 0x0D]) + Data("hello, world!".utf8))`.

`DeviceCommandTests`: add `("device_button", #"{"udid":"U","name":"volume_up"}"#, .button(udid: "U", name: .volumeUp, includeScreenshot: false))`.

- [ ] **Step 2: Run them to see them fail** — `swift test --package-path Packages/AlasCore --filter 'AndroidControlTests|ScrcpyTests|DeviceCommandTests'`.

- [ ] **Step 3: Implement**

`AndroidUIDump.swift` — a `XMLParser` delegate collecting `node` attributes in document order:

```swift
import Foundation

/// `uiautomator dump` XML as a `DeviceSnapshot`, frames in dp.
public enum AndroidUIDump {
    public static func parse(_ xml: Data, density: Double, generation: Int) throws -> DeviceSnapshot {
        // `uiautomator dump /dev/tty` prints a line after the document.
        var data = xml
        if let end = data.range(of: Data("</hierarchy>".utf8)) { data = data.prefix(upTo: end.upperBound) }
        let collector = NodeCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse(), let root = collector.nodes.first, let screen = bounds(root["bounds"]) else {
            throw DeviceSnapshotError(message: "The device did not describe its screen.")
        }
        let dp = 160 / max(density, 1)
        var elements: [DeviceElement] = []
        for node in collector.nodes.dropFirst() {
            guard let frame = bounds(node["bounds"]), frame.width > 0, frame.height > 0 else { continue }
            let password = node["password"] == "true"
            let label = nonEmpty(password ? nil : node["text"]) ?? nonEmpty(node["content-desc"])
            let id = nonEmpty(node["resource-id"])
            let isControl = node["clickable"] == "true" || node["checkable"] == "true"
                || (node["class"] ?? "").hasSuffix("EditText")
            guard label != nil || id != nil || isControl else { continue }
            elements.append(DeviceElement(
                ref: "s\(generation)e\(elements.count + 1)", role: role(ofClass: node["class"] ?? ""),
                label: label, value: nil, id: id,
                x: frame.minX * dp, y: frame.minY * dp, width: frame.width * dp, height: frame.height * dp,
                enabled: node["enabled"] != "false", isControl: isControl
            ))
        }
        return DeviceSnapshot(
            generation: generation, screenWidth: screen.width * dp, screenHeight: screen.height * dp, elements: elements
        )
    }

    /// `android.widget.ImageButton` → "image button".
    public static func role(ofClass name: String) -> String {
        let last = name.split(separator: ".").last.map(String.init) ?? name
        var words = ""
        for character in last {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(Character(character.lowercased()))
        }
        return words.isEmpty ? "view" : words
    }

    /// `[x1,y1][x2,y2]`.
    static func bounds(_ text: String?) -> CGRectLike? {
        guard let text else { return nil }
        let numbers = text.split(whereSeparator: { "[],".contains($0) }).compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRectLike(minX: numbers[0], minY: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    struct CGRectLike {
        let minX, minY, width, height: Double
    }

    private final class NodeCollector: NSObject, XMLParserDelegate {
        var nodes: [[String: String]] = []

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            if name == "node" { nodes.append(attributes) }
        }
    }
}
```

`AndroidSettings.swift`:

```swift
/// `font_scale` for each text size, one to one, so a value reads back as its size.
public enum AndroidFontScale {
    private static let table: [(SimulatorTextSize, Double)] = [
        (.extraSmall, 0.85), (.small, 0.9), (.medium, 0.95), (.large, 1.0), (.extraLarge, 1.1),
        (.extraExtraLarge, 1.2), (.extraExtraExtraLarge, 1.3), (.accessibilityMedium, 1.5),
        (.accessibilityLarge, 1.7), (.accessibilityExtraLarge, 1.8), (.accessibilityExtraExtraLarge, 1.9),
        (.accessibilityExtraExtraExtraLarge, 2.0),
    ]

    public static func scale(for size: SimulatorTextSize) -> Double {
        table.first { $0.0 == size }?.1 ?? 1.0
    }

    /// From `settings get system font_scale`; a value off the table is unknown.
    public static func textSize(for output: String) -> SimulatorReadBack<SimulatorTextSize> {
        guard let scale = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)),
              let size = table.first(where: { abs($0.1 - scale) < 0.001 })?.0 else { return .unknown }
        return .value(size)
    }
}

/// iOS's privacy services as Android runtime permissions; nil where Android has none.
public enum AndroidPermissions {
    public static func permissions(for service: SimulatorPrivacyService) -> [String]? {
        let p = "android.permission."
        switch service {
        case .location: return [p + "ACCESS_FINE_LOCATION", p + "ACCESS_COARSE_LOCATION"]
        case .locationAlways:
            return [p + "ACCESS_FINE_LOCATION", p + "ACCESS_COARSE_LOCATION", p + "ACCESS_BACKGROUND_LOCATION"]
        case .contacts: return [p + "READ_CONTACTS", p + "WRITE_CONTACTS"]
        case .calendar: return [p + "READ_CALENDAR", p + "WRITE_CALENDAR"]
        case .photos: return [p + "READ_MEDIA_IMAGES"]
        case .mediaLibrary: return [p + "READ_MEDIA_AUDIO"]
        case .microphone: return [p + "RECORD_AUDIO"]
        case .motion: return [p + "ACTIVITY_RECOGNITION"]
        case .all:
            return SimulatorPrivacyService.allCases.filter { $0 != .all }.compactMap(permissions(for:)).flatMap { $0 }
        case .contactsLimited, .photosAdd, .reminders, .siri: return nil
        }
    }
}

public enum AndroidLogcat {
    /// `logcat -v threadtime` lines: "MM-DD HH:MM:SS.mmm  PID  TID L TAG: message".
    public static func parse(_ output: String, year: Int) -> [SimulatorLogLine] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = Int(fields[2]), fields[4].count == 1 else { return nil }
            let rest = fields[5]
            guard let colon = rest.range(of: ": ") ?? rest.range(of: ":") else { return nil }
            return SimulatorLogLine(
                time: "\(year)-\(fields[0]) \(fields[1])", level: levelName(String(fields[4])),
                process: rest[..<colon.lowerBound].trimmingCharacters(in: .whitespaces), pid: pid,
                subsystem: nil, category: nil, message: String(rest[colon.upperBound...])
            )
        }
    }

    /// The logcat priority for a level: what `*:<letter>` keeps.
    public static func filter(_ level: SimulatorLogLevel) -> String {
        switch level {
        case .debug: "D"
        case .info: "I"
        case .default: "W"
        case .error: "E"
        }
    }

    static func levelName(_ letter: String) -> String {
        switch letter {
        case "V": "Verbose"
        case "D": "Debug"
        case "I": "Info"
        case "W": "Warning"
        case "E": "Error"
        case "F", "A": "Fault"
        default: letter
        }
    }

    /// The package of `dumpsys activity activities`' top resumed activity.
    public static func frontmostPackage(_ dumpsys: String) -> String? {
        guard let line = dumpsys.split(whereSeparator: \.isNewline).first(where: { $0.contains("topResumedActivity=") }),
              let record = line.split(separator: " ").first(where: { $0.contains("/") }) else { return nil }
        return record.split(separator: "/").first.map(String.init)
    }
}
```

`AgentDevice.swift`:

```swift
import Foundation

/// A device the `device_*` tools can drive, from either platform.
public struct AgentDevice: Equatable, Sendable {
    public enum Platform: String, Sendable { case ios, android }

    public let id: String
    public let name: String
    public let platform: Platform
    /// "iOS 26.5", "Android 16".
    public let runtime: String
    /// booted, booting, shutdown, shutting_down, unauthorized, offline.
    public let state: String

    public init(id: String, name: String, platform: Platform, runtime: String, state: String) {
        self.id = id
        self.name = name
        self.platform = platform
        self.runtime = runtime
        self.state = state
    }

    public var isBooted: Bool { state == "booted" }

    public var json: [String: Any] {
        ["udid": id, "name": name, "platform": platform.rawValue, "runtime": runtime, "state": state]
    }

    /// Simulators have UUIDs; Android serials and `avd:` ids never are.
    public static func isSimulatorID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }
}
```

`Scrcpy.swift`, after `keycode`:

```swift
    /// Text the device types through its key map; characters it can't type are dropped.
    public static func injectText(_ text: String) -> Data {
        let utf8 = Data(text.utf8)
        var data = Data([1])
        data.append(be: UInt32(utf8.count))
        return data + utf8
    }
```

`DeviceCommand.Button`: `case home, lock, siri, back` plus `case volumeUp = "volume_up", volumeDown = "volume_down"` next to the others.

- [ ] **Step 4: Run them** — all pass. Also run `DeviceSnapshotTests`, unaffected.

- [ ] **Step 5: Commit** — `feat(android): parse Android's UI tree, settings and logs for agents`.

---

### Task 2: The `DeviceBackend` seam, with iOS behind it

**Files:**
- Create: `Alas/Sources/Devices/DeviceBackend.swift`
- Create: `Alas/Sources/Devices/SimulatorBackend.swift`
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift`
- Modify: `Alas/Sources/App/AppState.swift` (construction), `Alas/Sources/App/DesignCaptureDevices.swift` (construction)
- Modify: `AlasTests/DeviceAgentControlTests.swift` (construction helpers only)

**Interfaces:**
- Produces:

```swift
/// Why a backend can't do something; the control answers `message` as is.
struct DeviceToolError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static func unsupported(_ tool: String) -> DeviceToolError {
        DeviceToolError(message: "device_unsupported: \(tool) isn't available on Android.")
    }
}

/// One platform's devices, for `DeviceAgentControl`.
@MainActor
protocol DeviceBackend: AnyObject {
    var platform: AgentDevice.Platform { get }
    /// Frames, touches, keys and the stream an agent's lease keeps open.
    var input: DeviceInput { get }
    func devices() async throws -> [AgentDevice]
    /// Boots `id` and returns the id to use from then on.
    func boot(_ id: String) async throws -> String
    func snapshot(_ id: String, generation: Int) async throws -> DeviceSnapshot
    /// False when the platform has no such button.
    func press(_ id: String, _ button: DeviceCommand.Button) -> Bool
    /// Turns the device and returns the interface orientation shown.
    func rotate(_ id: String, to orientation: DeviceScreenOrientation) async throws -> DeviceScreenOrientation
    func beginPaste(_ id: String) async throws -> any DevicePasteSession
    func readClipboard(_ id: String) async throws -> String
    func writeClipboard(_ id: String, _ text: String) async throws
    /// The app id and name; throws `DeviceToolError` with a device_* code for a bad file.
    func install(_ id: String, path: String) async throws -> (appID: String, name: String)
    func launch(_ id: String, appID: String) async throws -> Int
    func isInstalled(_ id: String, appID: String) async -> Bool
    func openURL(_ id: String, _ url: String) async throws
    func setDisplay(_ id: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?) async throws -> SimulatorDisplaySettings
    func setAccessibility(_ id: String, _ change: SimulatorAccessibilityChange) async throws -> SimulatorAccessibility
    func setPermission(_ id: String, appID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws
    func setLocation(_ id: String, _ location: SimulatorLocation?) async throws
    func push(_ id: String, appID: String, payload: Data) async throws
    /// device_logs' reply.
    func logs(_ id: String, since: Int, appID: String?, level: SimulatorLogLevel, includeApple: Bool, query: String?, limit: Int) async throws -> [String: Any]
}

/// Text pasted into the focused field, and the clipboard put back after.
@MainActor
protocol DevicePasteSession: AnyObject {
    func paste(_ text: String) async throws
    func end() async
}
```

- `DeviceAgentControl.init(backends: [any DeviceBackend], recorder:now:sleep:leaseWindow:holdLimit:)`.
- `SimulatorBackend.init(input:devices:boot:install:launch:settings:logs:pasteboard:sleep:)` — the closures and controls the control takes today.

- [ ] **Step 1: `SimulatorBackend`** — move into it, unchanged in behaviour: the `install` (app bundle reading and its `Problem` messages), `launch` (`SimulatorLaunchError.notInstalled` → `DeviceToolError("device_app_not_installed: … isn't installed on <name>.")`), every settings call, `readLogs`' body (front app, executables, `logShow`, crashes, reply dictionary), `rotate`'s waits (frame, then up to 2 s for the interface orientation; returns it), `press` (`siri`, `lock`, `side_button`, `home`, `app_switcher` → `input.button`; `back`, `volume_*` → false), the pasteboard (`DevicePasteboard.open(keepText: true)` / `paste` / `close` wrapped as a `DevicePasteSession`; `readClipboard`/`writeClipboard` → `pasteboard.read`/`write`), `snapshot` (`DeviceSnapshot.parse(input.describe)`), and `devices()` mapping `SimulatorDevice` to `AgentDevice` (`platform: .ios`, state names as `describe(_:)` writes them today).
- [ ] **Step 2: The control** — replace the per-platform members with `backends`; `backend(for id)` picks `.ios` when `AgentDevice.isSimulatorID(id)`, else `.android` (a missing backend answers `device_not_found: No device <id>. Call device_list.`). `input` uses become `backend.input`. `list()` merges every backend's `devices()` (a failing backend's devices are left out; all failing → `device_unavailable`). The listing in `perform` and `bootedDevice` use `AgentDevice`; `device_not_found` reads "No device \(udid). Call device_list."; `notInstalled` uses `device.name`. `typeRuns` uses `beginPaste`. `.button` answers `device_unsupported: The <name> button isn't available on <platform>.` when `press` is false. `.open` on a device that isn't booted calls `boot` and replies with the returned id's device. Errors a backend throws as `DeviceToolError` pass through as their message; others keep today's codes (`device_install_failed`, `device_launch_failed`, `device_settings_failed`, `device_logs_failed`, `device_clipboard_failed`).
- [ ] **Step 3: Construction** — `AppState.deviceControl` builds `SimulatorBackend(input: simulatorStreams, …)` with today's arguments; `DesignCaptureDevices` likewise with its fakes. `DeviceAgentControlTests`' helpers build the control the same way from their existing fakes (`FakeInput`, `FakeSettings`, `FakeLogs`, `Installs`, pasteboard); no test body changes.
- [ ] **Step 4: Run** `DeviceAgentControlTests` → every case passes unchanged; `build-for-testing` builds.
- [ ] **Step 5: Commit** — `refactor(devices): run device tools through a per-platform backend`.

---

### Task 3: `AndroidBackend`

**Files:**
- Create: `Alas/Sources/Devices/Android/AndroidBackend.swift`
- Modify: `Alas/Sources/Devices/Android/AndroidStreamClient.swift` (`text`, `readClipboard`, `writeClipboard`, `rotationOrientation`), `AndroidScreenSession.swift` (clipboard without copy, set without paste)
- Modify: `Alas/Sources/App/AppState.swift` (second backend)

**Interfaces:**
- Consumes: Task 1, Task 2; G's `AndroidControl`, `AndroidStreamClient`, `AndroidPaneModel`.
- Produces: `AndroidBackend(pane: AndroidPaneModel, streams: AndroidStreamClient)`; `AndroidStreamClient: DeviceInput` (its `describe` throws: snapshots come from `AndroidBackend.snapshot`; `button(udid:name:)` exists from G; `rotate(udid:to:)` sets `user-rotation`).

- [ ] **Step 1: Implement**, per the spec's "The tools on Android":
  - `devices()`: `pane.refresh()`, then ready devices (`booted`, runtime "Android \(release)"), unauthorized/offline phones with that state, and AVDs not running as `avd:<name>` (`shutdown`); names from `AndroidDevice.title`.
  - `boot`: an `avd:` id → `await pane.boot(avd:)`, then the serial whose `avdName` matches; a failure is `pane.errors` → `DeviceToolError("device_not_booted: …")`. A serial → returned as is.
  - `snapshot`: `adb exec-out uiautomator dump /dev/tty` (`Process.runData`, 20 s), density from `wm density` (cached per serial), `AndroidUIDump.parse`.
  - `press`: `home`, `back`, `app_switcher` (→ `app_switch`), `lock`/`side_button` (→ `power`), `volume_up`, `volume_down` through `streams.button`; `siri` → false.
  - `rotate`: map portrait 0, landscapeLeft 1, portraitUpsideDown 2, landscapeRight 3 to `user-rotation lock`; wait up to 2 s for the video size's aspect to match; return `orientation` if it did, else `.portrait`.
  - Paste session: reads the clipboard (scrcpy get, no copy), each `paste` sets it with paste, `end` sets the old text back without paste.
  - `install`: `.apk` only (`device_app_invalid: <path> isn't an .apk.` otherwise); `control.install`, package from `control.packageName` (`device_app_invalid: Alas couldn't read the package; install the Android SDK build-tools.` when nil); name from the file name.
  - `launch`: `am force-stop`, `monkey -p … LAUNCHER 1`, then `pidof` (retry up to 2 s) → pid; `isInstalled`: `pm path <package>` succeeds.
  - `openURL`: `am start -W -a android.intent.action.VIEW -d <url>`.
  - `setDisplay`: `cmd uimode night yes|no`, `settings put system font_scale <AndroidFontScale.scale>`, `settings put secure high_text_contrast_enabled 0|1`; reads back `cmd uimode night` ("Night mode: yes"), `font_scale` through `AndroidFontScale.textSize`, the contrast flag.
  - `setPermission`: `AndroidPermissions.permissions(for:)` (nil → `DeviceToolError("device_unsupported: <service> has no Android permission.")`); grant/revoke each with `pm grant|revoke` (ignoring "not requested" failures for `all`); reset: revoke, then `pm clear-permission-flags <pkg> <perm> user-set user-fixed`.
  - `setLocation`: `appops set com.android.shell android:mock_location allow`, `cmd location providers add-test-provider gps`, `set-test-provider-enabled gps true`, `set-test-provider-location gps --location <lat>,<lon>`; nil → `remove-test-provider gps`, `appops … default`.
  - `push`, `setAccessibility` → `DeviceToolError.unsupported("device_push" / "device_set_accessibility")`.
  - `logs`: app = `appID` or `AndroidLogcat.frontmostPackage(dumpsys activity activities)` (nil → `device_no_app`); pid by `pidof` (none → empty lines and a note "\(app) isn't running"); `logcat -d -v threadtime --pid=<pid> -T <since>s` filtered by `*:\(AndroidLogcat.filter(level))`, parsed, query-matched, limited like iOS; crashes: `logcat -d -b crash -v threadtime` lines mentioning the package, as `{"time", "exception": first line, "frames": next 10, "report": ""}`.
- [ ] **Step 2: Register it** in `AppState.deviceControl`: `backends: [simulatorBackend, AndroidBackend(pane: androidPane, streams: androidStreams)]`. `showDevice` selects `.android(udid)` for a non-UUID id.
- [ ] **Step 3: Build**; commit — `feat(android): drive Android devices with the device tools`.

---

### Task 4: Routing tests, take over on the Android stage

**Files:**
- Modify: `AlasTests/DeviceAgentControlTests.swift` (a `FakeBackend` and Android cases)
- Modify: `Alas/Sources/Devices/DeviceStageFrame.swift` (extract `DeviceDriverPill` from `DeviceStage`), `DeviceStage.swift`, `Android/AndroidDeviceStage.swift`, `DevicesTabView.swift`, `AppState+DevicesTab.swift`
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/DevicesTabState.swift` (busy Android rows), its tests

- [ ] **Step 1: Failing tests**

`DeviceAgentControlTests`: `FakeBackend: DeviceBackend` (platform `.android`; devices `[emulator-5554 booted, avd:Pixel_9 shutdown]`; `boot("avd:Pixel_9")` returns `"emulator-5556"` and lists it booted afterwards; `snapshot` returns a fixed one-element snapshot; records `press` calls; `push` throws `.unsupported`). Cases:
  - `device_list` merges both platforms with `platform` fields.
  - `device_open avd:Pixel_9` replies with `"udid":"emulator-5556"`; a following `device_snapshot avd:Pixel_9` answers `device_not_booted`.
  - `device_push` on `emulator-5554` answers `device_unsupported: device_push isn't available on Android.`
  - `device_button siri` on Android answers `device_unsupported: The siri button isn't available on android.`; `back` on iOS likewise with `ios`.
  - Taken over, a `device_tap` on `emulator-5554` waits in `waitingSessions` and runs after hand back (the hold is platform-neutral).

`DevicesTabStateTests`: an Android row an agent drives is `.busy`.

- [ ] **Step 2: Implement** — `DevicesTabState`: Android row tone `.busy` when `agentDriving.contains(.android(id))`. `AppState.devicesTabState`: add `.android(serial)` to `driving` for devices an agent drives. Extract the driver pill into `DeviceDriverPill(driver:waiting:agentName:pulse:onTakeOver:onHandBack:)`; `DeviceStage` uses it unchanged; `AndroidDeviceStage` takes `control` and `agentName`, gates `allowsInput` with `VMDriver.allowsViewInput`, pulses on a blocked click, and shows the pill. `DevicesTabView` passes them.
- [ ] **Step 3: Run** `DeviceAgentControlTests`, `DevicesTabStateTests`; commit — `feat(android): hold and take over Android devices like simulators`.

---

### Task 5: Tool text, setting, preamble

**Files:** `AlasCLI/crates/alas/src/mcp.rs`, `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift`, `Alas/Sources/Settings/ComputerUsePane.swift`, `Alas/Sources/Devices/DeviceAgentControl.swift` (`disabled`), tests that pin these strings.

- [ ] `DEVICE_BUTTONS` gains `back`, `volume_up`, `volume_down`; the `udid` schema description becomes "A simulator UDID or an Android serial, from device_list"; `device_list`: "List the iOS simulators and Android devices on this Mac: udid, name, platform (ios or android), runtime and state. AVDs that aren't running are listed as avd:<name>; device_open boots one and returns its serial."; `device_install`: "Install a built .app on a simulator, or an .apk on an Android device, …"; `device_launch`'s `bundle_id`: "The app's bundle ID, or its Android package"; descriptions that say "simulator" say "device"; push and set_accessibility say "iOS simulators only". Rust test for the button list.
- [ ] Preamble: device sentences say "iOS simulators and Android devices", and that ids are UDIDs or serials; its test.
- [ ] Setting: "Let agents use simulators and Android devices"; `disabled` message: "device_disabled: Agents can't use simulators or Android devices. Ask the user to turn on Settings › Computer Use › Let agents use simulators and Android devices."; tests pinning it.
- [ ] Run cargo, `ACPMCPPromptPreambleTests`, `DeviceAgentControlTests`; commit — `feat(android): describe the device tools for both platforms`.

---

### Task 6: Docs and end-to-end

- [ ] `docs/devices.md` Agents section: the tools work on Android devices; ids; what's unsupported; the 2 s snapshot cost. Device panel design follow-ups: note H built, the helper APK as a follow-up.
- [ ] Throwaway hosted test against the running AVD through `AppState`-free construction (`DeviceAgentControl(backends: [AndroidBackend(…)])`): `device_list`, `device_snapshot`, `device_tap` on a ref, `device_type`, `device_set_appearance` dark/large, `device_set_permission` microphone grant on `com.android.chrome`, `device_set_location`, `device_logs`; print replies; restore settings. Delete it.
- [ ] Lint, commit — `docs(android): describe agent tools on Android`.
