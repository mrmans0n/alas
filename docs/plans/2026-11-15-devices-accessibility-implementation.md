# Devices: accessibility settings and overlay — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Users and agents turn a simulator's VoiceOver, reduce motion, button shapes, reduce transparency, colour filter and Liquid Glass on and off, and users see the screen's accessibility elements outlined over it.

**Architecture:** serve-sim's `sim-ax-settings.m` is vendored, built for the simulator by a pre-build script, bundled under `Resources/sim-ax-settings/`, and run with `simctl spawn`. AlasCore parses its output and builds its arguments (`SimulatorAccessibility`), behind the existing `SimulatorSettingsControl` seam, which the popover and the new `device_set_accessibility` tool use. The overlay reads the tree through the existing `describe` path; a pure layout type turns elements into view rectangles and flags unlabelled controls.

**Tech Stack:** Swift 5.9 / SwiftUI / AppKit, Swift Testing, Rust (`alas-client`, `alas` MCP server), bash build scripts, xcodegen.

**Spec:** `docs/plans/2026-11-15-devices-accessibility-design.md`

## Global Constraints

- English only; Conventional Commits; no agent attribution.
- AlasCore must not import AppKit or SwiftUI; anything the app uses from it is `public`.
- Among vendored serve-sim files only `ThirdParty/serve-sim-native/Sources/ServeSimCore/AlasSimulatorSession.swift` may be edited; `sim-ax-settings.m` is copied unchanged.
- After adding app files or editing `project.yml`, run `xcodegen`. Commit `project.yml` edits with the regenerated pbxproj; for app files only, commit just the new-file hunks of the pbxproj (`git diff -U0` → keep matching hunks → `git checkout` the pbxproj → `git apply --unidiff-zero`).
- `swiftformat Alas AlasTests Packages --lint` must pass: no semicolons.
- Tests: Swift Testing, extend existing suites, parameterize variants, no fixed sleeps.
- Helper path in the bundle: `Contents/Resources/sim-ax-settings/alas-sim-ax-settings`.
- Agent-facing keys: `voiceover`, `reduce_motion`, `button_shapes`, `reduce_transparency` (booleans), `color_filter` (`none`, `grayscale`, `red-green`, `green-red`, `blue-yellow`), `liquid_glass` (`clear`, `tinted`).
- Helper keys: `voiceover`, `reduce-motion`, `show-borders`, `reduce-transparency` (`on`/`off`), `color-filter`, `liquid-glass`.
- Missing helper error text: `The accessibility helper is missing.`; agents see it as `device_settings_failed: The accessibility helper is missing.`
- VoiceOver warning in the tool description: "With VoiceOver on, a tap selects an element and a double tap activates it; turn it off when done."
- Unlabelled-control card text: "No label: VoiceOver reads its type only."

## Review Focus

1. **A machine without the iOS Simulator SDK** (some CI images, Xcode without the iOS platform): the app must still build; the helper is then absent and accessibility calls fail with the missing-helper message. Task 1 makes the build script skip with a warning, and Task 2 tests the missing-helper error.
2. **A status line missing a key or holding an unknown value** (older runtimes have no Liquid Glass key; future values): that setting reads `unknown`, the others still parse. Task 2's parameterized parse test covers both.
3. **A snapshot from another orientation than the one shown** (the user rotates between reads): the overlay must draw nothing stale rather than boxes in the wrong place. Task 5's layout test covers it.
4. **Overlapping elements under the pointer** (a cell containing a button): hover picks the smallest one, the most specific. Task 5's hover test covers it.
5. **An agent driving while the overlay is on**: reading is read-only and never takes the input turn; hover and the refresh button work whoever drives. Task 5 reads through `client.describe` only, never `DeviceAgentControl`.

---

### Task 1: Vendor, build, bundle and sign the helper

**Files:**
- Create: `ThirdParty/serve-sim-native/Sources/SimAXSettings/sim-ax-settings.m` (copied from upstream at `ThirdParty/serve-sim-native/UPSTREAM_COMMIT`)
- Modify: `ThirdParty/serve-sim-native/sync.sh`
- Create: `scripts/build-sim-ax-settings.sh`
- Modify: `scripts/embed-ghostty-resources.sh`
- Create: `Alas/Resources/SimAXSettings.entitlements`
- Modify: `scripts/sign-and-notarize.sh`
- Modify: `project.yml` (pre-build script), then `xcodegen`

**Interfaces:**
- Produces: the executable at `${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/sim-ax-settings/alas-sim-ax-settings` when the SDK exists; nothing otherwise.

- [ ] **Step 1: Vendor the source**

```bash
C=$(cat ThirdParty/serve-sim-native/UPSTREAM_COMMIT)
mkdir -p ThirdParty/serve-sim-native/Sources/SimAXSettings
gh api "repos/expo/expo-device-hub/contents/packages/serve-sim/packages/serve-sim/Sources/SimAXSettings/sim-ax-settings.m?ref=$C" \
  --jq .content | base64 -d > ThirdParty/serve-sim-native/Sources/SimAXSettings/sim-ax-settings.m
```

In `sync.sh`, copy the directory whole next to `StreamingPolicy`:

```bash
rm -rf "$here/Sources/StreamingPolicy" "$here/Sources/CoreDeviceShim" "$here/Sources/SimAXSettings"
mkdir -p "$here/Sources/SimAXSettings"
cp -R "$src/StreamingPolicy" "$src/CoreDeviceShim" "$here/Sources/"
cp "$src/SimAXSettings/sim-ax-settings.m" "$here/Sources/SimAXSettings/"
```

and update its header comment: "Copies StreamingPolicy and CoreDeviceShim whole, SimAXSettings' source, and the SimNative files listed in vendored-files.txt."

- [ ] **Step 2: Write `scripts/build-sim-ax-settings.sh`**

```bash
#!/usr/bin/env bash
# Builds serve-sim's accessibility settings helper for the iOS simulator. It
# runs inside a simulator with `simctl spawn`, so it targets the simulator SDK
# for both Mac architectures. Without that SDK the helper is left out and the
# app reports it missing.
set -euo pipefail

srcroot="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
source_file="${srcroot}/ThirdParty/serve-sim-native/Sources/SimAXSettings/sim-ax-settings.m"
out_dir="${srcroot}/.build/sim-ax-settings"
output="${out_dir}/alas-sim-ax-settings"
stamp="${out_dir}/fingerprint"

if ! sdk="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)"; then
    rm -rf "${out_dir}"
    echo "build-sim-ax-settings.sh: warning: no iOS Simulator SDK; simulator accessibility settings are unavailable" >&2
    exit 0
fi

fingerprint="$(cat "${source_file}" "$0" | shasum -a 256 | cut -d' ' -f1) ${sdk}"
if [ -x "${output}" ] && [ "$(cat "${stamp}" 2>/dev/null)" = "${fingerprint}" ]; then
    exit 0
fi

mkdir -p "${out_dir}"
xcrun --sdk iphonesimulator clang \
    -arch arm64 -arch x86_64 \
    -mios-simulator-version-min=15.0 \
    -isysroot "${sdk}" \
    -framework CoreFoundation \
    -o "${output}" \
    "${source_file}"
printf '%s' "${fingerprint}" > "${stamp}"
```

