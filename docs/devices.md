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

Not yet: agent control, Android, physical devices, rotation, and device
settings. The follow-up list is in
`docs/plans/2026-11-04-device-panel-design.md`.
