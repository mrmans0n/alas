# Devices: flows and GPS routes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record and replay Maestro-subset flows on simulators and Android devices, and play GPS routes, for the user and for agents.

**Architecture:** AlasCore holds the flow model (a YAML-subset reader and writer, element matching, the recorder's selector choice) and routes (GPX, presets, interpolation). `DeviceAgentControl` runs a flow as one call, through the same internals as the `device_*` tools, and records an agent's calls into steps. Backends gain route start/stop. The Devices tab gets Record Flow, Run Flow and a Route section in the settings popover.

**Tech Stack:** Swift 6, AlasCore (Linux-portable), Swift Testing, Rust MCP server.

**Spec:** `docs/plans/2026-11-16-devices-flows-routes-design.md`

## Global Constraints

- English; Conventional Commits; no attribution. AlasCore: no AppKit/SwiftUI/XMLParser/new dependencies; builds on Linux.
- New app files: `xcodegen`, commit only their pbxproj hunks. `swiftformat --lint` passes. Swift Testing, no fixed sleeps.
- Flow files: `.maestro/<name>.yaml` in the worktree; element waits: 5 s; text match: exact, then contains, case-insensitive; then id.
- Run replies: `{"passed": true, "steps": N}` / `{"passed": false, "failed_step": n, "line": l, "reason": "…"}`.
- Route presets: City Walk 5 km/h, Bike Ride 18 km/h, Freeway Drive 100 km/h, around Apple Park; default speed 30 km/h.

## Review Focus

1. **A flow edited by hand with Maestro features Alas lacks** (`runFlow`, `repeat`, regexes): refused when read, naming the command and line (Task 1).
2. **Text that appears twice** ("Save" in a title and a button): the tap goes to the first control with that exact text, else the first element (Task 1 matcher test).
3. **The user takes over mid-run**: the run stops at the current step with "The user took over" (Task 4).
4. **A route started on an iOS 16 simulator**: answers that routes need iOS 17 (Task 5).
5. **A route replaced by a fixed location, or the device shutting down**: the Android route task stops (Task 5).

---

### Task 1: Flows in AlasCore

**Files:** create `Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceFlow.swift`; test `Packages/AlasCore/Tests/AlasCoreTests/DeviceFlowTests.swift`.

**Produces:**

```swift
public struct DeviceFlow: Equatable, Sendable {
    public enum Selector: Equatable, Sendable { case text(String), id(String), point(x: Double, y: Double) } // point in 0…1
    public enum Key: String, Sendable { case home = "Home", back = "Back", enter = "Enter" }
    public enum Direction: String, Sendable { case up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT" }
    public enum Step: Equatable, Sendable {
        case launchApp(String?), tapOn(Selector), inputText(String), pressKey(Key), scroll, swipe(Direction)
        case assertVisible(Selector), assertNotVisible(Selector), openLink(String), waitForAnimationToEnd
    }
    public var appID: String?
    public var steps: [Step]
    /// Each step's line in the file it was read from, for errors.
    public var lines: [Int]
    public static func parse(_ yaml: String) throws(DeviceFlowError) -> DeviceFlow
    public var yaml: String
    /// The element a selector names in a snapshot, or nil.
    public static func find(_ selector: Selector, in snapshot: DeviceSnapshot) -> DeviceElement?
    /// How the recorder names an element: its label, else its id, else the point.
    public static func selector(for element: DeviceElement?, at point: DeviceScreenPoint) -> Selector
}
public struct DeviceFlowError: Error, Equatable, LocalizedError { public let line: Int; public let message: String }
```

- [ ] **Tests:** parse a full flow (every command, both `tapOn` forms, quoted and bare strings, comments, `---` header); `yaml` round-trips to the same flow; an unknown command (`runFlow`) fails with its line and name; a malformed `point` fails; `find` prefers an exact-text control over a contains match and falls back to id; `selector(for:)` picks label, then id, then point (rounded to whole percents).
- [ ] **Implement:** a line-based reader: header lines `key: value` until `---`; then `- command` or `- command: value` or `- command:` followed by indented `key: value` lines; values unquoted or in `"…"` with `\"` and `\\` escapes; `#` comments outside quotes. The writer quotes every string. Matching: exact case-insensitive label among `isControl` elements, then any element, then label `contains`, then id equality.
- [ ] Run `swift test --package-path Packages/AlasCore --filter DeviceFlowTests`; commit `feat(devices): read, write and match Maestro flows`.

### Task 2: Routes in AlasCore

**Files:** create `Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceRoute.swift`; test `DeviceRouteTests.swift`.

**Produces:** `public struct DeviceRoute: Equatable, Sendable { public let name: String; public let points: [SimulatorLocation]; public let speed: Double /* m/s */; public static func gpx(_ text: String, name: String, speedKmh: Double) throws -> DeviceRoute; public static let presets: [DeviceRoute]; public var length: Double /* m */; public var duration: Double /* s */; public func position(after seconds: Double) -> SimulatorLocation; public func travelled(after seconds: Double) -> Double }`.

- [ ] **Tests:** GPX with `trkpt`, with only `rtept`, with only `wpt`; a point missing `lon` is refused; fewer than two points refused; `position(after: 0)` is the first point, halfway along a two-point route is the midpoint, past the end is the last point; `length` of a known pair by haversine within 1 m; presets have at least two points and their speeds.
- [ ] **Implement** with a tag scanner like `AndroidUIDump`'s; haversine with R = 6 371 000 m; presets as literal point lists around 37.3349, -122.0090.
- [ ] Commit `feat(devices): read GPX and walk a route`.

### Task 3: Commands and Rust

**Files:** `DeviceCommand.swift` (+ tests), `alas-client/src/lib.rs`, `alas/src/mcp.rs`, preamble + test.

- [ ] `DeviceCommand`: `.runFlow(udid:path:)` (`device_run_flow`, absolute `path`), `.flowRecord(udid:start:path:)` (`device_flow_record`, `action` start/stop, absolute `path`), `.setRoute(udid:waypoints:gpxPath:speedKmh:)` (`device_set_route`, exactly one of waypoints (≥2) or `gpx_path`; speed 1…500, default 30). Decoding tests and refusals.
- [ ] Rust: client variants; MCP tools — `device_run_flow` (`path`, relative to the worktree, absolutized like `app_path`), `device_flow_record` (`action`, `name` → `<worktree>/.maestro/<name>.yaml`, name `[A-Za-z0-9_-]{1,64}`), `device_set_route` (`waypoints` array of `{latitude, longitude}`, `gpx_path`, `speed_kmh`); descriptions per the spec; tests for mapping and refusals; tool lists.
- [ ] Preamble: the three tools in the list and one sentence ("Record a flow with device_flow_record and replay it with device_run_flow; play a GPS route with device_set_route.").
- [ ] Commit `feat(devices): decode the flow and route tools`.

### Task 4: Running and recording flows in the control

**Files:** `Alas/Sources/Devices/DeviceAgentControl.swift`, `AlasTests/DeviceAgentControlTests.swift`.

- [ ] **Tests** (with `FakeBackend`, whose snapshot lists a "Save" button and a "Name" field): a flow (`tapOn: "Save"`, `inputText`, `pressKey: Back`, `assertVisible: "Name"`) passes and the backend saw a touch at Save's center, the keys and Back; `tapOn: "Missing"` fails with `failed_step: 1`, its line and "No element with text "Missing" after 5 s" (the wait uses the injected sleep, so the test doesn't wait); a run is held while the user drives; recording: start, a `device_tap` on a ref, `device_type`, `device_button` back, stop → the file holds `tapOn: "Save"`, `inputText`, `pressKey: Back`.
- [ ] **Implement:** `.runFlow` reads the file, then for each step: find via `takeSnapshot` + `DeviceFlow.find`, polling 100 ms up to 5 s through `sleep`; tap at `snapshot.center(of:)`; `inputText` through `typeRuns`; keys through `backend.press` (`Enter` as HID 0x28); `scroll` as a swipe up; `swipe` by direction; `launchApp` through `backend.launch` (the flow's or the step's app id); `openLink` through `backend.openURL`; `waitForAnimationToEnd` through `settle`. Stops on the user taking over or cancellation. Counts as input (one turn for the whole run). Recording: `flowRecordings[udid] = (sessionID, path, steps, appID)`; after each successful call of that session on that device, append the step (a ref tap by its element via `DeviceFlow.selector(for:at:)`); `stop` writes `.maestro/` (creating it) and returns `{"path": …, "steps": n}`.
- [ ] Commit `feat(devices): run and record flows`.

