# Devices tab redesign: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the experimental Device tab into a polished **Devices** tab that shows iOS simulators and this worktree's VMs, with layout A (stage + switcher).

**Architecture:** Pure decisions move to AlasCore: what the tab shows (`DevicesTabState`), a VM's state (`VMDeviceStatus`), and a simulator screen's shape from Xcode's device files (`DeviceScreenShape`). The app keeps one shared simulator list (`DevicePaneModel`), a per-worktree selection on `RightPaneState`, and thin views: a toolbar switcher, a stage that frames the live screen, and a VM status card. The experiment setting goes away; the tab shows where VMs or `simctl` exist.

**Tech stack:** Swift 6, SwiftUI/AppKit, Swift Testing, Rust (one string), xcodegen.

**Spec:** `docs/plans/2026-11-05-devices-tab-redesign-design.md`

## Global constraints

- Phase 1 and 2 constraints still hold: English, Swift Testing, no `.serialized`/extra `@MainActor`, `xcodegen` after new app files, Conventional Commits, no agent attribution, vendored serve-sim files untouched.
- AlasCore tests: `swift test --package-path Packages/AlasCore --filter <Suite>`. If an `alas-host` test crashes at startup after `AppConfig` changes, `rm -rf Packages/AlasCore/.build` first (stale incremental build).
- App tests: the focused `xcodebuild … -only-testing AlasTests/<Suite> test`. Rust: `cargo test --manifest-path AlasCLI/Cargo.toml -p alas`.
- `device_disabled` text, everywhere it appears: `device_disabled: Agents can't use iOS simulators. Ask the user to turn on Settings › Computer Use › Let agents use iOS simulators.`
- Device files: device types from `xcrun simctl list devicetypes --json` (`identifier`, `bundlePath`); `<bundle>/Contents/Resources/profile.plist` key `chromeIdentifier`; `<bundle>/Contents/Resources/capabilities.plist` keys `capabilities.ScreenDimensionsCapability.main-screen-width|main-screen-height|main-screen-scale`; chrome at `/Library/Developer/DeviceKit/Chrome/<last dotted component of chromeIdentifier>.devicechrome/Contents/Resources/chrome.json`, keys `paths.simpleOutsideBorder.cornerRadiusX` and `images.sizing.leftWidth`.
- Layout numbers: 12 pt stage margin, 44 pt right gutter for the controls capsule, 4 pt bezel, pill shown while `VMDriver` is not `.idle`.

## Spec changes found while planning

- **Fallback to a VM card.** When no simulator can be shown (no Xcode, or none created) but VMs are supported, the default selection falls through to the macOS VM card, as the spec's order says. The "Install Xcode" / "No iOS simulators" text then appears as a note in the switcher's Simulators section. The full-stage empty states remain for Macs without VM support.
- **Screen shape comes from `capabilities.plist`,** not from the first frame, so the stage is laid out before any frame arrives.

## Review focus

1. A worktree whose selected simulator is deleted falls back without showing a stale device, and a selected VM never falls back. Task 2, `selectionFallsBackOnlyWhenItsDeviceIsGone`.
2. A Mac with no Xcode but with VM support defaults to the macOS VM card and says why simulators are missing; one with neither has no tab. Task 2, `noSimulatorsFallsBackToTheMacOSVM`; Task 3, `availableTabsFollowFolderAndDevices`.
3. The screen's rounded corners match the device at any pane width: the radius scales with the fitted width. Task 1, `screenShapeScalesItsCornersWithTheFittedWidth`.
4. An iPad or a device type without chrome still lays out (square corners) instead of failing. Task 1, the nil rows of `cornerRadiusComesFromTheChrome`.
5. `device_open` from an agent selects that simulator in its own worktree only. Task 4 manual step and Task 6 manual pass.

---

