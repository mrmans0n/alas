# Devices

The Device tab in the right pane shows a live iOS Simulator next to your
session. It is an experiment: turn it on in **Settings › Advanced ›
Experiments › Device panel**. The Advanced pane appears once
`~/.alas/.debug` exists.

It needs Xcode with at least one iOS simulator runtime. Pick a simulator,
boot it if it is shut down, and use it: click to tap, drag to swipe, and type
while the screen has focus. Shift, Control and Option reach the simulator;
Command shortcuts stay with Alas. Home is under the screen.

Alas reads the simulator's screen directly through Xcode's private simulator
frameworks, in a helper process (`AlasSimService`). It does not need Node,
ffmpeg, or Simulator.app. A new Xcode release can break the stream until Alas
updates; the code comes from Expo's serve-sim (see
`ThirdParty/serve-sim-native/README.md`).

If the helper stops, the screen says so and Retry starts it again. If
`xcode-select` points at the Command Line Tools instead of Xcode, the tab
shows simctl's error.

## Agents

Agents can drive the same simulators. Turn on **Settings › Advanced ›
Experiments › Let agents use the device** (it needs Device panel on). Agent
sessions in a worktree then get these tools from the built-in `alas` MCP
server:

| Tool | What it does |
|---|---|
| `device_list` | Lists the iOS simulators and whether each is booted. |
| `device_open` | Boots a simulator if needed and shows it in the agent's worktree's Device tab. |
| `device_snapshot` | Reads the screen's accessibility elements, with refs such as `s2e3` and frames in points. |
| `device_screenshot` | Returns a PNG of the screen, at most 1280 px on the long edge. |
| `device_tap` | Taps a ref from the latest snapshot, or x/y pixels in the latest screenshot. |
| `device_swipe` | Swipes in a direction, or between two screenshot points. |
| `device_type` | Types ASCII text as key presses; `\n` presses Return. |
| `device_button` | Presses Home, Lock, Siri, the side button, or opens the app switcher. |

While an agent works on a simulator, the Device tab says who is driving and
ignores your clicks and keys. Take over to use it yourself: the agent's
calls then fail with `device_user_active` until you hand it back. With the
setting off, every call fails with `device_disabled`. An agent's calls keep
the simulator's stream running for a minute after its last call, so
screenshots work with the Device tab closed.

Not yet: Android, physical devices, rotation, and device settings. The
follow-up list is in `docs/plans/2026-11-04-device-panel-design.md`.