### Task 5: Routes in the backends

**Files:** `DeviceBackend.swift`, `SimulatorBackend.swift` (`SimulatorControl.locationRoute`), `Android/AndroidBackend.swift`, `DeviceAgentControl.swift`, tests.

- [ ] Backend: `startRoute(_ id: String, _ route: DeviceRoute) async throws`, `routeProgress(_ id: String) -> (name: String, travelled: Double?, length: Double)?`. `setLocation` stops a route.
- [ ] iOS: `xcrun simctl location <udid> start --speed=<m/s> --interval=1 <lat,lon>…`; an iOS < 17 runtime (from `SimulatorDevice.runtimeName`) answers "device_unsupported: Routes need iOS 17 or later."; progress without `travelled`.
- [ ] Android: a `Task` per serial setting the test provider each second at `route.position(after:)` (the first call also allows mock location and adds the provider, as `setLocation` does), ending at the last point; replaced by a new route or location, cancelled by `clear`, by the device leaving `pane.devices`, and by `stopAll` at quit.
- [ ] Control: `.setRoute` builds the route (waypoints or GPX file), calls `startRoute`, replies `{"points": n, "km": …, "seconds": …}`; tests through `FakeBackend` (reply shape, GPX file read, a bad GPX path).
- [ ] Commit `feat(devices): play GPS routes on simulators and Android devices`.