### Task 1: Device files in AlasCore

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorDevice.swift` (add `deviceTypeIdentifier`)
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorControl.swift` (shutdown, availability, device types)
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceScreenShape.swift`
- Modify: `Packages/AlasCore/Tests/AlasCoreTests/SimulatorDeviceListTests.swift`
- Create: `Packages/AlasCore/Tests/AlasCoreTests/DeviceScreenShapeTests.swift`

**Interfaces:**
- Produces:

```swift
// SimulatorDevice
public let deviceTypeIdentifier: String?   // init parameter defaults to nil
// SimulatorControl
public static func shutdown(udid: String) async throws
public static func isAvailable() async -> Bool
public static func deviceTypeBundles() async throws -> [String: URL]
// DeviceScreenShape
public struct DeviceScreenShape: Equatable, Sendable {
    public let widthPoints: Double
    public let heightPoints: Double
    public let cornerRadiusPoints: Double   // 0 without chrome
    public init(widthPoints: Double, heightPoints: Double, cornerRadiusPoints: Double)
    public func cornerRadius(forFittedWidth width: Double) -> Double
    public static func screenCornerRadius(chromeJSON: Data) -> Double?
    public static func chromeURL(profilePlist: Data, root: URL) -> URL?
    public static func screenSize(capabilitiesPlist: Data) -> (width: Double, height: Double)?
    /// Reads a device type bundle; nil without a screen size.
    public static func load(bundle: URL, chromeRoot: URL = URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome")) -> DeviceScreenShape?
}
```

- [ ] **Step 1: Failing tests.**
  - `SimulatorDeviceListTests.listsAvailableIOSDevicesBootedFirstThenNewestRuntimeThenName`: add `"deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Air"` to device `B` and expect it on `devices[0]`.
  - `DeviceScreenShapeTests`:

```swift
import Foundation
import Testing
import AlasCore

struct DeviceScreenShapeTests {
    static func chrome(outer: Int?, bezel: Int?) -> Data {
        var paths: [String: Any] = [:]
        if let outer { paths["simpleOutsideBorder"] = ["cornerRadiusX": outer, "cornerRadiusY": outer] }
        var images: [String: Any] = ["screen": "Screen"]
        if let bezel { images["sizing"] = ["leftWidth": bezel, "rightWidth": bezel] }
        return try! JSONSerialization.data(withJSONObject: ["paths": paths, "images": images])
    }

    @Test(arguments: [
        (chrome(outer: 80, bezel: 18), 62.0 as Double?),   // phone11
        (chrome(outer: 81, bezel: 59), 22.0),              // tablet4
        (chrome(outer: nil, bezel: 18), nil),
        (chrome(outer: 10, bezel: 18), nil),
        (Data("not json".utf8), nil),
    ] as [(Data, Double?)])
    func cornerRadiusComesFromTheChrome(json: Data, radius: Double?) {
        #expect(DeviceScreenShape.screenCornerRadius(chromeJSON: json) == radius)
    }

