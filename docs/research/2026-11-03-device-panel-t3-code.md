# Device panel: how T3 Code does it, and what it would take in Alas

Question: T3 Code shows a live iOS Simulator or Android Emulator next to a
thread, the user can tap it, and agents drive the same device. How does it
work, and can Alas do the same?

Short answer: yes. Alas is a native macOS app, so it can do the iOS part with
less machinery than T3 needs. T3 owns almost none of the hard parts. It runs
two pinned third-party tools as subprocesses: Expo's device hub for streaming
and Callstack's `agent-device` for agent control. Alas can do the same, or
replace the streaming half with a native surface.

## How T3 Code does it

Sources: [user doc][t3-user], [internals doc][t3-int].

### Components

| Concern | T3 uses | Notes |
|---|---|---|
| Discovery, boot, shutdown | `expo-device-hub` ([repo][hub]) via `simctl` / `avdmanager` / `emulator` | Behind T3's `DeviceHost` interface; local, SSH, EAS, and Simlock hosts implement it. |
| iOS video + input | `serve-sim` ([source][serve-sim-src], Apache-2.0) | Native N-API addon. Video is H.264 AVCC over HTTP, decoded with WebCodecs; input goes over a binary WebSocket. MJPEG and WebRTC fallbacks. |
| Android video + input | `serve-emu` ([README][serve-emu], Apache-2.0) | scrcpy server over adb (default), or emulator gRPC screenshots encoded with ffmpeg/libx264. H.264 and JSON gestures share one WebSocket. |
| Device settings drawer | T3's own `device.action` RPC running `simctl`, `adb`, and serve-sim helpers | Kept out of the hub on purpose (see Security). |
| Agent control | `agent-device` CLI ([README][agent-device], MIT) | Accessibility snapshots with refs; XCTest runner for iOS taps (built on first use); adb on Android. Claims a device per git worktree. |

Both tools are npm-installed at pinned versions into T3's home directory after
an explicit consent step, and run with the server's Node rather than `npx`.
The hub runs as a supervised child process because serve-sim loads private
CoreSimulator frameworks through a native addon, and a crash there must not
take down the server ([internals][t3-int]).

### How serve-sim gets iOS frames and input

From `packages/serve-sim/packages/serve-sim/Sources/SimNative` in
[expo-device-hub][serve-sim-src]:

- `SimFrameworks.swift` `dlopen`s `CoreSimulator` and `SimulatorKit` and uses
  them only through the Objective-C runtime. Xcode 27 moved SimulatorKit from
  `Developer/Library/PrivateFrameworks` to `Contents/SharedFrameworks`, so the
  helper tries both paths.
- `FrameCapture.swift` finds the `SimDevice` through `SimServiceContext`,
  registers screen callbacks on the `com.apple.framebuffer.display` port
  descriptors, and reads `framebufferSurface`, an `IOSurface`. The pipeline
  is IOSurface → `CVPixelBufferCreateWithIOSurface` (zero copy) → H.264. This
  runs headless, so Simulator.app or Device Hub does not need to be open.
- `HIDInjector.swift` builds touch, button, keyboard, and crown messages with
  the `IndigoHIDMessageFor*` C functions (`dlsym`) and sends them through
  `SimulatorKit.SimDeviceLegacyHIDClient`.

This is private API. Expo runs CI against the iOS 26 and iOS 27 Simulators
and builds nightly with Xcode 27 ([hub README][hub]), which shows how much
upkeep it takes.

### Agent surface

T3 keeps the MCP surface to four tools: `device_list`, `device_open`,
`device_screenshot`, `device_close`. Agents drive the device through the
`agent-device` CLI, which T3 puts on the agent's PATH through a shim
directory ([internals][t3-int]). Design points worth copying:

- Instructions for driving the device come back in the `device_open` result,
  not in an always-loaded prompt, so threads that never open a device pay
  nothing.
- `device_open` returns a launcher bound to its agent-device session, so
  agents never pass target flags. The launcher refuses commands that would
  replace T3's connection.
- The CLI has to be on PATH when the provider subprocess spawns. T3 starts it
  in `prepareMcpSession` only when the user has allowed agent access.
  Restarting the session after granting access is required.
- When an agent opens a device, the device floats over the chat, as an
  agent-driven browser does.

### Security

