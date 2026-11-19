# Devices rail: a stack of running devices

Replaces the Devices tab's single-device stage and switcher
(`docs/plans/2026-11-05-devices-tab-redesign-design.md`, "Layout A").

## Goal

Simulators, Android devices and worktree VMs behave the same way. Each one is
shown either in the right rail or in a center tab. When more than one device is
running, the rail shows all of them at once as a scrolling list. A single device
fills the rail and sits centered, as today. Nothing has to be pinned or
configured.

## What the rail lists

- **Running devices**, in a fixed order:
  1. booted iOS simulators,
  2. running Android devices (emulators and USB phones),
  3. this worktree's VMs that are running, starting or pausing.

  Devices are sorted alphabetically within each group. A device that boots or
  stops never moves the others around.
- Simulators and Android devices belong to the Mac, so every worktree lists
  them. VMs appear only in their own worktree.
- **+ Add ▾** in the rail toolbar lists what isn't running:
  - shut-down simulators, grouped by runtime as the switcher groups them today;
  - AVDs that aren't running;
  - this worktree's VMs that are stopped or paused (**Start**), or not set up
    (**Set up…**, which opens the VM's center tab).

  Picking a device boots or starts it. It then joins the stack expanded and
  becomes the last-used device.
- **Nothing running:** the current empty state and its notes, with Boot
  buttons (no Xcode, no simulators, Android SDK missing).
- A device that shuts down or stops, from Alas or from outside it, leaves the
  stack and appears under **+ Add** again.

## Where a device lives

- **A device is in the center exactly when this worktree has a center tab open
  for it.**
  - For a VM, that's its existing `.virtualMachine` tab.
  - For a simulator or Android device, it's a new `.device` tab.
  - No other location state is stored.
- **⤢ (Open in tab)** in a device's header opens that tab, or focuses it if it's
  already open.
- **⤡ (Back to rail)** in the center tab closes the tab. Closing the tab any
  other way has the same effect: the device returns to the rail, expanded.
- While a device is in the center, the rail keeps a one-line placeholder in its
  slot: status dot, name, "in a tab", and **Bring back**.
- A VM's screen is one cached `VZVirtualMachineView` that moves between
  containers (`VMDisplaySurface`). A device is therefore never drawn in both
  places at once.

## The last-used device

`RightPaneState.devicesSelection` becomes `devicesLastUsed: DevicesTarget?`,
held in memory like today's selection.

- **Set by:**
  - clicking a device's screen or header,
  - booting or starting a device from **+ Add**,
  - moving a device between the rail and the center,
  - an agent's `device_open`.
- **Read by:**
  - run-script installs (`SimulatorTarget.choose` keeps its order: the last-used
    simulator, then the first booted one, then the first in the list);
  - `device_open`, which expands the agent's device and scrolls it into view. A
    device that's in a center tab stays there.

`RightPaneState.devicesCollapsed: Set<DevicesTarget>` holds the collapsed
devices, per worktree, in memory.

## Layout

### Sizing

Let *visible* be the rail's height below its toolbar, and *expanded* the devices
whose screens show in the rail. Collapsed devices and center-tab placeholders
don't count.

- **One expanded device:** it fills the rail with the current 12 pt margins and
  sits centered.
- **Two or more:** each screen's height is capped at half of *visible*, minus
  the headers and spacing.
  - A portrait phone or tablet scales to that height.
  - A landscape screen or a VM scales to the rail's width, minus the hardware
    button capsule when there is one, and to no more than that height.
  - A screen is never shorter than 200 pt. Three or more expanded devices
    therefore scroll.
- A collapsed device or a placeholder is a single header row.

### Device header

`▾/▸` · status dot · name · OS version · `⌘` screenshot · `⤢` · `⋯`

- **Status dot:**
  - green: running;
  - amber: booting, busy, or an agent is driving;
  - grey: stopping.
- The OS version truncates first, then the name. The icons always stay.
- **`⋯` lists only what the device supports:**
  - Settings… (the existing settings popover, anchored to the header)
  - Logs (opens the existing center logs tab)
  - Record / Stop recording
  - Record flow / Run flow…
  - Rotate left / Rotate right
  - for simulators and AVDs, Shut down; for VMs, Pause, Stop and Open VM
    settings (its center tab)

### Screen

- **Hardware buttons:** they stay in the capsule beside each phone screen.
- **Unchanged behavior on each screen:** the driver pill with Take over / Hand
  back, the blocked-click pulse, and dropping a `.app` or `.apk` to install it.
- **Status inside the entry:** "Booting…", "The stream stopped" with Retry, and
  the install pill are drawn inside the entry at its own size.
- **Focus:** clicking a screen gives it keyboard focus and makes it the
  last-used device.

### Streaming

- **Simulators and Android devices:** the stack is a lazy list. An entry
  subscribes to its device's stream when it appears and unsubscribes when it
  scrolls off or collapses, as the current single-device views already do.
- **Agent calls:** they keep their own 60-second stream lease, unchanged, so a
  collapsed or off-screen device still answers `device_snapshot` and
  `device_screenshot`.
- **VMs:** they keep running whether they're visible or not. The cached screen
  view is attached to the rail entry only while that entry is on screen and the
  VM isn't in its center tab.

### Center tab

- **Simulators and Android devices:** the new tab shows the same entry at full
  size, with ⤡ in place of ⤢ and no collapse chevron.
- **VMs:** `VirtualMachineTabView` keeps its own chrome and its setup,
  customize, disk and delete screens. It only gains ⤡.

## Model and code

### AlasCore (`AlasFeatures/Devices`), pure and tested

- **`DevicesRailState.resolve(simulators:simulatorsError:android:vms:collapsed:inCenter:lastUsed:bootingUDIDs:)`**
  returns:
  - `entries`: each with its `DevicesTarget`, title, OS line, platform, status
    and placement (`.expanded`, `.collapsed` or `.inCenter`);
  - `addMenu`: sections of devices that aren't running, reusing
    `DevicesSwitcherSection` where it fits;
  - `empty`: the empty-state stage when nothing is running.

  It replaces `DevicesTabState.resolve`'s `Stage` and the switcher rows.
  `DevicesTabState` is deleted once nothing reads it.
- **`DevicesRailLayout.screenSizes(visibleHeight:width:entries:)`** returns each
  expanded entry's screen size from its aspect ratio, following the sizing
  rules above.
- **`SimulatorTarget.choose(lastUsed:simulators:)`** is renamed from `selection`;
  its behavior is unchanged.
- **`DevicesTarget`** gains `Codable` so that `DeviceTabState` can store it.

### App

- **`DevicesRailView`** (replaces `DevicesTabView`): the toolbar with
  **+ Add**, and a `LazyVStack` in a `ScrollViewReader` so `device_open` can
  scroll to its device.
- **`DeviceEntryView`:** a `DeviceEntryHeader` plus one of three screens:
  - `DeviceStage` (iOS),
  - `AndroidDeviceStage`,
  - `VMEntryScreen`, a small view around `VMDisplaySurface` with the driver
    pill and the look-only shield.

  The rail and the center `.device` tab both use it.
- **`Tab.device(DeviceTabState)`:** `DeviceTabState` stores the worktree and the
  `DevicesTarget`. It is restored after relaunch. A device that isn't running by
  then shows the shut-down state with **Boot**.
- **`VirtualMachineTabView`** gains ⤡.
- **Where a device is:** `inCenter` is computed from
  `tabs.tabs(forWorktree:)`. A `.device(target)` or `.virtualMachine(guest)` tab
  counts.
- **`AppState+Devices`** (`device_open`) and **`AppState+RunScriptApp`** set
  `devicesLastUsed`. `device_open` also removes its device from
  `devicesCollapsed`.
- **Removed:**
  - `DevicesSwitcher`,
  - `VMDeviceCard`,
  - the switcher chip and actions in `RightPaneView`'s Devices toolbar (they
    move into each entry's header).
- **`DesignCaptureDevices`:** the galleries cover the rail with one, two and
  three devices, a collapsed device and a center-tab placeholder.

## Tests

Following AGENTS.md's testing policy:

- **`DevicesRailStateTests`** (replaces `DevicesTabStateTests`), parameterized:
  - the stack order, and which devices count as running;
  - placement for collapsed devices and center tabs;
  - the **+ Add** sections for each `VMDeviceStatus`, shut-down simulators and
    AVDs that aren't running;
  - the empty state's reasons;
  - `SimulatorTarget.choose` with and without a last-used device.
- **`DevicesRailLayoutTests`:** one parameterized test covering:
  - one device,
  - two,
  - three with one collapsed,
  - the 200 pt minimum forcing a scroll,
  - a landscape screen and a VM fitting the width.
- **Tab restore:** the existing tab-restore test is extended only if
  `Tab.device` needs custom decoding.
- No view tests.
- **Visual check:** design-capture galleries at 300 and 420 pt.
- **Manual pass in Alas Dev**, done by the user, since computer use can't
  drive Alas Dev:
  - devices moving between the rail and the center;
  - two simulators and a VM on screen at once;
  - collapse;
  - an agent's `device_open` scrolling to its device.

## Docs

- Rewrite the Devices tab section of `docs/devices.md`.
- Add a CHANGELOG entry under Unreleased.

## Out of scope

- Dragging devices to reorder them
- Resizing individual entries
- Side-by-side layouts
- Device chrome options
- Keeping the collapsed set across relaunches