    @Test func chromeURLUsesTheLastComponentOfTheIdentifier() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["chromeIdentifier": "com.apple.dt.devicekit.chrome.phone11"], format: .xml, options: 0)
        let root = URL(fileURLWithPath: "/K")
        #expect(DeviceScreenShape.chromeURL(profilePlist: plist, root: root)?.path
            == "/K/phone11.devicechrome/Contents/Resources/chrome.json")
        let empty = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
        #expect(DeviceScreenShape.chromeURL(profilePlist: empty, root: root) == nil)
    }

    @Test func screenSizeIsInPoints() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["capabilities": ["ScreenDimensionsCapability": [
            "main-screen-width": 1206, "main-screen-height": 2622, "main-screen-scale": 3,
        ]]], format: .xml, options: 0)
        let size = try #require(DeviceScreenShape.screenSize(capabilitiesPlist: plist))
        #expect(size.width == 402 && size.height == 874)
    }

    @Test func screenShapeScalesItsCornersWithTheFittedWidth() {
        let shape = DeviceScreenShape(widthPoints: 402, heightPoints: 874, cornerRadiusPoints: 62)
        #expect(shape.cornerRadius(forFittedWidth: 201) == 31)
        #expect(DeviceScreenShape(widthPoints: 402, heightPoints: 874, cornerRadiusPoints: 0)
            .cornerRadius(forFittedWidth: 201) == 0)
    }

    @Test func loadReadsADeviceTypeBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-shape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Phone.simdevicetype/Contents/Resources")
        let chrome = root.appendingPathComponent("Chrome/phone11.devicechrome/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["chromeIdentifier": "x.phone11"], format: .xml, options: 0)
            .write(to: resources.appendingPathComponent("profile.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["capabilities": ["ScreenDimensionsCapability": [
            "main-screen-width": 1206, "main-screen-height": 2622, "main-screen-scale": 3,
        ]]], format: .xml, options: 0).write(to: resources.appendingPathComponent("capabilities.plist"))
        try Self.chrome(outer: 80, bezel: 18).write(to: chrome.appendingPathComponent("chrome.json"))
        let shape = DeviceScreenShape.load(
            bundle: root.appendingPathComponent("Phone.simdevicetype"), chromeRoot: root.appendingPathComponent("Chrome"))
        #expect(shape == DeviceScreenShape(widthPoints: 402, heightPoints: 874, cornerRadiusPoints: 62))
    }
}
```

- [ ] **Step 2: Run, see failures** (`cannot find 'DeviceScreenShape'`, missing `deviceTypeIdentifier`).
- [ ] **Step 3: Implement.**
  - `SimulatorDevice`: `public let deviceTypeIdentifier: String?`, init parameter `deviceTypeIdentifier: String? = nil` last; `Listing.Device` decodes `deviceTypeIdentifier: String?`.
  - `SimulatorControl.shutdown`: `xcrun simctl shutdown <udid>`; treat stderr containing `current state: Shutdown` as success.
  - `SimulatorControl.isAvailable`: `xcrun --find simctl`, true on exit 0; false on any throw.
  - `SimulatorControl.deviceTypeBundles`: decode `{"devicetypes":[{"identifier","bundlePath"}]}` into `[identifier: URL(fileURLWithPath: bundlePath)]`.
  - `DeviceScreenShape`:

```swift
import Foundation

/// A simulator screen's size in points and its corner radius, from the
/// device type's bundle and its DeviceKit chrome.
public struct DeviceScreenShape: Equatable, Sendable {
    public let widthPoints: Double
    public let heightPoints: Double
    /// 0 when the device type has no chrome: square corners.
    public let cornerRadiusPoints: Double

    public init(widthPoints: Double, heightPoints: Double, cornerRadiusPoints: Double) {
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.cornerRadiusPoints = cornerRadiusPoints
    }

    /// The corner radius once the screen is drawn `width` points wide.
    public func cornerRadius(forFittedWidth width: Double) -> Double {
        guard widthPoints > 0 else { return 0 }
        return cornerRadiusPoints * width / widthPoints
    }

    /// The chrome's outer radius minus its bezel width: 80 − 18 = 62 on an iPhone 17 Pro.
    public static func screenCornerRadius(chromeJSON: Data) -> Double? {
        guard let root = (try? JSONSerialization.jsonObject(with: chromeJSON)) as? [String: Any],
              let border = (root["paths"] as? [String: Any])?["simpleOutsideBorder"] as? [String: Any],
              let outer = (border["cornerRadiusX"] as? NSNumber)?.doubleValue,
              let sizing = (root["images"] as? [String: Any])?["sizing"] as? [String: Any],
              let bezel = (sizing["leftWidth"] as? NSNumber)?.doubleValue
        else { return nil }
        let radius = outer - bezel
        return radius > 0 ? radius : nil
    }

    public static func chromeURL(profilePlist: Data, root: URL) -> URL? {
        guard let profile = (try? PropertyListSerialization.propertyList(from: profilePlist, format: nil)) as? [String: Any],
              let identifier = profile["chromeIdentifier"] as? String,
              let name = identifier.split(separator: ".").last, !name.isEmpty
        else { return nil }
        return root.appendingPathComponent("\(name).devicechrome/Contents/Resources/chrome.json")
    }