serve-sim has a shell-exec route whose token is readable from its own
unauthenticated `/api`, and serve-emu's action routes have no auth. T3 binds
the hub to loopback and reaches it only through an allowlisting,
authenticating proxy. Settings actions are typed RPCs rather than proxied
exec ([internals][t3-int]).

## What Alas already has

Mapped from the current tree:

- **Right pane**: `ThreePaneLayout` plus `RightPaneView`, with a fixed registry
  `RightPaneTab` (`.changes`, `.files`, `.agent`, `.run`, `.schedules`). A
  `.device` case means updating the exhaustive switches in `RightPaneView`,
  `RightPaneRail`, `RightPaneRailModel`, and `RightPaneLoadingSkeletonView`.
  `RightPaneState` is scoped to the worktree.
- **Web preview** is a center tab (`Tab.webPreview`, `WebPreviewBrowser`
  wrapping `WKWebView`), not a side pane. T3's side-by-side layout needs the
  right pane.
- **Built-in MCP**: tools are hardcoded in `AlasCLI/crates/alas/src/mcp.rs` and
  travel as `alas_client::Command` → `AlasCLIRequest.Command` →
  `AlasCLICommandRouter` → `AppState.makeCLICommandRouter()`. `SessionOwnerID`
  scoping (used by `WebPreviewAutomationService`) is how a panel and an
  agent's tools would resolve to the same device.
- **Precedent for shared user and agent control**: VM support
  (`VMDisplaySurface` wrapping `VZVirtualMachineView`, `VMGuestService`)
  shields user input while the agent drives and tracks user takeover. A device
  panel needs the same behavior.
- **Computer use** (`ComputerUseKit`): ScreenCaptureKit one-shot screenshots,
  AX inspection, and CGEvent/SkyLight input. No continuous capture, video
  encoding or decoding, or `AVSampleBufferDisplayLayer` exists in the app
  today.
- **Pinned npm installs**: `ACPRegistryInstaller` already stages
  `npm install --prefix` into a private directory and resolves the package
  bin. The same code can install pinned `agent-device` / hub versions.
- **Per-project config**: `.alas/scripts` run scripts and `ProjectConfig`
  (which has VM settings) are where a default device or launch command would
  go.
- Nothing in the app uses `simctl`, `adb`, CoreSimulator, or scrcpy today.

## Options for Alas

### A. Reuse the hub and show it in a web view (closest to T3)

Supervise a pinned `expo-device-hub` (or `@expo/serve-sim` plus `serve-emu`)
on loopback, and show a small page built on `@expo/hub-client` in a
`WKWebView` hosted by a new `RightPaneTab.device`.

- Pros: Expo maintains the iOS and Android capture and input code and its
  Xcode churn. Both platforms ship at once. Settings toggles, foldables, and
  WebRTC come with it.
- Cons: Alas would require Node or Bun at runtime. Alas would inherit the
  hub's auth problems: it needs a proxy or tokened access like T3's, or else
  any local page or process that can reach the port can run shell commands.
  `WKWebView` decoding is not a concern; see Spike results.

### B. Native surface on iOS, a pinned tool on Android