`chmod +x scripts/build-sim-ax-settings.sh`.

- [ ] **Step 3: Embed it**

At the end of `scripts/embed-ghostty-resources.sh`:

```bash
# Simulator accessibility settings helper; optional (needs the iOS Simulator SDK).
sim_ax_source="${SRCROOT}/.build/sim-ax-settings/alas-sim-ax-settings"
sim_ax_destination_dir="${destination_root}/sim-ax-settings"
rm -rf "${sim_ax_destination_dir}"
if [ -x "${sim_ax_source}" ]; then
    mkdir -p "${sim_ax_destination_dir}"
    rsync -a "${sim_ax_source}" "${sim_ax_destination_dir}/alas-sim-ax-settings"
fi
```

- [ ] **Step 4: Sign it for release**

`Alas/Resources/SimAXSettings.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- simctl spawn starts simulator programs with DYLD_ROOT_PATH, which the hardened runtime strips otherwise. -->
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <true/>
</dict>
</plist>
```

In `sign-and-notarize.sh`, give `sign_embedded_executable` an optional third argument, an entitlements file, passed as `--entitlements "$3"` when set, and call after the `alas-host` line:

```bash
sign_embedded_executable "$app_path/Contents/Resources/sim-ax-settings/alas-sim-ax-settings" \
  "simulator accessibility helper" "$repo_root/Alas/Resources/SimAXSettings.entitlements"
```

The function body becomes:

```bash
sign_embedded_executable() {
  local path="$1"
  local label="$2"
  local entitlements="${3:-}"
  if [ ! -x "$path" ]; then
    return
  fi

  echo "==> Signing embedded $label"
  local extra=()
  if [ -n "$entitlements" ]; then extra=(--entitlements "$entitlements"); fi
  codesign \
    --force \
    --options runtime \
    --timestamp \
    ${extra[@]+"${extra[@]}"} \
    --sign "$MACOS_SIGNING_IDENTITY" \
    "$path"
  codesign --verify --strict --verbose=2 "$path"
}
```

(`${extra[@]+"${extra[@]}"}` because the script runs under `/usr/bin/env bash`, which can be macOS's bash 3.2, where `"${extra[@]}"` on an empty array fails under `set -u`.)

- [ ] **Step 5: Add the pre-build script and regenerate**

In `project.yml`, under the `Alas` target's `preBuildScripts`, after "Build TreeSitter Pack":

```yaml
      - name: Build Simulator Accessibility Helper
        script: '"${SRCROOT}/scripts/build-sim-ax-settings.sh"'
        basedOnDependencyAnalysis: false
```

Run `xcodegen`.

- [ ] **Step 6: Verify the bundled helper runs**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build
APP=$(xcodebuild -project Alas.xcodeproj -scheme Alas -showBuildSettings 2>/dev/null | awk '/ TARGET_BUILD_DIR /{print $3}')/Alas.app
lipo -archs "$APP/Contents/Resources/sim-ax-settings/alas-sim-ax-settings"
xcrun simctl spawn booted "$APP/Contents/Resources/sim-ax-settings/alas-sim-ax-settings" status
```

Expected: `x86_64 arm64`, then a JSON object with the six keys.

- [ ] **Step 7: Commit**

```bash
git add ThirdParty/serve-sim-native/Sources/SimAXSettings/sim-ax-settings.m ThirdParty/serve-sim-native/sync.sh \
  scripts/build-sim-ax-settings.sh scripts/embed-ghostty-resources.sh scripts/sign-and-notarize.sh \
  Alas/Resources/SimAXSettings.entitlements project.yml Alas.xcodeproj/project.pbxproj
git commit -m "build(devices): bundle serve-sim's simulator accessibility settings helper"
```

---

### Task 2: AlasCore accessibility settings

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorAccessibility.swift`
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorSettings.swift` (`SimulatorReadBack.jsonValue`, `SimulatorSettingsControl`, `LiveSimulatorSettings`)
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorControl.swift`
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Harness/DeviceCommand.swift`
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceSnapshot.swift` (`DeviceElement.isControl`)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/SimulatorSettingsTests.swift`, `DeviceCommandTests.swift`, `DeviceSnapshotTests.swift`

**Interfaces:**
- Produces:
  - `public enum SimulatorColorFilter: String, CaseIterable, Sendable { case none, grayscale, redGreen = "red-green", greenRed = "green-red", blueYellow = "blue-yellow"; public var label: String }`
  - `public enum SimulatorLiquidGlass: String, CaseIterable, Sendable { case clear, tinted }`
  - `public struct SimulatorAccessibility: Equatable, Sendable` with `voiceOver`, `reduceMotion`, `buttonShapes`, `reduceTransparency: SimulatorReadBack<Bool>`, `colorFilter: SimulatorReadBack<SimulatorColorFilter>`, `liquidGlass: SimulatorReadBack<SimulatorLiquidGlass>`, `static func parse(_ status: Data) throws -> SimulatorAccessibility`, `var json: [String: Any]`
  - `public struct SimulatorAccessibilityChange: Equatable, Sendable` with optional `voiceOver`, `reduceMotion`, `buttonShapes`, `reduceTransparency: Bool?`, `colorFilter: SimulatorColorFilter?`, `liquidGlass: SimulatorLiquidGlass?`, `var isEmpty: Bool`, `var helperArguments: [[String]]`
  - `public struct SimulatorAccessibilityError: Error, Equatable, LocalizedError` with `static let helperMissing`, `static let unreadable`
  - `SimulatorSettingsControl.accessibility(udid:) async throws -> SimulatorAccessibility` and `setAccessibility(udid:_:) async throws -> SimulatorAccessibility`
  - `LiveSimulatorSettings.init(accessibilityHelper: URL? = nil)`
  - `DeviceCommand.setAccessibility(udid: String, change: SimulatorAccessibilityChange)`, tool `device_set_accessibility`
  - `DeviceElement.isControl: Bool` (true for `DeviceSnapshot`'s interactive types)

- [ ] **Step 1: Write the failing tests**

In `SimulatorSettingsTests`:

```swift
    @Test(arguments: [
        (#"{"reduce-motion":"on","show-borders":"off","reduce-transparency":"on","voiceover":"off","color-filter":"red-green","liquid-glass":"tinted"}"#,
         SimulatorAccessibility(
             voiceOver: .value(false), reduceMotion: .value(true), buttonShapes: .value(false),
             reduceTransparency: .value(true), colorFilter: .value(.redGreen), liquidGlass: .value(.tinted)
         )),
        // An older runtime without Liquid Glass, and a value this version doesn't know.
        (#"{"reduce-motion":"off","show-borders":"on","reduce-transparency":"off","voiceover":"on","color-filter":"sepia"}"#,
         SimulatorAccessibility(
             voiceOver: .value(true), reduceMotion: .value(false), buttonShapes: .value(true),
             reduceTransparency: .value(false), colorFilter: .unknown, liquidGlass: .unknown
         )),
    ] as [(String, SimulatorAccessibility)])
    func accessibilityStatusParsesEachKey(status: String, expected: SimulatorAccessibility) throws {
        #expect(try SimulatorAccessibility.parse(Data((status + "\n").utf8)) == expected)
    }

    @Test func accessibilityStatusThatIsNotAnObjectIsUnreadable() {
        #expect(throws: SimulatorAccessibilityError.unreadable) {
            try SimulatorAccessibility.parse(Data("sim-ax-settings: missing symbol".utf8))
        }
    }

    @Test func accessibilityReadBackJSONUsesTheToolsKeys() throws {
        let read = SimulatorAccessibility(
            voiceOver: .value(true), reduceMotion: .value(false), buttonShapes: .unknown,
            reduceTransparency: .value(false), colorFilter: .value(.grayscale), liquidGlass: .value(.clear)
        )
        let data = try JSONSerialization.data(withJSONObject: read.json, options: .sortedKeys)
        #expect(String(decoding: data, as: UTF8.self) == #"{"button_shapes":"unknown","color_filter":"grayscale","liquid_glass":"clear","reduce_motion":false,"reduce_transparency":false,"voiceover":true}"#)
    }

    @Test func anAccessibilityChangeSetsOnlyItsKeysInAFixedOrder() {
        let change = SimulatorAccessibilityChange(voiceOver: false, colorFilter: .blueYellow, liquidGlass: .tinted)
        #expect(change.helperArguments == [
            ["set", "voiceover", "off"], ["set", "color-filter", "blue-yellow"], ["set", "liquid-glass", "tinted"],
        ])
        #expect(SimulatorAccessibilityChange().isEmpty)
    }

    @Test func accessibilityWithoutTheHelperFailsSayingSo() async {
        let settings = LiveSimulatorSettings(accessibilityHelper: nil)
        await #expect(throws: SimulatorAccessibilityError.helperMissing) { try await settings.accessibility(udid: "U") }
    }