    public static func screenSize(capabilitiesPlist: Data) -> (width: Double, height: Double)? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: capabilitiesPlist, format: nil)) as? [String: Any],
              let screen = (plist["capabilities"] as? [String: Any])?["ScreenDimensionsCapability"] as? [String: Any],
              let width = (screen["main-screen-width"] as? NSNumber)?.doubleValue,
              let height = (screen["main-screen-height"] as? NSNumber)?.doubleValue,
              let scale = (screen["main-screen-scale"] as? NSNumber)?.doubleValue, scale > 0
        else { return nil }
        return (width / scale, height / scale)
    }

    public static func load(
        bundle: URL, chromeRoot: URL = URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome")
    ) -> DeviceScreenShape? {
        let resources = bundle.appendingPathComponent("Contents/Resources")
        guard let capabilities = try? Data(contentsOf: resources.appendingPathComponent("capabilities.plist")),
              let size = screenSize(capabilitiesPlist: capabilities)
        else { return nil }
        let radius = (try? Data(contentsOf: resources.appendingPathComponent("profile.plist")))
            .flatMap { chromeURL(profilePlist: $0, root: chromeRoot) }
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(screenCornerRadius(chromeJSON:)) ?? 0
        return DeviceScreenShape(widthPoints: size.width, heightPoints: size.height, cornerRadiusPoints: radius)
    }
}
```

- [ ] **Step 4: Run** `SimulatorDeviceListTests|DeviceScreenShapeTests`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(devices): read a simulator screen's size and corners from Xcode's device files`

---

### Task 2: What the Devices tab shows

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/DevicesTabState.swift`
- Delete: `Packages/AlasCore/Sources/AlasFeatures/Devices/DevicePaneStatus.swift`, `Packages/AlasCore/Tests/AlasCoreTests/DevicePaneStatusTests.swift`
- Create: `Packages/AlasCore/Tests/AlasCoreTests/DevicesTabStateTests.swift`

**Interfaces:**
- Consumes: `SimulatorDevice`, `VMGuestOS` (AlasPlatform).
- Produces:

```swift
public enum DevicesTarget: Hashable, Sendable { case simulator(String), vm(VMGuestOS) }

public enum VMDeviceStatus: Equatable, Sendable {
    case notCreated, stopped, starting, running, pausing
    case paused(savedAt: Date)
    case runningElsewhere(label: String)
}