- iOS: an out-of-process helper (a separate binary or XPC service, for crash
  isolation like T3's) loads SimulatorKit, follows serve-sim's approach to get
  the framebuffer `IOSurface`, and passes it to the app as a mach port
  (`IOSurfaceCreateMachPort`). The app sets it as `CALayer.contents`. There is
  no encode and no decode, which gives the lowest latency and a native-feeling
  panel. Input goes through the helper as IndigoHID messages.
- Android: emulator gRPC (`streamScreenshot`, `sendTouch`, `sendKey`) or
  scrcpy H.264 decoded with VideoToolbox into `AVSampleBufferDisplayLayer`.
  The quicker path is to keep `serve-emu` for Android at first.
- Pros: best UX. No Node needed for the iOS view. Fits the
  `VMDisplaySurface` pattern.
- Cons: Alas owns private-API upkeep for every Xcode release. serve-sim's
  `FrameCapture.swift` alone is 836 lines of recovery logic: surface loss,
  re-wiring, multiple displays. App Store distribution would be ruled out;
  Alas ships Developer ID builds, so this is not a blocker today.

### C. Hybrid: native view on top of serve-sim's stream

Run serve-sim as the backend, decode its AVCC H.264 with VideoToolbox into
`AVSampleBufferDisplayLayer`, and send input over its WebSocket. The panel is
native without Alas owning SimulatorKit code, but Alas depends on serve-sim's
wire format, which is not a published API.

### Agent side (same for every option)

Do as T3 does:

1. Add `device_list`, `device_open`, `device_screenshot`, and `device_close` to
   the built-in `alas` MCP server, scoped by `SessionOwnerID`. That means
   changes in `mcp.rs`, `alas-client`, `AlasCLIRequest`,
   `AlasCLICommandRouter`, and `AppState`.
2. Install a pinned `agent-device` through the staged npm installer, and put a
   launcher bound to the session on the ACP agent's PATH when it spawns,
   gated by a setting like **Agents can use devices**.
3. Return the driving instructions from `device_open`.
4. Reuse the VM driver-ownership model so the panel shows when the agent is
   driving and the user can take over.

Writing native semantic snapshots and XCTest-based taps instead of using
`agent-device` would be a separate large project with no clear payoff.

### Baseline that works today

An agent can already use `computer_*` on the Simulator window, and a user can
install `agent-device` and have the agent call it from the shell. Xcode 27
replaces Simulator.app with Device Hub ([Expo blog][expo-blog]). Whether
computer-use works well against Device Hub's window has not been checked
[INFERENCE].

## Recommendation

Superseded on 2026-11-04: Alas goes without Node (see "Without Node"
below). The design is `docs/plans/2026-11-04-device-panel-design.md`; phase
1 is planned in `docs/plans/2026-11-04-device-panel-phase1-implementation.md`.

Decided after discussion: ship the feature with Alas rather than as a plugin
(the plugin API has no loopback network for pages, no MCP tool contribution,
and no agent environment control), off by default, in the right pane, iOS
first.

## Without Node (2026-11-04)

Follow-up question: can both platforms work without Node? Not with the
published Expo tools. `@expo/serve-sim` 0.13.1 has `"bin": "dist/serve-sim.js"`,
`"engines": {"node": ">=20"}`, and its capture code is a Node-API addon
(`dist/native/serve-sim-native.node`). There is no standalone binary.
`serve-emu` needs Bun 1.3.13+ and lists "compiled single binary" as planned
([README][serve-emu]). `agent-device` needs Node 22.12+.

Every piece has a native replacement:

| Piece | Native replacement | Cost |
|---|---|---|
| iOS video + input | An Alas helper process built from serve-sim's Swift sources (Apache-2.0, keep its NOTICE): `FrameCapture` for the framebuffer `IOSurface`, `HIDInjector` for IndigoHID input. The helper sends the `IOSurface` to the app as a mach port, and the app sets it as a `CALayer`'s contents. No encoding or decoding. | Alas owns private-API upkeep. Those two files alone are 836 and 892 lines. Leave out camera, network capture, WebRTC, and recording. |
| iOS snapshot for agents | serve-sim's `AccessibilityBridge.swift`, which uses the private `AXPTranslator` from the same helper | Same upkeep as above. |
| Android video + input | Ship the pinned `scrcpy-server` (Apache-2.0, v5.0.1, 734 KB) in the app bundle, push it with `adb`, read its H.264 socket, decode with VideoToolbox into `AVSampleBufferDisplayLayer`, and send touch and keys over its control socket. scrcpy documents the protocol for third-party clients ([develop.md][scrcpy-dev]). | The client must match the server version exactly, which pinning handles. Users need `adb`, which Android developers already have. No ffmpeg. |
| Android snapshot for agents | `adb shell uiautomator dump` | Slower than agent-device's helper, roughly a second per snapshot [INFERENCE]. |
| Agent control | Native `device_*` tools in the built-in `alas` MCP server, shaped like `computer_inspect` / `computer_click`: a snapshot with refs, then tap, type, swipe, button, screenshot | We lose agent-device's settle diffs, replay scripts, Metro/Expo integration, and cloud devices. Users who want those can still install agent-device themselves; Alas would not manage it. |

Rejected: building serve-sim into a self-contained Bun executable ourselves.
It removes the user's Node install but bundles a JS runtime and an
unpublished build into Alas, which is the same dependency in another form.

Going without Node is the better fit for a native app: the iOS view needs
no encoding at all, and Alas already uses private SkyLight calls for computer
use. In exchange, Alas carries the SimulatorKit code through every Xcode
release (Xcode 27 already moved `SimulatorKit.framework`), and the agent
tools start out simpler than agent-device.

## Spike results (2026-11-03)

Throwaway run on Xcode 26.6, iOS 26.5 Simulator (iPhone 17 Pro), Node 26.13,
`@expo/serve-sim` 0.13.1, `agent-device` 0.21.36. Nothing was added to the
repo.

**Stream in Alas's WKWebView: works, H.264 via WebCodecs.**

- `serve-sim --single-device <udid> -p 3290 --codec h264` on loopback, opened
  with `preview_open` in Alas's real web preview, painted the live screen.
- A standalone probe with the same `WKWebViewConfiguration` as
  `WebPreviewBrowser` (non-persistent store, nothing else) reported
  `isSecureContext: true`, `VideoDecoder` present,
  `isConfigSupported(avc1.640033)` true, and two decoders configured as
  `avc1.640033:prefer-hardware`. No MJPEG `<img>` was used.
- Decoded rate: about 5 fps on a static screen (serve-sim's idle floor), and
  35 decoded frames in the first second while Settings opened.
- serve-sim logged `Framebuffer: 1206x2622 (direct IOSurface, zero-copy)`,
  which confirms the SimulatorKit path described above.

**Input from the page: responsive while visible.**

- AppKit mouse events sent to the probe window over the canvas opened
  Settings. The first changed decoded frame came 173 and 188 ms after the
  click (a first cold trial took 824 ms). This is an upper bound on the
  pipeline: it includes iOS's own launch animation reaching a 2% pixel change.
- The page's Home button: 410 to 503 ms to a changed frame, which mostly
  reflects the slower home animation.
- After the Mac's screen locked, the page reported
  `visibilityState: "hidden"`. Video kept decoding at the idle rate, but
  clicks and the Home button no longer reached the device. Not rechecked
  once the screen was unlocked; a hidden panel should not need input anyway.
- Keyboard typing from the page was not tested.

**`agent-device` drives the same simulator: works.**

- `open Settings --platform ios --udid <udid> --foreground`: 3.5 s, returned
  an accessibility snapshot with refs.
- First `press @e8 --settle`: 9.2 s. The doctor had already started the
  XCTest runner build in the background, so a cold machine would take longer.
  Warm: `back --settle` 1.4 s, `fill 'role=search' "Keyboard" --settle`
  2.9 s.
- The result showed up live in the Alas web preview, which is the
  user-and-agent loop we need.
- Sessions are keyed by cwd hash plus platform (`cwd:<hash>:ios`). A
  follow-up command without `--platform ios` failed with `SESSION_NOT_FOUND`.
  Alas should bind the session through the environment it gives the agent at
  spawn: `AGENT_DEVICE_SESSION`, `AGENT_DEVICE_PLATFORM`, and
  `AGENT_DEVICE_STATE_DIR` (under Alas's own state, not `~/.agent-device`).
  `startAgentDevice({ stateDir })` is also available for embedding.
- When serve-sim pressed Home while an agent-device session was open, the
  next `snapshot` brought the session's app back to the foreground
  (`stale_target`). The agent takes the device back without asking, so the
  panel needs explicit driver ownership (agent driving or user took over),
  like the VM tab has.

**Security, confirmed:** serve-sim's unauthenticated `GET /api` returns
`execToken`, the token for its shell-exec route. Any local process can read
it, so Alas must start the hub with `--require-token` or put a proxy in
front, as T3 does.

**Not covered:**

- Xcode 27 / Device Hub: this machine has Xcode 26.6.
- Truly headless capture: Simulator.app was already running, so it attached a
  window to the spike device. serve-sim captures from SimulatorKit, not from
  that window.
- Android.

[t3-user]: https://github.com/pingdotgg/t3code/blob/main/docs/user/devices.md
[t3-int]: https://github.com/pingdotgg/t3code/blob/main/docs/internals/devices.md
[hub]: https://github.com/expo/expo-device-hub
[serve-sim-src]: https://github.com/expo/expo-device-hub/tree/main/packages/serve-sim
[serve-emu]: https://github.com/expo/expo-device-hub/blob/main/packages/serve-emu/README.md
[agent-device]: https://github.com/callstack/agent-device
[expo-blog]: https://expo.dev/blog/xcode-27-device-hub-expo-device-hub
[scrcpy-dev]: https://github.com/Genymobile/scrcpy/blob/master/doc/develop.md
