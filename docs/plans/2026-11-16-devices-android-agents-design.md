# Devices: agent tools on Android

## Goal

Agents drive Android emulators and phones with the same `device_*` tools
they use on iOS simulators, with held calls, take over and settle-and-diff
working the same way. Second of three Android sub-projects: G (Android in
the Devices tab, #2528) is merged; I (Android settings and tools for the
user) follows. H also carries I's agent half: appearance, permissions,
location and logs.

## Decisions

- **Same tools.** No `android_*` tools. `device_list` lists both platforms
  with a `platform` field; the other tools take a simulator UDID or an
  Android serial in `udid`. Tools that don't apply answer
  `device_unsupported: <tool> isn't available on Android.`
- **Scope.** Driving and apps (list, open, snapshot, screenshot, tap,
  swipe, type, button, install, launch, open_url, clipboard, rotate,
  record) plus set_appearance, set_permission, set_location and logs.
  push and set_accessibility are unsupported on Android.
- **Settle-and-diff on by default**, as on iOS, even though a snapshot
  costs about 2 s on Android. An on-device accessibility helper APK for a
  faster tree is a follow-up if that proves too slow.
- **One control, a platform backend** (approach A): `DeviceAgentControl`
  keeps held calls, take over, input turns, leases, settle, diffs and refs;
  a `DeviceBackend` protocol carries everything platform-specific.

## Spike evidence (Medium_Phone_API_36.1, Android 16, 1080×2400, 420 dpi)

- `adb exec-out uiautomator dump /dev/tty` prints the window's tree as XML
  in 2.0–2.2 s (12 KB for Settings): `node` elements with `text`,
  `resource-id`, `class`, `content-desc`, `clickable`, `enabled`,
  `password`, `bounds="[x1,y1][x2,y2]"` in pixels, and a trailing
  "UI hierchary dumped to: /dev/tty" line after `</hierarchy>`.
- `wm density` reports 420 (dp = px × 160 / 420).
- `cmd uimode night yes|no` sets dark mode; `cmd uimode night` reads it
  ("Night mode: yes").
- `settings put|get system font_scale` sets and reads the text scale;
  `settings put|get secure high_text_contrast_enabled` the high-contrast
  text.
- `pm grant|revoke <package> android.permission.RECORD_AUDIO` change a
  runtime permission.
- `logcat -d --pid=<pid> -v threadtime -t <n>` reads an app's lines;
  `logcat -d -b crash` reads the crash buffer.
- `am start -W -a android.intent.action.VIEW -d <url>` opens a URL
  ("Status: ok").
- Location: `emu geo fix` reaches the emulator but no reading changes while
  no app listens. The test provider does change it, and works on phones:
  `appops set com.android.shell android:mock_location allow`,
  `cmd location providers add-test-provider gps`,
  `set-test-provider-enabled gps true`,
  `set-test-provider-location gps --location 41.3874,2.1686` made
  `dumpsys location` report `gps 41.387400,2.168600 … mock`.
  `remove-test-provider gps` clears it.
- scrcpy's inject-text message: type 1, a u32 length, UTF-8 text (18 bytes
  for "hello, world!", from scrcpy v5.0.1's test vectors).

## Architecture

- **`DeviceBackend`** (app, `@MainActor` protocol). What
  `DeviceAgentControl` does per platform today:
  - `devices() async throws -> [AgentDevice]`. `AgentDevice` (AlasCore):
    id, name, platform (`ios`, `android`), state (`booted`, `booting`,
    `shutdown`, `unauthorized`, `offline`), runtime ("iOS 26.5",
    "Android 16").
  - `boot(id) async throws -> String`: the id to use afterwards (an AVD
    comes back as its emulator's serial).
  - Input: `touch`, `key`, `text`, `button(name) -> Bool` (false for a
    button the platform lacks).
  - `describe(id) async throws -> DeviceSnapshot` (parsed per platform),
    `lastFrame(id)`, `rotate(id, to:)`.
  - Apps: `install(id, path) -> (appID, name)`, `launch(id, appID) -> pid`,
    `isInstalled`, `openURL`.
  - Clipboard read and write; settings, permissions, location, push and
    logs, each able to answer unsupported; `startRecording(id, file)`.
  - `hold(id)` / `release(id)`: what a lease keeps open (Android: a stream
    subscription; iOS: nothing).
- **`SimulatorBackend`** wraps what the control calls today: `simctl`, the
  XPC input, `SimulatorSettingsControl`, `SimulatorLogsControl`,
  `DevicePasteboard`, `LiveScreenRecording`. iOS behaviour doesn't change.
- **`AndroidBackend`** uses `AndroidControl` and `AndroidStreamClient`
  from G.
- **Routing.** The control lists every backend and routes a call by the id
  it names. Everything else stays keyed by id.
- **Agent streams.** While an agent holds an Android device (its lease),
  the control keeps a subscription on `AndroidStreamClient`, so input has a
  control socket and settle and screenshots have frames, whether or not
  the Devices tab shows it.
- **Take over.** The Android stage gets the driver pill, Take over and Hand
  back; clicks and keys are blocked while an agent drives, as on iOS.
- **Setting.** The existing "let agents use iOS simulators" setting covers
  Android too and is renamed "let agents use simulators and Android
  devices"; `ALAS_MCP_DEVICES` keeps its meaning.

## The tools on Android

- **list.** Ready devices by serial (`booted`); AVDs that aren't running as
  `avd:<name>` (`shutdown`); unauthorized and offline phones with that
  state, refused by the other tools (`device_not_ready`).
- **open.** Boots an AVD headless and returns its serial in `udid`, with
  a note to use it from then on.
- **snapshot.** `uiautomator dump`, parsed in AlasCore into
  `DeviceSnapshot`:
  - role from the class's last component, lowercased and spaced
    (`android.widget.Button` → "button", `EditText` → "edit text");
  - label from `text`, else `content-desc` (a password field's text is
    left out); id from `resource-id`;
  - frames in dp; `isControl` for clickable, checkable or editable nodes;
  - nodes with nothing to name and no action are skipped, as on iOS.
  Settle and diff work unchanged.
- **screenshot, tap, swipe.** Through the stream, as on iOS. Coordinates are
  the latest screenshot's pixels.
- **button.** `home`, `app_switcher`, `lock` and `side_button` (both
  Power), and the new `back`, `volume_up` and `volume_down`; `siri` answers
  `device_unsupported`. On iOS the new three answer `device_unsupported`.
- **type.** scrcpy's inject-text for ASCII; a clipboard paste (set-clipboard
  with paste) for the rest, then the previous clipboard is restored.
