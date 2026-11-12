# Devices: simulator logs and crash reports

## Goal

See what the app under test logged, and why it crashed, without leaving
Alas: a Logs tab for the user and a `device_logs` tool for agents. Item A of
the Devices follow-ups (A logs, B clipboard and text, C small controls,
D settle-and-diff, E held calls for VMs).

## What exists, checked on iOS 26.5 / Xcode 26.6

- `simctl spawn <udid> log stream --style ndjson` prints one JSON event per
  line: `eventType`, `messageType` (`Default`, `Info`, `Debug`, `Error`,
  `Fault`), `subsystem`, `category`, `processImagePath`, `processID`,
  `timestamp`, `eventMessage`.
- It is noisy: relaunching a small app gave 715 events in five seconds from
  the app's process, nearly all from Apple subsystems (FrontBoard, CFBundle,
  UIKit), 567 of them Debug. `print`/`NSLog` lines and Swift runtime
  failures (`Fatal error: Index out of range`) have no subsystem.
- `simctl spawn <udid> log show --last <n> --style ndjson --predicate …`
  queries the archive in 2–4 s. Debug and Info lines are only archived when
  the app's logging configuration keeps them.
- A crashed simulator app's report lands in
  `~/Library/Logs/DiagnosticReports/<process>-<date>.ips` about 35 s later:
  a JSON header line (`bundleID`, `app_name`, `timestamp`), then a JSON body
  with `procPath` (contains `CoreSimulator/Devices/<udid>/`), `exception`
  (`type`, `signal`), `captureTime`, `faultingThread`, `threads[].frames[]`
  (`imageIndex`, `symbol`) and `usedImages[].name`.
- serve-sim's `AccessibilityBridge.frontmostApp(udid:)` (vendored) returns the
  frontmost app's bundle ID and pid without walking the UI; it throws when
  no app is in front. It isn't exposed through `AlasSimService` yet.
- `simctl listapps` gives each app's `CFBundleExecutable`.

## Decisions

- By default: the foreground app's own logs, Default level and above, without
  `com.apple.*` subsystems.
- The logs open in a center tab, not inside the Devices tab.
- Agents query the archive on demand; no capture state between calls.
- Crash reports are summarized in the tab and in `device_logs`.

## 1. The Logs tab

- A "Logs" toolbar button (`doc.text.magnifyingglass`) in the Devices tab,
  enabled while the simulator is booted, opens or focuses a center tab
  "Logs · <simulator name>". One per simulator per worktree; not restored
  after relaunch.
- **App picker**: Foreground app (default), one of the user's apps (from
  `listapps`), or All processes.
  - Foreground app polls `frontmostApp` every 2 s; logs are filtered by the
    app's executable name, so a relaunch keeps following it. With no app in
    front, the tab says "No app in front" and waits.
- **Filters**: a level menu (Default and above; + Info; + Debug; Errors and
  faults), an "Apple subsystems" toggle (off), and a search field. Level,
  subsystems and app restart the stream; search filters captured lines.
- **Stream**: `simctl spawn <udid> log stream --style ndjson --level <level>
  --predicate <predicate>`, parsed line by line. The last 5,000 lines are
  kept; the header says when older ones were dropped. Pause/Resume holds the
  view while lines still arrive; Clear and Copy (the visible lines as text)
  in the toolbar.
- **Rows** (monospaced): time `HH:mm:ss.SSS`, a level badge (Error and Fault
  in `del`, Default plain, Info and Debug dimmed), `Process[pid]`, faint
  `subsystem:category`, the message. The list follows new lines until the
  user scrolls up, then offers "Jump to latest".
- When the stream process exits (the simulator shut down, or simctl failed),
  a banner says logging stopped, with Restart.
- **Crash banner**: while open, the tab checks `~/Library/Logs/DiagnosticReports`
  every 5 s for `.ips` files newer than the tab whose `procPath` contains the
  simulator's UDID and, unless All processes is chosen, whose `bundleID` is
  the chosen app's. It shows "<app> crashed: <exception> in <first app
  frame>", with Open Report (opens the `.ips` with the default app, Console)
  and Dismiss.

## 2. `device_logs`