public struct DevicesTabState: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case live, busy, idle }
    public struct Row: Equatable, Sendable, Identifiable {
        public let target: DevicesTarget
        public let title: String      // "iPhone 17 Pro", "macOS VM"
        public let detail: String     // "iOS 26.5", "Running", "Paused"
        public let tone: Tone
        public var id: DevicesTarget { target }
    }
    public enum SimulatorStage: Equatable, Sendable { case booted, booting, shutDown }
    public enum Stage: Equatable, Sendable {
        case loading
        case unavailable(String)
        case noSimulators
        case simulator(SimulatorDevice, SimulatorStage)
        case vm(VMGuestOS, VMDeviceStatus)
    }
    public let selected: DevicesTarget?
    public let simulatorRows: [Row]
    /// Shown in the switcher's Simulators section instead of rows: the simctl error or "No iOS simulators".
    public let simulatorsNote: String?
    public let vmRows: [Row]
    public let stage: Stage

    public static func resolve(
        simulators: [SimulatorDevice]?, listError: String?,
        vms: [VMGuestOS: VMDeviceStatus], selection: DevicesTarget?,
        bootingUDIDs: Set<String>, agentDriving: Set<DevicesTarget>
    ) -> DevicesTabState
}
```

Rules:
- Rows: simulators in the given order, then VMs macOS before Linux (only those in `vms`, which is empty where VMs are unsupported).
- Tone: `.busy` when the target is in `agentDriving`, a simulator is booting (state `.booting` or in `bootingUDIDs`), or a VM is `starting`/`pausing`; `.live` when booted/running; else `.idle`. VM `runningElsewhere` is `.idle` (it can't be driven here).
- VM detail: Running, Starting, Pausing, Paused, Stopped, `In <label>`, Not created.
- Selection: a `.vm(g)` selection resolves while `vms[g]` exists; a `.simulator(u)` selection resolves while `u` is listed. Otherwise the default: first booted simulator; running VM (macOS, then Linux); first simulator; `.vm(.macOS)` if listed; `.vm(.linux)` if listed. With the list still loading, the default stops after the running VM (so it doesn't jump to the macOS card).
- Stage when nothing resolves: `listError` → `.unavailable(listError)`; list nil → `.loading`; else `.noSimulators`.
- `simulatorsNote`: `"Install Xcode to use iOS simulators"` with `listError`; `"No iOS simulators"` with an empty list; nil otherwise.

- [ ] **Step 1: Failing tests** in `DevicesTabStateTests` (parameterized `Case` table like the old `DevicePaneStatusTests`):
  - `selectionFallsBackOnlyWhenItsDeviceIsGone`: a selected booted simulator stays; a deleted one falls back to the first booted; a selected `.vm(.linux)` with Linux `notCreated` stays `.vm(.linux, .notCreated)`.
  - `defaultPrefersABootedSimulatorThenARunningVM`: none booted, macOS running → `.vm(.macOS, .running)`; none running → first simulator `.shutDown`.
  - `noSimulatorsFallsBackToTheMacOSVM`: `listError` with VMs → stage `.vm(.macOS, …)` and `simulatorsNote == "Install Xcode to use iOS simulators"`; `listError` without VMs → `.unavailable`; empty list without VMs → `.noSimulators`.
  - `loadingDoesNotJumpToAStoppedVM`: list nil, macOS stopped → `.loading`.
  - `bootingCountsBeforeSimctlSaysSo`: shut-down simulator in `bootingUDIDs` → `.simulator(_, .booting)`, row tone `.busy`.
  - `rowsCarryToneAndDetail` (parameterized over the VM statuses and agent driving).
- [ ] **Step 2: Run, see failures.**
- [ ] **Step 3: Implement** `DevicesTabState.swift`; delete `DevicePaneStatus.swift` and its test file.
- [ ] **Step 4: Run** `DevicesTabStateTests`. The app does not build until Task 4 replaces `DevicePaneStatus`; run only the AlasCore suite here.
- [ ] **Step 5: Commit** (with Task 4, since the app references `DevicePaneStatus`; stage these files now and commit at the end of Task 4). Commit title then: `feat(devices): list simulators and worktree VMs in one Devices tab`.

---

### Task 3: Settings, availability and the Run toolbar

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasModel/Persistence/AppConfig.swift` (remove `devicePanelEnabled` in its five places)
- Modify: `Alas/Sources/Settings/AdvancedPane.swift` (remove both device rows)
- Modify: `Alas/Sources/Settings/ComputerUsePane.swift` (new row)
- Modify: `Alas/Sources/Devices/AppState+Devices.swift` (gate on `deviceAgentsEnabled` only)
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift:31-32` (`disabled` text)
- Modify: `AlasCLI/crates/alas/src/mcp.rs:875` (`DEVICE_DRIVING_NOTE`: "`device_disabled` means the user hasn't let agents use iOS simulators in Alas's Computer Use settings.")
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift:281` (same meaning)
- Modify: `Alas/Sources/Right/RightPaneState.swift:9-14` (`available(isFolder:devices:)`)
- Modify: `Alas/Sources/Right/RightPaneRail.swift` (label `Devices`), `RightPaneToolbarModel.swift` (leading `Devices`)
- Modify: `Alas/Sources/Right/RightPaneView.swift` (availability, remove VM toolbar wiring)
- Modify: `Alas/Sources/Right/RightPaneToolbar.swift` (remove the VM menu, `onOpenVirtualMachine`, `vmHovered`)
- Test: `AlasTests/RightPaneTabTests.swift`

**Interfaces:**
- Produces: `RightPaneTab.available(isFolder: Bool = false, devices: Bool = false)`; `DevicePaneModel.simulatorToolsFound: Bool` (Task 4); `AppState.devicesTabAvailable: Bool { WorktreeVMManager.isSupported || devicePane.simulatorToolsFound }`.

