# Devices: slim simulators with simslim

## Goal

A stock iOS simulator holds about 3.9 GB and 250 processes, so a Mac runs
only a few at once, and parallel agent sessions each want their own.
[simslim](https://github.com/MobAI-App/simslim) turns off the background
daemons a simulator doesn't need. The user gets a "Slim simulator" switch in
a booted simulator's settings, and agents get `device_set_slim`. Issue
#2548.

## Decisions

- **Run simslim from Homebrew, don't bundle it.** Alas doesn't ship it or
  port its daemon list. The list of about 175 safe-to-disable daemons and
  its per-runtime exceptions is the part that needs upkeep, and simslim
  writes into the simulator's launchd store, an internal format. Alas finds
  the binary on each use, so installing it while Alas runs works.
- **One fixed profile:** `--except store,web`. It keeps `apsd` (remote push
  tokens) and `swcd` (universal links) for about 0.12 GB.
- **No reboot either way.** On: `simslim on <udid> --no-reboot --except
  store,web`. Off: `simslim enable <udid> <every category>`. The overrides
  persist on iOS 18.5 and newer, so a simulator stays slim across boots.
- **The simulator is the only record.** Alas stores nothing; it reads
  `simslim status` each time. A simulator the user slimmed in a terminal
  shows as slim.
- **User and agents.** The settings popover has the switch; agents get
  `device_set_slim`.
- **Without simslim,** the switch is disabled and the section offers an
  "Install simslim…" button that runs `brew install mobai-app/tap/simslim`,
  the way Settings › Changes installs gg.

## Spike evidence (iPhone 17, iOS 26.5, simslim 0.14.0, Xcode 26.6)

From `scripts/prototype-simslim/run.sh` on branch
`nacho/evaluate-simslim-addition` and a follow-up run:

| | stock | slim (default) | keep `store,web` | live (`--no-reboot`) |
|---|---|---|---|---|
| Memory after 60 s | 3.86 GB | 0.81 GB | 0.93 GB | 1.00 GB |
| Processes | 254 | 66 | 76 | 72 |
| Remote push token | ok | fails | ok | fails |

- Install, launch, list apps, location with a privacy grant, `simctl push`,
  app and foreground logs, `simctl ui`, pasteboard, the accessibility
  helper, `openurl` and screenshots work in every state.
- `simslim status <udid> --json` (0.7 s) answers `{"managedDisabled",
  "managedTotal", "booted", "persistent", "verdict"}`, and only for a booted
  simulator; a shut-down one exits 1 with "simulator must be booted".
- `simslim measure <udid> --json` answers `{"processes", "bytes", "cpu"}`.
- `simslim profiles --json` lists the categories, each with an `id`.
- `on --no-reboot` from stock: 18 s. Again on a slim one: 4 s, no change.
- `enable <udid> <all ids> --json`: 9 s, back to stock; one daemon,
  `com.apple.cloudsettingssyncagent`, starts at the next boot
  (`notStarted`).
- `on`, `off` and `on --no-reboot` take no `--json`. They exit 0, or 1 with
  `simslim: <reason>` as the last stderr line ("no simulator with udid …").
- `off` reboots (16 s); Alas doesn't use it.

## Unverified

Alas's own stream, taps and `device_snapshot` through AlasSimService across
a live slim. The plan checks this first. If they break, the switch uses
`simslim on`/`off` (a 10 to 16 s reboot) and the stage restarts its stream
afterwards.

## AlasCore

`AlasFeatures/Devices/SimulatorSlim.swift`:

- `SimulatorSlimState`: `servicesOff`, `services`, `persistent`,
  `memoryBytes?`, `processes?`; `isSlim` is `servicesOff > 0`; `json` for the
  tool.
- `SimulatorSlimError`: `.notInstalled`, `.failed(String)`.
- `SimulatorSlim`: parsing (`status`, `measure`, `profiles`, the failure
  line from stderr), `installCommand`, the kept categories, and the live
  `state(simslim:udid:)` and `set(simslim:udid:on:)` that run the CLI.
- `SimulatorSettingsControl` gains `slim(udid:)` and `setSlim(udid:on:)`;
  `LiveSimulatorSettings` takes a `simslim: () -> String?` lookup and throws
  `.notInstalled` when it answers nil.

## App

- `DeviceBackend` gains `slim(_:)` and `setSlim(_:on:)`. `SimulatorBackend`
  forwards to its settings and maps `.notInstalled` to
  `device_simslim_missing` and `.failed` to `device_slim_failed`. Android
  answers `device_unsupported`.
- `LiveSimulatorSettings.bundled` finds `simslim` with
  `AgentPath.resolveExecutable`, over its well-known directories plus
  `~/go/bin`.
- **Popover,** iOS only, a "Memory" section after Accessibility:
  - the "Slim simulator" switch, showing a spinner while it applies;
  - the read-back: "0.93 GB in 76 processes. 149 of 173 background services
    are off.", or "All background services run." when stock;
  - "Lasts until the simulator restarts on this iOS version." when
    `persistent` is false;
  - without simslim: the switch disabled, "Install simslim to cut this
    simulator's memory about 4x.", "Installs via Homebrew: brew install
    mobai-app/tap/simslim", and an "Install simslim…" button. While brew
    runs: a spinner and "Installing…". On success the section reads the
    simulator's state; on failure it shows brew's error and Retry.
  Changes take the input turn, as the other settings do. Installing
  doesn't touch the simulator, so it doesn't.
- **Installing:** `GGInstallController` becomes `HomebrewInstallController`
  (formula, the tool's name, and a re-probe), with gg and simslim as its
  two users. Same phases (idle, running, succeeded, failed), same
  `/usr/bin/env brew` run with the login shell's environment.

## Agent tool

- `device_set_slim`: `udid`, `on` (boolean, required). Answers
  `{"slim", "services_off", "services", "persistent", "memory_mb"}`. iOS
  only; held while the user drives.
- Errors: `device_simslim_missing: simslim isn't installed. Ask the user to
  install it from the simulator's settings in the Devices tab, or to run
  brew install mobai-app/tap/simslim.`, `device_slim_failed: <reason>`,
  and on Android `device_unsupported: device_set_slim isn't available on
  Android.`
- The description says what stops working while slim (Siri, Spotlight,
  iCloud, widgets, Photos and Contacts pickers) and that push and universal
  links keep working.
- Rust, `DeviceCommand`, the preamble's tool list and its platform sentence,
  and `docs/devices.md` gain it.

## Testing

- AlasCore: parsing `status`, `measure` and `profiles`; the failure reason
  from stderr; `DeviceCommand` decoding.
- App: `device_set_slim` through the control with fake settings (iOS
  answer, simslim missing, Android unsupported, held while the user drives).
- Rust: arguments and the tool lists.
- No test runs simslim. The end-to-end check runs the real CLI on a scratch
  simulator.

## Out of scope

- Slim marks in the device switcher: a shut-down simulator can't report its
  state, and listing all takes about 3 s.
- Slimming before a boot, or every simulator Alas boots.
- Choosing categories or daemons.
- Bundling simslim.
- tvOS, watchOS and visionOS simulators, which the Devices tab doesn't list.