```

In `DeviceCommandTests`, add to the decoding `arguments` list (next to `device_set_appearance`):

```swift
        ("device_set_accessibility", #"{"udid":"U","voiceover":true,"color_filter":"grayscale"}"#,
         .setAccessibility(udid: "U", change: SimulatorAccessibilityChange(voiceOver: true, colorFilter: .grayscale))),
```

and to the malformed list:

```swift
        ("device_set_accessibility", #"{"udid":"U"}"#),
        ("device_set_accessibility", #"{"udid":"U","liquid_glass":"frosted"}"#),
```

In `DeviceSnapshotTests.keepsLabelledAndInteractiveNodesInOrder`, change the expected element to pass `isControl: true` after `enabled: true`.

- [ ] **Step 2: Run them to see them fail**

`swift test --package-path Packages/AlasCore --filter 'SimulatorSettingsTests|DeviceCommandTests|DeviceSnapshotTests'`
Expected: build errors (`SimulatorAccessibility`, `setAccessibility`, `isControl` undefined).

- [ ] **Step 3: Implement `SimulatorAccessibility.swift`**

```swift
import Foundation

public enum SimulatorColorFilter: String, CaseIterable, Sendable {
    case none, grayscale
    case redGreen = "red-green", greenRed = "green-red", blueYellow = "blue-yellow"

    public var label: String {
        switch self {
        case .none: "None"
        case .grayscale: "Grayscale"
        case .redGreen: "Red/Green (Protanopia)"
        case .greenRed: "Green/Red (Deuteranopia)"
        case .blueYellow: "Blue/Yellow (Tritanopia)"
        }
    }
}

/// iOS 26's Liquid Glass legibility setting.
public enum SimulatorLiquidGlass: String, CaseIterable, Sendable {
    case clear, tinted
}

public struct SimulatorAccessibilityError: Error, Equatable, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }

    public static let helperMissing = SimulatorAccessibilityError(message: "The accessibility helper is missing.")
    public static let unreadable = SimulatorAccessibilityError(message: "The accessibility helper's reply wasn't readable.")
}

/// The accessibility settings `simctl ui` lacks, as serve-sim's
/// `sim-ax-settings status` reads them back.
public struct SimulatorAccessibility: Equatable, Sendable {
    public var voiceOver: SimulatorReadBack<Bool>
    public var reduceMotion: SimulatorReadBack<Bool>
    public var buttonShapes: SimulatorReadBack<Bool>
    public var reduceTransparency: SimulatorReadBack<Bool>
    public var colorFilter: SimulatorReadBack<SimulatorColorFilter>
    public var liquidGlass: SimulatorReadBack<SimulatorLiquidGlass>

    public init(
        voiceOver: SimulatorReadBack<Bool>, reduceMotion: SimulatorReadBack<Bool>, buttonShapes: SimulatorReadBack<Bool>,
        reduceTransparency: SimulatorReadBack<Bool>, colorFilter: SimulatorReadBack<SimulatorColorFilter>,
        liquidGlass: SimulatorReadBack<SimulatorLiquidGlass>
    ) {
        self.voiceOver = voiceOver
        self.reduceMotion = reduceMotion
        self.buttonShapes = buttonShapes
        self.reduceTransparency = reduceTransparency
        self.colorFilter = colorFilter
        self.liquidGlass = liquidGlass
    }

    /// From `sim-ax-settings status`: one JSON object of helper keys to values.
    /// A key that is absent or holds a value this version doesn't know is unknown.
    public static func parse(_ status: Data) throws -> SimulatorAccessibility {
        guard let object = (try? JSONSerialization.jsonObject(with: status)) as? [String: Any] else {
            throw SimulatorAccessibilityError.unreadable
        }
        func read<Value>(_ key: String, _ parse: (String) -> Value?) -> SimulatorReadBack<Value> {
            (object[key] as? String).flatMap(parse).map { .value($0) } ?? .unknown
        }
        let onOff: (String) -> Bool? = { $0 == "on" ? true : $0 == "off" ? false : nil }
        return SimulatorAccessibility(
            voiceOver: read("voiceover", onOff),
            reduceMotion: read("reduce-motion", onOff),
            buttonShapes: read("show-borders", onOff),
            reduceTransparency: read("reduce-transparency", onOff),
            colorFilter: read("color-filter", SimulatorColorFilter.init(rawValue:)),
            liquidGlass: read("liquid-glass", SimulatorLiquidGlass.init(rawValue:))
        )
    }

    /// What `device_set_accessibility` returns.
    public var json: [String: Any] {
        [
            "voiceover": voiceOver.jsonValue, "reduce_motion": reduceMotion.jsonValue,
            "button_shapes": buttonShapes.jsonValue, "reduce_transparency": reduceTransparency.jsonValue,
            "color_filter": colorFilter.jsonValue, "liquid_glass": liquidGlass.jsonValue,
        ]
    }
}

/// The settings one change sets; nil leaves a setting alone.
public struct SimulatorAccessibilityChange: Equatable, Sendable {
    public var voiceOver: Bool?
    public var reduceMotion: Bool?
    public var buttonShapes: Bool?
    public var reduceTransparency: Bool?
    public var colorFilter: SimulatorColorFilter?
    public var liquidGlass: SimulatorLiquidGlass?

    public init(
        voiceOver: Bool? = nil, reduceMotion: Bool? = nil, buttonShapes: Bool? = nil, reduceTransparency: Bool? = nil,
        colorFilter: SimulatorColorFilter? = nil, liquidGlass: SimulatorLiquidGlass? = nil
    ) {
        self.voiceOver = voiceOver
        self.reduceMotion = reduceMotion
        self.buttonShapes = buttonShapes
        self.reduceTransparency = reduceTransparency
        self.colorFilter = colorFilter
        self.liquidGlass = liquidGlass
    }

