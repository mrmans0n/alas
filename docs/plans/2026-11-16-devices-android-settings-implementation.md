# Devices: Android settings and logs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Android devices get the settings popover (with Network and Clear Data) and the Logs tab; agents get `device_set_network` and `device_clear_data`.

**Architecture:** The popover moves from `SimulatorSettingsControl` to H's `DeviceBackend`, which gains the reads it needs. The Logs tab moves behind a `DeviceLogSource` with an iOS source (today's code) and an Android one (logcat). AlasCore gains the network read-back, a logcat line reader, the pid-follow decision and crash dates.

**Tech Stack:** Swift 6, SwiftUI, AlasCore, Swift Testing, Rust MCP server, adb.

**Spec:** `docs/plans/2026-11-16-devices-android-settings-design.md`

## Global Constraints

- English; Conventional Commits; no attribution. AlasCore stays free of AppKit/SwiftUI/Network/VideoToolbox/XMLParser and builds on Linux.
- New app files: `xcodegen`, commit only their pbxproj hunks. `swiftformat --lint` passes.
- iOS behaviour unchanged: existing `DeviceAgentControlTests` and the iOS Logs tab keep working.
- Unsupported on iOS: `device_unsupported: <tool> isn't available on iOS.`
- Wi-Fi read: `cmd wifi status` first line "Wifi is enabled"/"Wifi is disabled"; data: `settings get global mobile_data` 1/0.

## Review Focus

