# Devices: rotation, screen recording, and hiding device tools

## Goal

Three small controls on top of the iOS simulator support: rotate a
simulator, record its screen, and keep `device_*` tools away from agents
while the user hasn't allowed them. Item C of the Devices follow-ups (A logs,
B clipboard and text, C small controls, D settle-and-diff, E held calls for
VMs).

## What exists, checked on iOS 26.5 / Xcode 26.6

- The vendored `HIDInjector.sendOrientation(orientation:)` rotates the
  device through a GSEvent on `PurpleWorkspacePort`, as Simulator.app does,
  or through CoreDevice's vendor channel on foldables. Its log says
  Simulator.app must be running; it doesn't: a probe rotated Safari to
  landscape with Simulator.app closed. `AlasSimulatorSession` doesn't expose
  it yet. Values are UIDeviceOrientation: 1 portrait, 2 upside down,
  3 landscape right, 4 landscape left.
- After rotating to landscape left:
  - the framebuffer stays portrait (1206×2622), with the landscape UI drawn
    sideways in it;
  - `simctl io screenshot` comes out landscape (2622×1206);
  - the accessibility root frame becomes 874×402 points, so snapshot frames
    are in the upright interface's points.
- The vendored capture's frame callback carries `CapturedScreenInfo`, whose
  `display?.orientation` names the interface orientation of that frame
  (`portrait`, `landscape_left`, `landscape_right`, `portrait_upside_down`);
  `AlasSimulatorSession.start` ignores it today.
- Touches go to the service as 0–1 coordinates across the portrait panel
  (`SimServiceProtocol.touch`). `DeviceScreenGeometry` (AlasCore) maps the
  view to those coordinates, for an upright portrait screen only.
- `simctl io <udid> recordVideo --codec=h264 --force <file>` records with
  Simulator.app closed and finishes writing within 0.1 s of SIGINT. The file
  is H.264 at the panel's size.
- The MCP server fixes its tool list at start from environment variables:
  `ALAS_MCP_HEADLESS` hides screen-bound tools, `ALAS_MCP_WORKSPACE_ONLY`
  limits to workspace tools. It has no `tools/list_changed` support. Device
  tools are always listed and answer `device_disabled` while
  `deviceAgentsEnabled` is off. The preamble drops lines through flags such
  as `computerUseAvailable`.

## Decisions

- Rotation is for you and for agents, and the screen, input, screenshots and
  refs follow the interface orientation.
- Recording is for you (toolbar, Desktop) and for agents (`device_record`,
  files in a folder Alas owns).
- Tools are hidden at session start. Turning the setting on applies to new
  sessions; turning it off mid-session leaves running sessions with
  `device_disabled`.

## 1. Rotation

### Orientation with every frame

- `AlasSimulatorSession.start(onFrame:)` passes each frame's interface
  orientation along with the pixel buffer.
- `SimFrameSink.frame(udid:surface:orientation:)` carries it to the app, so
  the screen and the agent's last frame never pair pixels with a stale
  orientation. `orientation` is the raw name; an unknown or missing name
  counts as portrait.
- `SimulatorStreamClient` keeps it with the last frame:
  `lastFrame(udid:)` returns the surface and its orientation.

### One mapping, in AlasCore

`DeviceScreenOrientation` (`portrait`, `landscapeLeft`, `landscapeRight`,
`portraitUpsideDown`), parsed from the frame's name:

- `uprightSize(panel:)`: the panel size, swapped for landscape.
- `panelPoint(_:)`: a 0–1 point in the upright interface to the 0–1 point on
  the portrait panel that touches use. For landscape left, the interface's
  top left is the panel's bottom left, and so on; the tests pin all four.
- `DeviceScreenGeometry` takes an orientation: it lays the upright screen
  into the view and maps clicks through `panelPoint`.

Everything that turns a position into a touch goes through it:

