# Devices: held agent calls, and installing and launching apps

## Goal

Close the loop an agent needs to work on an iOS app in a worktree: build it,
install it on a simulator, launch it, and test it with the `device_*` tools.
When the user takes over a simulator an agent is driving, the agent's calls
wait for the user to hand it back instead of failing at once.

Two items from the follow-up list in `2026-11-04-device-panel-design.md`:

- Pause the agent's turn on takeover, built here as held calls.
- Install and launch an app.

## What exists

- Taking over a simulator puts its UDID in `DeviceAgentControl.takenOver`.
  Every later `device_*` call for it fails with `device_user_active`, and
  `device_swipe` and `device_type` stop between steps
  (`DeviceAgentControl.swift:99-225`).
- VM takeover doesn't pause the agent's turn either. It stops the guest's
  computer use and refuses calls with `computer_user_active`; hand back sends
  no message to the agent (`AppState+ComputerUse.swift:457-500`).
- Input calls to one simulator already run one at a time, in arrival order
  (`acquireInput`/`releaseInput`).
- Alas has no model of build products. Run scripts can't declare an app, and
  no project config holds a scheme or bundle ID.
- Codex gives an MCP tool call 60 s unless `tool_timeout_sec` is raised, and
  Alas doesn't raise it. Claude Code gives a stdio server up to 30 min of
  silence. `computer_*` calls already wait up to 50 s for an app approval for
  this reason (`alas-client/src/lib.rs:1678-1681`).

## Decisions

- Calls are held, not refused, and the turn isn't interrupted: no new
  prompt, nothing lost from the agent's context.
- The hold lasts at most 50 s, under Codex's limit.
- Simulators only. VMs keep refusing; holding VM calls is a follow-up.
- Agents get `device_install` and `device_launch`. The user gets drag and
  drop of a `.app` onto the screen. No run-script integration, no install
  menu, no uninstall, app list or launch arguments.

## 1. Held calls

- A `device_*` call that names a simulator the user has taken over waits for
  hand back: `open`, `snapshot`, `screenshot`, `tap`, `swipe`, `type`,
  `button`, `install`, `launch`. `device_list` names none and never waits.
- The wait happens before the call takes its place in the input queue. Hand
  back releases the waiting calls in arrival order; input calls then go
  through `acquireInput` as today, so they can't overlap.
- After 50 s still taken over, the call fails with
  `device_user_active: The user is still driving <name>. Try again in a minute.`
  The limit is a `DeviceAgentControl` init parameter (`holdLimit`, default
  50 s), and the wait uses the injected `sleep`, so tests don't wait.
- A call whose task is cancelled while waiting (the agent's turn was
  cancelled, or the MCP client gave up) leaves the queue and returns
  `device_cancelled`.
- A waiting call counts as in flight, so the simulator's stream lease is kept.
  The driver stays `.user` while the user drives: takeover wins.
- A call already running when the user takes over:
  - `tap`, `button`, `snapshot`, `screenshot`, `install`, `launch` finish.
  - `type` and `swipe` stop at the next step and fail with
    `device_user_active`. `type` says how far it got:
    `typed 12 of 30 characters`. They don't wait and continue: the user may
    have moved focus.
- The driver pill shows a waiting agent: "You're driving · `<agent>` is
  waiting", with Hand back. `DeviceAgentControl` exposes the waiting session
  IDs per UDID, and the pill names the first.
- The `device_user_active` text, the `DEVICE_DRIVING_NOTE` in `mcp.rs` and the
  agent preamble say: a call waits up to 50 s for the user to hand the device
  back; if it still fails, try again later.

## 2. Installing and launching

### Agent tools