- [ ] **Step 1: Failing test.** Rename the parameter in `RightPaneTabTests` to `devices` and the test to `availableTabsFollowFolderAndDevices`; same four rows.
- [ ] **Step 2: Run, see failure** (`extra argument 'devices'`).
- [ ] **Step 3: Implement.**
  - `ComputerUsePane`, inside the "Computer Use" group after the existing row:

```swift
SettingsRow(
    name: "Let agents use iOS simulators",
    desc: "Agents in a worktree can list, open, read and drive simulators with the device_* tools. You can take over from the Devices tab."
) {
    AlasToggle(on: state.bind(\.deviceAgentsEnabled))
}
```

  - `performDeviceCommand`: `guard config.deviceAgentsEnabled else { return .error(DeviceAgentControl.disabled) }`.
  - `RightPaneView` lines 264 and 316: `RightPaneTab.available(isFolder: rps.isFolder, devices: state.devicesTabAvailable)`; remove the `onOpenVirtualMachine:` argument (lines 301-302).
  - `RightPaneToolbar`: delete `onOpenVirtualMachine`, `vmHovered`, and the `if let onOpenVirtualMachine { Menu … }` block.
- [ ] **Step 4: Update the other tests** for the new `device_disabled` wording: the phrase in `ACPMCPPromptPreambleTests.computerTurnGuidance` (if it quotes it) and any Rust assertion on `DEVICE_DRIVING_NOTE`.
- [ ] **Step 5: Run** `RightPaneTabTests`, `ACPMCPPromptPreambleTests`, `DeviceAgentControlTests`, and `cargo test -p alas`. Build after Task 4 (the app needs `devicesTabAvailable`).
- [ ] **Step 6: Commit** with Task 4.

---

### Task 4: Per-worktree selection, VM status and the shared model