- your clicks and drags on the screen;
- `device_tap` and `device_swipe` with screenshot pixels (upright pixels);
- `device_tap` with a ref (snapshot frames are already in upright points,
  so normalize by the snapshot root's size and map);
- swipe directions, so "up" is up on the screen you see.

### Showing it

- `DeviceScreenNSView` rotates its display layer by the frame's orientation
  and fits the upright size into the view.
- `DeviceStage` lays the device frame out landscape when the interface is
  landscape: the shape's width and height swap, and the bezel and corner
  radius stay. The hardware button gutter stays on the right.

### Rotating

- `AlasSimulatorSession.rotate(_ orientation: UInt32) async -> Bool` calls
  `HIDInjector.sendOrientation`. `SimServiceProtocol` gets
  `rotate(udid:orientation:reply:)`, replying with an error message or nil.
- The app tracks each simulator's device orientation as it last set it,
  starting at portrait (the simulator doesn't report it back on non-foldable
  devices).
- **You:** two buttons in the stage's hardware gutter, under the others:
  rotate left (`rotate.left`) and rotate right (`rotate.right`), each turning
  the device 90°. Disabled while an agent drives.
- **Agents:** `device_rotate`:

  | Argument | Values |
  |---|---|
  | `udid` | required |
  | `orientation` | `portrait`, `landscape_left`, `landscape_right`, `portrait_upside_down` |

  - It's input: held while you drive, and it takes an input turn.
  - After rotating, it waits up to 2 s for a frame whose interface
    orientation matches. It returns
    `{"device": "<orientation>", "interface": "<orientation>"}`: a
    portrait-only app leaves `interface` at `portrait`.
  - Errors: `device_not_booted`; `device_rotate_failed: <reason>`.

### Screenshots

`device_screenshot` (and `include_screenshot`) turn the PNG upright before
scaling, so its pixels are the upright pixels `device_tap` takes. Your
toolbar screenshot turns upright too.

## 2. Recording

`DeviceRecorder` (app, `@MainActor @Observable`) runs at most one
`simctl io <udid> recordVideo --codec=h264 --force <file>` per simulator:

- Each recording has an owner: you, or an agent session.
- Stop sends SIGINT and waits up to 5 s for the process to exit, then
  terminates it. The file is kept only when the process exited cleanly.
- A recording stops on its own when its simulator shuts down (the Devices
  pane's refresh sees it), when `recordVideo` exits, or for an agent after
  10 minutes. The finished file is kept for the agent's next `stop`.

**You:** a record button in the toolbar next to the screenshot button
(`record.circle`; red `stop.circle.fill` while recording). Stopping saves
"Simulator Recording <device> <yyyy-MM-dd 'at' HH.mm.ss>.mov" to the
Desktop and shows "Saved to Desktop" as the screenshot does. While an agent
records, the button shows the recording, is disabled, and its tooltip says
"<agent> is recording".

**Agents:** `device_record` with `action` `start` or `stop`:

- Not held while you drive and takes no input turn: it doesn't touch the
  screen.
- `start` returns `{"recording": true}`.
- `stop` returns `{"path": "<file>", "seconds": <duration>}`, also for a
  recording that already ended on its own.
- Files go to `~/Library/Caches/Alas/Recordings/<udid>-<timestamp>.mov`.
  Alas deletes ones older than 7 days when the recorder is first used.
- The video keeps the panel's portrait frame (1206×2622 on an iPhone 17),
  whatever the orientation: `recordVideo` records the framebuffer.
- Errors: `device_not_booted`; `device_recording_busy: <who> is recording
  <device>.`; `device_not_recording`; `device_record_failed: <reason>`.

## 3. Hiding device tools

- The session's MCP server starts with `ALAS_MCP_DEVICES=0` when
  `deviceAgentsEnabled` is off: `BuiltInAlasMCP`'s stdio environment and
  `AlasMCPHTTPSupervisor.environment(...)` both take a `deviceTools` flag.
- In the Rust server it's a `devices` flag on the session config. While it's
  false, `tools/list` leaves out `device_*`, and calling one answers the
  existing `device_disabled` text.
- `ACPMCPPromptPreamble.text(...)` takes `deviceToolsAvailable` (default
  true) and leaves out the device paragraph when false. `ACPSessionManager`
  reads it per session start, as it does `computerUseAvailable`.
- Headless and workspace scopes are unchanged; they hide more already.

## Code

- `ThirdParty/serve-sim-native/.../AlasSimulatorSession.swift` (Alas's
  file): the orientation in `start`'s callback, and `rotate(_:)`. No upstream
  file changes.
- AlasSimService and `SimServiceProtocol`/`SimFrameSink`: orientation with
  frames, `rotate`.
- AlasCore: `DeviceScreenOrientation`; `DeviceScreenGeometry` with an
  orientation; `DeviceCommand.rotate` and `.record`.
- App: `SimulatorStreamClient` (orientation with the last frame, `rotate`),
  `DeviceScreenNSView`, `DeviceStage`, `DevicesActions`, `DeviceRecorder`,
  `DeviceAgentControl`, the screenshot code, the session environment and
  preamble flag.
- Rust: `device_rotate`, `device_record`, the `devices` flag.

## Testing

- AlasCore: `DeviceScreenOrientation` for all four orientations
  (parameterized: names, upright size, corner points); `DeviceScreenGeometry`
  in landscape; `DeviceCommandTests` rows.
- App `DeviceAgentControlTests`:
  - `device_rotate` is held during a takeover, and waits for a frame in the
    new orientation;
  - a ref tap and a pixel tap in landscape send the right panel point;
  - recording start, busy and stop with a fake recorder.
- Rust: parsing, refusals, tool lists, and `ALAS_MCP_DEVICES=0` hiding and
  refusing device tools.
- `ACPMCPPromptPreambleTests`: no device paragraph without device tools.
- Not tested: the AppKit layer rotation and the simctl process. A throwaway
  end-to-end run: rotate Safari, check the upright screenshot, tap an element
  by ref in landscape, record and stop. Then your manual pass.

## Docs

- `docs/devices.md`: rotating, recording, `device_rotate` and `device_record`
  in the tool table, and that the tools are absent while the setting is off.
- Tick "Rotate …" and "Screenshot and screen recording" in
  `docs/plans/2026-11-04-device-panel-design.md` where they apply.
