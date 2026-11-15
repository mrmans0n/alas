# Devices: Android in the Devices tab

## Goal

Show Android emulators and connected phones in the Devices tab next to iOS
simulators: list them, boot an AVD, stream its screen and drive it with the
mouse and keyboard. Phase 3 of the device panel
(`2026-11-04-device-panel-design.md`), first of three Android sub-projects:

- **G** (this): Android in the Devices tab, for the user.
- **H**: the `device_*` agent tools on Android, with take over and hand back.
- **I**: Android settings and tools (dark mode, font scale, network,
  location, permissions, clear data, logcat).

GPS route playback and session record/replay are decided after I.

## Decisions

- Emulators and connected phones both show. Only AVDs can be booted.
- Alas boots an AVD headless; the screen lives in the Devices tab.
- Shut Down stops an emulator (`adb emu kill`). A phone has nothing to shut
  down, so its toolbar has no Shut Down.
- The scrcpy client is written in Swift, in the app (approach A). The SDK's
  `adb` and `emulator` are the user's; Alas bundles only `scrcpy-server`.
- Beyond the screen and input, G includes rotate, ⌘C/⌘V, screenshot, screen
  recording and installing a dropped `.apk`.

## Spike evidence (Medium_Phone_API_36.1, Android 16, 1080×2400)

- `emulator -avd … -no-window -no-audio -no-boot-anim` cold-boots in about
  20 s and logs "Boot completed"; `sys.boot_completed` turns 1 then.
- `scrcpy-server` v5.0.1 is 734 KB and matches the release's `SHA256SUMS.txt`
  (`764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536`).
- With `tunnel_forward=true`, `adb forward` accepts connections before the
  server listens; the client connects and reads until the dummy byte
  arrives (9 tries, about 1 s). Then: the device name (64 bytes), codec id
  `h264`, a 12-byte session packet (720×1600 at `max_size=1600`), a 32-byte
  config packet (SPS and PPS), and the first key frame 2.1 s after start.
- Rotating the device sends a new session packet (1600×720).
- VideoToolbox decodes the key frame (SPS/PPS → `CMVideoFormatDescription`,
  Annex B → AVCC, `VTDecompressionSession`) to a 720×1600 image.