    public var isEmpty: Bool { helperArguments.isEmpty }

    /// One `sim-ax-settings set <key> <value>` per setting to change, in a fixed order.
    public var helperArguments: [[String]] {
        func onOff(_ key: String, _ value: Bool?) -> [String]? { value.map { ["set", key, $0 ? "on" : "off"] } }
        return [
            onOff("voiceover", voiceOver),
            onOff("reduce-motion", reduceMotion),
            onOff("show-borders", buttonShapes),
            onOff("reduce-transparency", reduceTransparency),
            colorFilter.map { ["set", "color-filter", $0.rawValue] },
            liquidGlass.map { ["set", "liquid-glass", $0.rawValue] },
        ].compactMap { $0 }
    }
}
```

In `SimulatorReadBack.jsonValue`, add before `case .value(let value):`

```swift
        case .value(let value as SimulatorColorFilter): value.rawValue
        case .value(let value as SimulatorLiquidGlass): value.rawValue
```

- [ ] **Step 4: Run the helper through simctl**

In `SimulatorControl`, after `display(udid:)`:

```swift
    /// Runs serve-sim's accessibility settings helper inside the simulator and returns what it printed.
    static func accessibilityHelper(udid: String, helper: URL, _ arguments: [String]) async throws -> String {
        let result = try await Process.run(xcrun, args: ["simctl", "spawn", udid, helper.path] + arguments)
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
        return result.stdout
    }
```

In `SimulatorSettingsControl`, add:

```swift
    func accessibility(udid: String) async throws -> SimulatorAccessibility
    /// Sets each setting `change` names, then reads all of them back.
    func setAccessibility(udid: String, _ change: SimulatorAccessibilityChange) async throws -> SimulatorAccessibility
```

`LiveSimulatorSettings`:

```swift
public struct LiveSimulatorSettings: SimulatorSettingsControl {
    /// serve-sim's `sim-ax-settings`, built for the simulator; the app bundles it.
    public let accessibilityHelper: URL?

    public init(accessibilityHelper: URL? = nil) {
        self.accessibilityHelper = accessibilityHelper
    }

    // The existing methods stay as they are; add:

    public func accessibility(udid: String) async throws -> SimulatorAccessibility {
        try SimulatorAccessibility.parse(Data(try await runHelper(udid: udid, ["status"]).utf8))
    }

    public func setAccessibility(udid: String, _ change: SimulatorAccessibilityChange) async throws -> SimulatorAccessibility {
        for arguments in change.helperArguments { _ = try await runHelper(udid: udid, arguments) }
        return try await accessibility(udid: udid)
    }

    private func runHelper(udid: String, _ arguments: [String]) async throws -> String {
        guard let helper = accessibilityHelper, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw SimulatorAccessibilityError.helperMissing
        }
        return try await SimulatorControl.accessibilityHelper(udid: udid, helper: helper, arguments)
    }
```

- [ ] **Step 5: Decode `device_set_accessibility`**

In `DeviceCommand`:
- case, after `setAppearance`: `/// At least one setting is set.` `case setAccessibility(udid: String, change: SimulatorAccessibilityChange)`
- `toolName`: `case .setAccessibility: "device_set_accessibility"`
- `udid`: add `.setAccessibility(let udid, _)` to the list.
- `Params`: add `var voiceover: Bool?`, `var reduce_motion: Bool?`, `var button_shapes: Bool?`, `var reduce_transparency: Bool?`, `var color_filter: String?`, `var liquid_glass: String?`
- `allowed`: `"device_set_accessibility": ["udid", "voiceover", "reduce_motion", "button_shapes", "reduce_transparency", "color_filter", "liquid_glass"],`
- decode, after `device_set_appearance`:

```swift
        case "device_set_accessibility":
            let change = SimulatorAccessibilityChange(
                voiceOver: params.voiceover, reduceMotion: params.reduce_motion, buttonShapes: params.button_shapes,
                reduceTransparency: params.reduce_transparency,
                colorFilter: try params.color_filter.map { try enumValue(SimulatorColorFilter.self, $0) },
                liquidGlass: try params.liquid_glass.map { try enumValue(SimulatorLiquidGlass.self, $0) }
            )
            guard !change.isEmpty else { throw AlasCLIRequestError.malformed }
            return .setAccessibility(udid: try udid(), change: change)
```

- [ ] **Step 6: Mark controls in snapshots**

`DeviceElement` gains `public let isControl: Bool` — "An element of a type that acts (button, field, switch, slider, cell, link, tab), kept even without a label." Add `isControl: Bool = false` as the init's last parameter, store it, and pass it through `withRef`. In `DeviceSnapshot.parse`, pass `isControl: interactiveTypes.contains(type)`.

- [ ] **Step 7: Run the tests**

`swift test --package-path Packages/AlasCore --filter 'SimulatorSettingsTests|DeviceCommandTests|DeviceSnapshotTests'`
Expected: all pass. (If `alas-host` fails to link, `swift package --package-path Packages/AlasCore clean` first.)

- [ ] **Step 8: Commit**

```bash
git add Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorAccessibility.swift \
  Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorSettings.swift \
  Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorControl.swift \
  Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceSnapshot.swift \
  Packages/AlasCore/Sources/AlasAgentKit/Harness/DeviceCommand.swift \
  Packages/AlasCore/Tests/AlasCoreTests/SimulatorSettingsTests.swift \
  Packages/AlasCore/Tests/AlasCoreTests/DeviceCommandTests.swift \
  Packages/AlasCore/Tests/AlasCoreTests/DeviceSnapshotTests.swift
git commit -m "feat(devices): read and set simulator accessibility settings"
```

---

### Task 3: The `device_set_accessibility` tool

**Files:**
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift`
- Modify: `Alas/Sources/Devices/AppState+Devices.swift` (bundled settings)
- Modify: `Alas/Sources/App/AppState.swift:741`, `Alas/Sources/Devices/DevicesSwitcher.swift:113`
- Modify: `AlasCLI/crates/alas-client/src/lib.rs`, `AlasCLI/crates/alas/src/mcp.rs`
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift`
- Test: `AlasTests/DeviceAgentControlTests.swift`, `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift`, Rust tests in `mcp.rs`

**Interfaces:**
- Consumes: Task 2's `SimulatorAccessibilityChange`, `SimulatorSettingsControl.setAccessibility`, `DeviceCommand.setAccessibility`.
- Produces: `extension LiveSimulatorSettings { static var bundled: LiveSimulatorSettings }` (app side), used by Task 4.

- [ ] **Step 1: Write the failing tests**

`DeviceAgentControlTests`: give `FakeSettings` the two methods —

```swift
        var accessibilityRead = SimulatorAccessibility(
            voiceOver: .value(false), reduceMotion: .value(false), buttonShapes: .value(false),
            reduceTransparency: .value(false), colorFilter: .value(.none), liquidGlass: .value(.clear)
        )
        func accessibility(udid: String) async throws -> SimulatorAccessibility { accessibilityRead }
        func setAccessibility(udid: String, _ change: SimulatorAccessibilityChange) async throws -> SimulatorAccessibility {
            calls.append("accessibility \(change.helperArguments.map { $0.joined(separator: " ") })")
            if let voiceOver = change.voiceOver { accessibilityRead.voiceOver = .value(voiceOver) }
            return accessibilityRead
        }
```