**Files:**
- Modify: `Alas/Sources/Devices/DevicePaneModel.swift`
- Modify: `Alas/Sources/Right/RightPaneState.swift` (add `var devicesSelection: DevicesTarget?`)
- Create: `Alas/Sources/Devices/AppState+DevicesTab.swift`
- Create: `Alas/Sources/Devices/DeviceScreenshot.swift` (moved out of `DeviceAgentControl`)
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift` (use `DeviceScreenshot`)
- Modify: `Alas/Sources/Devices/AppState+Devices.swift` (`showDevice` sets the worktree selection)

**Interfaces:**
- Produces:

```swift
@MainActor @Observable final class DevicePaneModel {
    private(set) var devices: [SimulatorDevice]?
    private(set) var listError: String?
    private(set) var bootingUDIDs: Set<String> = []
    private(set) var bootErrors: [String: String] = [:]
    private(set) var simulatorToolsFound = false
    private(set) var shapes: [String: DeviceScreenShape] = [:]   // by deviceTypeIdentifier
    init()   // starts `SimulatorControl.isAvailable()` and, when found, `deviceTypeBundles()` + shape loading
    func refresh() async
    func pollWhileVisible() async
    func boot(_ device: SimulatorDevice) async
    func shutDown(_ device: SimulatorDevice) async
    func shape(for device: SimulatorDevice) -> DeviceScreenShape?
}
extension AppState {
    var devicesTabAvailable: Bool
    func vmDeviceStatus(worktreeID: String, guest: VMGuestOS) -> VMDeviceStatus
    func devicesTabState(worktreeID: String, selection: DevicesTarget?) -> DevicesTabState
}
enum DeviceScreenshot {
    /// PNG of the surface, scaled so its long edge is at most `maxLongEdge` (nil keeps full size).
    static func png(_ surface: IOSurface, maxLongEdge: CGFloat?) -> (data: Data, width: Int, height: Int)?
    /// Saves a full-size PNG to the Desktop as Simulator.app names it; returns the file.
    static func saveToDesktop(_ surface: IOSurface, deviceName: String, now: Date = .now) throws -> URL
}
```

- `vmDeviceStatus`:

```swift
func vmDeviceStatus(worktreeID: String, guest: VMGuestOS) -> VMDeviceStatus {
    let id = VMIdentity.recordID(worktree: worktreeID, guest: guest)
    if vmManager.pausing.contains(id) { return .pausing }
    if vmManager.isStarting(id) { return .starting }
    if vmManager.running(worktreeID, guest: guest) != nil { return .running }
    let record = vmManager.recordStatus(worktreeID, guest: guest)
    guard record.hasVM else { return .notCreated }
    if let label = record.runningElsewhere { return .runningElsewhere(label: label) }
    if let savedAt = record.pausedAt { return .paused(savedAt: savedAt) }
    return .stopped
}
```

- `devicesTabState` passes `vms` only where `WorktreeVMManager.isSupported` (both guests), and `agentDriving` from `deviceControl.driver(udid:)` and `vmDriver(recordID:)` being `.agent`.
- `showDevice(udid, in: worktreeID)`: `pane.devicesSelection = .simulator(udid)`, `pane.activeTab = .device`, show the right pane.

- [ ] **Step 1:** Move the PNG code from `DeviceAgentControl.screenshot` into `DeviceScreenshot.png`, keeping its 1280 px cap for agents (`maxLongEdge: 1280`). Desktop file name: `Simulator Screenshot - <name> - <yyyy-MM-dd 'at' HH.mm.ss>.png` (Simulator.app's pattern).
- [ ] **Step 2:** Rework `DevicePaneModel` as above. `boot` no longer selects (the view sets the pane's selection first). `shutDown` calls `SimulatorControl.shutdown` then `refresh()`, recording a failure in `bootErrors`.
- [ ] **Step 3:** Add `devicesSelection` to `RightPaneState`; implement `AppState+DevicesTab.swift`; update `showDevice`.
- [ ] **Step 4:** Point `DeviceTabView` at `state.devicesTabState(...)` minimally so the app builds (Task 5 replaces the view).
- [ ] **Step 5:** `xcodegen`, build, and run `DeviceAgentControlTests`, `RightPaneTabTests`, `RightPaneRailReducerTests`, `AppStateRightPaneRailAcceptanceTests`, plus AlasCore `DevicesTabStateTests`.
- [ ] **Step 6: Commit** Tasks 2–4: `feat(devices): list simulators and worktree VMs in one Devices tab`.

---

### Task 5: The views

**Files:**
- Rewrite: `Alas/Sources/Devices/DeviceTabView.swift` → `DevicesTabView` (rename the file to `DevicesTabView.swift`)
- Create: `Alas/Sources/Devices/DevicesSwitcher.swift`, `DeviceStage.swift`, `VMDeviceCard.swift`, `DevicesEmptyState.swift`
- Modify: `Alas/Sources/Right/RightPaneToolbar.swift` (`deviceSwitcher` / `deviceActions` slots)
- Modify: `Alas/Sources/Right/RightPaneView.swift` (pass them for `.device`)
- Modify: `Alas/Sources/Devices/DeviceScreenView.swift` only if needed: `allowsInput` and `onBlockedClick` stay; the tab now uses `onBlockedClick` to pulse the driver pill instead of showing a hint.

**Interfaces:**
- Consumes: `DevicesTabState`, `DeviceScreenShape`, `DeviceScreenView(udid:client:onStopped:allowsInput:onBlockedClick:)`, `VMDriverStatus.make`, `DeviceScreenshot.saveToDesktop`.
- Produces: `RightPaneToolbar(…, deviceSwitcher: AnyView? = nil, deviceActions: AnyView? = nil)`; when `tab == .device` and set, `deviceSwitcher` replaces the leading text (without the drag-handle overlay) and `deviceActions` sits where the trailing accessory goes.

Pieces:
- **`DevicesSwitcher`** (chip + `Menu`): an 8 pt dot (`Tone` → `add` / `warn` / `fg-faint` theme colors), title in 11.5 pt semibold, detail in `fg-dim`, `chevron.down` 9 pt; `bg-3` capsule on hover. Menu sections "Simulators" (rows, or `simulatorsNote` as a disabled item) and "This worktree's VMs". Choosing sets `rps.devicesSelection`.
- **`DevicesActions`** (simulator selected): `ToolbarBtn(icon: "camera", tooltip: "Save screenshot to Desktop")` disabled without `client.lastFrame`; after saving, a 2 s "Saved to Desktop" label in `fg-dim`. A `ToolbarMenuButton` (`ellipsis`) with "Shut Down", enabled while booted.
- **`DeviceStage`**: `GeometryReader`; available width = width − 12 × 2 − 44, height = height − 12 × 2. With a shape, fit `widthPoints:heightPoints` into it; else fill it. The screen view gets that frame, `.clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))` with `r = shape.cornerRadius(forFittedWidth:)`, inside a 4 pt `#111` bezel (`RoundedRectangle(cornerRadius: r + 4)`) with `.shadow(color: .black.opacity(0.35), radius: 12, y: 6)`. Centered in the area left of the gutter.
  - **Controls capsule** in the 44 pt gutter, vertically centered: `house` (Home), `square.stack` (App switcher, `app_switcher`), `lock` (Lock), `mic` (Siri); 28 pt buttons, `bg-2` capsule with a `line` stroke; disabled while an agent drives.
  - **Driver pill**: top center of the screen, 8 pt below its top edge; only when `driver != .idle`. Agent: tone dot, "`<name>` is driving", a "Take over" text button (accent). User: "You're driving", "Hand back". `bg-2` fill with `.ultraThinMaterial`, `line` stroke, 10.5 pt. A blocked click pulses the pill (scale 1.06, 0.2 s) instead of the old hint.
  - **Stream stopped** overlay stays (message + Retry), restyled as an empty state over the screen.
