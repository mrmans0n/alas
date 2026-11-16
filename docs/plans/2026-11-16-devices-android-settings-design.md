# Devices: Android settings and logs

## Goal

The user gets for Android devices what iOS simulators already have in the
Devices tab: the settings popover and the Logs tab, plus two things only
Android has here: network switches and clearing an app's data. Agents get
those two as tools. Third and last Android sub-project: G (the Devices tab,
#2528) and H (agent tools, #2545) come first.

## Decisions

- **One settings popover** over H's `DeviceBackend`, with each section shown
  where the platform supports it; no second Android popover.
- **Two new agent tools**, `device_set_network` and `device_clear_data`,
  Android only for now; iOS answers `device_unsupported`.
- **One Logs tab** over a small `DeviceLogSource` protocol with an iOS and
  an Android implementation.

## Spike evidence (Medium_Phone_API_36.1, Android 16)

- `svc wifi enable|disable` and `svc data enable|disable` switch Wi-Fi and
  mobile data. `cmd wifi status`'s first line reads "Wifi is enabled" or
  "Wifi is disabled"; `settings get global mobile_data` reads 1 or 0.
  `settings get global wifi_on` is no good for reading back: with airplane
  mode on it reads 2 or 3.
- `pm clear <package>` prints "Success" and stops the app.
- `pm list packages -3` lists third-party packages as `package:<name>`
  (none on a fresh emulator).
- `adb logcat -v threadtime -T 1 '*:W'` streams from now on, starting with
  "--------- beginning of main"; `--pid=<pid>` limits it to one process.

## Settings

- **Backend reads.** `DeviceBackend` gains `display(id)`,
  `accessibility(id)` (iOS; Android throws unsupported), `userApps(id)`,
  `network(id)` and `setNetwork(id, wifi:, data:)`, and `clearData(id,
  appID:)`. `SimulatorBackend` forwards the first three to
  `SimulatorSettingsControl` and answers unsupported for the rest.
- **Android display read.** The same commands H's `setDisplay` reads back
  with, without setting anything first.
- **Network** (AlasCore `AndroidNetwork`): Wi-Fi from `cmd wifi status`,
  data from `mobile_data`, each a `SimulatorReadBack<Bool>` (unknown when the
  output says neither).
- **Apps on Android.** `pm list packages -3`, named by package.
- **Popover.** `DeviceSettingsPopover` takes a `DeviceBackend`, the device
  id and its platform:
  - Display: both platforms.
  - Accessibility: iOS.
  - Network: Android, Wi-Fi and Mobile data switches showing what was read.
  - App: the picker and permissions on both; Push on iOS; Clear Data on
    Android, after a confirmation naming the app.
  - Device: location presets and a URL on both.
  Changes take the device's input turn, as today.
- **Toolbar.** Android's toolbar gets the settings button and the Logs
  button next to recording and the screenshot.

## Agent tools

- `device_set_network`: `udid`, `wifi` and/or `data` (booleans, at least
  one); answers `{"wifi": …, "data": …}` read back. Held while the user
  drives.
- `device_clear_data`: `udid`, `bundle_id`; `pm clear`, answering
  `{"ok": true}`; `device_app_not_installed` when the package isn't there.
  Held while the user drives.
- On iOS both answer `device_unsupported: <tool> isn't available on iOS.`
- Rust, `DeviceCommand`, the preamble's tool list and `docs/devices.md` gain
  them.

## Logs tab

- `SimulatorLogsTabView` becomes `DeviceLogsTabView` over
  `DeviceLogSource`: the front app, user apps, a live stream of
  `SimulatorLogLine`s for a source (an app, or all) at a level, and crashes
  since a time. The tab keeps its sources (the app in front, a chosen app,
  all), level, search, pause and crash banners. "Apple subsystems" shows on
  iOS only.
- **iOS source:** what the tab does today (`log stream` through
  `SimulatorLogStream`, `SimulatorForegroundTracker`, `.ips` crash reports).
- **Android source:**
  - Stream: `adb logcat -v threadtime -T 1 '*:<level>'`, plus
    `--pid=<pid>` for one app, parsed line by line with `AndroidLogcat`
    (a reader that keeps a partial line across reads).
  - The app in front: every 2 s, `AndroidLogcat.frontmostPackage` and its
    `pidof`. A new pid (the app restarted, or another came to the front)
    restarts the stream; none shows "No app in front".
  - Crashes: every 5 s, `logcat -d -b crash -T <opened>` through
    `AndroidLogcat.crashes`, as banners with the exception and first frames.
- The tab's state names the device and its platform; tabs restored after a
  relaunch keep working.

## Testing

- AlasCore: network read-back parsing; the line reader across partial
  reads; the restart decision (pid changed, app gone) as a pure function.
- App: `device_set_network` and `device_clear_data` through the control with
  H's fake backend (Android answers, iOS unsupported, held while the user
  drives).
- Rust: arguments and refusals.
- End to end on the AVD: network off and on, clear data, the popover and
  Logs tab by hand.

## Out of scope

- Airplane mode, network speed and latency shaping (`emu network`).
- Uninstalling apps.
- iOS network switches (simctl has none).
