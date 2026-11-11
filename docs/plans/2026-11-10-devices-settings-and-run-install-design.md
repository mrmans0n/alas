# Devices: simulator settings, and installing apps from run scripts

## Goal

Two follow-ups from `2026-11-04-device-panel-design.md`:

1. Change a booted simulator's settings from the Devices tab, and let agents
   do the same: appearance, text size, increase contrast, privacy
   permissions, simulated location, push notifications, open URL.
2. Install and launch the app a run script builds, when the script succeeds,
   so the user gets the build → run loop agents have with `device_install`
   and `device_launch`.

## What exists

- `SimulatorControl` wraps `xcrun simctl` (list, boot, shutdown, install,
  launch); `SimulatorAppBundle` reads a `.app`; `DevicePaneModel.installAndLaunch`
  installs a dropped app and shows a pill on the screen.
- `DeviceAgentControl` runs `device_*` calls: held while the user drives (up
  to 50 s), one at a time per simulator through input turns, cancelled with
  their client.
- Run scripts carry `# alas-<key>: <value>` metadata in their first 20 lines
  (`name`, `on-exit`, `cwd`, `url`, `console`). A finished run reaches the
  app through `AppRunLauncher.runDidFinish` with its `RunRecord`, exit code,
  `RunScript` and `Worktree`.
- simctl, checked against Xcode 26.6 and iOS 26.5:
  - `ui <udid> appearance|content_size|increase_contrast` reads back
    `light`/`dark`, a size name, `enabled`/`disabled`, or `unsupported`/`unknown`.
  - `listapps <udid>` prints a plist; the user's apps have
    `ApplicationType` `User`.
  - `privacy`, `location set|clear`, `push <udid> <bundle> -` and `openurl`
    report nothing to read back.

## Decisions

- The settings live in a popover from a toolbar button, not a side panel.
- Agents get five tools for them.
- A run script's app goes to the worktree's selected simulator, else the
  first booted one, else the first one, booted. No per-script override yet.

## 1. The settings popover

- A `slider.horizontal.3` toolbar button, after the screenshot button,
  enabled while the selected simulator is booted and no agent drives it.
  The popover reads the display values each time it opens.
- **Display**
  - Appearance: a Light / Dark segmented control.
  - Text size: a stepper over simctl's twelve sizes (`extra-small` …
    `accessibility-extra-extra-extra-large`), labelled "Large",
    "Accessibility XL" and so on.
  - Increase contrast: a toggle.
  - Each control sets the value, reads it back and shows what it read. A
    setting the runtime reports as `unsupported` is disabled with a note.
- **App**: a picker of the user's apps (`listapps`, `ApplicationType`
  `User`), by display name, refreshed when the popover opens.
  - Permissions: a service menu with simctl's services (`all`, `calendar`,
    `contacts-limited`, `contacts`, `location`, `location-always`,
    `photos-add`, `photos`, `media-library`, `microphone`, `motion`,
    `reminders`, `siri`) and Grant, Revoke and Reset buttons. A line says
    what happened ("Granted Photos to Hello") and that a change may end the
    running app.
  - Push notification: a text editor prefilled with
    `{"aps":{"alert":{"title":"Hello","body":"From Alas"}}}` and Send.
    Refused before sending when it isn't a JSON object, has no `aps`
    object, or is over 4096 bytes.
- **Device**
  - Location: latitude and longitude fields, Set and Clear, and presets:
    Apple Park (37.3349, -122.0090), London (51.5072, -0.1276),
    Tokyo (35.6762, 139.6503), Barcelona (41.3874, 2.1686).
  - Open URL: a field and Open.
- simctl's error shows under the control that failed.
- State per UDID lives in `DevicePaneModel`.

## 2. Agent tools

Each tool needs a booted simulator, is held while the user drives, takes an
input turn, and shows the agent as driving.

| Tool | Arguments | Returns |
|---|---|---|
| `device_set_appearance` | `udid`; at least one of `appearance` (`light`, `dark`), `text_size` (one of the twelve names), `increase_contrast` (bool) | `{"appearance", "text_size", "increase_contrast"}` as read back |
| `device_set_permission` | `udid`, `bundle_id`, `service` (the list above), `action` (`grant`, `revoke`, `reset`) | `{"ok": true}` |
| `device_set_location` | `udid`; `latitude` and `longitude`, or `clear: true` | `{"ok": true}` |
| `device_push` | `udid`, `bundle_id`, `payload` (a JSON object with an `aps` object, at most 4096 bytes encoded) | `{"ok": true}` |
| `device_open_url` | `udid`, `url` (with a scheme, at most 4096 bytes) | `{"ok": true}` |