- **`DevicesEmptyState`**: a column: SF Symbol at 28 pt in `fg-faint`, a 12.5 pt line, optional small secondary text, optional primary `AlasButton`. Used for `.loading` (spinner instead of a symbol), `.unavailable`, `.noSimulators`, shut down ("`<name>` is shut down", Boot), booting ("Booting `<name>`…", spinner), and boot errors (warning tone under the shut-down state).
- **`VMDeviceCard`**: a 260 pt-wide card, centered: `desktopcomputer` (macOS) or `terminal` (Linux) symbol, title, state line (Paused uses `RelativeDateTimeFormatter`: "Paused, saved 2 hours ago"), driver line while running (`VMDriverStatus.make` title + details), and buttons: Open / Set up (primary, `openVirtualMachine(in:guest:)`), Take over / Hand back while running (`takeOverVM` in a `Task`, `handBackVM`). Running elsewhere: no Open, the line "Running in `<label>`".
- **`DevicesTabView`**: `TimelineView(.periodic(from: .now, by: 1))` around `state.devicesTabState(...)` (VM status and "n s ago" stay current), switches on `stage`, `.task { await model.pollWhileVisible() }`.

- [ ] **Step 1:** Build the pieces and wire them; delete what they replace (old picker, `driverBar`, `blockedHint`).
- [ ] **Step 2:** `xcodegen`, build, run `RightPaneTabTests` and `DeviceAgentControlTests`.
- [ ] **Step 3: Commit.** `feat(devices): redesign the Devices tab around the device screen`

---

### Task 6: Docs, and checking it

**Files:**
- Modify: `docs/devices.md` (no experiment; the Devices tab; VMs listed; settings in Computer Use)
- Modify: `docs/plans/2026-11-04-device-panel-design.md` (note the redesign under Phase 1 behavior)

- [ ] **Step 1:** Update the docs.
- [ ] **Step 2: Throwaway render check** (deleted before commit): an app-host test that renders `DevicesTabView` pieces with `ImageRenderer` for a booted simulator state, a shut-down state, a VM card and the no-Xcode note at 300 pt and 420 pt widths, writes PNGs to `/tmp`, and they are looked at. The live screen itself won't render in `ImageRenderer`; the frame, corners, capsule and pill do.
- [ ] **Step 3: Manual pass in Alas Dev** (the user; computer use can't drive Alas Dev): switch between simulators and both VMs; boot, shut down, screenshot; corners on an iPhone 17 Pro and an iPad Air; the driver pill while an agent drives and after Take over; Open and Set up for VMs; the Run tab without its VM menu; an agent's `device_open` switching only its own worktree's pane.
- [ ] **Step 4: Commit.** `docs(devices): describe the Devices tab`