- `device_install(udid, app_path)`
  - `app_path` is absolute or relative to the agent's worktree; the MCP server
    resolves it to an absolute path before sending the request.
  - Alas reads the app's `Info.plist` (at the bundle's root, as iOS apps keep it)
    with `SimulatorAppBundle.read(_:)` and fails before installing when:
    - the path isn't a directory ending in `.app`, or has no `Info.plist`:
      `device_app_invalid: <path> is not an app bundle.`
    - `CFBundleIdentifier` is missing: `device_app_invalid: <path> has no bundle ID.`
    - `DTPlatformName` is `iphoneos`:
      `device_app_wrong_platform: <name> was built for a device. Build it for the simulator, for example with -destination 'platform=iOS Simulator,id=<udid>'.`
      A missing `DTPlatformName` is let through for `simctl` to judge.
  - Runs `xcrun simctl install <udid> <path>` with a 90 s limit; a failure
    returns `device_install_failed: <simctl's stderr>`.
  - Returns `{"bundle_id": "...", "name": "..."}`; `name` is
    `CFBundleDisplayName`, else `CFBundleName`, else the file name.
- `device_launch(udid, bundle_id)`
  - Runs `xcrun simctl launch --terminate-running-process <udid> <bundle_id>`
    and returns `{"pid": n}` from simctl's `<bundle_id>: <pid>` output.
  - A missing app returns `device_app_not_installed: <bundle_id> isn't installed on <name>.`;
    other failures `device_launch_failed: <stderr>`.
- Both need a booted simulator (`device_not_booted` otherwise), run through
  the per-simulator input queue, show the agent as driving, and are held
  while the user drives.
- The agent preamble adds: build for the simulator with `xcodebuild`, then
  call `device_install` and `device_launch`.

### Drag and drop

- `DeviceScreenNSView` accepts a file drop of exactly one `.app` directory
  whose `SimulatorAppBundle` reads as a simulator build (or has no platform).
  While such a drag hovers, the screen gets a 2 pt accent outline; other drags
  are refused with no outline.
- Drops are refused while an agent drives, like clicks; the driver pill
  pulses as it does for a blocked click.
- Dropping installs then launches through the same `AppState` helper the
  tools use, outside the agent's driver state. A pill at the bottom of the
  screen says "Installing `<name>`…", then "Launching `<name>`…", and goes
  away on success. On failure it shows the error until clicked.

### Code

- AlasCore (`AlasFeatures/Devices`):
  - `SimulatorAppBundle`: `read(_ url: URL) throws -> SimulatorAppBundle`
    with `bundleID`, `name`, `platform: String?`, and an error enum for the
    cases above.
  - `SimulatorControl.install(udid:app:)` and
    `SimulatorControl.launch(udid:bundleID:) -> Int32`.
  - `DeviceCommand.install(udid:appPath:)` and `.launch(udid:bundleID:)`,
    decoded in `AlasCLIRequest`.
- App: `DeviceAgentControl` takes `install` and `launch` closures like
  `boot`, so tests use fakes. `AppState` installs the `SimulatorControl`
  ones and offers `installAndLaunch(_ app: URL, on udid:)` for the drop.
- Rust: tool definitions and parsing in `mcp.rs`, `DeviceCommand` variants
  and request building in `alas-client`, read timeout 120 s
  (`COMPUTER_READ_TIMEOUT`), and the two names in the built-in tool list the
  preamble uses.

## Testing

- `DeviceAgentControlTests`, extended:
  - a call made while taken over runs after hand back;
  - it fails with `device_user_active` when the hold limit passes;
  - held calls run in arrival order;
  - a cancelled held call leaves the queue;
  - `device_type` stops at takeover and reports how far it got;
  - install and launch are held and go through the input queue.
- AlasCore `SimulatorAppBundleTests`: a simulator build, a device build, no
  bundle ID, and not a `.app`, as one parameterized test.
- Rust: parsing for both tools (missing and extra arguments, a relative path
  resolved against the worktree) and their read timeout, in the existing
  tables.
- Not tested: the drop target and pills; checked by hand.
- End to end: a throwaway app built with `xcodebuild` in `/tmp`, installed and
  launched on a booted simulator through the tools; then the user's manual
  pass in Alas Dev (drag and drop, an agent's build-install-launch, a takeover
  mid-work and hand back).

## Docs

- `docs/devices.md`: the two tools, drag and drop, and how calls wait while
  the user drives.
- `2026-11-04-device-panel-design.md`: tick "Install and launch an app" and
  the pause item, noting it was built as held calls and VMs remain.