- The MCP server validates arguments (latitude −90…90, longitude −180…180,
  enums, payload shape); the Swift decoder checks them again.
- simctl failures return `device_settings_failed: <simctl's message>`.
  `device_set_permission` and `device_push` for an app that isn't installed
  return `device_app_not_installed: <bundle_id> isn't installed on <name>.`
  (checked with `simctl get_app_container`).
- `device_set_appearance` reports `"unsupported"` for a field the runtime
  doesn't support instead of failing.
- `device_set_permission`'s description notes that simctl may end the
  running app.
- The agent preamble adds one sentence naming the five tools, for testing
  dark mode, Dynamic Type, permissions, location, notifications and deep
  links.
- Read timeout: the usual 120 s for device calls.

## 3. Installing from a run script

- New metadata: `# alas-app: <path>`, the `.app` the script builds,
  relative to the worktree root or absolute. Parsed with the other keys
  into `RunScript.appPath: String?`.
- When a run of such a script finishes with exit code 0 in a local
  worktree, and Xcode's simulator tools were found, the app's
  `runDidFinish` hands it to the Devices code:
  1. `SimulatorTarget.choose(selection:simulators:)` (AlasCore) picks the
     worktree's selected simulator, else the first booted one, else the
     first one; nil when there are none.
  2. The worktree's `devicesSelection` becomes that simulator, its right
     pane shows the Devices tab, and the pane is made visible, as
     `device_open` does.
  3. A shut-down simulator is booted first.
  4. `DevicePaneModel.installAndLaunch` installs and launches it, with the
     screen pill ("Installing …", "Launching …", or the error).
- Failures show in that pill, not in the run's result: the run still
  succeeded. With no simulator at all, an Alas notification says so.
- If an agent drives the chosen simulator, nothing is installed and the
  pill says to take over first, as a drop is refused.
- A failed, stopped or unknown run does nothing. Remote worktrees are
  skipped: their simulators would be on another Mac.

## Code

- AlasCore (`AlasFeatures/Devices`):
  - `SimulatorSettings`: the text sizes, services and read-back parsing.
  - `SimulatorAppList.parse(_:)`: the user apps from `listapps`.
  - `SimulatorTarget.choose(selection:simulators:)`.
  - `SimulatorControl`: get and set appearance, content size and increase
    contrast; `privacy`, `setLocation`, `clearLocation`, `push`, `openURL`,
    `userApps`.
  - `DeviceCommand`: five cases, decoded in `AlasCLIRequest`.
  - `RunScript.appPath`, parsed from `alas-app`.
- App: `DeviceAgentControl` takes the settings calls through one injected
  protocol, `SimulatorSettingsControl`, with `SimulatorControl` as the
  production implementation. `DeviceSettingsPopover` and its toolbar
  button. `AppState` handles `alas-app` from `runScriptFinished`.
- Rust: definitions, parsing and requests for the five tools, and their
  names in the tool lists.

## Testing

- AlasCore:
  - read-back parsing, including `unsupported` and `unknown`;
  - `SimulatorAppList.parse` keeps only user apps;
  - `alas-app` in the existing run-script metadata suite;
  - `SimulatorTarget.choose`, parameterized;
  - `DeviceCommandTests` rows for the five tools and the arguments they
    refuse.
- App `DeviceAgentControlTests`: a settings call is held during a takeover
  and returns the read-back values; permission and push for a missing app
  return `device_app_not_installed`.
- Rust: parsing and refusals for the five tools, and the tool lists.
- Not tested: the popover, the run-script hand-off and the notification;
  checked by hand.
- End to end: each simctl action through a throwaway test on a booted
  simulator, then the user's manual pass in Alas Dev.

## Docs

- `docs/devices.md`: the popover, the five tools, and `# alas-app:`.
- `2026-11-04-device-panel-design.md`: tick the settings drawer and
  permissions/location/push/open URL items, and note run scripts on the
  install item.