— and parameterize `settingsAreHeldDuringATakeoverAndReturnWhatSimctlReadBack` over both settings tools:

```swift
    @Test(arguments: [
        (DeviceCommand.setAppearance(udid: "on", appearance: .dark, textSize: nil, increaseContrast: nil),
         #"{"appearance":"dark","increase_contrast":"unsupported","text_size":"large"}"#),
        (.setAccessibility(udid: "on", change: SimulatorAccessibilityChange(voiceOver: true)),
         #"{"button_shapes":false,"color_filter":"none","liquid_glass":"clear","reduce_motion":false,"reduce_transparency":false,"voiceover":true}"#),
    ])
    func settingsAreHeldDuringATakeoverAndReturnWhatWasReadBack(command: DeviceCommand, readBack: String) async throws {
        let settings = FakeSettings()
        let control = control(FakeInput(), settings: settings, sleep: Self.untilCancelled)
        control.takeOver(udid: "on")
        async let changed = control.perform(command, sessionID: "s")
        try await eventually("call is held") { control.waitingSessions(udid: "on") == ["s"] }
        #expect(settings.calls.isEmpty)
        control.handBack(udid: "on")
        #expect(await changed == .text([readBack]))
    }
```

`ACPMCPPromptPreambleTests`: add `"device_set_accessibility"` after `"device_set_appearance"` in the expected tool list at line 320.

Rust (`mcp.rs` tests): in the mapping test next to `device_set_appearance` (line ~5342):

```rust
        assert_eq!(
            map("device_set_accessibility", json!({ "udid": "U", "voiceover": true, "color_filter": "grayscale" })).unwrap(),
            Command::Device(DeviceCommand::SetAccessibility {
                udid: "U".into(),
                voiceover: Some(true),
                reduce_motion: None,
                button_shapes: None,
                reduce_transparency: None,
                color_filter: Some("grayscale".into()),
                liquid_glass: None,
            })
        );
```

in the refusal list (line ~5418):

```rust
            ("device_set_accessibility", json!({ "udid": "U" }), "pass at least one of voiceover, reduce_motion, button_shapes, reduce_transparency, color_filter, liquid_glass"),
```

and add `"device_set_accessibility"` after `"device_set_appearance"` in the tool-list test (line ~4477) and the `destructiveHint` list (line ~5473).

- [ ] **Step 2: Run them to see them fail**

`cargo test --manifest-path AlasCLI/Cargo.toml -p alas -p alas-client` → compile error (`SetAccessibility`).
App suites fail to build until Step 3.

- [ ] **Step 3: Implement the app side**

`DeviceAgentControl.perform`: add `.setAccessibility` to the `isInput` list next to `.setAppearance`, and the case:

```swift
        case .setAccessibility(_, let change):
            return await settingsCall {
                .text([Self.json(try await settings.setAccessibility(udid: udid, change).json)])
            }
```

`AppState+Devices.swift`:

```swift
extension LiveSimulatorSettings {
    /// Settings with the app's bundled accessibility helper.
    static var bundled: LiveSimulatorSettings {
        LiveSimulatorSettings(accessibilityHelper: Bundle.main.resourceURL?
            .appendingPathComponent("sim-ax-settings/alas-sim-ax-settings"))
    }
}
```

Replace `LiveSimulatorSettings()` with `.bundled` at `AppState.swift:741` and `DevicesSwitcher.swift:113`.

Preamble: add `"device_set_accessibility"` after `"device_set_appearance"` in the tool list (line 84), and in the device sentence (line ~354) replace
`"To test dark mode, Dynamic Type, permissions, location, notifications or deep links, use " + "device_set_appearance, device_set_permission, device_set_location, device_push and device_open_url. "`
with
`"To test dark mode, Dynamic Type, accessibility settings, permissions, location, notifications or deep links, use " + "device_set_appearance, device_set_accessibility, device_set_permission, device_set_location, device_push and device_open_url. "`.

- [ ] **Step 4: Implement the Rust side**

`alas-client/src/lib.rs`: the variant after `SetAppearance`:

```rust
    /// At least one is set.
    SetAccessibility {
        udid: String,
        voiceover: Option<bool>,
        reduce_motion: Option<bool>,
        button_shapes: Option<bool>,
        reduce_transparency: Option<bool>,
        color_filter: Option<String>,
        liquid_glass: Option<String>,
    },
```

add `| DeviceCommand::SetAccessibility { .. }` to the `include_screenshot` false arm, and the request:

```rust
        DeviceCommand::SetAccessibility {
            udid,
            voiceover,
            reduce_motion,
            button_shapes,
            reduce_transparency,
            color_filter,
            liquid_glass,
        } => {
            let mut params = json!({ "udid": udid });
            for (key, value) in [
                ("voiceover", voiceover),
                ("reduce_motion", reduce_motion),
                ("button_shapes", button_shapes),
                ("reduce_transparency", reduce_transparency),
            ] {
                if let Some(value) = value {
                    params[key] = json!(value);
                }
            }
            for (key, value) in [("color_filter", color_filter), ("liquid_glass", liquid_glass)] {
                if let Some(value) = value {
                    params[key] = json!(value);
                }
            }
            ("device_set_accessibility", params)
        }
```

`mcp.rs`: constants next to `DEVICE_TEXT_SIZES`:

```rust
const DEVICE_COLOR_FILTERS: &[&str] = &["none", "grayscale", "red-green", "green-red", "blue-yellow"];
const DEVICE_LIQUID_GLASS: &[&str] = &["clear", "tinted"];
```

the tool, after `device_set_appearance`:

```rust
        json!({
            "name": "device_set_accessibility",
            "description": format!("Turn the simulator's accessibility settings on or off: VoiceOver, Reduce Motion, Button Shapes, Reduce Transparency, a color filter and the Liquid Glass look (iOS 26); pass at least one. Running apps pick changes up live. Returns all six read back; a value is \"unknown\" when the runtime doesn't report it. With VoiceOver on, a tap selects an element and a double tap activates it; turn it off when done. {DEVICE_DRIVING_NOTE}"),
            "annotations": { "readOnlyHint": false, "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "udid": udid,
                    "voiceover": { "type": "boolean" },
                    "reduce_motion": { "type": "boolean" },
                    "button_shapes": { "type": "boolean" },
                    "reduce_transparency": { "type": "boolean" },
                    "color_filter": { "type": "string", "enum": DEVICE_COLOR_FILTERS },
                    "liquid_glass": { "type": "string", "enum": DEVICE_LIQUID_GLASS }
                },
                "required": ["udid"]
            }
        }),
```

and the mapping, after `device_set_appearance`:

