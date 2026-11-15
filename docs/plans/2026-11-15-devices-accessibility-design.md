# Devices: accessibility settings and overlay

## Goal

Let the user and agents turn a simulator's accessibility settings on and
off, and let the user see what the accessibility tree says about the screen
without leaving Alas. This is the first item of the device panel's remaining
follow-ups ("VoiceOver, reduce motion and an accessibility overlay").

## What exists

- `simctl ui` covers appearance, text size and increase contrast. Alas has
  them in the settings popover (`DeviceSettingsPopover`) and as
  `device_set_appearance`, through `SimulatorSettingsControl` /
  `LiveSimulatorSettings` (AlasCore) and `SimulatorDisplaySettings`, whose
  values are read back after every change.
- `simctl ui` does not cover VoiceOver, reduce motion and the rest.
  serve-sim's `Sources/SimAXSettings/sim-ax-settings.m` does: a CLI built for
  the simulator and run inside it with `simctl spawn`. It calls the same
  private libAccessibility and MediaAccessibility setters Xcode's Devices
  window uses, which also post the notifications running apps listen to.
- The element tree: `SimulatorStreamClient` asks the session to `describe`
  the screen. `DeviceSnapshot` parses it into elements with role, label,
  value, id and an upright frame in points. Elements of its
  `interactiveTypes` are kept even without a label.

## Spike evidence (iPhone 17, iOS 26.5)

- `sim-ax-settings status` prints
  `{"reduce-motion":"off","show-borders":"off","reduce-transparency":"off","voiceover":"off","color-filter":"none","liquid-glass":"clear"}`
  in about 0.7 s through `simctl spawn`. `set reduce-motion on` reads back as
  `on`.
- `set voiceover on` turns VoiceOver on: its cursor appears and a one-time
  "VoiceOver Gestures" sheet shows. `set voiceover off` turns it off.
- Signed with the hardened runtime (as the release script signs embedded
  executables), the helper aborts: `dyld: DYLD_ROOT_PATH not set for
  simulator program`. With the hardened runtime plus
  `com.apple.security.cs.allow-dyld-environment-variables` it runs.

## The helper

- Vendor `Sources/SimAXSettings/sim-ax-settings.m` unchanged into
  `ThirdParty/serve-sim-native/Sources/SimAXSettings/`. `sync.sh` copies the
  directory whole, like `StreamingPolicy`.
- `scripts/build-sim-ax-settings.sh`, a pre-build script, compiles it with
  `xcrun --sdk iphonesimulator clang -arch arm64 -arch x86_64
  -mios-simulator-version-min=15.0 -framework CoreFoundation` into
  `.build/sim-ax-settings/alas-sim-ax-settings`, skipping the build when the
  source and script fingerprint match. Both architectures, because an Intel
  Mac runs x86_64 simulators.
- `scripts/embed-ghostty-resources.sh` copies it into
  `Contents/Resources/sim-ax-settings/alas-sim-ax-settings`.
- `scripts/sign-and-notarize.sh` signs it with the hardened runtime and a new
  `Alas/Resources/SimAXSettings.entitlements`
  (`allow-dyld-environment-variables`). The release workflow is the check:
  notarization can't be run locally.
- AlasCore stays free of the bundle. `LiveSimulatorSettings(accessibilityHelper: URL?)`
  takes the helper's URL; the app passes `Bundle.main`'s. Without it, the
  accessibility calls fail with `device_settings_failed: The accessibility
  helper is missing.`

## Settings

- AlasCore `SimulatorAccessibility`:
  - `voiceOver`, `reduceMotion`, `buttonShapes`, `reduceTransparency`
    (`Bool`), `colorFilter` (`none`, `grayscale`, `red-green`, `green-red`,
    `blue-yellow`) and `liquidGlass` (`clear`, `tinted`). Each value is read
    back, so an unknown one shows as unknown, as in `SimulatorDisplaySettings`.
  - Parses the helper's `status` JSON and builds the `set <key> <value>`
    arguments. `json` is what the agent tool returns.
- `SimulatorSettingsControl` gains `accessibility(udid:)` and
  `setAccessibility(udid:_:)`, which sets each given value in turn, then
  reads `status`.
- The settings popover gets an **Accessibility** section, after Appearance:
  VoiceOver, Reduce Motion, Button Shapes and Reduce Transparency toggles,
  plus Color Filter and Liquid Glass pickers. It reads the values when the
  popover opens and after each change.

## The agent tool

- `device_set_accessibility` with `udid` and any of `voiceover`,
  `reduce_motion`, `button_shapes`, `reduce_transparency` (booleans),
  `color_filter` and `liquid_glass` (strings), at least one. It returns all
  six read back.
- It is a settings call: held while the user drives, like
  `device_set_appearance`.
- The description warns: "With VoiceOver on, a tap selects an element and a
  double tap activates it; turn it off when done."
- Rust (`alas-client` and `mcp.rs`), `DeviceCommand`, the MCP tool lists and
  the preamble's device tool list gain it.

## Overlay

- A toolbar toggle, "Accessibility Overlay" (`accessibility` symbol), shown
  while a simulator is booted.
- When on, the stage reads the element tree through the existing `describe`
  path and draws each element's frame over the screen. Frames are upright
  points, so they scale by the view's points per device point. For a rotated
  screen they rotate with the content.
- Hovering an element shows a small card: role, label, value and id.
- Elements of the types `DeviceSnapshot` keeps without a label (button, text,
  secure and search fields, switch, slider, cell, link, tab: its
  `interactiveTypes`) that have no label are outlined in the warning colour.
  Elements keep only their role description, so parsing records the type as
  `DeviceElement.isControl` for this. Their card says "No label: VoiceOver
  reads its type only." Other elements are outlined in a neutral colour.
- Refresh: about 1 s after the user's last click or key, when the
  orientation changes, and with a refresh button. A read takes 0.4–1.8 s, so
  the overlay never reads continuously. Reading is read-only, so it does not
  interfere with agents.
- A pure function maps elements to view rectangles and flags the
  unlabelled ones; the view only draws its output.

## Testing

- AlasCore: parsing `status` (all values, an unknown value), the `set`
  arguments, and `DeviceCommand` decoding for `device_set_accessibility`
  (extend the existing suites).
- App: `DeviceAgentControlTests` for `device_set_accessibility` (held while
  the user drives, returns the read-back) with the existing fake settings;
  the overlay layout function in each orientation and the unlabelled flag,
  parameterized.
- Rust: argument parsing, refusals and tool lists.
- A throwaway run of the bundled helper through the built app, then a manual
  pass.

## Out of scope

- Driving VoiceOver itself (rotor, swipes) as agent tools.
- An audit beyond missing labels (contrast, target size).
- Android: it gets its own design with phase 3.
