# Devices

The Devices tab in the right pane shows the devices a worktree can use: the
Mac's iOS simulators and the worktree's own macOS and Linux VMs. It appears
when the Mac has Xcode's simulator tools or can run worktree VMs. Pick a
device with the switcher at the top of the tab. Each worktree remembers its
own choice until Alas quits. Until you pick one, the tab shows a booted
simulator, then a running VM, then the first simulator.

## Simulators

Simulators need Xcode with at least one iOS simulator runtime. Boot a
simulator that is shut down, then use it: click to tap, drag to swipe, and
type while the screen has focus. Shift, Control and Option reach the
simulator; Command shortcuts stay with Alas. The buttons next to the screen
press Home, open the app switcher, lock the device, and start Siri. The
toolbar saves a screenshot to the Desktop and shuts the simulator down.

To run an app you built for the simulator, drop its `.app` onto the screen:
Alas installs it, replacing an installed copy, and launches it. The screen
outlines itself while the drag is one it can take; an app built for a device
is refused.

The screen keeps the device's real shape: its size and corner radius come
from Xcode's device type and DeviceKit chrome files.

Alas reads the simulator's screen directly through Xcode's private simulator
frameworks, in a helper process (`AlasSimService`). It does not need Node,
ffmpeg, or Simulator.app. A new Xcode release can break the stream until Alas
updates; the code comes from Expo's serve-sim (see
`ThirdParty/serve-sim-native/README.md`).

If the helper stops, the screen says so and Retry starts it again. If
`xcode-select` points at the Command Line Tools instead of Xcode, the tab
says simulators need Xcode.

## VMs

A VM's screen opens in a center tab. In the Devices tab, its card says
whether it is running, paused or stopped, who drives it, and opens it, or
sets it up when the worktree has none yet. A VM another Alas runs is shown
but can't be opened here.

## Agents

Agents can drive the same simulators. Turn on **Settings › Computer Use ›
Let agents use iOS simulators**. Agent sessions in a worktree then get these
tools from the built-in `alas` MCP server:

| Tool | What it does |
|---|---|
| `device_list` | Lists the iOS simulators and whether each is booted. |
| `device_open` | Boots a simulator if needed and shows it in the Devices tab of the agent's worktree. |
| `device_snapshot` | Reads the screen's accessibility elements, with refs such as `s2e3` and frames in points. |
| `device_screenshot` | Returns a PNG of the screen, at most 1280 px on the long edge. |
| `device_tap` | Taps a ref from the latest snapshot, or x/y pixels in the latest screenshot. |
| `device_swipe` | Swipes in a direction, or between two screenshot points. |
| `device_type` | Types ASCII text as key presses; `\n` presses Return. |
| `device_button` | Presses Home, Lock, Siri, the side button, or opens the app switcher. |
| `device_install` | Installs a built `.app` on a booted simulator and returns its bundle ID. |
| `device_launch` | Launches an installed app, ending a running copy first. |

While an agent works on a simulator, a pill on its screen says who is driving
and the screen ignores your clicks and keys. Take over to use it yourself. An
agent's call made while you drive waits for you to hand the simulator back,
for up to 50 seconds, and the pill says the agent is waiting; after that the
call fails with `device_user_active` and the agent tries again later. Typing
or a swipe already under way when you take over stops. With the setting off,
every call fails with `device_disabled`. An agent's calls keep the
simulator's stream running for a minute after its last call, so screenshots
work with the Devices tab closed.

Not yet: Android, physical devices, rotation, and device settings. The
follow-up list is in `docs/plans/2026-11-04-device-panel-design.md`.