```rust
        "device_set_accessibility" => {
            reject_arguments(args, name, &["udid", "voiceover", "reduce_motion", "button_shapes", "reduce_transparency", "color_filter", "liquid_glass"])?;
            let voiceover = optional_bool(args, "voiceover")?;
            let reduce_motion = optional_bool(args, "reduce_motion")?;
            let button_shapes = optional_bool(args, "button_shapes")?;
            let reduce_transparency = optional_bool(args, "reduce_transparency")?;
            let color_filter = optional_enum(args, "color_filter", DEVICE_COLOR_FILTERS)?.map(String::from);
            let liquid_glass = optional_enum(args, "liquid_glass", DEVICE_LIQUID_GLASS)?.map(String::from);
            if voiceover.is_none() && reduce_motion.is_none() && button_shapes.is_none() && reduce_transparency.is_none()
                && color_filter.is_none() && liquid_glass.is_none()
            {
                return Err("pass at least one of voiceover, reduce_motion, button_shapes, reduce_transparency, color_filter, liquid_glass".into());
            }
            Ok(Command::Device(alas_client::DeviceCommand::SetAccessibility {
                udid: required_limited_string(args, "udid", 64)?,
                voiceover,
                reduce_motion,
                button_shapes,
                reduce_transparency,
                color_filter,
                liquid_glass,
            }))
        }
```

CI doesn't run rustfmt; match the surrounding style.

- [ ] **Step 5: Run the tests**

```bash
cargo test --manifest-path AlasCLI/Cargo.toml -p alas -p alas-client
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation \
  -only-testing AlasTests/DeviceAgentControlTests -only-testing AlasTests/ACPMCPPromptPreambleTests test
```

Expected: pass; check the `Test run with N tests in 2 suites` line.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Devices/DeviceAgentControl.swift Alas/Sources/Devices/AppState+Devices.swift Alas/Sources/App/AppState.swift \
  Alas/Sources/Devices/DevicesSwitcher.swift AlasCLI/crates/alas-client/src/lib.rs AlasCLI/crates/alas/src/mcp.rs \
  Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift AlasTests/DeviceAgentControlTests.swift \
  AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift
git commit -m "feat(devices): let agents set simulator accessibility settings"
```

---

### Task 4: Accessibility section in the settings popover

**Files:**
- Modify: `Alas/Sources/Devices/DeviceSettingsPopover.swift`

**Interfaces:**
- Consumes: `SimulatorSettingsControl.accessibility(udid:)`, `setAccessibility(udid:_:)`, `SimulatorColorFilter.label`, `SimulatorLiquidGlass`.

No unit test: view composition (AGENTS.md); the parsing and argument decisions are tested in Task 2.

- [ ] **Step 1: State and load**

Add `@State private var accessibility: SimulatorAccessibility?` and `@State private var accessibilityError: String?`. In `load()`, after reading `display`, read accessibility in its own `do`/`catch` so a missing helper doesn't hide Display:

```swift
        do {
            accessibility = try await settings.accessibility(udid: udid)
        } catch {
            accessibilityError = error.localizedDescription
        }