### Task 6: The Devices tab

**Files:** `DeviceSettingsPopover.swift` (Route rows), create `Alas/Sources/Devices/DeviceFlowRecorder.swift`, `DeviceScreenView.swift` (`onTypedText`, `onTap(point)`, `onSwipe(direction)`), `DeviceStage.swift`, `Android/AndroidDeviceStage.swift`, `DevicesSwitcher.swift`, `Android/AndroidActions.swift`, `RightPaneView.swift`, `AppState+Devices.swift`.

- [ ] Popover Device section: a "Route" menu (presets, "GPX File…" with `NSOpenPanel` for `.gpx`), a speed field in km/h, Stop, and the progress line, refreshed each second while the popover is open.
- [ ] `DeviceFlowRecorder` (@Observable, per device): on start, take a snapshot through the backend; each user tap is named from the latest snapshot (`DeviceFlow.selector`), then the snapshot is read again after 1 s; typed characters merge into one `inputText`, Return becomes `pressKey: Enter`; gutter Home/Back become `pressKey`; drags longer than a quarter of the screen become `swipe`. Stop shows a name field (default `flow-<date>`) and writes `.maestro/<name>.yaml` in the worktree.
- [ ] Toolbar (both platforms): "Record Flow" toggle (red while recording) and a "Run Flow" menu listing the worktree's `.maestro/*.yaml`; running calls `deviceControl.perform(.runFlow…, sessionID: "flow:user")` and shows the result in the toolbar notice; the stage's agent name for `flow:` sessions is "Flow".
- [ ] Build; commit `feat(devices): record, run flows and play routes from the Devices tab`.

### Task 7: Docs and end to end

- [ ] `docs/devices.md`: flows (format subset, recording, running, agents' tools) and routes. Device panel design: tick the last follow-up.
- [ ] End to end through the control on the AVD and, when a simulator boots, on iOS: record a flow by agent calls in Settings, replay it; `device_set_route` City Walk, read the location twice a few seconds apart (Android: `dumpsys location`; iOS: `simctl location` has no get, so check the app-side by snapshot of Maps if available, else note it).
- [ ] Lint; commit `docs(devices): describe flows and routes`.
