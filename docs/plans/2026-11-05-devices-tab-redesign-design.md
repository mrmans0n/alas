# Devices tab redesign

## Goal

Give the right pane's Device tab a proper design, and make it the one place
for everything an agent can run and test on: iOS simulators and this
worktree's macOS and Linux VMs. The tab stops being an experiment.

Builds on `docs/plans/2026-11-04-device-panel-design.md` (phases 1 and 2,
shipped in #2348 and #2356).

## Decisions

- **Layout A, stage + switcher.** The simulator screen gets the whole pane.
  A switcher in the pane toolbar picks between simulators and this
  worktree's VMs. Chosen over a list above a smaller screen, and over one
  card per device, because a phone screen is what needs room in a pane that
  can be 240 pt wide.
- **VMs are listed, their screens stay in the center tab.** A macOS or Linux
  desktop is unreadable at pane width, and the VM tab's setup, pause and
  disk flows stay where they are. The Devices tab shows a VM's status and
  driver and opens its tab.
- **No experiment toggle.** Simulators and VMs are both regular features.
  The "Device panel" setting goes away. Letting agents use simulators stays
  opt-in, moved to Settings › Computer Use.
- **Selection is per worktree.** Simulators belong to the Mac, but VMs belong
  to a worktree, so each worktree's pane remembers its own choice.

## Structure

- The tab is renamed **Devices** and keeps the `iphone` icon. It appears for
  local worktrees and folders, never for peer worktrees, when the Mac can
  run worktree VMs (`WorktreeVMManager.isSupported`) or `xcrun --find
  simctl` succeeds. The simctl check runs once per launch, in the
  background; until it answers, the tab follows VM support alone.
- It lists:
  - **Simulators:** available iOS simulators from `simctl`, booted first,
    then newest runtime, then name (as today).
  - **This worktree's VMs:** macOS and Linux, always both, each with its
    state.
- The Run tab toolbar loses its **VM ▾** menu. **Preview** stays.
- Settings:
  - `AppConfig.devicePanelEnabled` is removed, along with its row in
    `AdvancedPane`. A stored value is ignored by the tolerant decoder.
  - "Let agents use the device" moves to `ComputerUsePane`, renamed **Let
    agents use iOS simulators**. Same key, `deviceAgentsEnabled`, still off
    by default.
  - `performDeviceCommand` checks only `deviceAgentsEnabled`. The
    `device_disabled` message becomes: `device_disabled: Agents can't use iOS
    simulators. Ask the user to turn on Settings › Computer Use › Let agents
    use iOS simulators.`
- Out of scope: Android, web preview as a device, moving VM setup, pause or
  disk tools out of the center tab, and showing a live VM screen in the pane.

## Selection

Each worktree's `RightPaneState` holds `devicesSelection: DevicesTarget?`,
in memory only. `DevicesTarget` is `.simulator(udid)` or `.vm(VMGuestOS)`.

When there is no selection, or the selected simulator no longer exists, the
tab shows, in order: the first booted simulator; this worktree's running
VM (macOS before Linux); the first simulator; the macOS VM. A selected VM
never disappears, because both VM entries are always listed.

`device_open` sets the agent's worktree selection to that simulator, as
phase 2 does with the global selection today. `DevicePaneModel.selectedUDID`
goes away.

## Layout

### Pane toolbar

- **Leading:** the switcher chip: a state dot, the device name, a dim
  secondary label (`iOS 26.5`, `macOS VM`, `Linux VM`), and a chevron.
  Dot colours: green when booted or running; amber when an agent is driving
  or the device is booting, starting or pausing; grey when shut down,
  stopped, paused or not created.
- **Switcher menu:** a **Simulators** section and a **This worktree's VMs**
  section. Each row has the dot, the name, and the runtime or a one-word VM
  state. Choosing a row only selects it.
- **Trailing, for a simulator:**
  - A screenshot button: saves `Simulator Screenshot - <name> - <date
    time>.png` to the Desktop from the latest frame and shows "Saved to
    Desktop" in the toolbar for 2 seconds. Disabled until a frame arrives.
  - A ⋯ menu with **Shut down** (`simctl shutdown`), enabled while booted.
- **Trailing, for a VM:** nothing.

### Stage: simulator booted

- The screen is centered and fitted to the pane with 12 pt margins.
- Its corners are rounded with the device's screen radius, read from its
  chrome. `simctl list devicetypes --json` gives the device type's
  `bundlePath`; its `Contents/Resources/profile.plist` names a
  `chromeIdentifier` such as `com.apple.dt.devicekit.chrome.phone11`; and
  `/Library/Developer/DeviceKit/Chrome/<last component>.devicechrome/Contents/Resources/chrome.json`
  gives the outer radius (`paths.simpleOutsideBorder.cornerRadiusX`) and the
  bezel width (`images.sizing.leftWidth`). The screen radius is the outer
  radius minus the bezel width: 80 − 18 = 62 pt for the iPhone 17 Pro
  (`phone11`, the value serve-sim reports) and 81 − 59 = 22 pt for current
  iPads (`tablet4`). The radius scales with the screen as it is fitted.
  Without chrome, corners are square.
- The screen sits in a 4 pt dark bezel that follows the same corners, with a
  soft shadow.
- **Controls:** a vertical capsule floating at the right edge of the pane,
  over the pane background, never over the screen: Home, App switcher, Lock,
  Siri, each with a tooltip. Disabled while an agent drives.
- **Driver pill:** top center, over the screen, shown only when someone has
  driven in the last 30 seconds or the user has taken over:
  - Agent: `● <agent> is driving · Take over`
  - User: `You're driving · Hand back`
  - It replaces the current full-width status bar. A click on the screen
    while an agent drives briefly highlights the pill instead of showing a
    separate hint.

### Stage: other simulator states

Each is a centered column with a large SF Symbol, one line of text and at
most one primary button:

| State | Text | Button |
|---|---|---|
| Shut down | `<name> is shut down` | Boot |
| Booting | `Booting <name>…` with a spinner | none |
| No Xcode / simctl failed | `Install Xcode to use iOS simulators`, simctl's error small underneath | none |
| No simulators | `No iOS simulators. Create one in Xcode › Window › Devices and Simulators.` | none |
| Stream stopped | `The simulator stream stopped` | Retry |
| Boot failed | the error, in the warning tone, under the shut-down state | Boot |

### Stage: VM selected

A centered status card:

- **Title:** `macOS VM` or `Linux VM`.
- **State line:** Running · Starting · Pausing · Paused (saved <relative
  time>) · Stopped · Running in <other window label> · Not created.
- **Driver line,** while running, worded like the VM tab
  (`VMDriverStatus.make`): `<agent> is driving · device_tap 4 s ago`, or
  `You're driving · agent calls are on hold`.
- **Buttons:**
  - **Open** (primary): `openVirtualMachine(in:guest:)`, which shows the VM
    center tab; that tab starts, resumes or sets up the VM as it does
    today. Reads **Set up** when the VM is not created.
  - **Take over** / **Hand back** while running: `takeOverVM` /
    `handBackVM`.

## Units

### AlasCore, `AlasFeatures/Devices` (unit-tested)

- `DevicesTarget`: `.simulator(String)`, `.vm(VMGuestOS)`.
- `VMDeviceStatus`: `notCreated`, `stopped`, `paused(savedAt: Date)`,
  `starting`, `running`, `pausing`, `runningElsewhere(label: String)`.
- `DevicesTabState.resolve(simulators: [SimulatorDevice]?, listError:
  String?, vms: [VMGuestOS: VMDeviceStatus], selection: DevicesTarget?,
  bootingUDIDs: Set<String>) -> DevicesTabState`, giving the switcher rows
  (with dot tone and secondary text) and the stage
  (`.simulator(SimulatorDevice, SimulatorStage)` or `.vm(VMGuestOS,
  VMDeviceStatus)` or `.unavailable(String)` / `.noSimulators` /
  `.loading`). Replaces `DevicePaneStatus`.
- `DeviceChrome.screenCornerRadius(chromeJSON: Data) -> Double?` (outer
  radius minus bezel width, nil when either is missing or the result is
  not positive) and `DeviceChrome.chromeURL(profilePlist: Data, root: URL)
  -> URL?`.
- `SimulatorControl.shutdown(udid:)`, `SimulatorControl.isAvailable() async
  -> Bool` (`xcrun --find simctl`), and `SimulatorControl.deviceTypeBundles()
  async throws -> [String: URL]` (identifier → `bundlePath`, from
  `simctl list devicetypes --json`, read once per launch).
- `SimulatorDevice` gains `deviceTypeIdentifier` from simctl's device JSON,
  to find its device type.

### App, `Alas/Sources/Devices`

- `DevicesTabView`: composes the stage from `DevicesTabState`.
- `DevicesSwitcher`: the toolbar chip and menu, plus the screenshot and ⋯
  controls; shown by `RightPaneToolbar` for `.device`.
- `DeviceStage`: bezel, corners, controls capsule and driver pill around
  `DeviceScreenView`.
- `VMDeviceCard`.
- `VMDeviceStatusSource`: builds `[VMGuestOS: VMDeviceStatus]` and each
  VM's `VMDriver` from `vmManager.recordStatus`, `running`, `isStarting`,
  `pausing` and `vmDriver(recordID:)`.
- `DeviceScreenshot`: PNG encoding from an `IOSurface`, moved out of
  `DeviceAgentControl` and shared by the agent tool and the toolbar button.

## Testing

- `DevicesTabStateTests` (AlasCore): default selection order; fallback when
  the selected simulator is deleted; a selected VM always resolving; each
  simulator stage; each VM status; dot tones; simctl error.
- `DeviceChromeTests` (AlasCore): radius from `phone11`- and
  `tablet4`-shaped `chrome.json` (62 and 22); missing keys, malformed JSON or
  a non-positive result give nil; `chromeURL` from a `profile.plist` with and
  without `chromeIdentifier`.
- `SimulatorDeviceListTests`: `deviceTypeIdentifier` is read.
- `DevicePaneStatusTests` is deleted; its cases move into
  `DevicesTabStateTests`.
- `RightPaneTabTests`: availability by the `devices` flag.
- `DeviceAgentControlTests`, `ACPMCPPromptPreambleTests` and the Rust MCP
  tests are updated for the new `device_disabled` text.
- No tests of view layout.
- Manual, in a running Alas Dev: switch between simulators and both VMs;
  boot, shut down and screenshot; corners on an iPhone and an iPad; the
  driver pill while an agent drives and after Take over; Open and Set up for
  VMs; the Run tab without its VM menu; the tab missing on a Mac with
  neither VMs nor Xcode (by forcing both checks off in a debug build).