```

- [ ] **Step 2: The section**

In `body`, after the Display section: `Divider()` then `section("Accessibility") { accessibilityRows }`.

```swift
    // MARK: Accessibility

    @ViewBuilder
    private var accessibilityRows: some View {
        if let accessibility {
            toggleRow("VoiceOver", accessibility.voiceOver) { SimulatorAccessibilityChange(voiceOver: $0) }
            toggleRow("Reduce Motion", accessibility.reduceMotion) { SimulatorAccessibilityChange(reduceMotion: $0) }
            toggleRow("Button Shapes", accessibility.buttonShapes) { SimulatorAccessibilityChange(buttonShapes: $0) }
            toggleRow("Reduce Transparency", accessibility.reduceTransparency) { SimulatorAccessibilityChange(reduceTransparency: $0) }
            row("Color filter", supported: accessibility.colorFilter) {
                Picker("", selection: Binding(
                    get: { if case .value(let value) = accessibility.colorFilter { value } else { .none } },
                    set: { value in changeAccessibility(SimulatorAccessibilityChange(colorFilter: value)) }
                )) {
                    ForEach(SimulatorColorFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            row("Liquid Glass", supported: accessibility.liquidGlass) {
                Picker("", selection: Binding(
                    get: { if case .value(let value) = accessibility.liquidGlass { value } else { .clear } },
                    set: { value in changeAccessibility(SimulatorAccessibilityChange(liquidGlass: value)) }
                )) {
                    Text("Clear").tag(SimulatorLiquidGlass.clear)
                    Text("Tinted").tag(SimulatorLiquidGlass.tinted)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
        } else if accessibilityError == nil {
            ProgressView().controlSize(.small)
        }
        if let accessibilityError { note(accessibilityError, tone: "warn") }
    }

    private func toggleRow(
        _ title: String, _ value: SimulatorReadBack<Bool>, change: @escaping (Bool) -> SimulatorAccessibilityChange
    ) -> some View {
        row(title, supported: value) {
            Toggle("", isOn: Binding(get: { value == .value(true) }, set: { changeAccessibility(change($0)) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    /// Applies an accessibility change and shows what the helper read back.
    private func changeAccessibility(_ change: SimulatorAccessibilityChange) {
        mutate(report: { accessibilityError = $0 }) {
            do {
                accessibility = try await settings.setAccessibility(udid: udid, change)
                accessibilityError = nil
            } catch {
                accessibilityError = error.localizedDescription
            }
        }
    }
```

Update the type's doc comment: "The selected simulator's settings: display, accessibility, an app's permissions and notifications, location and URLs."

- [ ] **Step 3: Build and look at it**

Build (`xcodebuild … -quiet build`), launch Alas Dev, open the settings popover for the booted simulator, turn Reduce Motion on, and check `xcrun simctl spawn booted <bundled helper> get reduce-motion` prints `on`. Turn it off again.

- [ ] **Step 4: Commit**

```bash
git add Alas/Sources/Devices/DeviceSettingsPopover.swift
git commit -m "feat(devices): add accessibility settings to the simulator settings popover"
```

---

### Task 5: Accessibility overlay

**Files:**
- Create: `Alas/Sources/Devices/AccessibilityOverlayLayout.swift`
- Create: `Alas/Sources/Devices/DeviceAccessibilityOverlay.swift`
- Modify: `Alas/Sources/Devices/DeviceScreenView.swift` (`onHover`, `onUserInput`)
- Modify: `Alas/Sources/Devices/DeviceStage.swift`
- Modify: `Alas/Sources/Devices/DevicePaneModel.swift` (overlay on/off per device)
- Modify: `Alas/Sources/Devices/DevicesSwitcher.swift` (`DevicesActions` toggle)
- Modify: `Alas/Sources/Right/RightPaneView.swift`, `Alas/Sources/Devices/DevicesTabView.swift`, `Alas/Sources/App/DesignCaptureDevices.swift`
- Test: create `AlasTests/AccessibilityOverlayLayoutTests.swift`
- Run `xcodegen`; commit only the new-file hunks of the pbxproj.

**Interfaces:**
- Consumes: `DeviceSnapshot`, `DeviceElement.isControl` (Task 2), `SimulatorStreamClient.describe(udid:)`.
- Produces:
  - `struct AccessibilityOverlayLayout { struct Box: Equatable { let element: DeviceElement; let rect: CGRect; let unlabelled: Bool }; static func boxes(_ snapshot: DeviceSnapshot, in size: CGSize) -> [Box]; static func hovered(_ boxes: [Box], at point: CGPoint) -> Box? }`
  - `DevicePaneModel.accessibilityOverlays: Set<String>`, `toggleAccessibilityOverlay(udid:)`
  - `DeviceScreenView.onHover: ((CGPoint?) -> Void)?` (top-left-origin view points), `onUserInput: () -> Void`

- [ ] **Step 1: Write the failing layout tests**

`AlasTests/AccessibilityOverlayLayoutTests.swift`:

```swift
import AlasCore
import CoreGraphics
import Testing
@testable import Alas

struct AccessibilityOverlayLayoutTests {
    private func element(_ ref: String, label: String?, isControl: Bool, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DeviceElement {
        DeviceElement(ref: ref, role: "button", label: label, value: nil, id: nil, x: x, y: y, width: w, height: h, enabled: true, isControl: isControl)
    }

    private func snapshot(width: Double, height: Double, _ elements: [DeviceElement]) -> DeviceSnapshot {
        DeviceSnapshot(generation: 1, screenWidth: width, screenHeight: height, elements: elements)
    }

    @Test(arguments: [
        // Portrait screen in a view half its size.
        (402.0, 874.0, CGSize(width: 201, height: 437), CGRect(x: 10, y: 50, width: 50, height: 22)),
        // Landscape screen, as a rotated device describes it, in a landscape view.
        (874.0, 402.0, CGSize(width: 437, height: 201), CGRect(x: 10, y: 50, width: 50, height: 22)),
    ])
    func framesScaleFromScreenPointsToTheView(width: Double, height: Double, view: CGSize, expected: CGRect) {
        let boxes = AccessibilityOverlayLayout.boxes(
            snapshot(width: width, height: height, [element("e1", label: "Save", isControl: true, 20, 100, 100, 44)]), in: view
        )
        #expect(boxes.map(\.rect) == [expected])
    }

    @Test func aSnapshotFromTheOtherOrientationDrawsNothing() {
        let boxes = AccessibilityOverlayLayout.boxes(
            snapshot(width: 402, height: 874, [element("e1", label: "Save", isControl: true, 20, 100, 100, 44)]),
            in: CGSize(width: 437, height: 201)
        )
        #expect(boxes.isEmpty)
    }

    @Test(arguments: [
        (nil as String?, true, true),
        ("Save", true, false),
        (nil, false, false),
    ])
    func onlyControlsWithoutALabelAreFlagged(label: String?, isControl: Bool, unlabelled: Bool) {
        let boxes = AccessibilityOverlayLayout.boxes(
            snapshot(width: 402, height: 874, [element("e1", label: label, isControl: isControl, 0, 0, 100, 44)]),
            in: CGSize(width: 402, height: 874)
        )
        #expect(boxes.map(\.unlabelled) == [unlabelled])
    }

    @Test func hoverPicksTheSmallestElementUnderThePointer() {
        let boxes = AccessibilityOverlayLayout.boxes(snapshot(width: 402, height: 874, [
            element("cell", label: "General", isControl: true, 0, 300, 402, 60),
            element("button", label: "Info", isControl: true, 350, 310, 40, 40),
        ]), in: CGSize(width: 402, height: 874))
        #expect(AccessibilityOverlayLayout.hovered(boxes, at: CGPoint(x: 360, y: 320))?.element.ref == "button")
        #expect(AccessibilityOverlayLayout.hovered(boxes, at: CGPoint(x: 100, y: 320))?.element.ref == "cell")
        #expect(AccessibilityOverlayLayout.hovered(boxes, at: CGPoint(x: 100, y: 10)) == nil)
    }
}
```

- [ ] **Step 2: Run to see it fail**

`xcodegen`, then `xcodebuild … -only-testing AlasTests/AccessibilityOverlayLayoutTests test` → build error (`AccessibilityOverlayLayout` undefined).

- [ ] **Step 3: Implement the layout**

`Alas/Sources/Devices/AccessibilityOverlayLayout.swift`:

```swift
import AlasCore
import CoreGraphics

/// Where the accessibility overlay draws each element, and which it flags.
struct AccessibilityOverlayLayout {
    struct Box: Equatable {
        let element: DeviceElement
        /// In the screen view's points, top-left origin.
        let rect: CGRect
        /// A control VoiceOver can only name by its type.
        let unlabelled: Bool
    }

    /// Snapshot frames are upright screen points, like the view, so they only
    /// scale. A snapshot taken in the other orientation draws nothing until the
    /// next read.
    static func boxes(_ snapshot: DeviceSnapshot, in size: CGSize) -> [Box] {
        guard snapshot.screenWidth > 0, snapshot.screenHeight > 0, size.width > 0, size.height > 0,
              (snapshot.screenWidth > snapshot.screenHeight) == (size.width > size.height)
        else { return [] }
        let sx = size.width / snapshot.screenWidth
        let sy = size.height / snapshot.screenHeight
        return snapshot.elements.map { element in
            Box(
                element: element,
                rect: CGRect(x: element.x * sx, y: element.y * sy, width: element.width * sx, height: element.height * sy),
                unlabelled: element.isControl && element.label == nil
            )
        }
    }

    /// The most specific element under `point`: the smallest that contains it.
    static func hovered(_ boxes: [Box], at point: CGPoint) -> Box? {
        boxes.filter { $0.rect.contains(point) }.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }
}
```

- [ ] **Step 4: Run the layout tests**

Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 5: Hover and input from the screen view**

`DeviceScreenView`: add

```swift
    /// The pointer over the screen, in top-left-origin view points; nil when it leaves.
    var onHover: ((CGPoint?) -> Void)?
    /// The user finished a click, drag or key press on the simulator.
    var onUserInput: () -> Void = {}
```

pass both through `makeNSView`/`updateNSView` like `onOrientation`. In `DeviceScreenNSView`:

```swift
    var onHover: ((CGPoint?) -> Void)?
    var onUserInput: () -> Void = {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let onHover else { return }
        let point = location(event)
        onHover(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
    }

    override func mouseExited(with event: NSEvent) { onHover?(nil) }
```

Call `onUserInput()` at the end of `mouseUp` (after `send("end", …)`) and in `sendKey` when `!key.down`.

- [ ] **Step 6: Overlay on/off per device**

`DevicePaneModel`:

```swift
    /// Simulators whose screen shows the accessibility overlay.
    private(set) var accessibilityOverlays: Set<String> = []

    func toggleAccessibilityOverlay(udid: String) {
        if accessibilityOverlays.remove(udid) == nil { accessibilityOverlays.insert(udid) }
    }
```

`DevicesActions`: add `let accessibilityOverlay: Bool` and `let onToggleAccessibilityOverlay: () -> Void`; before the settings button:

```swift
            ToolbarBtn(
                icon: "accessibility", tooltip: accessibilityOverlay ? "Hide Accessibility Overlay" : "Show Accessibility Overlay",
                isActive: accessibilityOverlay, action: onToggleAccessibilityOverlay
            )
            .disabled(!booted)
```

`RightPaneView.devicesActions`: pass `accessibilityOverlay: state.devicePane.accessibilityOverlays.contains(device.udid)`, `onToggleAccessibilityOverlay: { state.devicePane.toggleAccessibilityOverlay(udid: device.udid) }`. `DesignCaptureDevices`: pass `false` and `{}`.

- [ ] **Step 7: The overlay view**

`Alas/Sources/Devices/DeviceAccessibilityOverlay.swift`:

```swift
import AlasCore
import SwiftUI

/// The screen's accessibility elements outlined over it, with the one under the
/// pointer described. Reads the tree once per `readKey` change, a second after
/// it, and on Refresh; never continuously, since a read takes up to 2 s.
struct DeviceAccessibilityOverlay: View {
    let udid: String
    let client: SimulatorStreamClient
    /// Changes after the user's input or a rotation.
    let readKey: Int
    /// The pointer, in top-left-origin view points.
    let hover: CGPoint?
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var snapshot: DeviceSnapshot?
    @State private var reading = false
    @State private var readError: String?

    var body: some View {
        GeometryReader { geometry in
            let boxes = snapshot.map { AccessibilityOverlayLayout.boxes($0, in: geometry.size) } ?? []
            let hovered = hover.flatMap { AccessibilityOverlayLayout.hovered(boxes, at: $0) }
            ZStack(alignment: .topLeading) {
                ForEach(boxes, id: \.element.ref) { box in
                    Rectangle()
                        .strokeBorder(theme.color(box.unlabelled ? "warn" : "accent"), lineWidth: box == hovered ? 2 : 1)
                        .background(theme.color(box.unlabelled ? "warn" : "accent").opacity(box == hovered ? 0.15 : 0))
                        .frame(width: box.rect.width, height: box.rect.height)
                        .offset(x: box.rect.minX, y: box.rect.minY)
                }
                .allowsHitTesting(false)
                VStack {
                    if let hovered, hovered.rect.midY > geometry.size.height / 2 { card(hovered) }
                    Spacer(minLength: 0)
                    if let hovered, hovered.rect.midY <= geometry.size.height / 2 { card(hovered) }
                }
                .frame(maxWidth: .infinity)
                .padding(scale.space[3])
                .allowsHitTesting(false)
                refreshButton
                    .padding(scale.space[2])
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .task(id: readKey) {
            // The first read is immediate; later ones wait for the screen to settle.
            if snapshot != nil { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            await read()
        }
    }

    private func card(_ box: AccessibilityOverlayLayout.Box) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(box.element.role).font(scale.caption.font(weight: .semibold))
            if let label = box.element.label { Text("Label: \(label)") }
            if let value = box.element.value { Text("Value: \(value)") }
            if let id = box.element.id { Text("ID: \(id)") }
            if box.unlabelled {
                Text("No label: VoiceOver reads its type only.").foregroundStyle(theme.color("warn"))
            }
        }
        .font(scale.caption.font)
        .foregroundStyle(theme.color("fg"))
        .lineLimit(2)
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }

    private var refreshButton: some View {
        Button {
            Task { await read() }
        } label: {
            HStack(spacing: 4) {
                if reading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                Text(readError == nil ? "Refresh" : "Couldn't read: retry")
            }
            .font(scale.caption.font)
            .padding(.horizontal, scale.space[2])
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(readError ?? "Read the screen's accessibility elements again")
        .disabled(reading)
    }

    private func read() async {
        reading = true
        defer { reading = false }
        do {
            snapshot = try DeviceSnapshot.parse(try await client.describe(udid: udid), generation: 0)
            readError = nil
        } catch {
            readError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 8: Put it on the stage**

`DeviceStage`: add `let accessibilityOverlay: Bool`, `@State private var hover: CGPoint?`, `@State private var overlayReadKey = 0`. In `screen(…)`, pass to `DeviceScreenView`:

```swift
                onHover: accessibilityOverlay ? { hover = $0 } : nil,
                onUserInput: { overlayReadKey += 1 },
```

and extend `onOrientation` so a rotation also reads again:

```swift
                onOrientation: { orientation in
                    frameOrientation = orientation
                    overlayReadKey += 1
                },
```

 In the `ZStack`, right after `DeviceScreenView(…)…id(…)`:

```swift
            if accessibilityOverlay, streamError == nil {
                DeviceAccessibilityOverlay(udid: device.udid, client: client, readKey: overlayReadKey, hover: hover)
            }
```

Hardware buttons and rotate buttons also bump `overlayReadKey` after sending. `DevicesTabView` passes `accessibilityOverlay: model.accessibilityOverlays.contains(device.udid)`; `DesignCaptureDevices`' stage passes `false`.

- [ ] **Step 9: Build, run the layout tests, and look at it**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation \
  -only-testing AlasTests/AccessibilityOverlayLayoutTests test
```

Then launch Alas Dev, open Settings on the booted simulator, turn the overlay on: boxes over the rows, a card when hovering one, an orange box on a control without a label (if none, drop `/tmp/alas-hello/Hello.app`, whose button is unlabelled, or note that none showed). Rotate: boxes disappear, then come back in place about a second later. Take a screenshot as proof.

- [ ] **Step 10: Commit**

Stage the new-file hunks of the pbxproj only (Global Constraints), then:

```bash
git add Alas/Sources/Devices/AccessibilityOverlayLayout.swift Alas/Sources/Devices/DeviceAccessibilityOverlay.swift \
  Alas/Sources/Devices/DeviceScreenView.swift Alas/Sources/Devices/DeviceStage.swift Alas/Sources/Devices/DevicePaneModel.swift \
  Alas/Sources/Devices/DevicesSwitcher.swift Alas/Sources/Right/RightPaneView.swift Alas/Sources/Devices/DevicesTabView.swift \
  Alas/Sources/App/DesignCaptureDevices.swift AlasTests/AccessibilityOverlayLayoutTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(devices): outline the simulator's accessibility elements over its screen"
```

---

### Task 6: Docs and the end-to-end check

**Files:**
- Modify: `docs/devices.md`
- Modify: `docs/plans/2026-11-04-device-panel-design.md`

- [ ] **Step 1: Docs**

`docs/devices.md`, Simulators section, after the settings paragraph:

> The settings also hold accessibility: VoiceOver, Reduce Motion, Button
> Shapes, Reduce Transparency, a color filter and the Liquid Glass look. Apps
> pick changes up while they run. With VoiceOver on, a click selects an
> element and a double click activates it.
>
> The accessibility button in the toolbar outlines the screen's accessibility
> elements over it. Hover one to see its role, label, value and id. Buttons,
> fields and other controls without a label are outlined in orange, since
> VoiceOver can only read their type. The outlines update a second after you
> click or type, and with Refresh.

Agents table, after `device_set_appearance`:

> | `device_set_accessibility` | Turns VoiceOver, Reduce Motion, Button Shapes, Reduce Transparency, a color filter and the Liquid Glass look on or off, and returns what the simulator reports. |

Device panel design, follow-ups: tick the item and point at the spec:

> - [x] VoiceOver, reduce motion and an accessibility overlay
>   (`2026-11-15-devices-accessibility-design.md`).

- [ ] **Step 2: End-to-end with the built app**

Throwaway (not committed): with the bundled helper, set every setting through `LiveSimulatorSettings.bundled` from a scratch test or via an agent session calling `device_set_accessibility` with `{"reduce_motion":true,"color_filter":"grayscale"}`; check the reply reads them back, the simulator turns grey, then set them back.

- [ ] **Step 3: Lint and commit**

```bash
swiftformat Alas AlasTests Packages --lint
git add docs/devices.md docs/plans/2026-11-04-device-panel-design.md
git commit -m "docs(devices): describe simulator accessibility settings and overlay"
```
