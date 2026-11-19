# Devices rail stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the right rail's Devices tab stacks every running simulator, Android
device and worktree VM, and moves any of them to a center tab and back.

**Architecture:**
- **AlasCore** (pure, tested): the existing `DevicesTabState` gains the list of
  running devices and the empty state. A new `DevicesRail` decides each entry's
  placement (expanded, collapsed, in a center tab), and `DevicesRailLayout`
  sizes the screens.
- **App:** `DevicesRailView` stacks shared entry pieces (`DeviceEntryHeader`,
  `DeviceEntryActions`, `DeviceEntryStage`, `VMEntryScreen`). A new center
  `.device` tab reuses the same pieces.
- A device is in the center exactly when this worktree has a center tab open
  for it.

**Tech Stack:** Swift 6, SwiftUI on macOS 15, Swift Testing, the AlasCore SwiftPM
package, Virtualization (`VZVirtualMachineView`).

**Spec:** `docs/plans/2026-11-19-devices-rail-stack-design.md`

## Changes from the spec

Each of these was found while reading the code for this plan.

1. **`DevicesTabState` stays.** It already builds the rows, tones, the
   simulator note and the switcher listing that **+ Add** needs. It gains
   `running` and `empty`, and loses only its `Stage` and selection fallback.
   `DevicesRail` holds placement and sizing. There is no separate
   `DevicesRailState`.
2. **+ Add reuses the switcher's panel** (`DevicesSwitcherPanel`, renamed
   `DevicesAddPanel`), keeping its filter, runtime folding, keyboard navigation
   and inline Boot. Its Running section stays as a jump list: picking a running
   device scrolls to it.
3. **VMs start from their tab.**
   - Picking a VM that isn't running in **+ Add** opens its center tab.
     Starting, resuming, slot choices and Set up live there today, and
     duplicating them in the rail would copy `VirtualMachineTabView`'s start
     logic.
   - A VM's **⋯** has **Stop VM** only; Alas has no user-facing Pause.
4. **Header details:**
   - The header shows the device's OS line ("iOS 26.5", "Android 16",
     "Running").
   - Notices ("Saved to Desktop") show in the existing pill at the bottom of the
     screen.
   - Rotate stays in the hardware gutter, where it already is.
   - A recording under way, and a flow being recorded, each show a lit Stop
     button in the header next to the screenshot button.
5. **Moving a VM back to the rail hands it back.** ⤡ closes the VM tab, and
   closing a VM tab already hands the VM back (`onVMTabClosed`). The rail's
   Take over works again right after.
6. **The rail doesn't resize a VM's display.** `VZVirtualMachineView`
   reconfigures the guest display to its own size, which at the rail's ~300 pt
   would shrink the guest desktop. In the rail, `VMDisplaySurface` turns
   `automaticallyReconfiguresDisplay` off; the VM tab keeps it on. Task 6
   checks this by hand.

## Global Constraints

- **AlasCore:** no SwiftUI, AppKit or Virtualization imports. `swift test
  --package-path Packages/AlasCore` must keep working.
- **Tests:** Swift Testing (`import Testing`); one behavior per test;
  parameterize input variants; no view tests.
- **Design tokens:** colors through `theme.color(...)`, fonts through
  `scale.*`. A literal size gets a `// design-literal:` comment, as the
  existing device views do.
- **Strings:** English UI strings in the repo's sentence style.
- **Project file:** after adding or removing files, run `xcodegen` and commit
  only the file hunks of `Alas.xcodeproj/project.pbxproj`. xcodegen also
  reshuffles two "Embed Dependencies" copy phases; restore those hunks.
- **Layout constants:** header row 28 pt, stack spacing 8 pt, minimum stage
  height 200 pt, VM screen aspect 10:16. Phone chrome is 76 pt horizontal and
  32 pt vertical (12 pt margins, 44 pt gutter, 4 pt bezel). VM chrome is 24 pt
  both ways.
- **Conventional Commits,** with no agent attribution.

## Review Focus

These are the inputs most likely to break for a user that the main tests don't
cover. Each one gets a pinned test in the task that owns the code.

1. **An emulator boots again under a new serial.** Its center tab still finds
   it, by AVD name. Pinned in Task 2,
   `aCenterTabFindsItsDeviceOrItsAVDsNewEmulator`.
2. **A center tab's device stops.** The rail shows no placeholder for a device
   that isn't running. Pinned in Task 2,
   `placementFollowsCollapsedDevicesAndCenterTabs`.
3. **The pane is shorter than two screens.** Each expanded screen keeps
   200 pt and the stack scrolls. Pinned in Task 2, case "a short pane keeps
   screens usable".
4. **A VM that another Alas runs, or a paused VM.** It never joins the stack.
   Pinned in Task 1, `onlyAVMRunningHereJoinsTheStack`.
5. **A USB phone waiting for USB-debugging approval.** It stays in the stack,
   where its Retry is. Pinned in Task 1,
   `runningDevicesStackSimulatorsThenAndroidThenVMsEachByName`.

---

### Task 1: Running devices and the empty state (AlasCore)

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/DevicesTabState.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/DevicesTabStateTests.swift`

**Interfaces:**
- Produces:
  - `DevicesTabState.Screen`:
    - `.simulator(SimulatorDevice, SimulatorStage)`
    - `.android(AndroidTarget, AndroidStage)`
    - `.vm(VMGuestOS, VMDeviceStatus)`
  - `DevicesTabState.Running`: `row: Row`, `screen: Screen`,
    `id: DevicesTarget`.
  - `DevicesTabState.Empty`:
    - `.loading`
    - `.unavailable(String)`
    - `.noSimulators`
    - `.nothingRunning(suggested: Row?)`
  - `DevicesTabState.running: [Running]` and `DevicesTabState.empty: Empty?`
    (nil while something runs).

- [ ] **Step 1: Write the failing tests.** Append these inside
  `struct DevicesTabStateTests`, before its closing brace:

```swift
    /// Booting and connected devices count; a USB phone waiting for approval stays, where its Retry is.
    @Test func runningDevicesStackSimulatorsThenAndroidThenVMsEachByName() {
        let zeta = SimulatorDevice(udid: "zeta", name: "iPhone Zeta", runtimeName: "iOS 26.5", state: .booted)
        let state = DevicesTabState.resolve(
            simulators: [zeta, Self.off, Self.on, Self.mid], listError: nil,
            vms: [.macOS: .running, .linux: .starting], selection: nil, bootingUDIDs: ["off"], agentDriving: [],
            android: AndroidListing(
                devices: [Self.phone, Self.emulator], avds: ["Medium_Phone", "Pixel_9", "Tablet"],
                bootingAVDs: ["Tablet"], note: nil
            )
        )
        #expect(state.running.map(\.id) == [
            .simulator("off"), .simulator("on"), .simulator("zeta"),
            .android("emulator-5554"), .android("R5CT"), .android("avd:Tablet"),
            .vm(.macOS), .vm(.linux),
        ])
        #expect(state.running.first?.screen == .simulator(Self.off, .booting))
        #expect(state.running[4].screen == .android(
            AndroidTarget(id: "R5CT", title: "R5CT", device: Self.phone, avdName: nil), .unauthorized
        ))
        #expect(state.empty == nil)
    }

    @Test(arguments: [
        (VMDeviceStatus.running, true), (.starting, true), (.pausing, true),
        (.stopped, false), (.notCreated, false), (.paused(savedAt: .distantPast), false),
        (.runningElsewhere(label: "Alas Dev"), false),
    ] as [(VMDeviceStatus, Bool)])
    func onlyAVMRunningHereJoinsTheStack(status: VMDeviceStatus, stacked: Bool) {
        let state = resolve(vms: [.macOS: status], android: nil)
        #expect(state.running.map(\.id) == (stacked ? [.vm(.macOS)] : []))
    }

    @Test func withNothingRunningTheRailSaysWhyOrOffersADevice() {
        #expect(resolve(simulators: nil, android: nil).empty == .loading)
        let noXcode = DevicesTabState.resolve(
            simulators: nil, listError: "no simctl", vms: [:], selection: nil, bootingUDIDs: [], agentDriving: []
        )
        #expect(noXcode.empty == .unavailable("no simctl"))
        #expect(resolve(simulators: [], android: nil).empty == .noSimulators)
        let simulator = resolve(simulators: [Self.off], vms: Self.stoppedVMs, android: nil)
        #expect(simulator.empty == .nothingRunning(suggested: simulator.simulatorRows.first))
        let vmOnly = DevicesTabState.resolve(
            simulators: nil, listError: "no simctl", vms: Self.stoppedVMs, selection: nil, bootingUDIDs: [], agentDriving: []
        )
        #expect(vmOnly.empty == .nothingRunning(suggested: vmOnly.vmRows.first))
    }

    @Test func theLastUsedDeviceIsOfferedFirst() {
        let state = resolve(simulators: [Self.off, Self.mid], selection: .simulator("mid"), android: nil)
        #expect(state.empty == .nothingRunning(suggested: state.simulatorRows.last))
    }
```

- [ ] **Step 2: Run the tests and check that they fail.**

  Run: `swift test --package-path Packages/AlasCore --filter DevicesTabStateTests`

  Expected: the build fails with `value of type 'DevicesTabState' has no member 'running'`.

- [ ] **Step 3: Add the types and fields.** In `DevicesTabState.swift`, after
  the closing brace of `public enum Stage`, insert:

```swift
    /// What a running device's entry in the Devices rail shows.
    public enum Screen: Equatable, Sendable {
        /// Booted or booting.
        case simulator(SimulatorDevice, SimulatorStage)
        /// Connected (ready, booting, unauthorized or offline), or an AVD booting.
        case android(AndroidTarget, AndroidStage)
        /// Running, starting or pausing.
        case vm(VMGuestOS, VMDeviceStatus)
    }

    /// A device that is up or coming up, as the Devices rail stacks it.
    public struct Running: Equatable, Sendable, Identifiable {
        public let row: Row
        public let screen: Screen
        public var id: DevicesTarget { row.target }
    }

    /// What the rail shows when nothing runs.
    public enum Empty: Equatable, Sendable {
        case loading
        /// simctl failed, and there are no Android devices or VMs to list.
        case unavailable(String)
        /// No simulators, Android devices or VMs at all.
        case noSimulators
        /// Devices exist, but none runs; `suggested` is the one to offer.
        case nothingRunning(suggested: Row?)
    }
```

  Then replace the stored property `public let stage: Stage` with:

```swift
    public let stage: Stage
    /// iOS simulators, then Android devices, then VMs; by name within each.
    public let running: [Running]
    /// Nil while something runs.
    public let empty: Empty?
