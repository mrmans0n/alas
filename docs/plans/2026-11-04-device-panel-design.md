# Device panel

## Goal

Show a live iOS Simulator in the right pane, next to the agent session, and
let the user and later the agent drive it. No Node, Bun, or ffmpeg at runtime.
Research and spike results are in
`docs/research/2026-11-03-device-panel-t3-code.md`.

## Phases

1. **iOS panel for the user.** A Device tab in the right pane: pick a
   simulator, boot it, watch it, tap, drag, type, press Home. Off by default,
   behind a toggle in the hidden Advanced settings pane. This document's
   implementation plan covers this phase only:
   `docs/plans/2026-11-04-device-panel-phase1-implementation.md`.
2. **Agent tools.** `device_*` tools in the built-in `alas` MCP server and a
   driver state shared with the panel. Its own plan, written after phase 1
   ships.
3. **Android.** The same tab backed by a pinned `scrcpy-server`. Its own plan.

## Decisions

- **Built in, not a plugin.** The plugin API has no loopback network for web
  pages, no MCP tool contribution, and no control over the agent's
  environment.
- **No JavaScript runtime.** Expo's `serve-sim` needs Node 20+ and a Node-API
  addon, `serve-emu` needs Bun, and `agent-device` needs Node 22.12+. Alas
  uses serve-sim's Swift sources directly instead.
- **Vendored serve-sim Swift, unmodified.** Fourteen files from serve-sim's
  `SimNative` module, plus its `StreamingPolicy` and `CoreDeviceShim`
  modules, live in a local SwiftPM package at `ThirdParty/serve-sim-native`,
  pinned to expo/expo-device-hub commit
  `79221dfb1d0822edbd606435175639b541b98813` (Apache-2.0, with its NOTICE).
  One file of ours, `AlasSimulatorSession.swift`, is the only public API.
  `sync.sh <commit>` re-vendors the same file list, so each Xcode release
  means one sync and a rebuild rather than a hand merge.
- **Out of process, over XPC.** The private frameworks load in an XPC service,
  `AlasSimService.xpc`, so a crash in them ends the stream instead of Alas.
  XPC is the only standard way to hand an `IOSurface` to another process, and
  launchd restarts the service on the next message. This is the first XPC
  service in the repo; the other helpers are child processes under
  `Contents/Resources`.
- **No encoding.** serve-sim's `FrameCapture` copies each new framebuffer into
  an IOSurface-backed `CVPixelBuffer` from a pool (`420v`). The service sends
  that `IOSurface` over XPC; the app wraps it in a `CMSampleBuffer` and
  enqueues it on an `AVSampleBufferDisplayLayer`, which displays YUV buffers
  as they are.
- **simctl for the device list.** Listing, booting, and shutting down use
  `xcrun simctl`, which is public and stable. Only capture and input use
  private API.
- **One shared device list.** Simulators belong to the Mac, not to a
  worktree, so one `DevicePaneModel` in `AppState` holds the list and the
  selected device for every worktree's pane.
- **Visible means streaming.** The right pane shows only the selected tab, so
  the Device screen starts its stream on appear and stops it on disappear.
  Streams are counted per device, because SwiftUI can show the next pane
  before it removes the previous one.

## Spike evidence

Measured on 2026-11-04 with the vendored files built as a standalone SwiftPM
package, Xcode 26.6, iOS 26.5 Simulator (iPhone 17 Pro):

- Capture started in 394 to 485 ms and delivered `1206x2622` IOSurface-backed
  `420v` buffers, about 5 to 6 fps on a static screen and about 36 fps while
  an app opened.
- A tap through `HIDInjector` opened Settings. The first changed frame
  arrived 74 ms after the tap on one run and 208 ms on another.
- The same binary signed ad hoc with the hardened runtime
  (`codesign -o runtime`) still loaded SimulatorKit from Xcode and streamed.
- `IOSurface` objects crossed an `NSXPCConnection` (an anonymous listener in
  one process) as plain method parameters, 0.09 ms per frame.
- `AccessibilityBridge.describeUI` returned the screen's element tree in
  3.9 s cold and 1.0 s warm. Phase 2 uses it.

Not yet measured: the XPC hop between two processes, and how
`AVSampleBufferDisplayLayer` looks when a pooled buffer is reused while still
on screen. The implementation plan checks both by hand.

## Phase 1 behavior

- The Device tab appears in the rail only when **Settings › Advanced ›
  Experiments › Device panel** is on, only for local worktrees and folders,
  and never for peer worktrees. Turning the toggle off moves any pane showing
  Device back to its default tab.
- The pane lists available iOS simulators: booted first, then newest runtime,
  then name. With nothing selected it shows the first booted device, or the
  list when none is booted.
- A shut-down device shows a Boot button. Booting runs `simctl boot` and then
  `simctl bootstatus -b`, and the pane says "Booting…" until it finishes.