- **install, launch.** An `.apk` path; the package is the app id (from
  `aapt2`; without build-tools, install works but launch needs the package
  the agent knows). launch ends a running copy (`am force-stop`), starts the
  launcher activity and returns `pidof`'s pid.
- **open_url.** `am start -W -a android.intent.action.VIEW -d <url>`.
- **clipboard.** scrcpy's get and set clipboard.
- **rotate.** `cmd window user-rotation lock <n>`.
- **record.** G's `screenrecord` recording through `DeviceRecorder`, capped
  at 3 minutes by Android.
- **set_appearance.** Dark mode with `cmd uimode night`; text size to
  `font_scale` through one table, read back through the same table (a value
  outside it reads `unknown`); increase contrast to
  `high_text_contrast_enabled`.

  | text_size | font_scale |
  |---|---|
  | extra-small | 0.85 |
  | small | 0.9 |
  | medium | 0.95 |
  | large | 1.0 |
  | extra-large | 1.1 |
  | extra-extra-large | 1.2 |
  | extra-extra-extra-large | 1.3 |
  | accessibility-medium | 1.5 |
  | accessibility-large | 1.7 |
  | accessibility-extra-large | 1.8 |
  | accessibility-extra-extra-large | 1.9 |
  | accessibility-extra-extra-extra-large | 2.0 |

- **set_permission.** iOS's service names mapped to runtime permissions:
  `location` → fine and coarse location; `location-always` → those plus
  background location; `contacts` → read and write contacts; `calendar` →
  read and write calendar; `photos` → read media images; `media-library` →
  read media audio; `microphone` → record audio; `motion` → activity
  recognition; `all` → every one of these the app requests. Others
  (`contacts-limited`, `photos-add`, `reminders`, `siri`) answer
  `device_unsupported`. grant and revoke are `pm grant|revoke`; reset
  revokes and clears the user-set and user-fixed flags.
- **set_location.** The test provider, on emulators and phones; clear
  removes it.
- **logs.** `logcat -d -v threadtime --pid=<pid>` for the app (the one in
  front by default, from `dumpsys activity activities`), lines newer than
  `since_seconds`, at `level` and above, matching `query`; with the app's
  crashes from `logcat -b crash`. `include_apple` is ignored on Android.
- **push, set_accessibility.** `device_unsupported`.
- **Text.** Tool descriptions, the preamble and the settings say
  "simulators and Android devices"; `udid` is described as "a simulator
  UDID or an Android serial".

## Testing

- AlasCore: `uiautomator` XML parsing (roles, labels, password text, dp
  frames, controls, the trailing line), font-scale mapping both ways,
  permission mapping, logcat line parsing, the inject-text encoder (scrcpy's
  vector), `AgentDevice` JSON.
- App: `DeviceAgentControlTests` moves from `FakeInput` and `FakeSettings`
  to one `FakeBackend`; its scenarios stay, plus Android cases: a call
  routed by serial, `device_open` on an AVD returning the serial, an
  unsupported tool, a lease holding the Android stream.
- Rust: tool descriptions and the new button names.
- End to end on the AVD with a throwaway test: list, open, snapshot, tap a
  ref, type, set appearance, grant a permission, set a location, read logs.

## Out of scope

- An on-device accessibility helper (a faster tree).
- TalkBack and Android accessibility settings for agents.
- Settings UI for Android (I).