1. **The app in front restarts** (same package, new pid): the Android Logs tab keeps following it (Task 4's follow decision test).
2. **A partial logcat line split across reads**: not dropped or doubled (Task 1's reader test).
3. **Clear Data by mistake**: the popover asks first, naming the app (Task 3).
4. **iOS popover regressions**: Display, Accessibility, App and Device sections behave as before (Task 3 keeps the iOS calls one to one).
5. **A tab restored after relaunch for a device that's gone**: the Logs tab shows its stopped banner, not a crash (Task 4 keeps `SimulatorLogsTabState`'s shape and adds a platform).

---

### Task 1: AlasCore pieces

**Files:** `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/AndroidSettings.swift`, `AlasAgentKit/Harness/DeviceCommand.swift`; tests in `AndroidControlTests.swift`, `DeviceCommandTests.swift`.

**Produces:**
- `public enum AndroidNetwork { public static func wifi(_ status: String) -> SimulatorReadBack<Bool>; public static func data(_ setting: String) -> SimulatorReadBack<Bool> }`
- `public struct LogcatLineReader: Sendable { public init(); public mutating func lines(_ chunk: Data, year: Int) -> [SimulatorLogLine] }` (keeps a partial last line)
- `public enum AndroidLogFollow: Equatable, Sendable { case keep, restart(pid: Int), waitForApp; public static func next(running: Int?, found: Int?) -> AndroidLogFollow }`
- `AndroidCrash.date(year:)` → `Date?` and `AndroidCrash.report(bundleID:)` → `SimulatorCrashReport`
- `DeviceCommand.setNetwork(udid:wifi:data:)` (`device_set_network`, at least one) and `.clearData(udid:bundleID:)` (`device_clear_data`)

- [ ] **Step 1: Tests**

```swift
    @Test(arguments: [("Wifi is enabled\nWifi scanning…", SimulatorReadBack<Bool>.value(true)), ("Wifi is disabled", .value(false)), ("", .unknown)])
    func wifiReadsFromItsStatus(status: String, expected: SimulatorReadBack<Bool>) {
        #expect(AndroidNetwork.wifi(status) == expected)
    }

    @Test(arguments: [("1\n", SimulatorReadBack<Bool>.value(true)), ("0", .value(false)), ("null", .unknown)])
    func mobileDataReadsFromItsSetting(setting: String, expected: SimulatorReadBack<Bool>) {
        #expect(AndroidNetwork.data(setting) == expected)
    }

    @Test func aLineSplitAcrossReadsIsReadOnce() {
        var reader = LogcatLineReader()
        let first = reader.lines(Data("11-16 10:00:00.000  1  1 W A: one\n11-16 10:00:01.000  1  1 W B: tw".utf8), year: 2026)
        let second = reader.lines(Data("o\n".utf8), year: 2026)
        #expect(first.map(\.message) == ["one"])
        #expect(second.map(\.message) == ["two"])
    }

    @Test(arguments: [
        (nil as Int?, 42 as Int?, AndroidLogFollow.restart(pid: 42)),
        (42, 42, .keep),
        (42, 43, .restart(pid: 43)),
        (42, nil, .waitForApp),
        (nil, nil, .waitForApp),
    ])
    func followingAnAppRestartsOnANewPID(running: Int?, found: Int?, next: AndroidLogFollow) {
        #expect(AndroidLogFollow.next(running: running, found: found) == next)
    }

    @Test func aCrashBecomesACrashReport() {
        let crash = AndroidCrash(time: "2026-11-16 10:01:02.100", exception: "java.lang.X: boom", frames: ["a.B.c(B.kt:1)"])
        let report = crash.report(bundleID: "com.example.hello")
        #expect(report.exception == "java.lang.X: boom")
        #expect(report.frames == ["a.B.c(B.kt:1)"])
        #expect(Calendar(identifier: .gregorian).component(.second, from: report.capturedAt) == 2)
    }
```

`DeviceCommandTests`: `("device_set_network", #"{"udid":"U","wifi":false}"#, .setNetwork(udid: "U", wifi: false, data: nil))`, `("device_clear_data", #"{"udid":"U","bundle_id":"b"}"#, .clearData(udid: "U", bundleID: "b"))`; malformed: `("device_set_network", #"{"udid":"U"}"#)`.

- [ ] **Step 2: Implement** (parse by the first line's text; `0`/`1` trimmed; reader splits on `\n`, keeps the tail; `next`: found nil → `.waitForApp`, equal → `.keep`, else `.restart`; crash date with a `en_US_POSIX` formatter "yyyy-MM-dd HH:mm:ss.SSS" in the current time zone, report text = exception + frames joined; `DeviceCommand` cases, tool names, `udid`, `allowed`, decoding; `isInput` treats both as input).
- [ ] **Step 3: Run** `swift test --package-path Packages/AlasCore --filter 'AndroidControlTests|DeviceCommandTests'`; commit `feat(android): read network state, follow logcat and decode the new tools`.

---

### Task 2: Backend reads, the new tools through the control, Rust

**Files:** `Alas/Sources/Devices/DeviceBackend.swift`, `SimulatorBackend.swift`, `Android/AndroidBackend.swift`, `DeviceAgentControl.swift`, `AlasTests/DeviceAgentControlTests.swift` (`FakeBackend` + cases), `AlasCLI/crates/alas-client/src/lib.rs`, `AlasCLI/crates/alas/src/mcp.rs`, preamble + its test.

**Produces on `DeviceBackend`:**
`display(_:) async throws -> SimulatorDisplaySettings`, `accessibility(_:) async throws -> SimulatorAccessibility`, `userApps(_:) async throws -> [SimulatorApp]`, `network(_:) async throws -> AndroidNetworkState`, `setNetwork(_:wifi:data:) async throws -> AndroidNetworkState`, `clearData(_:appID:) async throws`. `AndroidNetworkState` (AlasCore): `wifi`, `data: SimulatorReadBack<Bool>`, `json`.

- [ ] **Step 1: Tests** (`DeviceAgentControlTests`, with H's `FakeBackend` gaining a recorded network and clears):
  - `device_set_network` on `emulator-5554` with `wifi: false` answers `{"data":true,"wifi":false}`;
  - `device_clear_data` on `emulator-5554` answers `{"ok":true}` and records the package; for a package `isInstalled` denies, `device_app_not_installed`;
  - both on iOS `on`: `device_unsupported: device_set_network isn't available on iOS.` / `device_clear_data …`;
  - `device_set_network` while the user drives `emulator-5554` waits in `waitingSessions`.
  Rust: mapping, "pass at least one of wifi, data", tool lists, destructive hints.
- [ ] **Step 2: Implement.** `SimulatorBackend`: `display`/`accessibility`/`userApps` forward to `settings`; `network`/`setNetwork`/`clearData` throw `DeviceToolError(message: "device_unsupported: <tool> isn't available on iOS.")` — the control passes the tool name. `AndroidBackend`: `display` = H's read-back half of `setDisplay` (extract a `readDisplay`); `accessibility` unsupported; `userApps` = `pm list packages -3` → `SimulatorApp(bundleID: name, name: name)` sorted; `network` = `cmd wifi status` + `settings get global mobile_data`; `setNetwork` = `svc wifi enable|disable`, `svc data enable|disable`, then `network`; `clearData` = `pm clear` (output "Success" else `DeviceToolError("device_clear_data_failed: …")`). Control: two cases, input turns, `isInstalled` check for clear data, `settingsCall` wrapping. Rust: client variants and params, MCP tools (`device_set_network`: "Turn Wi-Fi and mobile data on or off on an Android device; pass at least one. Returns both read back. iOS simulators don't support it."; `device_clear_data`: "Clear an installed app's data on an Android device, as a fresh install would have it; this also stops the app. iOS simulators don't support it."). Preamble tool list and the iOS-only/Android-only sentence.
- [ ] **Step 3: Run** cargo, `DeviceAgentControlTests`, `ACPMCPPromptPreambleTests`; commit `feat(android): let agents switch the network and clear app data`.

---

### Task 3: The settings popover over the backend

**Files:** `Alas/Sources/Devices/DeviceSettingsPopover.swift`, `DevicesSwitcher.swift` (iOS call site), `Android/AndroidActions.swift`, `RightPaneView.swift`, `DesignCaptureDevices.swift`.

- [ ] Replace `settings: any SimulatorSettingsControl` with `backend: any DeviceBackend` and `platform: AgentDevice.Platform`; map each call one to one (`settings.setDisplay(udid:…)` → `backend.setDisplay(udid, …)`, and so on). `load()` reads display, accessibility (iOS), network (Android) and apps.
- [ ] Sections: Accessibility when `platform == .ios`; Network (Wi-Fi, Mobile data toggles, `.unknown` shows "Unknown") when `.android`; in App, Push when `.ios`, and a "Clear Data…" button when `.android` that shows a `confirmationDialog("Clear the data of \(appName)?")` with a destructive "Clear Data" calling `backend.clearData`, reporting "Cleared" or the error in the app message.
- [ ] iOS call site: `DevicesActions` passes `state.deviceControl`'s simulator backend — expose `DeviceAgentControl.backend(for platform:)` (internal) so views reach the live backend. `DesignCaptureDevices`' `SettingsPanel` wraps its fakes in a `SimulatorBackend`.
- [ ] `AndroidActions`: a settings button (same icon/tooltip as iOS, disabled while an agent drives, `VMDriver.allowsViewInput`) opening the popover with the Android backend, and a Logs button opening the Logs tab (Task 4's `openDeviceLogs`). `RightPaneView` passes what they need.
- [ ] Build; capture `devices-settings` if the display allows, else note it. Commit `feat(android): open the settings popover for Android devices`.

---

### Task 4: The Logs tab over a log source

**Files:** create `Alas/Sources/Devices/DeviceLogSource.swift`, `Alas/Sources/Devices/Android/AndroidLogSource.swift`; rename `SimulatorLogsTabView.swift` → `DeviceLogsTabView.swift`; modify `SimulatorLogStream.swift`, `Center/Tab.swift` (`SimulatorLogsTabState` gains `platform` decoded with a default of `ios`), `TabsManager.swift`, `AppState+DevicesTab.swift`.

**Produces:**

```swift
/// What the Logs tab reads from: a simulator's unified log, or an Android device's logcat.
@MainActor
protocol DeviceLogSource: AnyObject {
    /// iOS: Apple's subsystems can be included.
    var hasAppleSubsystems: Bool { get }
    func userApps() async -> [SimulatorApp]
    /// The app in front, each time it changes, until cancelled; nil while none is.
    func frontApps() -> AsyncStream<String?>
    /// Streams lines into `stream` for `app` (nil: every process).
    func start(_ stream: SimulatorLogStream, app: String?, level: SimulatorLogLevel, includeApple: Bool) async
    func crashes(app: String?, since: Date) async -> [SimulatorCrashReport]
}
```

- [ ] `SimulatorLogStream.start(executable:args:parse:)`: the process/pipe/line-limit code made generic over a parse closure; the iOS `start(udid:query:)` calls it with `log stream`'s ndjson parser. A `stopReason` when the process ends unasked stays.
- [ ] `SimulatorLogSource` moves the tab's iOS code: apps, executables, the foreground tracker as an `AsyncStream`, `SimulatorLogQuery`, `.ips` crashes.
- [ ] `AndroidLogSource(serial:control:)`: apps via `pm list packages -3`; front apps by polling `dumpsys activity activities` every 2 s, yielding on change; `start` resolves the pid with `pidof` and runs `adb -s <serial> logcat -v threadtime -T 1 '*:<filter>' [--pid=<pid>]` through `start(executable:args:parse:)` with a `LogcatLineReader`, and for an app keeps a task polling `pidof` every 2 s that applies `AndroidLogFollow.next` (restart on a new pid, a note when the app isn't running); crashes from `logcat -d -b crash -v threadtime -T '<MM-dd HH:mm:ss.000 of since>'` through `AndroidLogcat.crashes` and `report(bundleID:)`.
- [ ] `DeviceLogsTabView` takes the source; "Apple subsystems" only when `hasAppleSubsystems`; otherwise unchanged. `AppState.openDeviceLogs(worktreeID:udid:name:platform:)` replaces `openSimulatorLogs`; the tab builds the source from the state's platform.
- [ ] Build; run the Android Logs tab against the AVD with a throwaway hosted test of `AndroidLogSource` (start for Settings, see lines arrive, force-stop and relaunch Settings, see lines continue under the new pid). Commit `feat(android): show Android logs in the Logs tab`.

---

### Task 5: Docs, end to end

- [ ] `docs/devices.md`: Android settings (Display, Network, App with Clear Data, Device), the Logs tab on Android, and the two tools in the agents table. Device panel design: tick the Android follow-ups built here.
- [ ] Throwaway end to end on the AVD through the control: `device_set_network` off/on, `device_clear_data` for Chrome; the popover and Logs tab by hand if the display allows, else noted.
- [ ] Lint; commit `docs(android): describe Android settings, logs and the new tools`.