```

- [ ] **Step 4: Compute them in `resolve`.** In `resolve`, replace the final
  `return DevicesTabState(...)` statement (its five lines) with:

```swift
        func byName(_ lhs: Running, _ rhs: Running) -> Bool {
            let byTitle = lhs.row.title.localizedStandardCompare(rhs.row.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return "\(lhs.row.detail) \(lhs.id)" < "\(rhs.row.detail) \(rhs.id)"
        }
        let runningSimulators = zip(listed ?? [], simulatorRows).compactMap { device, row -> Running? in
            let stage = simulatorStage(device)
            return stage == .shutDown ? nil : Running(row: row, screen: .simulator(device, stage))
        }
        let runningAndroid = zip(androidEntries, androidRows).compactMap { entry, row -> Running? in
            entry.stage == .shutDown ? nil : Running(row: row, screen: .android(entry.target, entry.stage))
        }
        let runningVMs = vmRows.compactMap { row -> Running? in
            guard case .vm(let guest) = row.target, let status = vms[guest] else { return nil }
            switch status {
            case .running, .starting, .pausing: return Running(row: row, screen: .vm(guest, status))
            case .notCreated, .stopped, .paused, .runningElsewhere: return nil
            }
        }
        let running = runningSimulators.sorted(by: byName) + runningAndroid.sorted(by: byName) + runningVMs

        let offerable = simulatorRows.filter(\.canBoot) + androidRows.filter(\.canBoot) + vmRows
        let suggested = offerable.first { $0.target == selection } ?? offerable.first
        let empty: Empty? = if !running.isEmpty {
            nil
        } else if listed == nil {
            .loading
        } else if let listError, androidRows.isEmpty, vmRows.isEmpty {
            .unavailable(listError)
        } else if simulatorRows.isEmpty, androidRows.isEmpty, vmRows.isEmpty {
            .noSimulators
        } else {
            .nothingRunning(suggested: suggested)
        }
        return DevicesTabState(
            selected: chosen, simulatorRows: simulatorRows, simulatorsNote: note,
            androidRows: androidRows, androidNote: android?.note, vmRows: vmRows, stage: stage,
            running: running, empty: empty
        )
```

- [ ] **Step 5: Run the tests and check that they pass.**

  Run: `swift test --package-path Packages/AlasCore --filter DevicesTabStateTests`

  Expected: PASS, including the four new tests.

- [ ] **Step 6: Commit.**
  `feat(devices): list the running devices and why none run`

---

### Task 2: Rail placement and sizing (AlasCore)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/DevicesRail.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/DevicesRailTests.swift`

**Interfaces:**
- Consumes: `DevicesTabState.Running` and `.Screen` (Task 1).
- Produces:
  - `DevicesRail.Placement` (`.expanded`, `.collapsed`, `.inCenter`)
  - `DevicesRail.Entry` (`device: DevicesTabState.Running`,
    `placement: Placement`, `id: DevicesTarget`)
  - `DevicesRail.entries(_:collapsed:inCenter:) -> [Entry]`
  - `DevicesRail.device(forTab:avdName:in:) -> DevicesTabState.Running?`
  - `DevicesRailLayout.init(visibleHeight:entries:)`, `.stageHeight`,
    `.fitsScreens`, `.height(width:aspect:chrome:) -> Double`
  - `DevicesRailLayout.Chrome(horizontal:vertical:)`, `.rowHeight` (36),
    `.minimumStageHeight` (200)

- [ ] **Step 1: Write the failing tests.** Create `DevicesRailTests.swift`:

```swift
import Foundation
import Testing
import AlasCore

struct DevicesRailTests {
    private static func booted(_ id: String) -> SimulatorDevice {
        SimulatorDevice(udid: id, name: "iPhone \(id)", runtimeName: "iOS 26.5", state: .booted)
    }

    private static func running(_ ids: [String], android: AndroidListing? = nil) -> [DevicesTabState.Running] {
        DevicesTabState.resolve(
            simulators: ids.map(booted), listError: nil, vms: [:], selection: nil, bootingUDIDs: [],
            agentDriving: [], android: android
        ).running
    }

    /// `expanded` devices, then `collapsed` ones, then `inCenter` ones.
    private static func entries(expanded: Int, collapsed: Int = 0, inCenter: Int = 0) -> [DevicesRail.Entry] {
        let ids = (0..<(expanded + collapsed + inCenter)).map { "s\($0)" }
        let folded = Set(ids.dropFirst(expanded).prefix(collapsed).map(DevicesTarget.simulator))
        let centered = Set(ids.suffix(inCenter).map(DevicesTarget.simulator))
        return DevicesRail.entries(running(ids), collapsed: folded, inCenter: centered)
    }

    @Test func placementFollowsCollapsedDevicesAndCenterTabs() {
        let entries = DevicesRail.entries(
            Self.running(["a", "b", "c"]), collapsed: [.simulator("b"), .simulator("c")],
            inCenter: [.simulator("c"), .simulator("gone")]
        )
        #expect(entries.map(\.id) == [.simulator("a"), .simulator("b"), .simulator("c")])
        #expect(entries.map(\.placement) == [.expanded, .collapsed, .inCenter])
    }

    @Test func aCenterTabFindsItsDeviceOrItsAVDsNewEmulator() {
        let emulator = AndroidDevice(
            serial: "emulator-5556", state: .ready, model: nil, avdName: "Medium_Phone", release: "16"
        )
        let running = Self.running(
            ["on"], android: AndroidListing(devices: [emulator], avds: ["Medium_Phone"], bootingAVDs: [], note: nil)
        )
        #expect(DevicesRail.device(forTab: "on", avdName: nil, in: running)?.id == .simulator("on"))
        #expect(DevicesRail.device(forTab: "emulator-5554", avdName: "Medium_Phone", in: running)?.id
            == .android("emulator-5556"))
        #expect(DevicesRail.device(forTab: "gone", avdName: nil, in: running) == nil)
    }

    struct LayoutCase: Sendable, CustomTestStringConvertible {
        let name: String
        let visibleHeight: Double
        let expanded: Int
        var collapsed = 0
        var inCenter = 0
        var aspect: Double?
        var chrome = DevicesRailLayout.Chrome(horizontal: 76, vertical: 32)
        let height: Double
        var testDescription: String { name }
    }

    @Test(arguments: [
        LayoutCase(name: "one device fills the rail", visibleHeight: 800, expanded: 1, aspect: 2.17, height: 764),
        LayoutCase(name: "rows above it leave the rest", visibleHeight: 800, expanded: 1, collapsed: 1, inCenter: 1,
                   aspect: 2.17, height: 692),
        LayoutCase(name: "two phones share it", visibleHeight: 800, expanded: 2, aspect: 2.17, height: 364),
        LayoutCase(name: "a third expanded scrolls", visibleHeight: 800, expanded: 3, aspect: 2.17, height: 364),
        LayoutCase(name: "a collapsed row takes its height", visibleHeight: 800, expanded: 2, collapsed: 1,
                   aspect: 2.17, height: 346),
        LayoutCase(name: "a VM fits the width", visibleHeight: 800, expanded: 2, aspect: 0.625,
                   chrome: .init(horizontal: 24, vertical: 24), height: 197),
        LayoutCase(name: "no frame yet fills the stage", visibleHeight: 800, expanded: 2, height: 364),
        LayoutCase(name: "a short pane keeps screens usable", visibleHeight: 400, expanded: 2, aspect: 2.17, height: 200),
    ])
    func stagesSplitTheRailTwoAtATime(_ c: LayoutCase) {
        let layout = DevicesRailLayout(
            visibleHeight: c.visibleHeight,
            entries: Self.entries(expanded: c.expanded, collapsed: c.collapsed, inCenter: c.inCenter)
        )
        #expect(layout.height(width: 300, aspect: c.aspect, chrome: c.chrome) == c.height)
    }
}
```

- [ ] **Step 2: Run the tests and check that they fail.**

  Run: `swift test --package-path Packages/AlasCore --filter DevicesRailTests`

  Expected: the build fails with `cannot find 'DevicesRail' in scope`.

- [ ] **Step 3: Write the implementation.** Create `DevicesRail.swift`:

```swift
import Foundation

/// The Devices rail: the running devices one under the other, each expanded
/// to its screen, collapsed to its header, or moved to a center tab.
public enum DevicesRail {
    public enum Placement: Equatable, Sendable {
        case expanded, collapsed
        /// A center tab shows it; the rail keeps a one-line placeholder.
        case inCenter
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let device: DevicesTabState.Running
        public let placement: Placement
        public var id: DevicesTarget { device.id }
    }

    /// A center tab wins over collapsing. Targets that don't run are ignored.
    public static func entries(
        _ running: [DevicesTabState.Running], collapsed: Set<DevicesTarget>, inCenter: Set<DevicesTarget>
    ) -> [Entry] {
        running.map { device in
            let placement: Placement = inCenter.contains(device.id) ? .inCenter
                : collapsed.contains(device.id) ? .collapsed : .expanded
            return Entry(device: device, placement: placement)
        }
    }

    /// The running device a center device tab shows: the one it was opened
    /// for, else, for an emulator that booted again under another serial, the
    /// one from its AVD.
    public static func device(
        forTab deviceID: String, avdName: String?, in running: [DevicesTabState.Running]
    ) -> DevicesTabState.Running? {
        if let same = running.first(where: { $0.id == .simulator(deviceID) || $0.id == .android(deviceID) }) {
            return same
        }
        guard let avdName else { return nil }
        return running.first { device in
            guard case .android(let target, _) = device.screen else { return false }
            return target.avdName == avdName
        }
    }
}

/// How tall each expanded device's stage is in the Devices rail. One fills the
/// rail; two or more split it in two, and the rest scroll.
public struct DevicesRailLayout: Equatable, Sendable {
    /// A header, collapsed device or placeholder, with the gap under it.
    public static let rowHeight: Double = 36
    public static let minimumStageHeight: Double = 200

    /// The space a stage adds around its screen.
    public struct Chrome: Equatable, Sendable {
        public let horizontal: Double
        public let vertical: Double

        public init(horizontal: Double, vertical: Double) {
            self.horizontal = horizontal
            self.vertical = vertical
        }
    }

    /// The height each expanded stage may take.
    public let stageHeight: Double
    /// Two or more stages: each shrinks to its screen's fitted height.
    public let fitsScreens: Bool

    /// `visibleHeight` is the scroll view's, less its padding.
    public init(visibleHeight: Double, entries: [DevicesRail.Entry]) {
        let expanded = entries.filter { $0.placement == .expanded }.count
        let shown = Double(min(max(expanded, 1), 2))
        let rows = Double(entries.count - expanded) + shown
        stageHeight = max(Self.minimumStageHeight, ((visibleHeight - rows * Self.rowHeight) / shown).rounded(.down))
        fitsScreens = expanded > 1
    }

    /// The stage's height for a screen of `aspect` (height over width, as
    /// shown) in a rail `width` wide; the whole stage height without one.
    public func height(width: Double, aspect: Double?, chrome: Chrome) -> Double {
        guard fitsScreens, let aspect, aspect > 0 else { return stageHeight }
        return min(stageHeight, ((width - chrome.horizontal) * aspect + chrome.vertical).rounded(.up))
    }
}
```

- [ ] **Step 4: Run the tests and check that they pass.**

  Run: `swift test --package-path Packages/AlasCore --filter DevicesRailTests`

  Expected: PASS (2 tests, plus 8 layout cases).

- [ ] **Step 5: Commit.**
  `feat(devices): place and size the Devices rail's stack`

---

### Task 3: The shared entry pieces (app)

These are new views for one device's header, actions and screen, used later by
the rail and the center tab. Nothing shows them yet, and the app still builds.

**Files:**
- Create: `Alas/Sources/Devices/DeviceEntryHeader.swift`
- Create: `Alas/Sources/Devices/DeviceEntryActions.swift`
- Create: `Alas/Sources/Devices/DeviceFlowFiles.swift`
- Create: `Alas/Sources/Devices/DeviceEntryStage.swift`
- Create: `Alas/Sources/Devices/VMEntryScreen.swift`
- Modify:
  - `Alas/Sources/Devices/DeviceFlowButtons.swift`: use `DeviceFlowFiles`.
  - `Alas/Sources/Devices/DevicesSwitcher.swift` (`colorToken`, `glyph`) and
    `Alas/Sources/Devices/DeviceStageFrame.swift:177`: use `DeviceStyle`.
  - `Alas/Sources/Devices/DeviceStage.swift` and
    `Alas/Sources/Devices/Android/AndroidDeviceStage.swift`: add `onUse`.
  - `Alas/Sources/Devices/DevicePaneModel.swift:118`: make `show` internal.
  - `Alas/Sources/VM/VMDisplaySurface.swift`: add `reconfiguresDisplay`.
  - `Alas/Sources/Center/TabsManager.swift:2345`: rename `clearVMView` to the
    internal `releaseVMView`.

**Interfaces:**
- Consumes: `DevicesTabState.Row`, `DevicesTabState.Running` and `.Screen`
  (Task 1).
- Produces:
  - `DeviceStyle.colorToken(_:)`, `DeviceStyle.glyph(_:)`
  - `DeviceEntryHeader(row:collapsed:onToggleCollapsed:move:onMove:actions:)`,
    with `DeviceEntryHeader.Move` (`.toTab`, `.toRail`)
  - `DeviceEntryActions(kind:ready:control:recorder:flowRecorder:worktree:accessibilityOverlay:onToggleAccessibilityOverlay:onOpenLogs:onScreenshot:onShutDown:onNotice:)`
  - `DeviceEntryLiveActions(state:worktree:device:)` and
    `VMEntryActions(running:onStop:)`
  - `DeviceEntryStage(state:worktree:screen:now:onUse:)` and
    `DeviceEntryStage.waitingState(for:) -> DevicesEmptyState?`
  - `VMEntryScreen(state:worktreeID:guest:onUse:)`
  - `DevicePaneModel.show(_:udid:)` and
    `TabsManager.releaseVMView(tabID:)`
  - `DeviceFlowFiles.folder(in:)`, `.flows(in:)`, `.defaultName(at:)`,
    `.save(_:name:in:) -> String?`, `.summary(_:name:)`

- [ ] **Step 1: Shared style and header.** Create `DeviceEntryHeader.swift`:

```swift
import AlasCore
import SwiftUI

/// Colors and symbols the Devices rail, its center tabs and + Add share.
enum DeviceStyle {
    static func colorToken(_ tone: DevicesTabState.Tone) -> String {
        switch tone {
        case .live: "add"
        case .busy: "warn"
        case .idle: "fg-faint"
        }
    }

    static func glyph(_ platform: DevicesPlatform) -> String {
        switch platform {
        case .ios: "iphone"
        case .android: "candybarphone"
        case .vm(.macOS): "macwindow"
        case .vm(.linux): "terminal"
        }
    }
}

/// One device's header in the Devices rail and its center tab: the collapse
/// chevron, the status dot, its name and OS line, then its actions and the
/// move between the rail and a tab.
struct DeviceEntryHeader<Actions: View>: View {
    enum Move {
        case toTab, toRail

        var icon: String {
            switch self {
            case .toTab: "arrow.up.left.and.arrow.down.right"
            case .toRail: "sidebar.right"
            }
        }

        var help: String {
            switch self {
            case .toTab: "Open in a tab"
            case .toRail: "Back to the Devices rail"
            }
        }
    }

    let row: DevicesTabState.Row
    /// Nil hides the chevron, as a center tab does.
    var collapsed: Bool?
    var onToggleCollapsed: () -> Void = {}
    let move: Move
    let onMove: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            if let collapsed {
                Button(action: onToggleCollapsed) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)) // design-literal: disclosure chevron
                        .foregroundStyle(theme.color("fg-faint"))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show the screen" : "Collapse")
            }
            Circle()
                .fill(theme.color(DeviceStyle.colorToken(row.tone)))
                .frame(width: 7, height: 7) // design-literal: status dot size
            Text(row.title)
                .font(scale.meta.font(weight: .medium))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(1)
                // The OS line truncates first.
                .layoutPriority(1)
            Text(row.detail)
                .font(scale.caption.font(weight: .regular))
                .foregroundStyle(theme.color("fg-dim"))
                .lineLimit(1)
            Spacer(minLength: 4)
            actions()
                .layoutPriority(2)
            ToolbarBtn(icon: move.icon, tooltip: move.help, action: onMove)
                .layoutPriority(2)
        }
        .frame(height: 28) // design-literal: DevicesRailLayout's header row
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 2: Point the existing views at `DeviceStyle`.**
  - In `DevicesSwitcher.swift`, delete `static func colorToken` and
    `static func glyph` (lines 72-87). Then replace `Self.colorToken(` (line
    24), `DevicesSwitcher.colorToken(` (line 253) and `DevicesSwitcher.glyph(`
    (line 255) with `DeviceStyle.colorToken(` and `DeviceStyle.glyph(`.
  - In `DeviceStageFrame.swift:177`, replace
    `DevicesSwitcher.colorToken(.busy)` with `DeviceStyle.colorToken(.busy)`.

- [ ] **Step 3: Flow files.** Create `DeviceFlowFiles.swift`:

```swift
import AlasCore
import Foundation

/// The flows a worktree keeps in `.maestro/`: listing them, saving a
/// recording, and what a run answered, in words.
enum DeviceFlowFiles {
    static func folder(in worktree: URL) -> URL {
        worktree.appendingPathComponent(".maestro", isDirectory: true)
    }

    static func flows(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// "flow-20261119-1405".
    static func defaultName(at date: Date) -> String { "flow-\(stamp.string(from: date))" }

    /// Saves `flow` as `<name>.yaml` in `folder`: why it couldn't, or nil once saved.
    static func save(_ flow: DeviceFlow, name: String, in folder: URL) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 64,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return "Use letters, digits, - and _."
        }
        let file = folder.appendingPathComponent("\(trimmed).yaml")
        guard !FileManager.default.fileExists(atPath: file.path) else { return "\(trimmed).yaml already exists." }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try flow.yaml.write(to: file, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func summary(_ response: AlasCLIResponse, name: String) -> String {
        switch response {
        case .text(let parts):
            guard let reply = (try? JSONSerialization.jsonObject(with: Data(parts.joined().utf8))) as? [String: Any] else {
                return parts.joined()
            }
            if reply["passed"] as? Bool == true { return "\(name) passed: \(reply["steps"] as? Int ?? 0) steps." }
            let step = reply["failed_step"] as? Int ?? 0
            let line = reply["line"] as? Int ?? 0
            return "\(name) failed at step \(step) (line \(line)): \(reply["reason"] as? String ?? "")"
        case .error(let message):
            return message
        default:
            return "\(name) ran."
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()
}
```

  Then update `DeviceFlowButtons.swift` so its logic lives in one place until
  Task 5 deletes the file:
  - `private var folder` returns `DeviceFlowFiles.folder(in: worktree)`.
  - `name = "flow-\(Self.stamp.string(from: Date()))"` becomes
    `name = DeviceFlowFiles.defaultName(at: Date())`.
  - `Self.flows(in: folder)` becomes `DeviceFlowFiles.flows(in: folder)`.
  - `Self.summary(` becomes `DeviceFlowFiles.summary(`.
  - The body of `private func save()` becomes:

```swift
        guard let recorded else { return }
        if let error = DeviceFlowFiles.save(recorded, name: name, in: folder) {
            saveError = error
        } else {
            self.recorded = nil
        }
```

  - Delete its `static func summary`, `private static func flows` and
    `private static let stamp`.

- [ ] **Step 4: Header actions.** Create `DeviceEntryActions.swift`:

```swift
import AlasCore
import AppKit
import SwiftUI

/// A simulator's or Android device's actions in its Devices header: a lit Stop
/// for a recording or flow recording under way, a screenshot, then the rest in
/// a menu. Popovers the menu opens hang off it.
struct DeviceEntryActions: View {
    enum Kind {
        case simulator(SimulatorDevice)
        case android(AndroidDevice)
    }

    let kind: Kind
    /// It has a screen: a booted simulator, a ready Android device.
    let ready: Bool
    let control: DeviceAgentControl
    let recorder: DeviceRecorder
    let flowRecorder: DeviceFlowRecorder
    let worktree: URL
    let accessibilityOverlay: Bool
    let onToggleAccessibilityOverlay: () -> Void
    let onOpenLogs: () -> Void
    /// Saves a screenshot to the Desktop and says how it went.
    let onScreenshot: () async -> String
    /// Nil where Alas can't shut it down: a USB phone.
    let onShutDown: (() -> Void)?
    /// A short message over the bottom of the screen.
    let onNotice: (String) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var showsSettings = false
    /// A flow recording waiting for its name.
    @State private var recordedFlow: DeviceFlow?
    @State private var flowName = ""
    @State private var flowSaveError: String?
    /// What the last flow you ran answered.
    @State private var flowResult: String?

    private var udid: String {
        switch kind {
        case .simulator(let device): device.udid
        case .android(let device): device.serial
        }
    }

    private var platform: AgentDevice.Platform {
        if case .simulator = kind { .ios } else { .android }
    }

    /// It has a screen, and no agent drives it.
    private var canChange: Bool { ready && VMDriver.allowsViewInput(control.driver(udid: udid)) }

    private var flowFolder: URL { DeviceFlowFiles.folder(in: worktree) }

    var body: some View {
        HStack(spacing: 2) {
            if case .user? = recorder.owner(udid: udid) {
                ToolbarBtn(icon: "stop.circle.fill", tooltip: "Stop recording", isActive: true) {
                    Task { await stopRecording() }
                }
            }
            if flowRecorder.isRecording(udid) {
                ToolbarBtn(icon: "hand.tap", tooltip: "Stop recording flow", isActive: true, action: stopFlowRecording)
            }
            ToolbarBtn(icon: "camera", tooltip: "Save screenshot to Desktop") {
                Task { onNotice(await onScreenshot()) }
            }
            .disabled(!ready)
            ToolbarMenuButton(iconName: "ellipsis", help: "More") { menu }
                // One popover per view: each hangs off its own clear background.
                .background { Color.clear.popover(isPresented: $showsSettings, arrowEdge: .bottom) { settings } }
                .background { Color.clear.popover(isPresented: savingFlow, arrowEdge: .bottom) { flowSaveForm } }
                .background { Color.clear.popover(isPresented: showingFlowResult, arrowEdge: .bottom) { flowResultText } }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var menu: some View {
        Button("Settings…") { showsSettings = true }
            .disabled(!canChange)
        Button("Logs", action: onOpenLogs)
            .disabled(!ready)
        if case .simulator = kind {
            Button(
                accessibilityOverlay ? "Hide Accessibility Overlay" : "Show Accessibility Overlay",
                action: onToggleAccessibilityOverlay
            )
            .disabled(!ready)
        }
        Divider()
        recordItem
        flowItems
        if let onShutDown {
            Divider()
            Button("Shut Down", action: onShutDown)
                .disabled(!ready)
        }
    }

    @ViewBuilder
    private var recordItem: some View {
        switch recorder.owner(udid: udid) {
        case nil:
            Button(platform == .ios ? "Record Screen" : "Record Screen (up to 3 Minutes)", action: startRecording)
                .disabled(!ready)
        case .user:
            Button("Stop Recording") { Task { await stopRecording() } }
        case .agent:
            Button("An Agent Is Recording") {}
                .disabled(true)
        }
    }

    @ViewBuilder
    private var flowItems: some View {
        let recording = flowRecorder.isRecording(udid)
        if recording {
            Button("Stop Recording Flow…", action: stopFlowRecording)
        } else {
            Button("Record Flow") {
                guard let backend = control.backend(for: platform) else { return }
                Task { await flowRecorder.start(udid: udid, backend: backend) }
            }
            .disabled(!canChange)
        }
        // A flow you start runs only on an idle device: taking it from you here would let held agent calls in first.
        let held = control.driver(udid: udid) == .user
        Menu(held ? "Run Flow (Hand the Device Back First)" : "Run Flow") {
            let flows = DeviceFlowFiles.flows(in: flowFolder)
            if flows.isEmpty {
                Text("No flows in .maestro")
            }
            ForEach(flows, id: \.self) { file in
                Button(file.deletingPathExtension().lastPathComponent) { runFlow(file) }
            }
        }
        .disabled(!canChange || recording || held)
    }

    @ViewBuilder
    private var settings: some View {
        if let backend = control.backend(for: platform) {
            DeviceSettingsPopover(udid: udid, backend: backend, control: control)
        }
    }

    private var savingFlow: Binding<Bool> {
        Binding(get: { recordedFlow != nil }, set: { if !$0 { recordedFlow = nil } })
    }

    private var showingFlowResult: Binding<Bool> {
        Binding(get: { flowResult != nil }, set: { if !$0 { flowResult = nil } })
    }

    private var flowSaveForm: some View {
        VStack(alignment: .leading, spacing: scale.space[3]) {
            Text("\(recordedFlow?.steps.count ?? 0) steps recorded")
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("fg"))
            HStack(spacing: 6) {
                TextField("Name", text: $flowName)
                    .onSubmit(saveFlow)
                Text(".yaml").foregroundStyle(theme.color("fg-dim"))
            }
            if let flowSaveError {
                Text(flowSaveError)
                    .foregroundStyle(theme.color("warn"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Discard", role: .destructive) { recordedFlow = nil }
                Spacer()
                Button("Save", action: saveFlow).keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .font(scale.meta.font)
        .padding(scale.space[4])
        .frame(width: 280)
    }

    private var flowResultText: some View {
        Text(flowResult ?? "")
            .font(scale.meta.font)
            .foregroundStyle(theme.color("fg"))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 280)
            .padding(scale.space[4])
    }

    private func startRecording() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-recording-\(UUID().uuidString).\(platform == .ios ? "mov" : "mp4")")
        do throws(DeviceRecorder.Failure) {
            try recorder.start(udid: udid, owner: .user, file: file)
        } catch {
            onNotice("Couldn't start recording")
        }
    }

    private func stopRecording() async {
        do {
            // The recorder saves it to the Desktop (AppState's onUserRecordingEnded).
            _ = try await recorder.stop(udid: udid, owner: .user)
            onNotice("Saved to Desktop")
        } catch DeviceRecorder.Failure.notSaved {
            onNotice("Couldn't save to the Desktop; it's shown in Finder")
        } catch {
            onNotice("Couldn't save the recording")
        }
    }

    private func stopFlowRecording() {
        recordedFlow = flowRecorder.stop(udid)
        flowName = DeviceFlowFiles.defaultName(at: Date())
        flowSaveError = nil
    }

    private func saveFlow() {
        guard let recordedFlow else { return }
        if let error = DeviceFlowFiles.save(recordedFlow, name: flowName, in: flowFolder) {
            flowSaveError = error
        } else {
            self.recordedFlow = nil
        }
    }

    /// Runs as the "flow" session, so the screen shows its progress and Take over stops it.
    private func runFlow(_ file: URL) {
        Task {
            let response = await control.perform(
                .runFlow(udid: udid, path: file.path), sessionID: DeviceAgentControl.userFlowSession
            )
            flowResult = DeviceFlowFiles.summary(response, name: file.deletingPathExtension().lastPathComponent)
        }
    }
}

/// A running device's header actions, wired to the app.
struct DeviceEntryLiveActions: View {
    let state: AppState
    let worktree: Worktree
    let device: DevicesTabState.Running

    var body: some View {
        switch device.screen {
        case .simulator(let simulator, let stage):
            DeviceEntryActions(
                kind: .simulator(simulator), ready: stage == .booted, control: state.deviceControl,
                recorder: state.deviceRecorder, flowRecorder: state.deviceFlowRecorder, worktree: worktree.path,
                accessibilityOverlay: state.devicePane.accessibilityOverlays.contains(simulator.udid),
                onToggleAccessibilityOverlay: { state.devicePane.toggleAccessibilityOverlay(udid: simulator.udid) },
                onOpenLogs: {
                    state.openDeviceLogs(worktreeID: worktree.id, udid: simulator.udid, name: simulator.name, platform: .ios)
                },
                onScreenshot: { Self.saveScreenshot(state.simulatorStreams.lastFrame(udid: simulator.udid), name: simulator.name) },
                onShutDown: { Task { await state.devicePane.shutDown(simulator) } },
                onNotice: { state.devicePane.show($0, udid: simulator.udid) }
            )
        case .android(let target, let stage):
            if let android = target.device {
                DeviceEntryActions(
                    kind: .android(android), ready: stage == .ready, control: state.deviceControl,
                    recorder: state.deviceRecorder, flowRecorder: state.deviceFlowRecorder, worktree: worktree.path,
                    accessibilityOverlay: false, onToggleAccessibilityOverlay: {},
                    onOpenLogs: {
                        state.openDeviceLogs(worktreeID: worktree.id, udid: android.serial, name: android.title, platform: .android)
                    },
                    onScreenshot: { await Self.saveScreenshot(android, pane: state.androidPane) },
                    onShutDown: android.isEmulator ? {
                        Task {
                            // Saves a recording before the device goes.
                            await state.deviceRecorder.simulatorStopped(udid: android.serial)
                            await state.androidPane.shutDown(android)
                        }
                    } : nil,
                    onNotice: { state.androidPane.show($0, serial: android.serial) }
                )
            }
        case .vm(let guest, let status):
            VMEntryActions(running: status == .running) {
                Task { await state.vmManager.stopVM(worktreeID: worktree.id, guest: guest) }
            }
        }
    }

    static func saveScreenshot(_ frame: DeviceFrame?, name: String) -> String {
        guard let frame else { return "No frame yet" }
        do {
            _ = try DeviceScreenshot.saveToDesktop(frame, deviceName: name)
            return "Saved to Desktop"
        } catch {
            return "Couldn't save the screenshot"
        }
    }

    static func saveScreenshot(_ device: AndroidDevice, pane: AndroidPaneModel) async -> String {
        do {
            guard let control = pane.control else { throw AndroidControlError("No Android SDK.") }
            let png = try await control.screenshot(serial: device.serial)
            _ = try DeviceScreenshot.savePNGToDesktop(png, kind: "Android Screenshot", deviceName: device.title)
            return "Saved to Desktop"
        } catch {
            return "Couldn't save the screenshot"
        }
    }
}

/// A VM's actions in its Devices header: Stop, in a menu.
struct VMEntryActions: View {
    let running: Bool
    let onStop: () -> Void

    var body: some View {
        ToolbarMenuButton(iconName: "ellipsis", help: "More") {
            Button("Stop VM", action: onStop)
                .disabled(!running)
        }
        .fixedSize()
    }
}
```

  In `DevicePaneModel.swift:118`, change `private func show(` to `func show(`.

- [ ] **Step 5: A screen reports its use.**
  - In `DeviceStage.swift`, add after `let flowRecorder: DeviceFlowRecorder`:

```swift
    /// The user clicked or typed into the screen.
    var onUse: () -> Void = {}
```

    and change its `onUserInput: { overlayReadKey += 1 },` argument to
    `onUserInput: { overlayReadKey += 1; onUse() },`.
  - In `AndroidDeviceStage.swift`, add the same `var onUse: () -> Void = {}`
    after `let flowRecorder: DeviceFlowRecorder`, and insert
    `onUserInput: onUse,` after `onPaste: paste, onCopy: copy,` in its
    `DeviceScreenView(...)` call.

- [ ] **Step 6: The VM screen can leave the guest's display alone.** In
  `VMDisplaySurface.swift`:
  - After `var capturesSystemKeys = false`, add:

```swift
    /// Resize the guest's display to the view. Off in the Devices rail, whose
    /// narrow view would shrink the guest's desktop; the screen scales instead.
    var reconfiguresDisplay = true
```

  - In `attach`, right after the
    `if view.capturesSystemKeys != capturesSystemKeys { ... }` block, add:

```swift
        if view.automaticallyReconfiguresDisplay != reconfiguresDisplay {
            view.automaticallyReconfiguresDisplay = reconfiguresDisplay
        }
```

- [ ] **Step 7: Release a VM screen the rail used.** In `TabsManager.swift`:
  - Rename `private func clearVMView(tabID: TabID)` to
    `func releaseVMView(tabID: TabID)`, and add this doc comment above it:
    `/// Drops a VM's cached screen view: when its tab closes, or when the Devices rail stops showing it.`
  - Update its one caller in `clearCachedViews` to
    `releaseVMView(tabID: state.id)`.
  - Change the comment on `vmView(tabID:)` to
    `/// The VM screen of a VM tab, kept while the tab is open or the Devices rail shows the VM.`

- [ ] **Step 8: The live stage.** Create `VMEntryScreen.swift`:

```swift
import AlasCore
import SwiftUI

/// A running worktree VM's live screen in the Devices rail, with who drives it
/// on top. It borrows the VM tab's cached screen view, so moving the VM between
/// the rail and its tab moves one view, never two.
struct VMEntryScreen: View {
    let state: AppState
    let worktreeID: String
    let guest: VMGuestOS
    var onUse: () -> Void = {}
    @State private var pulse = false

    private var recordID: String { VMIdentity.recordID(worktree: worktreeID, guest: guest) }
    private var tabID: TabID { VirtualMachineTabState(ownerKey: worktreeID, guest: guest).id }

    var body: some View {
        let driver = state.vmDriver(recordID: recordID)
        ZStack(alignment: .top) {
            VMDisplaySurface(
                view: state.tabs.vmView(tabID: tabID), virtualMachine: state.vmManager.running(worktreeID, guest: guest)?.vm,
                allowsInput: VMDriver.allowsViewInput(driver), capturesSystemKeys: driver == .user,
                reconfiguresDisplay: false,
                onBlockedClick: pulsePill,
                onUserInput: { [state, recordID, onUse] in
                    state.noteVMUserInput(recordID: recordID)
                    onUse()
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 6)) // design-literal: VM screen corners
            if driver != .idle {
                DeviceDriverPill(
                    driver: driver, waiting: state.vmHolds.waiting(recordID).first,
                    agentName: { state.computerUseAgentName($0) }, pulse: pulse,
                    onTakeOver: { Task { await state.takeOverVM(recordID: recordID) } },
                    onHandBack: { state.handBackVM(recordID: recordID) }
                )
                .padding(.top, 8) // design-literal: pill inset, as on a phone screen
            }
        }
        .padding(12) // design-literal: DevicesRailLayout's VM chrome
        .onDisappear {
            // The VM's tab keeps the view while it's open; otherwise the screen goes, and the VM runs on.
            if !state.tabs.tabs(forWorktree: worktreeID).contains(where: { $0.id == tabID }) {
                state.tabs.releaseVMView(tabID: tabID)
            }
        }
    }

    /// A click while an agent drives: draw the eye to Take over.
    private func pulsePill() {
        pulse = true
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            pulse = false
        }
    }
}
```

  Create `DeviceEntryStage.swift`. Its cases come from
  `DevicesTabView.stage(_:now:)`; the shut-down cases move to the center tab in
  Task 4:

```swift
import AlasCore
import AppKit
import SwiftUI

/// A running device's screen as the Devices rail and its center tab show it:
/// the live stage once it's up, else what it's waiting for.
struct DeviceEntryStage: View {
    let state: AppState
    let worktree: Worktree
    let screen: DevicesTabState.Screen
    let now: Date
    /// The user clicked or typed into the screen.
    var onUse: () -> Void = {}

    private var model: DevicePaneModel { state.devicePane }

    var body: some View {
        if let waiting = Self.waitingState(for: screen) {
            waiting
        } else {
            live
        }
    }

    /// What a device coming up or going away shows instead of its screen.
    static func waitingState(for screen: DevicesTabState.Screen) -> DevicesEmptyState? {
        switch screen {
        case .simulator(let device, .booting):
            DevicesEmptyState(title: "Booting \(device.name)…", detail: "The first boot can take a minute.")
        case .android(let target, .booting):
            DevicesEmptyState(title: "Booting \(target.title)…", detail: "A cold boot takes about 20 seconds.")
        case .vm(let guest, .starting):
            DevicesEmptyState(title: "Starting the \(guest == .macOS ? "macOS" : "Linux") VM…")
        case .vm(let guest, .pausing):
            DevicesEmptyState(title: "Saving the \(guest == .macOS ? "macOS" : "Linux") VM's state…")
        default:
            nil
        }
    }

    @ViewBuilder
    private var live: some View {
        switch screen {
        case .simulator(let device, _):
            DeviceStage(
                device: device, shape: model.shape(for: device), client: state.simulatorStreams,
                control: state.deviceControl, agentName: { state.computerUseAgentName($0) }, now: now,
                appInstall: model.appInstalls[device.udid],
                onDropApp: { url in Task { await state.installAppForUser(url, on: device) } },
                onDismissAppInstall: { model.dismissAppInstall(udid: device.udid) },
                notice: model.notices[device.udid],
                onPaste: {
                    let text = NSPasteboard.general.string(forType: .string)
                    Task {
                        if await model.paste(text, udid: device.udid, pasteboard: state.devicePasteboard), let text {
                            state.deviceFlowRecorder.pasted(device.udid, text)
                        }
                    }
                },
                onCopy: { Task { await model.copy(udid: device.udid, pasteboard: state.devicePasteboard) } },
                accessibilityOverlay: model.accessibilityOverlays.contains(device.udid),
                flowRecorder: state.deviceFlowRecorder,
                onUse: onUse
            )
            .id(device.udid)
        case .android(let target, .unauthorized):
            DevicesEmptyState(
                symbol: "lock", title: "Allow USB debugging on the phone",
                detail: "Unlock \(target.title) and allow this Mac when it asks.",
                action: .init(title: "Retry", icon: "arrow.clockwise") { Task { await state.androidPane.refresh() } }
            )
        case .android(let target, .offline):
            DevicesEmptyState(
                symbol: "candybarphone", title: "\(target.title) is offline",
                detail: "Reconnect it, or restart adb with `adb kill-server`.",
                action: .init(title: "Retry", icon: "arrow.clockwise") { Task { await state.androidPane.refresh() } }
            )
        case .android(let target, _):
            if let device = target.device {
                AndroidDeviceStage(
                    device: device, client: state.androidStreams, pane: state.androidPane, control: state.deviceControl,
                    agentName: { state.computerUseAgentName($0) }, now: now, flowRecorder: state.deviceFlowRecorder,
                    onUse: onUse
                )
                .id(device.serial)
            }
        case .vm(let guest, _):
            VMEntryScreen(state: state, worktreeID: worktree.id, guest: guest, onUse: onUse)
        }
    }
}
```

- [ ] **Step 9: Regenerate the project and build.**

  Run: `xcodegen`. Keep only the hunks for the five new files in
  `Alas.xcodeproj/project.pbxproj`.

  Run:

  ```bash
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -skipPackagePluginValidation -skipMacroValidation -quiet build
  ```

  Expected: the build succeeds.

- [ ] **Step 10: Lint and commit.**

  Run `swiftformat --lint` on the changed Swift files.

  Commit: `feat(devices): add shared device entry header, actions and screen`

---

### Task 4: The center device tab and rail helpers (app)

**Files:**
- Modify:
  - `Alas/Sources/Center/Tab.swift`: the `.device` case and `DeviceTabState`.
  - `Alas/Sources/Center/TabsManager.swift`: `openOrFocusDeviceTab`.
  - `Alas/Sources/Center/CenterPaneView.swift:739` (area): render `.device`.
  - `Alas/Sources/Right/RightPaneState.swift:252`: rename `devicesSelection`
    and add `devicesCollapsed` and `devicesScrollRequest`.
  - The `devicesSelection` users: `Alas/Sources/Devices/DevicesTabView.swift`,
    `Alas/Sources/Right/RightPaneView.swift`,
    `Alas/Sources/Devices/AppState+Devices.swift`,
    `Alas/Sources/Devices/AppState+RunScriptApp.swift` and
    `Alas/Sources/Devices/DevicePaneModel.swift:8` (a comment).
  - `Alas/Sources/VM/VirtualMachineTabView.swift:382`: the ⤡ button.
- Create:
  - `Alas/Sources/Devices/AppState+DevicesRail.swift`
  - `Alas/Sources/Devices/DeviceTabView.swift`

**Interfaces:**
- Consumes:
  - `DevicesRail.device(forTab:avdName:in:)` (Task 2)
  - `DeviceEntryHeader`, `DeviceEntryLiveActions` and `DeviceEntryStage`
    (Task 3)
- Produces:
  - `Tab.device(DeviceTabState)`.
  - `DeviceTabState(worktreeId:deviceID:platform:deviceName:avdName:)`, with
    `.target`.
  - `RightPaneState.devicesLastUsed: DevicesTarget?`,
    `.devicesCollapsed: Set<DevicesTarget>` and
    `.devicesScrollRequest: DevicesTarget?`.
  - New `AppState` methods:
    - `centerDeviceTabs(worktreeID:running:) -> [DevicesTarget: TabID]`
    - `openDeviceInTab(_:worktree:)`
    - `bringDeviceToRail(_:tabID:worktreeID:)`
    - `revealDevice(_:worktreeID:)`
    - `useDevice(_:worktreeID:)`
    - `bootDevice(_:worktreeID:)`
    - `bootError(_:) -> String?`
    - `devicesRailAspect(_:) -> Double?`
  - `View.devicesPolling(_:)`.

- [ ] **Step 1: Rename the selection to "last used".**
  - In `RightPaneState.swift`, replace:

```swift
    /// The device this worktree's Devices tab shows; nil picks a default.
    var devicesSelection: DevicesTarget?
```

    with:

```swift
    /// The device last used in this worktree: where run-script apps go and what the empty rail offers.
    var devicesLastUsed: DevicesTarget?
    /// Devices collapsed to their header in this worktree's Devices rail.
    var devicesCollapsed: Set<DevicesTarget> = []
    /// A device the rail scrolls to once, then clears.
    var devicesScrollRequest: DevicesTarget?
```

  - Replace `devicesSelection` with `devicesLastUsed` in `DevicesTabView.swift`,
    `RightPaneView.swift`, `AppState+Devices.swift`,
    `AppState+RunScriptApp.swift` and the `DevicePaneModel.swift:8` comment.
  - In `SimulatorTarget.swift`, rename the parameter `selection:` to
    `lastUsed:` and the doc's "The selected simulator" to "The last-used
    simulator". Update the caller in `AppState+RunScriptApp.swift` and the two
    tests in `DevicesTabStateTests.swift`
    (`aRunScriptsAppGoesToTheSelectedSimulatorElseABootedOne` becomes
    `aRunScriptsAppGoesToTheLastUsedSimulatorElseABootedOne`, with the
    `selection` argument renamed `lastUsed`).

- [ ] **Step 2: The tab state.**
  - In `Tab.swift`, add `case device(DeviceTabState)` after
    `case simulatorLogs(SimulatorLogsTabState)`.
  - Add `case .device(let s): return s.id` to `id`,
    `case .device(let s): return s.title` to `title`, and
    `case .device: return "iphone"` to `iconName`, each after its
    `.simulatorLogs` line.
  - After `struct SimulatorLogsTabState { ... }`, add:

```swift
/// A simulator's or Android device's screen in a center tab instead of the
/// Devices rail. One per device in each worktree; it restores, showing Boot
/// when its device isn't running.
struct DeviceTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    /// A simulator's UDID or an Android serial.
    let deviceID: String
    let platform: AgentDevice.Platform
    let deviceName: String
    /// An emulator's AVD, to find it again after it boots under another serial.
    let avdName: String?

    var title: String { deviceName }
    var target: DevicesTarget { platform == .ios ? .simulator(deviceID) : .android(deviceID) }

    init(worktreeId: String, deviceID: String, platform: AgentDevice.Platform, deviceName: String, avdName: String? = nil) {
        self.worktreeId = worktreeId
        self.deviceID = deviceID
        self.platform = platform
        self.deviceName = deviceName
        self.avdName = avdName
        id = "device:\(deviceID)"
    }
}
```

  - In `TabsManager.swift`, after `openOrFocusDeviceLogs`, add:

```swift
    @discardableResult
    func openOrFocusDeviceTab(worktreeId: String, state: DeviceTabState) -> Tab {
        if let existing = tabs(forWorktree: worktreeId).first(where: { $0.id == state.id }) {
            activate(worktreeId: worktreeId, tabId: state.id)
            return existing
        }
        let tab = Tab.device(state)
        append(tab, to: worktreeId)
        return tab
    }
```

- [ ] **Step 3: The app helpers.** Create `AppState+DevicesRail.swift`:

```swift
import AlasCore
import Foundation
import SwiftUI

extension AppState {
    /// This worktree's center tabs that show a running device, by device. A
    /// device tab follows its emulator to a new serial.
    func centerDeviceTabs(worktreeID: String, running: [DevicesTabState.Running]) -> [DevicesTarget: TabID] {
        var tabsByDevice: [DevicesTarget: TabID] = [:]
        for tab in tabs.tabs(forWorktree: worktreeID) {
            switch tab {
            case .device(let state):
                if let device = DevicesRail.device(forTab: state.deviceID, avdName: state.avdName, in: running) {
                    tabsByDevice[device.id] = state.id
                }
            case .virtualMachine(let state):
                tabsByDevice[.vm(state.guest)] = state.id
            default:
                continue
            }
        }
        return tabsByDevice
    }

    /// Moves a running device from the rail to a center tab, or focuses its tab.
    func openDeviceInTab(_ device: DevicesTabState.Running, worktree: Worktree) {
        useDevice(device.id, worktreeID: worktree.id)
        let state: DeviceTabState
        switch device.screen {
        case .vm(let guest, _):
            openVirtualMachine(in: worktree, guest: guest)
            return
        case .simulator(let simulator, _):
            state = DeviceTabState(worktreeId: worktree.id, deviceID: simulator.udid, platform: .ios, deviceName: simulator.name)
        case .android(let target, _):
            state = DeviceTabState(
                worktreeId: worktree.id, deviceID: target.id, platform: .android, deviceName: target.title,
                avdName: target.avdName
            )
        }
        let tab = tabs.openOrFocusDeviceTab(worktreeId: worktree.id, state: state)
        activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
    }

    /// Closes a device's center tab and shows the device, expanded, in the rail.
    func bringDeviceToRail(_ target: DevicesTarget, tabID: TabID, worktreeID: String) {
        closeTab(worktreeId: worktreeID, tabId: tabID)
        revealDevice(target, worktreeID: worktreeID)
    }

    /// Shows `target` and makes it last used: its center tab when it has one,
    /// else the worktree's Devices rail, expanded and scrolled to.
    func revealDevice(_ target: DevicesTarget, worktreeID: String) {
        useDevice(target, worktreeID: worktreeID)
        if let tab = tabs.tabs(forWorktree: worktreeID).first(where: { Self.tab($0, shows: target) }) {
            activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
            return
        }
        guard let pane = rightPaneStore.activeState(worktreeId: worktreeID) else { return }
        pane.devicesCollapsed.remove(target)
        pane.devicesScrollRequest = target
        pane.activeTab = .device
        if !config.rightPaneVisible {
            config.rightPaneVisible = true
            saveConfig()
        }
    }

    /// Marks a device as the worktree's last used, and its owner for the sidebar.
    func useDevice(_ target: DevicesTarget, worktreeID: String) {
        rightPaneStore.activeState(worktreeId: worktreeID)?.devicesLastUsed = target
        switch target {
        case .simulator(let id), .android(let id): noteDeviceUse(id, worktreeID: worktreeID)
        case .vm: break
        }
    }

    /// Boots a shut-down simulator or AVD.
    func bootDevice(_ target: DevicesTarget, worktreeID: String) {
        useDevice(target, worktreeID: worktreeID)
        switch target {
        case .simulator(let udid):
            guard let device = devicePane.devices?.first(where: { $0.udid == udid }) else { return }
            Task { await devicePane.boot(device) }
        case .android(let id) where id.hasPrefix("avd:"):
            Task { await androidPane.boot(avd: String(id.dropFirst(4))) }
        default:
            break
        }
    }

    /// Why the last boot of `target` failed.
    func bootError(_ target: DevicesTarget?) -> String? {
        switch target {
        case .simulator(let udid)?: devicePane.errors[udid]
        case .android(let id)?: androidPane.errors[id]
        default: nil
        }
    }

    /// A running device's screen height over width as the rail shows it; nil
    /// before an Android device's first frame.
    func devicesRailAspect(_ device: DevicesTabState.Running) -> Double? {
        switch device.screen {
        case .simulator(let simulator, _):
            guard let shape = devicePane.shape(for: simulator), shape.widthPoints > 0, shape.heightPoints > 0 else { return nil }
            let landscape = simulatorStreams.lastFrame(udid: simulator.udid)?.orientation.isLandscape ?? false
            return Double(landscape ? shape.widthPoints / shape.heightPoints : shape.heightPoints / shape.widthPoints)
        case .android(let target, _):
            guard let serial = target.device?.serial, let size = androidStreams.videoSizes[serial], size.width > 0 else {
                return nil
            }
            return Double(size.height / size.width)
        case .vm:
            return 10.0 / 16.0
        }
    }

    private static func tab(_ tab: Tab, shows target: DevicesTarget) -> Bool {
        switch tab {
        case .device(let state): state.target == target
        case .virtualMachine(let state): target == .vm(state.guest)
        default: false
        }
    }
}

extension View {
    /// Keeps the simulator and Android lists current while this view is on screen.
    func devicesPolling(_ state: AppState) -> some View {
        task {
            await state.devicePane.checkTools()
            guard state.devicePane.simulatorToolsFound == true else { return }
            await state.devicePane.pollWhileVisible()
        }
        .task {
            guard state.androidPane.control != nil else { return }
            await state.androidPane.pollWhileVisible()
        }
    }
}
```

  `devicePane.errors` and `androidPane.errors` are `private(set)`, so this can
  read them.

- [ ] **Step 4: The center tab view.** Create `DeviceTabView.swift`:

```swift
import AlasCore
import SwiftUI

/// A simulator's or Android device's screen in a center tab: the same header,
/// screen and driver pill as its entry in the Devices rail, at full size.
struct DeviceTabView: View {
    let state: AppState
    let worktree: Worktree
    let tab: DeviceTabState

    var body: some View {
        // Each second, for the agent's driving window.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(state.devicesTabState(worktree: worktree, selection: nil), now: context.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .devicesPolling(state)
    }

    @ViewBuilder
    private func content(_ devices: DevicesTabState, now: Date) -> some View {
        if let device = DevicesRail.device(forTab: tab.deviceID, avdName: tab.avdName, in: devices.running) {
            VStack(spacing: 0) {
                DeviceEntryHeader(
                    row: device.row, move: .toRail,
                    onMove: { state.bringDeviceToRail(device.id, tabID: tab.id, worktreeID: worktree.id) }
                ) {
                    DeviceEntryLiveActions(state: state, worktree: worktree, device: device)
                }
                .padding(.horizontal, 8) // design-literal: matches the rail's padding
                Divider()
                DeviceEntryStage(
                    state: state, worktree: worktree, screen: device.screen, now: now,
                    onUse: { state.useDevice(device.id, worktreeID: worktree.id) }
                )
            }
        } else {
            notRunning(devices)
        }
    }

    /// Its device shut down or went away: Boot it, or say it's gone.
    @ViewBuilder
    private func notRunning(_ devices: DevicesTabState) -> some View {
        let rows = devices.simulatorRows + devices.androidRows
        let row = rows.first { $0.target == tab.target }
            ?? tab.avdName.flatMap { avd in rows.first { $0.target == .android(AndroidListing.avdID(avd)) } }
        let symbol = tab.platform == .ios ? "iphone" : "candybarphone"
        if let row, row.canBoot {
            let error = state.bootError(row.target)
            DevicesEmptyState(
                symbol: symbol, title: "\(tab.deviceName) is shut down",
                detail: error ?? row.detail, detailTone: error == nil ? "fg-dim" : "warn",
                action: .init(title: "Boot", icon: "power") { state.bootDevice(row.target, worktreeID: worktree.id) }
            )
        } else {
            DevicesEmptyState(
                symbol: symbol, title: "\(tab.deviceName) isn't available",
                detail: "Connect it again, or close this tab."
            )
        }
    }
}
```

  In `CenterPaneView.swift`, after the `case .simulatorLogs(let s):` block,
  add:

```swift
                    case .device(let s):
                        DeviceTabView(state: state, worktree: worktree, tab: s)
                            .id(s.id)
                            .onAppear { completeStartupRecoveryIfActive(s.id) }
```

- [ ] **Step 5: The VM tab's way back.** In `VirtualMachineTabView.swift`'s
  `runningStatusBar(at:canUpdateHelper:)`, insert before
  `ToolbarBtn(icon: "stop.fill", ...)`:

```swift
            ToolbarBtn(icon: "sidebar.right", tooltip: "Back to the Devices rail", metrics: .vmStatusBar) {
                state.bringDeviceToRail(.vm(guest), tabID: tab.id, worktreeID: worktreeID)
            }
            .vmDisabled(busy)
```

- [ ] **Step 6: Regenerate, build and test.**

  Run `xcodegen`, keeping only the new-file hunks. Then run:

  ```bash
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -skipPackagePluginValidation -skipMacroValidation -quiet build
  swift test --package-path Packages/AlasCore --filter DevicesTabStateTests
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -skipPackagePluginValidation -skipMacroValidation \
    -only-testing AlasTests/DeviceLogsTabStateTests -only-testing AlasTests/RightPaneTabTests test
  ```

  Expected: the build succeeds and every suite passes. Check the
  `Test run with N tests` lines. If the build reports another exhaustive
  `switch` over `Tab`, add `.device` there, next to `.simulatorLogs`, with the
  same behavior.

- [ ] **Step 7: Lint and commit.**
  `feat(devices): show a simulator or Android device in a center tab`

---

### Task 5: The rail replaces the single-device tab (app + AlasCore)

**Files:**
- Create:
  - `Alas/Sources/Devices/DevicesRailList.swift`
  - `Alas/Sources/Devices/DevicesRailView.swift`
  - `Alas/Sources/Devices/AddDeviceButton.swift`
- Rename: `Alas/Sources/Devices/DevicesSwitcher.swift` becomes
  `Alas/Sources/Devices/DevicesAddPanel.swift` (`git mv`).
- Delete:
  - `Alas/Sources/Devices/DevicesTabView.swift`
  - `Alas/Sources/Devices/VMDeviceCard.swift`
  - `Alas/Sources/Devices/Android/AndroidActions.swift`
  - `Alas/Sources/Devices/DeviceFlowButtons.swift`
- Modify:
  - `Alas/Sources/Devices/DeviceStageFrame.swift`: add `DeviceStageMetrics`.
  - `Alas/Sources/Right/RightPaneView.swift:222,305-368` and
    `Alas/Sources/Right/RightPaneToolbar.swift:24-49`.
  - `Alas/Sources/Devices/AppState+Devices.swift` (`showDevice`),
    `Alas/Sources/Devices/AppState+RunScriptApp.swift` and
    `Alas/Sources/Devices/AppState+DevicesTab.swift`.
  - `Alas/Sources/Devices/DeviceTabView.swift` (the `lastUsed:` label).
  - `Packages/AlasCore/Sources/AlasFeatures/Devices/DevicesTabState.swift` and
    `DevicesSwitcherListing.swift`.
  - `Packages/AlasCore/Tests/AlasCoreTests/DevicesTabStateTests.swift`.
  - `Alas/Sources/App/DesignCaptureDevices.swift` and `scripts/design/README.md`.

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces:
  - `DevicesRailList(entries:scrollRequest:onToggleCollapsed:onOpenInTab:onBringBack:onUse:aspect:stage:actions:)`
  - `DevicesRailView(state:worktree:rps:)` and
    `AddDeviceButton(state:worktree:rps:)`
  - `DevicesAddPanel` (the renamed `DevicesSwitcherPanel`), with the same
    initializer.
  - `DevicesTabState.resolve(..., lastUsed:, ...)` and
    `DevicesTabState.lastUsed`. `Stage`, `stage`, `selected` and
    `selectedRow` are gone.

- [ ] **Step 1: Stage metrics.** In `DeviceStageFrame.swift`, add before
  `struct DeviceStageFrame`:

```swift
/// The space a device's stage puts around its screen; `DevicesRailList`
/// sizes stages with it.
enum DeviceStageMetrics {
    static let margin: CGFloat = 12
    static let gutterWidth: CGFloat = 44
    static let bezel: CGFloat = 4
}
```

  Then replace `DeviceStageFrame`'s three `private static var` lines with:

```swift
    private static var margin: CGFloat { DeviceStageMetrics.margin }
    private static var gutterWidth: CGFloat { DeviceStageMetrics.gutterWidth }
    private static var bezel: CGFloat { DeviceStageMetrics.bezel }
```

- [ ] **Step 2: The stack.** Create `DevicesRailList.swift`:

```swift
import AlasCore
import SwiftUI

/// The Devices rail's stack: every running device one under the other, each
/// expanded to its screen, collapsed to its header, or a one-line placeholder
/// while a center tab shows it. One expanded device fills the rail; two or more
/// split it in two, and the rest scroll. A screen scrolled out of view isn't
/// drawn, so its stream stops.
struct DevicesRailList<Stage: View, Actions: View>: View {
    let entries: [DevicesRail.Entry]
    /// Scrolled to once, then cleared.
    @Binding var scrollRequest: DevicesTarget?
    let onToggleCollapsed: (DevicesTarget) -> Void
    let onOpenInTab: (DevicesTabState.Running) -> Void
    let onBringBack: (DevicesTarget) -> Void
    /// A click on a device's header.
    let onUse: (DevicesTarget) -> Void
    /// The screen's height over its width as shown; nil fills the stage.
    let aspect: (DevicesTabState.Running) -> Double?
    @ViewBuilder let stage: (DevicesTabState.Running) -> Stage
    @ViewBuilder let actions: (DevicesTabState.Running) -> Actions
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    /// Expanded devices scrolled out of view.
    @State private var offscreen: Set<DevicesTarget> = []

    private static var padding: CGFloat { 8 }

    var body: some View {
        GeometryReader { geometry in
            let layout = DevicesRailLayout(visibleHeight: geometry.size.height - Self.padding * 2, entries: entries)
            let width = geometry.size.width - Self.padding * 2
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) { // design-literal: DevicesRailLayout's row gap
                        ForEach(entries) { entry in
                            row(entry, layout: layout, width: width)
                                .id(entry.id)
                        }
                    }
                    .padding(Self.padding)
                }
                .onChange(of: scrollRequest, initial: true) { _, target in
                    guard let target else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    scrollRequest = nil
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: DevicesRail.Entry, layout: DevicesRailLayout, width: CGFloat) -> some View {
        let device = entry.device
        switch entry.placement {
        case .inCenter:
            placeholder(device)
        case .expanded, .collapsed:
            VStack(spacing: 8) { // design-literal: DevicesRailLayout's row gap
                DeviceEntryHeader(
                    row: device.row, collapsed: entry.placement == .collapsed,
                    onToggleCollapsed: { onToggleCollapsed(device.id) },
                    move: .toTab, onMove: { onOpenInTab(device) }
                ) {
                    actions(device)
                }
                .simultaneousGesture(TapGesture().onEnded { onUse(device.id) })
                if entry.placement == .expanded {
                    Group {
                        if offscreen.contains(device.id) {
                            Color.clear
                        } else {
                            stage(device)
                        }
                    }
                    .frame(height: layout.height(width: width, aspect: aspect(device), chrome: Self.chrome(device)))
                    .onScrollVisibilityChange(threshold: 0.01) { shown in
                        if shown { offscreen.remove(device.id) } else { offscreen.insert(device.id) }
                    }
                }
            }
        }
    }

    private func placeholder(_ device: DevicesTabState.Running) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(theme.color(DeviceStyle.colorToken(device.row.tone)))
                .frame(width: 7, height: 7) // design-literal: status dot size
            Text(device.row.title)
                .font(scale.meta.font(weight: .medium))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(1)
            Text("in a tab")
                .font(scale.caption.font(weight: .regular))
                .foregroundStyle(theme.color("fg-dim"))
            Spacer(minLength: 4)
            AlasButton(title: "Bring back", compact: true) { onBringBack(device.id) }
        }
        .padding(.horizontal, scale.space[2])
        .frame(height: 28) // design-literal: DevicesRailLayout's header row
        .background(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line"), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        )
    }

    /// Around a phone screen: the stage's margins, bezel and button gutter. Around a VM: its padding.
    static func chrome(_ device: DevicesTabState.Running) -> DevicesRailLayout.Chrome {
        if case .vm = device.screen { return .init(horizontal: 24, vertical: 24) }
        let margin = Double(DeviceStageMetrics.margin), bezel = Double(DeviceStageMetrics.bezel)
        return .init(
            horizontal: margin * 2 + Double(DeviceStageMetrics.gutterWidth) + bezel * 2,
            vertical: margin * 2 + bezel * 2
        )
    }
}
```

- [ ] **Step 3: The live rail.** Create `DevicesRailView.swift`:

```swift
import AlasCore
import SwiftUI

/// The right pane's Devices tab: every running simulator, Android device and
/// VM of this worktree in a stack, each movable to a center tab and back.
struct DevicesRailView: View {
    let state: AppState
    let worktree: Worktree
    @Bindable var rps: RightPaneState

    var body: some View {
        // Each second, for the agent's driving window.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let devices = state.devicesTabState(worktree: worktree, lastUsed: rps.devicesLastUsed)
            if let empty = devices.empty {
                emptyState(empty)
            } else {
                rail(devices, now: context.date)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .devicesPolling(state)
    }

    private func rail(_ devices: DevicesTabState, now: Date) -> some View {
        let centered = state.centerDeviceTabs(worktreeID: worktree.id, running: devices.running)
        return DevicesRailList(
            entries: DevicesRail.entries(devices.running, collapsed: rps.devicesCollapsed, inCenter: Set(centered.keys)),
            scrollRequest: $rps.devicesScrollRequest,
            onToggleCollapsed: { target in
                if rps.devicesCollapsed.remove(target) == nil { rps.devicesCollapsed.insert(target) }
            },
            onOpenInTab: { state.openDeviceInTab($0, worktree: worktree) },
            onBringBack: { target in
                guard let tabID = centered[target] else { return }
                state.bringDeviceToRail(target, tabID: tabID, worktreeID: worktree.id)
            },
            onUse: { state.useDevice($0, worktreeID: worktree.id) },
            aspect: { state.devicesRailAspect($0) },
            stage: { device in
                DeviceEntryStage(
                    state: state, worktree: worktree, screen: device.screen, now: now,
                    onUse: { state.useDevice(device.id, worktreeID: worktree.id) }
                )
            },
            actions: { DeviceEntryLiveActions(state: state, worktree: worktree, device: $0) }
        )
    }

    @ViewBuilder
    private func emptyState(_ empty: DevicesTabState.Empty) -> some View {
        switch empty {
        case .loading:
            DevicesEmptyState(title: "Looking for devices…")
        case .unavailable:
            DevicesEmptyState(
                symbol: "iphone.slash", title: "iOS simulators need Xcode",
                detail: "Install it, or select it with `sudo xcode-select -s /Applications/Xcode.app`."
            )
        case .noSimulators:
            DevicesEmptyState(
                symbol: "iphone", title: "No iOS simulators",
                detail: "Create one in Xcode under Window › Devices and Simulators."
            )
        case .nothingRunning(let suggested):
            let error = state.bootError(suggested?.target)
            DevicesEmptyState(
                symbol: "iphone", title: "No devices running",
                detail: error ?? "Boot one here, or from + Add in the toolbar.",
                detailTone: error == nil ? "fg-dim" : "warn",
                action: suggested.map(offer)
            )
        }
    }

    /// Boots a simulator or AVD, or opens a VM's tab.
    private func offer(_ row: DevicesTabState.Row) -> DevicesEmptyState.Action {
        if case .vm(let guest) = row.platform {
            return .init(title: "Open \(row.title)", icon: DeviceStyle.glyph(row.platform)) {
                state.useDevice(row.target, worktreeID: worktree.id)
                state.openVirtualMachine(in: worktree, guest: guest)
            }
        }
        return .init(title: "Boot \(row.title)", icon: "power") {
            state.bootDevice(row.target, worktreeID: worktree.id)
        }
    }
}
```

- [ ] **Step 4: + Add.** `git mv Alas/Sources/Devices/DevicesSwitcher.swift
  Alas/Sources/Devices/DevicesAddPanel.swift`. In the moved file:
  - Delete `struct DevicesSwitcher` (its doc comment through its closing brace)
    and `struct DevicesActions` (its doc comment through the end of the file).
  - Rename `struct DevicesSwitcherPanel` to `struct DevicesAddPanel`, and change
    its doc comment to
    `/// The Devices rail's + Add popover: a filter field over the sectioned device list, with arrow-key navigation and an inline Boot on shut-down rows. Modeled on ACPSelectChip's dropdown.`
  - Replace `state.selected` with `state.lastUsed` (its two uses).

  Then create `AddDeviceButton.swift`:

```swift
import AlasCore
import SwiftUI

/// The Devices rail's toolbar + Add. A running device scrolls into view; a
/// shut-down simulator or AVD boots and joins the stack; a VM opens its tab,
/// where it starts or is set up.
struct AddDeviceButton: View {
    let state: AppState
    let worktree: Worktree
    @Bindable var rps: RightPaneState
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var showsPanel = false

    var body: some View {
        ToolbarBtn(icon: "plus", tooltip: "Add a device") { showsPanel = true }
            .accessibilityIdentifier("devices-add")
            .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
                DevicesAddPanel(
                    state: state.devicesTabState(worktree: worktree, lastUsed: rps.devicesLastUsed),
                    onSelect: { target in
                        pick(target)
                        showsPanel = false
                    },
                    onBoot: { target in
                        boot(target)
                        showsPanel = false
                    },
                    onClose: { showsPanel = false }
                )
                .environment(\.theme, theme)
                .environment(\.designScale, scale)
            }
    }

    private func pick(_ target: DevicesTarget) {
        let devices = state.devicesTabState(worktree: worktree, lastUsed: rps.devicesLastUsed)
        if devices.running.contains(where: { $0.id == target }) {
            state.revealDevice(target, worktreeID: worktree.id)
        } else if case .vm(let guest) = target {
            state.useDevice(target, worktreeID: worktree.id)
            state.openVirtualMachine(in: worktree, guest: guest)
        } else {
            boot(target)
        }
    }

    private func boot(_ target: DevicesTarget) {
        state.bootDevice(target, worktreeID: worktree.id)
        state.revealDevice(target, worktreeID: worktree.id)
    }
}
```

- [ ] **Step 5: Wire the pane.**
  - In `RightPaneView.swift:222`, replace
    `DevicesTabView(state: state, worktree: worktree, rps: rps)` with
    `DevicesRailView(state: state, worktree: worktree, rps: rps)`.
  - In `paneToolbar`, delete the `deviceSwitcher:` argument, and replace the
    `deviceActions:` argument with:

```swift
            deviceActions: rps.activeTab == .device
                ? AnyView(AddDeviceButton(state: state, worktree: worktree, rps: rps)) : nil
```

  - Delete `private func devicesSwitcher(rps:)` and
    `private func devicesActions(rps:)`.
  - In `RightPaneToolbar.swift`, delete `var deviceSwitcher: AnyView?` and its
    doc comment. Change the doc on `deviceActions` to
    `/// The Devices tab's + Add.` Replace the opening
    `if tab == .device, panelTitle == nil, let deviceSwitcher { ... } else { ... }`
    (lines 41-49) with its else branch only:

```swift
            leading
                .overlay { WindowDragHandle() }
                .layoutPriority(1)
```

- [ ] **Step 6: Agents and run scripts reveal their device.**
  - In `AppState+Devices.swift`, replace the body of
    `func showDevice(_ udid: String, in worktreeID: String?)` and its doc
    comment with:

```swift
    /// Shows the device an agent opened in its worktree: expanded in the rail, or its center tab.
    func showDevice(_ udid: String, in worktreeID: String?) {
        Task { await devicePane.refresh() }
        guard let worktreeID else { return }
        revealDevice(AgentDevice.isSimulatorID(udid) ? .simulator(udid) : .android(udid), worktreeID: worktreeID)
    }
```

  - In `AppState+RunScriptApp.swift`, replace the lines from
    `noteDeviceUse(device.udid, worktreeID: worktree.id)` through the closing
    brace of the `if !config.rightPaneVisible { ... }` block with:

```swift
        revealDevice(.simulator(device.udid), worktreeID: worktree.id)
```

    In that file's doc comment, change "which its Devices tab then shows" to
    "which the Devices rail or its tab then shows".

- [ ] **Step 7: Drop the selection from AlasCore.** In `DevicesTabState.swift`:
  - Delete `public enum Stage { ... }`, `public let stage: Stage`,
    `public var selectedRow: Row? { ... }` and `private static func choose(...)`.
  - Rename `public let selected: DevicesTarget?` to:

```swift
    /// The worktree's last-used device: + Add starts there and keeps its runtime unfolded.
    public let lastUsed: DevicesTarget?
```

  - Rename the `resolve` parameter `selection: DevicesTarget?` to
    `lastUsed: DevicesTarget?`, and change its doc comment to:
    `/// `vms` holds this worktree's VMs, empty where worktree VMs aren't supported.`
  - Delete the `let chosen = ...` and `let stage: Stage = switch chosen { ... }`
    statements.
  - Change `offerable.first { $0.target == selection }` to
    `offerable.first { $0.target == lastUsed }`.
  - Change the return to:

```swift
        return DevicesTabState(
            lastUsed: lastUsed, simulatorRows: simulatorRows, simulatorsNote: note,
            androidRows: androidRows, androidNote: android?.note, vmRows: vmRows,
            running: running, empty: empty
        )
```

  - Change the doc on `DevicesTabState` to
    `/// What the Devices rail lists: the running devices, the rows + Add offers, and why nothing runs.`
  - In `DevicesSwitcherListing.swift:62`, change
    `group.rows.contains { $0.target == selected }` to
    `group.rows.contains { $0.target == lastUsed }`.
  - In `AppState+DevicesTab.swift`, rename
    `devicesTabState(worktree:selection:)`'s parameter to `lastUsed`, and pass
    `lastUsed: lastUsed`.
  - In `DeviceTabView.swift`, change `selection: nil` to `lastUsed: nil`.

- [ ] **Step 8: Update the AlasCore tests.** In `DevicesTabStateTests.swift`:
  - Delete:
    - the `Case` struct and `private func resolve(_ c: Case)`
    - `theChipFindsAnAndroidSelection`
    - `aSelectedAVDFollowsItsEmulatorOnceItRuns`
    - `aReadyAndroidDeviceIsTheDefaultWhenNoSimulatorIsBooted`
    - `selectionFallsBackOnlyWhenItsDeviceIsGone`
    - `defaultPrefersABootedSimulatorThenARunningVM`
    - `loadingDoesNotJumpToAStoppedVM`
    - `bootingCountsBeforeSimctlSaysSo`

    Tasks 1 and 2 cover booting, loading and AVD-following in their new form.
  - Rename every remaining `selection:` argument to `lastUsed:`, including in
    the private `resolve(simulators:vms:selection:android:)` helper, which
    becomes `resolve(simulators:vms:lastUsed:android:)`.
  - In `olderRuntimesFoldUnlessSelectedOrShown`, rename the test to
    `olderRuntimesFoldUnlessLastUsedOrShown` and the local `selectedOld` to
    `lastUsedOld`.
  - In `vmRowsCarryToneAndDetail`, replace
    `resolve(Case(name: "", vms: [.macOS: status], stage: .loading)).vmRows.first`
    with `resolve(vms: [.macOS: status], android: nil).vmRows.first`.
  - Replace `noSimulatorsFallsBackToTheMacOSVM` with:

```swift
    @Test func theSimulatorsNoteSaysWhyThereAreNone() {
        let noXcode = DevicesTabState.resolve(
            simulators: nil, listError: "no simctl", vms: Self.stoppedVMs, lastUsed: nil, bootingUDIDs: [], agentDriving: []
        )
        #expect(noXcode.simulatorsNote == "Install Xcode to use iOS simulators")
        #expect(resolve(simulators: [], vms: Self.stoppedVMs, android: nil).simulatorsNote == "No iOS simulators")
    }
```

  - In `DevicesRailTests.swift`, rename `selection: nil` to `lastUsed: nil`.

  Run: `swift test --package-path Packages/AlasCore --filter "DevicesTabStateTests|DevicesRailTests"`

  Expected: PASS.

- [ ] **Step 9: Delete the replaced views.**

  ```bash
  git rm Alas/Sources/Devices/DevicesTabView.swift Alas/Sources/Devices/VMDeviceCard.swift \
    Alas/Sources/Devices/Android/AndroidActions.swift Alas/Sources/Devices/DeviceFlowButtons.swift
  ```

- [ ] **Step 10: Design captures.** In `DesignCaptureDevices.swift`:
  - In the file's doc comment, replace the list of views with:
    ``(`DevicesRailList`, `DeviceEntryHeader`, `DeviceEntryActions`, `DeviceStage`, `DevicesEmptyState`, `DevicesAddPanel`, `DeviceSettingsPopover`)``.
  - Change the `devices` and `devices-switcher` lines of the target list to:
    `/// - devices: one simulator an agent drives while an app launches; one you drive while an agent waits and an install failed; a simulator and the macOS VM, at 300 and 420 pt; three devices with one collapsed and the VM in a tab.`
    and
    `/// - devices-switcher: + Add's popover: as it opens, filtered, and hovering a shut-down row.`
  - Add `var width: CGFloat?` to `Cell`, with an `init(_ label: String, _ content: some View, width: CGFloat? = nil)`
    that stores it, and in `Gallery.cell` use
    `.frame(width: cell.width ?? (columns == 4 ? 340 : 360), height: columns == 4 ? 560 : height)`.
  - Delete `private static func tab(...)`.
  - In `private static func resolve(...)`, rename `selection` to `lastUsed`.
  - Add these helpers in place of `tab`:

```swift
    /// The rail as the pane shows it: the toolbar's + Add over the stack.
    private static func railChrome(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Devices")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                Spacer(minLength: 0)
                ToolbarBtn(icon: "plus", tooltip: "Add a device") {}
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            Divider()
            content()
        }
    }

    /// What a scripted VM shows: no VM runs in a capture.
    private static var vmScreen: some View {
        LinearGradient(
            colors: [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.32, green: 0.42, blue: 0.56)],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(Text("macOS VM").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(12)
    }

    @ViewBuilder
    private static func actions(_ device: DevicesTabState.Running, control: DeviceAgentControl) -> some View {
        switch device.screen {
        case .simulator(let simulator, let stage):
            DeviceEntryActions(
                kind: .simulator(simulator), ready: stage == .booted, control: control, recorder: fakeRecorder(),
                flowRecorder: DeviceFlowRecorder(), worktree: FileManager.default.temporaryDirectory,
                accessibilityOverlay: false, onToggleAccessibilityOverlay: {}, onOpenLogs: {},
                onScreenshot: { "" }, onShutDown: {}, onNotice: { _ in }
            )
        case .vm(_, let status):
            VMEntryActions(running: status == .running) {}
        case .android:
            EmptyView()
        }
    }
```

  - Replace the body of `driverCells(control:)` after
    `try? await Task.sleep(for: .milliseconds(300))` with:

```swift
        let now = Date()
        let client = SimulatorStreamClient()
        let second = SimulatorDevice(
            udid: demoUDIDPrefix + "SECOND", name: "iPhone 17", runtimeName: "iOS 26.5", state: .booted,
            deviceTypeIdentifier: "demo.phone")
        func phoneStage(_ device: SimulatorDevice, control: DeviceAgentControl, install: DevicePaneModel.AppInstall?) -> some View {
            DeviceStage(
                device: device, shape: shape, client: client, control: control, agentName: { _ in "Claude" }, now: now,
                appInstall: install, onDropApp: { _ in }, onDismissAppInstall: {}, notice: nil, onPaste: {}, onCopy: {},
                accessibilityOverlay: false, flowRecorder: DeviceFlowRecorder())
        }
        func rail(
            _ devices: DevicesTabState, collapsed: Set<DevicesTarget> = [], inCenter: Set<DevicesTarget> = [],
            control: DeviceAgentControl, install: DevicePaneModel.AppInstall? = nil
        ) -> some View {
            railChrome {
                DevicesRailList(
                    entries: DevicesRail.entries(devices.running, collapsed: collapsed, inCenter: inCenter),
                    scrollRequest: .constant(nil), onToggleCollapsed: { _ in }, onOpenInTab: { _ in },
                    onBringBack: { _ in }, onUse: { _ in },
                    aspect: { device in
                        if case .vm = device.screen { return 10.0 / 16.0 }
                        return Double(shape.heightPoints / shape.widthPoints)
                    },
                    stage: { device in
                        switch device.screen {
                        case .simulator(let simulator, .booted): phoneStage(simulator, control: control, install: install)
                        case .vm(_, .running): vmScreen
                        default: DeviceEntryStage.waitingState(for: device.screen)
                        }
                    },
                    actions: { actions($0, control: control) }
                )
            }
        }
        let phoneTarget = DevicesTarget.simulator(phoneUDID)
        let withVM = resolve(
            simulators: [phone, air], vms: [.macOS: .running, .linux: .stopped], lastUsed: nil, driving: [phoneTarget])
        return [
            Cell("one simulator: agent driving, app launching", rail(
                resolve(simulators: [phone, air, pad], vms: [.macOS: .stopped], lastUsed: nil, driving: [phoneTarget]),
                control: control, install: .launching("Lantern")
            ), width: 300),
            Cell("you drive, agent waiting, install failed", rail(
                resolve(simulators: [userDevice, air], lastUsed: nil), control: userControl,
                install: .failed("Couldn't open Lantern: the app was built for a device.")
            ), width: 300),
            Cell("simulator and macOS VM", rail(withVM, control: control), width: 300),
            Cell("simulator and macOS VM, 420 pt", rail(withVM, control: control), width: 420),
            Cell("three: one collapsed, the VM in a tab", rail(
                resolve(simulators: [phone, second], vms: [.macOS: .running], lastUsed: nil, driving: [phoneTarget]),
                collapsed: [.simulator(second.udid)], inCenter: [.vm(.macOS)], control: control
            ), width: 300),
        ]
```

    This deletes its old `agentVMDriver` and `macOS` locals and the
    `VMDeviceCard` cells.
  - Replace the body of `emptyCells()` after the `shutDown` constant with:

```swift
        func rail(_ devices: DevicesTabState) -> some View {
            railChrome {
                DevicesRailList(
                    entries: DevicesRail.entries(devices.running, collapsed: [], inCenter: []),
                    scrollRequest: .constant(nil), onToggleCollapsed: { _ in }, onOpenInTab: { _ in },
                    onBringBack: { _ in }, onUse: { _ in }, aspect: { _ in nil },
                    stage: { DeviceEntryStage.waitingState(for: $0.screen) },
                    actions: { actions($0, control: control) }
                )
            }
        }
        return [
            Cell("loading", railChrome { DevicesEmptyState(title: "Looking for devices…") }),
            Cell("no Xcode", railChrome {
                DevicesEmptyState(
                    symbol: "iphone.slash", title: "iOS simulators need Xcode",
                    detail: "Install it, or select it with `sudo xcode-select -s /Applications/Xcode.app`.")
            }),
            Cell("no simulators", railChrome {
                DevicesEmptyState(
                    symbol: "iphone", title: "No iOS simulators",
                    detail: "Create one in Xcode under Window › Devices and Simulators.")
            }),
            Cell("nothing running, boot failed", railChrome {
                DevicesEmptyState(
                    symbol: "iphone", title: "No devices running",
                    detail: "Unable to boot device in current state: Booting", detailTone: "warn",
                    action: .init(title: "Boot \(shutDown.name)", icon: "power") {})
            }),
            Cell("simulator booting", rail(resolve(simulators: [shutDown, air], lastUsed: nil, booting: [shutDown.udid]))),
            Cell("VM starting", rail(resolve(simulators: [], vms: [.macOS: .starting], lastUsed: nil))),
        ]
```

    The `now` local in `emptyCells` becomes unused; delete it.
  - In `switcherCells()`, rename `selection:` to `lastUsed:`, delete the
    `DevicesSwitcher(state: state, ...)` line inside `open`, and rename
    `DevicesSwitcherPanel` to `DevicesAddPanel`.
  - In `scripts/design/README.md`, change the `devices-switcher` sentence to
    say it shows "+ Add's popover", and describe `devices` as "the Devices rail
    with one, two and three devices, a collapsed one and a VM in a tab".

- [ ] **Step 11: Regenerate, build, test and capture.**

  Run `xcodegen`, keeping only the file hunks. Then run:

  ```bash
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -skipPackagePluginValidation -skipMacroValidation -quiet build
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/RightPaneTabTests \
    -only-testing AlasTests/AppStateRightPaneRailAcceptanceTests -only-testing AlasTests/DeviceAgentControlTests test
  scripts/design/make-demo-profile.sh /tmp/alas-devices-rail-demo
  for target in devices devices-empty devices-switcher; do
    ALAS_CAPTURE_CENTER=$target scripts/design/capture.sh /tmp/alas-devices-rail-demo /tmp/alas-devices-rail-$target dark
  done
  ```

  Expected: the build succeeds, the suites pass, and each capture writes a
  `window.png`. Open each one and check:
  - one device fills its rail and sits centered;
  - two stacked screens both fit at 300 pt;
  - the collapsed row and the dashed "in a tab" placeholder each take one row;
  - the header's name truncates before its icons at 300 pt.

  If a capture can't run (no window server), say so and leave the visual check
  to Task 6's manual pass.

- [ ] **Step 12: Lint and commit.** Run `swiftformat --lint` on every changed
  Swift file.

  Commit: `feat(devices): stack running devices in the Devices rail`

---

### Task 6: Docs, CHANGELOG and the end-to-end check

**Files:**
- Modify: `docs/devices.md`, `CHANGELOG.md`, and
  `docs/plans/2026-11-04-device-panel-design.md` (follow-up list)

- [ ] **Step 1: Docs.** In `docs/devices.md`, replace the opening paragraph
  (lines 3-8) with:

```markdown
The Devices tab in the right pane stacks the devices a worktree is using: the
Mac's booted iOS simulators and running Android devices, then the worktree's
own running macOS and Linux VMs. It appears when the Mac has Xcode's simulator
tools, the Android SDK, or can run worktree VMs. One running device fills the
tab; with more, they stack, two screens to a view, and the rest scroll. Each
device's header collapses it to one line, saves a screenshot, opens it in a
center tab, and holds the rest of its actions in its **⋯** menu. A device in a
center tab leaves a line in the stack with **Bring back**; the tab's own
button, or closing it, puts the device back. **+ Add** in the toolbar boots a
simulator or AVD, jumps to a running device, or opens a VM's tab, where it
starts or is set up.
```

  Then make these exact edits:
  - "The toolbar saves a screenshot to the Desktop and shuts the simulator
    down." becomes "Its header saves a screenshot to the Desktop; **⋯** shuts
    the simulator down."
  - "The settings button in the toolbar opens" becomes "**Settings…** in a
    device's **⋯** opens".
  - "The accessibility button in the toolbar outlines" becomes "**Show
    Accessibility Overlay** in **⋯** outlines".
  - "The record button in the toolbar records the screen until you click it
    again" becomes "**Record Screen** in **⋯** records the screen until you
    click the lit stop button in the header".
  - "The Logs button in the toolbar opens" becomes "**Logs** in **⋯** opens".
  - "The device switcher's Android section lists" becomes "**+ Add**'s Android
    section lists".
  - "The toolbar records up to 3 minutes of the screen and saves a screenshot,
    both to the Desktop, and shuts an emulator down." becomes "Its header saves
    a screenshot, and **⋯** records up to 3 minutes of the screen, both to the
    Desktop, and shuts an emulator down."
  - "The settings button opens the same settings" becomes "**Settings…** opens
    the same settings".
  - "The Logs button opens a center tab" becomes "**Logs** opens a center tab".
  - "The hand button in the toolbar records one" becomes "**Record Flow** in
    **⋯** records one".

  Replace the "## VMs" section's paragraph with:

```markdown
A running VM shows its live screen in the stack, with who drives it, Take over
and Hand back, as a simulator does. The stack leaves the guest's display size
alone and scales the screen down. Open it in a tab for a full-size screen and
the VM's setup, clean points and disk tools; a VM that isn't running opens
there from **+ Add**, to start or set up. A VM another Alas runs is listed in
**+ Add** but can't be shown here. While you drive a VM, an agent's call to it
waits up to 50 seconds for you to hand it back, and the status names the agent
waiting. Moving a VM back from its tab hands it back.
```

- [ ] **Step 2: CHANGELOG.** Under `## [Unreleased]`, add a `### Features`
  section if there isn't one, and add:

```markdown
- Stack every running simulator, Android device and worktree VM in the Devices tab, and move any of them to a center tab and back.
```

- [ ] **Step 3: Design doc.** In
  `docs/plans/2026-11-04-device-panel-design.md`'s "Follow-up work", add:

```markdown
- [x] Several devices at once: the Devices tab stacks every running device, and any of them opens in a center tab (`2026-11-19-devices-rail-stack-design.md`).
```

- [ ] **Step 4: End-to-end with real devices.** Boot the iPhone 17 Pro
  simulator and the `Medium_Phone_API_36.1` emulator, build Alas Dev, and
  launch it on a scratch profile:

  ```bash
  mkdir -m 700 -p /tmp/alas-dev-profile
  open -n --env ALAS_APP_SUPPORT_DIR=/tmp/alas-dev-profile \
    "$HOME/Library/Developer/Xcode/DerivedData/Alas-bsgopsrkmtpjvyheygmtyflcwcrp/Build/Products/Debug/Alas.app"
  ```

  Computer use can't drive Alas Dev, so hand the user this checklist:
  1. The Devices tab shows both devices stacked. Collapse one, and the other
     grows to fill.
  2. ⤢ on the simulator opens a center tab, and the rail shows "in a tab".
     **Bring back** and the tab's ⤡ both return it, expanded.
  3. Start a worktree macOS VM from **+ Add** (its tab opens), then ⤡ it to the
     rail. The guest desktop keeps its size, scaled down. Take over, type,
     then ⤢ it back to its tab.
  4. Scroll a screen out of view and back: it resumes.
  5. An agent's `device_open` on the collapsed device expands it and scrolls to
     it.
  6. **⋯** on each device: Settings…, Logs, Record Screen, Record Flow, Run
     Flow, Shut Down.

- [ ] **Step 5: Commit.**
  `docs(devices): describe the stacked Devices tab`