- A Back keycode (14-byte message) takes Settings to the launcher; a tap
  (32-byte message, in the video's size) opens a Settings row. A touch whose
  screen size isn't the current video size is dropped.
- `cleanup=true` deletes the pushed server when it exits, so every start
  pushes it again. A client that dies leaves server processes waiting on the
  device; they need killing before the next start.

## Discovery and lifecycle

- **SDK.** AlasCore's `AndroidSDK` finds `adb` and `emulator` in
  `$ANDROID_HOME`, then `$ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`,
  then `PATH`. Without them the Android section shows "Install Android Studio
  or the SDK command-line tools to use Android devices."
- **Devices.** `adb devices -l` gives serial, state (`device`,
  `unauthorized`, `offline`) and model. `emulator -list-avds` lists AVDs;
  `adb -s emulator-NNNN emu avd name` maps a running emulator to its AVD, so
  a booted AVD shows once. Polled while the tab is visible, like simulators.
- **Tab.** `DevicesTarget` gains `.android(String)`: a serial for a
  connected device, `avd:<name>` for an AVD that isn't running. The switcher
  gets an "Android" section after Simulators ("Pixel 9 · Android 16",
  "Medium Phone API 36.1 · Shut down"). `DevicesTabState.resolve` gains
  Android rows and stages: booted, booting, shut down, unauthorized
  ("Allow USB debugging on the phone", with Retry), offline.
- **Boot.** `emulator -avd <name> -no-window -no-audio -no-boot-anim`,
  started detached so it outlives Alas, as simulators do. Alas waits for the
  device and `sys.boot_completed`; a failed boot shows the emulator's last
  log lines.
- **Shut down.** The toolbar's ⋯ menu, for an emulator: Shut Down runs
  `adb -s <serial> emu kill` and selects the AVD's row again.
- **Agents.** None in G: no driver pill on Android until H.

## Streaming

- **Server.** `scripts/fetch-scrcpy-server.sh` (pre-build, like
  `fetch-cua-driver.sh`) downloads `scrcpy-server-v5.0.1` and checks the
  SHA-256 above. The embed step copies it, with scrcpy's Apache-2.0 LICENSE,
  to `Contents/Resources/scrcpy/`. It is a jar for the device, not Mac code,
  so release signing skips it.
- **One stream per device**, while its screen is shown:
  1. Kill leftover servers: `adb shell pkill -f com.genymobile.scrcpy.Server`.
  2. `adb push` the server to `/data/local/tmp/alas-scrcpy-server.jar`.
  3. `adb forward tcp:0 localabstract:scrcpy_<scid>` (a free local port;
     `scid` is a random 31-bit number).
  4. `adb shell CLASSPATH=… app_process / com.genymobile.scrcpy.Server 5.0.1
     scid=<scid> tunnel_forward=true audio=false control=true max_size=1600
     clipboard_autosync=false`.
  5. Connect the video socket, reconnecting until the dummy byte arrives
     (10 s limit), then the control socket.
  Hiding the screen closes the sockets, ends the server process and removes
  the forward.
- **Wire format (AlasCore).** A stream parser fed from partial reads: codec
  id, session packets (size), frame headers (config, key frame, PTS, size).
  Control encoders: touch, keycode, scroll, back-or-screen-on, set and get
  clipboard. A device-message decoder for the clipboard reply.
- **Decoding (app).** The config packet's SPS/PPS becomes a
  `CMVideoFormatDescription`; packets go from Annex B to AVCC and through a
  `VTDecompressionSession`. The pixel buffers feed the screen's
  `AVSampleBufferDisplayLayer`, as simulator frames do. A new session (a
  rotation) rebuilds the format and the session.
- **Screen view.** `DeviceScreenView` works through a `DeviceScreenSource`
  protocol (subscribe to frames, touch, key, button) that
  `SimulatorStreamClient` and the new `AndroidStreamClient` both adopt, so
  clicks, drags, keys, focus and drops stay one implementation. Android
  frames are already upright: the geometry is the video's size, portrait.
- **Stage shape.** The first session's aspect ratio with rounded corners;
  Android has no per-model shapes.

## Input

- Click and drag: touch down, move and up, in the current video size.
- Scroll wheel: a scroll event.
- Keys: the HID usages iOS uses, mapped to Android keycodes, with metastate
  for Shift, Control and Option (an AlasCore table).
- The gutter: Back, Home, Recents, Power, Volume up and down, Rotate left
  and right.

## Tools

- **Rotate.** `adb shell cmd window user-rotation lock <0–3>`, from the
  current rotation. The next stream session carries the new size; the
  screen re-fits.
- **⌘V.** Set-clipboard with `paste=true`: the Mac's text goes to the device
  and is pasted into the focused field.
- **⌘C.** Get-clipboard with the COPY key: the device copies and answers with
  a clipboard message, waited for up to 2 s as on iOS.
- **Screenshot.** `adb exec-out screencap -p` to
  `Android Screenshot <date>.png` on the Desktop.
- **Record.** `adb shell screenrecord --time-limit 180
  /sdcard/alas-<id>.mp4`. Stop sends it SIGINT; Alas pulls the file to the
  Desktop and deletes it from the device. At the 3-minute limit it stops by
  itself and is saved the same way.
- **Drop an `.apk`.** `adb install -r -t`, then launch: the package comes
  from `aapt2 dump packagename` (the SDK's newest build-tools), the launch
  from `adb shell monkey -p <package> -c android.intent.category.LAUNCHER 1`.
  Without build-tools it installs and says "Installed; open it from the
  launcher." The install pill shows progress and failures, as on iOS.

## Errors

- A lost stream (server died, phone unplugged): "The screen stopped" with
  Retry; the detail carries the server's last log lines.
- An unauthorized phone: "Allow USB debugging on the phone", with Retry.
- No SDK: the Android section's note.

## Testing

- AlasCore: `adb devices -l` and AVD parsing, the running-AVD mapping; SDK
  path order; the stream parser (split reads; session, config, key and P
  packets); the control encoders against scrcpy's own byte vectors
  (`app/tests/test_control_msg_serialize.c` at v5.0.1); the clipboard
  decoder; the key table; rotation math.
- App: `DevicesTabState` Android rows and stages (its existing suite); the
  connect-until-dummy-byte loop with an injected connector.
- No device in CI. An end-to-end pass on the AVD, with screenshots, before
  the PR.

## Out of scope

- Agent tools (H); settings, logcat and the rest of I.
- Audio forwarding, camera mirroring, multiple displays.
- Per-model device frames.