- While the pane is visible it rereads the device list every 3 seconds. A
  device shut down or deleted outside Alas stops its stream and shows the
  shut-down state or the list, never a frozen last frame.
- The screen fits the pane width, keeping its aspect ratio. A click is a
  tap; a drag is a touch that moves. Clicks in the letterbox bars do nothing.
  A drag that leaves the screen keeps sending positions clamped to the edge,
  so the simulator always receives the touch-up.
- Keys go to the simulator while the screen has keyboard focus, mapped by
  physical key position to USB HID usages. Shift, Control, and Option are
  forwarded; Command is not, so Alas's own shortcuts keep working.
- A toolbar under the screen has Home.
- If `simctl` fails (no Xcode, or `xcode-select` points at the Command Line
  Tools), the pane shows simctl's error and a hint to install or select
  Xcode.
- If the XPC service dies, the screen shows "The simulator stream stopped."
  with a Retry button.

## Phase 2 outline: agent tools

- `device_list`, `device_open`, `device_snapshot`, `device_tap`, `device_type`,
  `device_swipe`, `device_button`, and `device_screenshot` in
  `AlasCLI/crates/alas/src/mcp.rs`, routed like `preview_*` through
  `AlasCLIRequest` and `AlasCLICommandRouter`, scoped by `SessionOwnerID`.
- `device_snapshot` returns `AccessibilityBridge.describeUI` output turned into
  refs, shaped like `computer_inspect`. Taps by ref resolve to the element's
  frame center.
- A driver state per device, modeled on the VM tab's: the panel shows "Agent
  is driving", a user click takes over, and the agent is told so. The spike
  showed agent-device grabbing the foreground back without asking, so this
  is required, not polish.
- An "Agents can use devices" setting; tools are hidden when it is off.
- Open question: whether AXPTranslator needs the Accessibility permission
  when it runs inside an XPC service. The spike ran from a process that may
  already have it.

## Phase 3 outline: Android

- Ship `scrcpy-server` v5.0.1 (Apache-2.0, 734 KB) in the app bundle. Push it
  with `adb`, read its H.264 video socket, decode with VideoToolbox into the
  same `AVSampleBufferDisplayLayer`, and send input over its control socket
  ([protocol](https://github.com/Genymobile/scrcpy/blob/master/doc/develop.md)).
- List devices with `adb devices -l` and AVDs with `emulator -list-avds`.
- `adb shell uiautomator dump` for agent snapshots.

## Follow-up work

Features the Expo tools offer that phase 1 leaves out, and the native way to
add each. Each item gets its own plan after phase 1; check them off here as
they land. The `simctl` subcommands were checked against Xcode 26.6's
`xcrun simctl help`.

iOS:

- [ ] Rotate, lock, Siri, side button and app switcher buttons.
  `HIDInjector.sendOrientation` and `sendButton` are already vendored; this
  is toolbar work plus `AlasSimulatorSession` methods.
- [ ] Foldable hinge and pose. Needs `HingePoseControl` wiring and possibly
  more vendored files (add them to `vendored-files.txt`).
- [ ] Settings drawer: appearance, text size, increase contrast
  (`simctl ui <udid> appearance|content_size|increase_contrast`), each control
  showing the value read back after a change.
- [ ] Permissions, simulated location, push notifications, open URL
  (`simctl privacy`, `simctl location`, `simctl push`, `simctl openurl`).
- [ ] Install and launch an app (`simctl install`, `simctl launch`), for
  example from a run script's build output.
- [ ] Clipboard both ways (`simctl pbcopy`, `simctl pbpaste`).
- [ ] Screenshot and screen recording (`simctl io <udid> screenshot|recordVideo`,
  or a PNG from the frames Alas already receives).
- [ ] Device logs (`simctl spawn <udid> log stream`), filtered to the
  foreground app.
- [ ] VoiceOver, reduce motion and an accessibility overlay. serve-sim's
  accessibility settings helper (`Sources/SimAXSettings`, not yet vendored)
  and the vendored `AccessibilityBridge`.

Android (after phase 3):

- [ ] Dark mode, font scale, orientation, network on and off, location,
  permissions, APK install and launch, clear data, logcat. Each is an `adb`
  command (`cmd uimode night`, `settings put system font_scale`,
  `adb emu geo fix`, `pm grant`, `install`, `logcat`).
- [ ] GPS route playback and session record/replay. serve-emu builds these
  itself; they need a design of their own.

Agents (phase 2 and after):

- [ ] Settle-and-diff after each action, so agents see what changed without
  a new snapshot.
- [ ] Optional agent-device: when the user already has it installed, put it
  on the agent's PATH next to the native tools, for replay scripts, Metro and
  Expo integration, and profiling. Alas would not install or manage it.

Expensive, not planned: network traffic capture (serve-sim uses mitmproxy),
camera feed injection, and streaming to another machine over WebRTC.

## Out of scope

Physical iOS devices, remote or SSH hosts, and cloud device pools.