| Argument | Default | Bounds |
|---|---|---|
| `udid` | required | |
| `since_seconds` | 60 | 1–600 |
| `bundle_id` | the foreground app | ≤ 255 bytes |
| `level` | `default` | `default`, `info`, `debug`, `error` |
| `include_apple` | false | |
| `query` | none | ≤ 256 bytes, matched case-insensitively against message, subsystem and category |
| `limit` | 200 | 1–1000 |

- Runs `log show --last <since_seconds>s` with the predicate the tab uses
  (`SimulatorLogPredicate`), for the app's executable from `listapps`.
- Returns:

  ```json
  {"app": "com.example.crash",
   "lines": [{"time": "17:18:26.875", "level": "default", "process": "Crash",
              "subsystem": null, "category": null, "message": "…"}],
   "truncated": false,
   "crashes": [{"time": "17:18:26", "exception": "EXC_BREAKPOINT (SIGTRAP)",
                "frames": ["Crash AppDelegate.application(_:didFinishLaunchingWithOptions:)", "…"],
                "report": "/Users/…/Crash-2026-11-11-171903.ips"}]}
  ```

  `lines` are the newest `limit`, oldest first; `truncated` is true when
  more matched. Messages are cut at 2,000 characters. `crashes` are the
  app's reports captured in the window: up to 10 frames of the faulting
  thread as `<image> <symbol>`, starting at the first frame in the app's own
  executable, else at the top.
- Errors: `device_no_app: No app is in front on <name>. Pass bundle_id.`;
  `device_app_not_installed` for an unknown `bundle_id`; `device_not_booted`;
  `device_logs_failed: <simctl's message>`.
- Read-only: not held while the user drives and takes no input turn. Read
  timeout 120 s.
- Its description says Debug and Info lines may not be archived, and that a
  crash report appears about 30 s after the crash, so a fatal error with no
  `crashes` yet is worth a second look shortly after.

## Code

- AlasCore (`AlasFeatures/Devices`):
  - `SimulatorLog.swift`: `SimulatorLogLine` with `parse(_ json: Data)`,
    `SimulatorLogLevel`, `SimulatorLogPredicate.make(executable:level:includeApple:)`
    returning the predicate and `--level`, `SimulatorCrashReport.parse(_ data: Data, udid: String)`.
  - `SimulatorApp.executable`, from `listapps`.
  - `SimulatorControl.logShow(udid:predicate:level:seconds:)` and
    `crashReports(udid:bundleID:since:)`.
  - `DeviceCommand.logs(...)`, decoded in `AlasCLIRequest`.
- `ThirdParty/serve-sim-native/.../AlasSimulatorSession.swift` (Alas's file):
  a static `frontmostApp(udid:)` calling the vendored `frontmostApp`. No
  upstream file changes.
- `AlasSimService` and `SimServiceProtocol`: `frontmostApp(udid:reply:)`;
  `SimulatorStreamClient.frontmostApp(udid:) async throws -> String?`.
- App:
  - `Tab.simulatorLogs(SimulatorLogsTabState)` and
    `TabsManager.openOrFocusSimulatorLogs`.
  - `SimulatorLogStream`: runs `log stream`, parses lines, keeps the buffer.
  - `SimulatorLogsTabView`; the Logs button in `DevicesActions`.
  - `DeviceAgentControl` runs `.logs` as a read through an injected
    `SimulatorLogsControl` protocol (live: `SimulatorControl` plus the
    stream client's `frontmostApp`).
- Rust: the `device_logs` definition, parsing, request, and the tool lists.

## Testing

- AlasCore: parsing a trimmed real ndjson sample, including a line with no
  subsystem; the predicate at each level, with and without Apple
  subsystems; the crash summary from a trimmed `.ips` (exception, frames from
  the app's image, a report from another simulator or bundle rejected);
  `DeviceCommandTests` rows for `device_logs`.
- App `DeviceAgentControlTests`: `device_logs` isn't held during a takeover;
  the foreground app is used without `bundle_id`; `device_no_app`; `query`,
  `limit` and `truncated`.
- Rust: parsing, refusals, tool lists.
- Not tested: the tab view and the process plumbing. A throwaway end-to-end
  run on a booted simulator (a crashing app, `log show`, the crash summary,
  `frontmostApp` through the real `AlasSimService`), then the user's manual
  pass.

## Docs

- `docs/devices.md`: a Logs section (the tab, crash banners) and
  `device_logs` in the tool table.
- `2026-11-04-device-panel-design.md`: tick "Device logs".
