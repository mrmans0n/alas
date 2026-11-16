# Devices: flows and GPS routes

## Goal

The last follow-up of the device panel (`2026-11-04-device-panel-design.md`):

- **Flows:** record what you or an agent do on a device into a script in the
  worktree, by element rather than by coordinates, and replay it on any
  simulator or Android device, from the Devices tab or by an agent.
- **Routes:** move a device's simulated location along a path at a speed,
  from presets, a GPX file, or an agent's waypoints.

## Decisions

- **Flows are files**, in a subset of Maestro's YAML, in `.maestro/<name>.yaml`
  in the worktree. Alas reads, writes and runs the subset itself: Maestro need
  not be installed (it isn't on the machine this was designed on), and a flow
  Alas writes also runs under the Maestro CLI.
- Steps target elements by text or id, so a flow survives layout changes and
  works across devices; a replay stops at the first step that fails.
- **Routes** come from built-in presets, a GPX file, or `device_set_route`;
  a route stays at its last point when it ends.
- Both work on iOS simulators and Android devices, through H's
  `DeviceBackend`.

## Evidence

- `xcrun simctl location <udid> start [--speed=<m/s>] [--interval=<s>]
  <lat,lon> <lat,lon>…` plays at least two waypoints, interpolating along
  the path, with updates every second by default; `clear` stops it and
  clears the location (Xcode 26.6's `simctl location` help).
- Android's test location provider (H, `set-test-provider-location`) takes
  one point at a time; Alas moves it along the path.
- `maestro` is not on the PATH here.

## Flows

### Format (AlasCore `DeviceFlow`)

A Maestro flow: an optional header (`appId: com.example.hello`), `---`, then
a list of commands. The subset:

| Command | Meaning |
|---|---|
| `launchApp` | Launch `appId` (or `launchApp: {appId: …}`). |
| `tapOn: "Save"` / `tapOn: {id: "save"}` / `tapOn: {point: "50%,80%"}` | Tap the element with that text (exact, then contains, case-insensitive), with that id, or a point. |
| `inputText: "hello"` | Type into the focused field. |
| `eraseText: 3` | Delete characters before the cursor (50 without a count). |
| `pressKey: Home \| Back \| Enter` | A hardware button or Return. |
| `scroll` / `swipe: {direction: UP \| DOWN \| LEFT \| RIGHT}` | Scroll down, or swipe that way. |
| `assertVisible: "Done"` / `assertNotVisible: …` (text or `{id: …}`) | Wait up to 5 s for it to appear, or to be gone. |
| `openLink: "myapp://x"` | Open a URL. |
| `waitForAnimationToEnd` | Wait for the screen to settle. |

Anything else is refused when the flow is read, naming the command and its
line. AlasCore gets a small YAML reader for this subset (scalars, one-level
maps, the list of commands, quoting and comments), since it must build on
Linux without new dependencies, and a writer whose output it reads back the
same.

### Recording

- **You:** a "Record Flow" toggle in the Devices tab's toolbar, on a booted
  device. While it's on:
  - each click is matched against the latest snapshot, read again after each
    action settles (as the accessibility overlay does). It becomes `tapOn`
    with the element's label, else its id, else a point in percent;
  - typing becomes `inputText`; buttons and swipes their steps.
  Stopping asks for a name and writes `.maestro/<name>.yaml`; the header's
  `appId` is the app in front when recording started.
- **Agents:** `device_flow_record` with `action: start|stop` and `name`.
  While it's on, the session's own `device_*` calls on that device become
  steps; a tap on a ref is written by its element's label or id. `stop`
  writes the file and returns its path.

### Replay

- The toolbar's "Run Flow" menu lists `.maestro/*.yaml` of the worktree;
  agents call `device_run_flow` with `path` (in the worktree) and `udid`.
- Each step reads a fresh snapshot and finds its element, waiting up to 5 s
  for it to appear, then acts through the same paths as the `device_*` tools.
- It stops at the first failing step and reports the step number, its line
  and why ("No element with text "Save" after 5 s").
- A run is one agent call: it is held while the user drives and takes the
  device's input turns, and the stage shows "Running login.yaml · step 3 of
  9". A run you start shows its result in the toolbar's notice.
- `device_run_flow` returns `{"passed": true, "steps": 9}` or
  `{"passed": false, "failed_step": 3, "line": 7, "reason": …}`.

## Routes

- **AlasCore `DeviceRoute`:** waypoints and a speed in m/s.
  - A GPX reader: `trkpt`, else `rtept`, else `wpt` (`lat`/`lon`
    attributes); a small scanner, not `XMLParser`, so it builds on Linux.
  - Presets around Apple Park: City Walk (5 km/h), Bike Ride (18 km/h),
    Freeway Drive (100 km/h).
  - `position(after:)` for Android: distance along the path (haversine),
    linear between points, the last point past the end.
- **iOS:** `simctl location <udid> start --speed=<m/s> --interval=1
  <points…>`; `clear` stops it.
- **Android:** a route task sets the test location provider once a second at
  `position(after:)`, stopping at the last point. A new location, route or
  clear replaces it; it also stops when the device goes away or Alas quits.
- **Settings popover, Device section:** a Route menu (the presets, then "GPX
  File…"), a speed in km/h (the preset's, or 30 for a file), and Stop. While
  a route plays: "Following City Walk · 2.1 of 4.3 km" on Android, "Following
  City Walk" on iOS.
- **Agents:** `device_set_route` with `waypoints` (two or more
  `{latitude, longitude}`) or `gpx_path` (in the worktree), and `speed_kmh`
  (default 30); returns the point count, length in km and duration in
  seconds. `device_set_location` with `clear` stops a route.

## Testing

- AlasCore: the YAML reader and writer (round trip, unknown commands with
  their line, quoting, comments); element matching (exact text, then
  contains, then id); the recorder's selector choice; GPX (tracks, routes,
  waypoints, malformed points); route interpolation (start, middle, past the
  end) and length.
- App: the flow runner against H's fake backend (a passing flow, a missing
  element, a failed assertion, held while the user drives); the agent
  recorder turning calls into steps; `device_set_route` routed to each
  backend.
- Rust: the three new tools' arguments and refusals.
- End to end: record a short flow on the emulator, replay it on the emulator
  and on an iOS simulator; play City Walk on both and watch the location
  move.

## Out of scope

- Maestro's other commands (conditions, loops, JavaScript, sub-flows,
  `runFlow`), and running flows with the Maestro CLI.
- Recording timing; flows wait for elements instead.
- Routes along roads (a route is the straight lines between its points).
