# Devices: slim simulators — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Slim simulator" switch in a booted simulator's settings and a `device_set_slim` agent tool, both running the user's installed simslim without a reboot.

**Architecture:** AlasCore's `SimulatorSlim` parses simslim's output and runs it; `SimulatorSettingsControl` gains `slim`/`setSlim`, so the existing fakes cover the control and the design capture. `DeviceBackend` forwards them; the control maps simslim's errors to tool codes; the popover gets a Memory section.

**Tech Stack:** Swift 6, SwiftUI, AlasCore, Swift Testing, Rust MCP server, simslim 0.14.0.

**Spec:** `docs/plans/2026-11-16-devices-simslim-design.md`

## Global Constraints

- English; Conventional Commits; no attribution. AlasCore stays free of AppKit/SwiftUI and builds on Linux (no `XMLParser`).
- New app files: run `xcodegen`, commit only their pbxproj hunks. `swiftformat --lint` passes.
- Profile: `--except store,web`, from `SimulatorSlim.keptCategories`. On: `simslim on <udid> --no-reboot --except store,web`. Off: `simslim enable <udid> <every id from profiles --json>`. Never `off`.
- Install command, everywhere it shows: `brew install mobai-app/tap/simslim`.
- Tool errors: `device_simslim_missing: simslim isn't installed. Ask the user to run brew install mobai-app/tap/simslim.`; `device_slim_failed: <reason>`; Android `device_unsupported: device_set_slim isn't available on Android.`
- No test runs simslim; no fixed sleeps in tests.

## Review Focus

1. **simslim installed while Alas runs:** the next popover open finds it, no relaunch (Task 2's lookup runs per call; checked by hand in Task 4).
2. **simslim fails half way** (simulator shut down meanwhile, a daemon that won't stop): the popover and tool show simslim's own reason, not a generic error (Task 1's failure test, Task 2's mapping).
3. **A simulator the user slimmed in a terminal, or with a custom profile:** the switch reads on, and turning it off brings every category back (Task 1's `categories` test; Task 4 by hand).
4. **A runtime before iOS 18.5:** the popover says slimming lasts until restart (`persistent` false; Task 1's parse test covers the field).
5. **An agent slimming while the user drives:** held like every other settings call (the generic `isInput` path, already pinned by `anAndroidCallWaitsForTheUserToHandBack`; `setSlim` must be in the `isInput` list, Task 2).

---

### Task 0: Does the stream survive a live slim?

The one assumption the prototype couldn't check. Do it before writing code.

- [ ] **Step 1:** Build and run Alas Dev from this worktree (AGENTS.md build command, then open the product).
- [ ] **Step 2:** Create a scratch simulator: `xcrun simctl create "Alas slim check" com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-26-5`, boot it, select it in Alas Dev's Devices tab, turn on the accessibility overlay.
- [ ] **Step 3:** `simslim on <udid> --no-reboot --except store,web` (download from the v0.14.0 release if it isn't on PATH, as `scripts/prototype-simslim/run.sh` on `nacho/evaluate-simslim-addition` does).
- [ ] **Step 4:** In Alas Dev: the screen still updates (press Home in the gutter, open Settings by clicking its icon), and the overlay still outlines elements after a click (it reads through the same `describe` as `device_snapshot`). Use the computer tools' screenshots of the Alas Dev window, or ask the user.
- [ ] **Step 5:** `simslim enable <udid> <all ids>` and repeat Step 4. Delete the scratch simulator.
- [ ] **Outcome A (expected):** both work. Continue with Task 1 as written.
- [ ] **Outcome B:** either breaks. Change Task 1's `set` to `on <udid> --except store,web` and `off <udid>` (both reboot, 10 to 16 s); in Task 3, after a change, bump `DeviceStage`'s `streamGeneration` for the udid (lift it into `DevicePaneModel` keyed by udid so the popover can bump it). Note the outcome in the design doc's "Unverified" section and commit it with Task 1.

---

### Task 1: AlasCore — `SimulatorSlim` and `device_set_slim` decoding

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorSlim.swift`
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Harness/DeviceCommand.swift`
- Test: create `Packages/AlasCore/Tests/AlasCoreTests/SimulatorSlimTests.swift`; modify `DeviceCommandTests.swift`

**Interfaces — Produces:**
- `public struct SimulatorSlimState: Equatable, Sendable { servicesOff: Int, services: Int, persistent: Bool, memoryBytes: Int64?, processes: Int?; var isSlim: Bool; var json: [String: Any] }` with a memberwise `public init`.
- `public enum SimulatorSlimError: Error, Equatable, LocalizedError { case notInstalled; case failed(String) }`
- `public enum SimulatorSlim { static let installCommand: String; static let keptCategories: [String]; static func state(status: Data, measure: Data?) throws -> SimulatorSlimState; static func categories(_ profiles: Data) throws -> [String]; static func failure(stderr: String, exitCode: Int32) -> SimulatorSlimError; static func state(simslim: String, udid: String) async throws -> SimulatorSlimState; static func set(simslim: String, udid: String, on: Bool) async throws -> SimulatorSlimState }`
- `DeviceCommand.setSlim(udid: String, on: Bool)`, tool name `device_set_slim`.

- [ ] **Step 1: Write the failing tests**

`SimulatorSlimTests.swift`:

```swift
import Foundation
import Testing
@testable import AlasCore

struct SimulatorSlimTests {
    @Test func statusAndMeasureMakeTheState() throws {
        let state = try SimulatorSlim.state(
            status: Data(#"{"managedDisabled":149,"managedTotal":173,"booted":true,"persistent":true,"verdict":"partially slim"}"#.utf8),
            measure: Data(#"{"processes":76,"bytes":998579814,"cpu":12.5}"#.utf8)
        )
        #expect(state == SimulatorSlimState(servicesOff: 149, services: 173, persistent: true, memoryBytes: 998_579_814, processes: 76))
        #expect(state.isSlim)
        #expect(state.json["memory_mb"] as? Int == 952)
    }

    @Test func anUnreadableMeasureLeavesMemoryOut() throws {
        let state = try SimulatorSlim.state(
            status: Data(#"{"managedDisabled":0,"managedTotal":173,"persistent":false}"#.utf8), measure: Data("{}".utf8)
        )
        #expect(!state.isSlim)
        #expect(!state.persistent)
        #expect(state.memoryBytes == nil)
        #expect(state.json["memory_mb"] == nil)
    }

    @Test func statusWithoutCountsIsAFailure() {
        #expect(throws: SimulatorSlimError.self) { try SimulatorSlim.state(status: Data(#"{"booted":true}"#.utf8), measure: nil) }
    }

    @Test func everyCategoryComesFromProfiles() throws {
        let profiles = Data(#"[{"id":"widgets","labels":["com.apple.chronod"]},{"id":"siri"},{"id":"store"}]"#.utf8)
        #expect(try SimulatorSlim.categories(profiles) == ["widgets", "siri", "store"])
    }

    @Test(arguments: [
        ("simslim: no simulator with udid X\n", "no simulator with udid X"),
        ("Slimming X…\nsimslim: simulator must be booted to read its state (it is Shutdown)\n",
         "simulator must be booted to read its state (it is Shutdown)"),
        ("", "simslim exited with status 1"),
    ])
    func aFailureNamesSimslimsReason(stderr: String, reason: String) {
        #expect(SimulatorSlim.failure(stderr: stderr, exitCode: 1) == .failed(reason))
    }
}
```

`DeviceCommandTests`: add `("device_set_slim", #"{"udid":"U","on":true}"#, .setSlim(udid: "U", on: true))` to the decoding arguments and `("device_set_slim", #"{"udid":"U"}"#)` to the malformed ones.

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path Packages/AlasCore --filter 'SimulatorSlimTests|DeviceCommandTests'`
Expected: build failure, `SimulatorSlim` and `.setSlim` undefined.

- [ ] **Step 3: Implement `SimulatorSlim.swift`**

```swift
import AlasPlatform
import Foundation

/// A simulator as simslim reports it. https://github.com/MobAI-App/simslim
public struct SimulatorSlimState: Equatable, Sendable {
    /// simslim's managed background services that are off, of `services`.
    public var servicesOff: Int
    public var services: Int
    /// False on runtimes before iOS 18.5, where slimming lasts until the simulator restarts.
    public var persistent: Bool
    public var memoryBytes: Int64?
    public var processes: Int?

    public init(servicesOff: Int, services: Int, persistent: Bool, memoryBytes: Int64?, processes: Int?) {
        self.servicesOff = servicesOff
        self.services = services
        self.persistent = persistent
        self.memoryBytes = memoryBytes
        self.processes = processes
    }

    public var isSlim: Bool { servicesOff > 0 }

    /// What `device_set_slim` returns.
    public var json: [String: Any] {
        var json: [String: Any] = ["slim": isSlim, "services_off": servicesOff, "services": services, "persistent": persistent]
        if let memoryBytes { json["memory_mb"] = Int((Double(memoryBytes) / 1_048_576).rounded()) }
        return json
    }
}

public enum SimulatorSlimError: Error, Equatable, LocalizedError {
    case notInstalled
    /// simslim's own reason.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "simslim isn't installed."
        case .failed(let reason): reason
        }
    }
}

/// Runs the user's simslim, which turns off the background services a
/// simulator doesn't need. Alas never installs it.
public enum SimulatorSlim {
    public static let installCommand = "brew install mobai-app/tap/simslim"
    /// Kept on: push tokens (apsd) and universal links (swcd).
    public static let keptCategories = ["store", "web"]

    /// From `status --json` and `measure --json`; memory is left out when `measure` is unreadable.
    public static func state(status: Data, measure: Data?) throws -> SimulatorSlimState {
        struct Status: Decodable {
            let managedDisabled: Int
            let managedTotal: Int
            let persistent: Bool
        }
        struct Measure: Decodable {
            let processes: Int
            let bytes: Int64
        }
        guard let read = try? JSONDecoder().decode(Status.self, from: status) else {
            throw SimulatorSlimError.failed("simslim status answered something Alas can't read.")
        }
        let memory = measure.flatMap { try? JSONDecoder().decode(Measure.self, from: $0) }
        return SimulatorSlimState(
            servicesOff: read.managedDisabled, services: read.managedTotal, persistent: read.persistent,
            memoryBytes: memory?.bytes, processes: memory?.processes
        )
    }

    /// Every category id in `profiles --json`, in order.
    public static func categories(_ profiles: Data) throws -> [String] {
        struct Category: Decodable { let id: String }
        guard let read = try? JSONDecoder().decode([Category].self, from: profiles) else {
            throw SimulatorSlimError.failed("simslim profiles answered something Alas can't read.")
        }
        return read.map(\.id)
    }

    /// simslim ends a failure with `simslim: <reason>` on stderr.
    public static func failure(stderr: String, exitCode: Int32) -> SimulatorSlimError {
        let prefix = "simslim: "
        let line = stderr.split(whereSeparator: \.isNewline).last { $0.hasPrefix(prefix) }
        return .failed(line.map { String($0.dropFirst(prefix.count)) } ?? "simslim exited with status \(exitCode)")
    }

    /// A booted simulator's state; simslim can't read a shut-down one.
    public static func state(simslim: String, udid: String) async throws -> SimulatorSlimState {
        let status = try await run(simslim, ["status", udid, "--json"])
        let measure = try? await run(simslim, ["measure", udid, "--json"])
        return try state(status: Data(status.utf8), measure: measure.map { Data($0.utf8) })
    }

    /// Slims a booted simulator, or brings every service back, without a reboot; then reads it back.
    public static func set(simslim: String, udid: String, on: Bool) async throws -> SimulatorSlimState {
        if on {
            _ = try await run(simslim, ["on", udid, "--no-reboot", "--except", keptCategories.joined(separator: ",")], timeout: 180)
        } else {
            let all = try categories(Data(try await run(simslim, ["profiles", "--json"]).utf8))
            _ = try await run(simslim, ["enable", udid, all.joined(separator: ",")], timeout: 180)
        }
        return try await state(simslim: simslim, udid: udid)
    }

    private static func run(_ simslim: String, _ args: [String], timeout: TimeInterval = 30) async throws -> String {
        let result = try await Process.run(simslim, args: args, timeout: timeout)
        guard result.exitCode == 0 else { throw failure(stderr: result.stderr, exitCode: result.exitCode) }
        return result.stdout
    }
}
```

- [ ] **Step 4: `DeviceCommand`**
  - Case, after `clearData`: `/// iOS only: simslim's profile on or off, without a reboot.` `case setSlim(udid: String, on: Bool)`.
  - `toolName`: `case .setSlim: "device_set_slim"`. `udid`: add `.setSlim(let udid, _)`.
  - `Params`: `var on: Bool?`. Allowed: `"device_set_slim": ["udid", "on"]`.
  - Decoding: `case "device_set_slim": guard let on = params.on else { throw AlasCLIRequestError.malformed }; return .setSlim(udid: try udid(), on: on)`.

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path Packages/AlasCore --filter 'SimulatorSlimTests|DeviceCommandTests'`
Expected: PASS. Then the whole package once (`swift test --package-path Packages/AlasCore`), since `DeviceCommand`'s exhaustive switches may have other users.

- [ ] **Step 6: Commit** `feat(devices): read and set simslim's state of a simulator`

---

### Task 2: Settings, backends, the control and the tool

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorSettings.swift` (protocol + `LiveSimulatorSettings`)
- Modify: `Alas/Sources/Devices/AppState+Devices.swift` (`bundled`), `DeviceBackend.swift`, `SimulatorBackend.swift`, `Android/AndroidBackend.swift`, `DeviceAgentControl.swift`, `Alas/Sources/App/DesignCaptureDevices.swift` (its `FakeSettings`)
- Modify: `AlasCLI/crates/alas-client/src/lib.rs`, `AlasCLI/crates/alas/src/mcp.rs`
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift`
- Test: `AlasTests/DeviceAgentControlTests.swift`, `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift`, the Rust tests in `mcp.rs`

**Interfaces:**
- Consumes: Task 1's `SimulatorSlim`, `SimulatorSlimState`, `SimulatorSlimError`, `DeviceCommand.setSlim`.
- Produces: `SimulatorSettingsControl.slim(udid:) async throws -> SimulatorSlimState`, `.setSlim(udid:on:) async throws -> SimulatorSlimState`; `DeviceBackend.slim(_:) async throws -> SimulatorSlimState`, `.setSlim(_:on:) async throws -> SimulatorSlimState`. Both throw `SimulatorSlimError` unchanged on iOS; Android throws `DeviceToolError.unsupported("device_set_slim")`.

- [ ] **Step 1: Fakes and failing tests** (`DeviceAgentControlTests`)

`FakeSettings` gains:

```swift
        /// nil: simslim isn't installed.
        var slimState: SimulatorSlimState? = SimulatorSlimState(
            servicesOff: 0, services: 173, persistent: true, memoryBytes: 3_865_470_566, processes: 254
        )
        func slim(udid: String) async throws -> SimulatorSlimState {
            guard let slimState else { throw SimulatorSlimError.notInstalled }
            return slimState
        }
        func setSlim(udid: String, on: Bool) async throws -> SimulatorSlimState {
            calls.append("slim \(on)")
            guard var state = slimState else { throw SimulatorSlimError.notInstalled }
            state.servicesOff = on ? 149 : 0
            state.memoryBytes = on ? 998_579_814 : 3_865_470_566
            slimState = state
            return state
        }
```

The Android `FakeBackend` gains:

```swift
        func slim(_ id: String) async throws -> SimulatorSlimState { throw DeviceToolError.unsupported("device_set_slim") }
        func setSlim(_ id: String, on: Bool) async throws -> SimulatorSlimState { throw DeviceToolError.unsupported("device_set_slim") }
```

Tests:

```swift
    @Test func aSimulatorSlimsAndReportsWhatItHolds() async {
        let settings = FakeSettings()
        let response = await control(FakeInput(), settings: settings).perform(.setSlim(udid: "on", on: true), sessionID: "s")
        #expect(response == .text([#"{"memory_mb":952,"persistent":true,"services":173,"services_off":149,"slim":true}"#]))
        #expect(settings.calls == ["slim true"])
    }

    @Test(arguments: [
        (nil as SimulatorSlimError?,
         "device_simslim_missing: simslim isn't installed. Ask the user to run brew install mobai-app/tap/simslim."),
        (.failed("simulator must be booted to read its state (it is Shutdown)"),
         "device_slim_failed: simulator must be booted to read its state (it is Shutdown)"),
    ])
    func aSlimFailureSaysWhatToDo(failure: SimulatorSlimError?, message: String) async {
        let settings = FakeSettings()
        settings.slimState = nil
        settings.slimFailure = failure
        let response = await control(FakeInput(), settings: settings).perform(.setSlim(udid: "on", on: true), sessionID: "s")
        #expect(error(response) == message)
    }
```

For the second test, `FakeSettings.setSlim` throws `slimFailure` when set, before the `notInstalled` guard: add `var slimFailure: SimulatorSlimError?` and `if let slimFailure { throw slimFailure }` as `setSlim`'s first line after recording the call.

Add to `whatAPlatformLacksIsUnsupported`'s arguments: `(.setSlim(udid: "emulator-5554", on: true), "device_unsupported: device_set_slim isn't available on Android.")`.

Holding while the user drives is the generic `isInput` path, pinned by `anAndroidCallWaitsForTheUserToHandBack`; don't add a per-tool copy.

- [ ] **Step 2: Run to see them fail**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/DeviceAgentControlTests test`
Expected: build failure on the missing protocol members and `.setSlim`.

- [ ] **Step 3: Settings protocol and live settings** (`SimulatorSettings.swift`)

Protocol:

```swift
    /// simslim's state of a booted simulator; `SimulatorSlimError.notInstalled` without simslim.
    func slim(udid: String) async throws -> SimulatorSlimState
    func setSlim(udid: String, on: Bool) async throws -> SimulatorSlimState
```

`LiveSimulatorSettings`:

```swift
    /// The simslim binary, looked up on each use so installing it while Alas runs works.
    public let simslim: @Sendable () -> String?

    public init(accessibilityHelper: URL? = nil, simslim: @escaping @Sendable () -> String? = { nil }) {
        self.accessibilityHelper = accessibilityHelper
        self.simslim = simslim
    }

    public func slim(udid: String) async throws -> SimulatorSlimState {
        try await SimulatorSlim.state(simslim: try simslimPath(), udid: udid)
    }

    public func setSlim(udid: String, on: Bool) async throws -> SimulatorSlimState {
        try await SimulatorSlim.set(simslim: try simslimPath(), udid: udid, on: on)
    }

    private func simslimPath() throws -> String {
        guard let path = simslim() else { throw SimulatorSlimError.notInstalled }
        return path
    }
```

`AppState+Devices.swift`, `bundled`:

```swift
    static var bundled: LiveSimulatorSettings {
        LiveSimulatorSettings(
            accessibilityHelper: Bundle.main.resourceURL?.appendingPathComponent("sim-ax-settings/alas-sim-ax-settings"),
            simslim: {
                // Homebrew or `go install`; a GUI app's PATH has neither.
                AgentPath.resolveExecutable(
                    named: "simslim", base: ProcessInfo.processInfo.environment["PATH"],
                    wellKnown: AgentPath.wellKnownDirectories + ["~/go/bin"]
                )
            }
        )
    }
```

`DesignCaptureDevices.FakeSettings`: `slim` answers a slim state (`servicesOff: 149, services: 173, persistent: true, memoryBytes: 998_579_814, processes: 76`), `setSlim` returns it.

- [ ] **Step 4: Backends and control**
  - `DeviceBackend`: `/// simslim's state of a booted simulator; iOS only.` `func slim(_ id: String) async throws -> SimulatorSlimState` and `func setSlim(_ id: String, on: Bool) async throws -> SimulatorSlimState`.
  - `SimulatorBackend`: `try await settings.slim(udid: id)` and `try await settings.setSlim(udid: id, on: on)`.
  - `AndroidBackend`: both `throw DeviceToolError.unsupported("device_set_slim")`.
  - `DeviceAgentControl.perform`: add `.setSlim` to the `isInput` list, and:

```swift
        case .setSlim(_, let on):
            do {
                return .text([Self.json(try await backend.setSlim(udid, on: on).json)])
            } catch SimulatorSlimError.notInstalled {
                return .error("device_simslim_missing: simslim isn't installed. Ask the user to run \(SimulatorSlim.installCommand).")
            } catch SimulatorSlimError.failed(let reason) {
                return .error("device_slim_failed: \(reason)")
            } catch let error as DeviceToolError {
                return .error(error.message)
            } catch {
                return .error("device_slim_failed: \(error.localizedDescription)")
            }
```

- [ ] **Step 5: Rust**
  - `alas-client/src/lib.rs`: `/// iOS only.` `SetSlim { udid: String, on: bool }`; add `| DeviceCommand::SetSlim { .. }` to `includes_screenshot`'s `false` arm; params: `DeviceCommand::SetSlim { udid, on } => ("device_set_slim", json!({ "udid": udid, "on": on }))`.
  - `mcp.rs`, tool definition after `device_clear_data`:

```rust
        json!({
            "name": "device_set_slim",
            "description": format!("Slim an iOS simulator with simslim, or bring it back to stock, without a reboot. Slim turns off about 150 background services and cuts the simulator's memory about 4x, so more simulators fit on the Mac; Siri, Spotlight, iCloud, widgets and the Photos and Contacts pickers stop working, while push notifications and universal links keep working. It stays slim across reboots on iOS 18.5 and newer. Takes up to 20 seconds. Returns slim, services_off, services, persistent and memory_mb. Needs simslim installed; Android devices don't support it. {DEVICE_DRIVING_NOTE}"),
            "annotations": { "readOnlyHint": false, "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "udid": udid,
                    "on": { "type": "boolean", "description": "true slims the simulator; false brings every service back." }
                },
                "required": ["udid", "on"]
            }
        }),
```

  - Parsing:

```rust
        "device_set_slim" => {
            reject_arguments(args, name, &["udid", "on"])?;
            Ok(Command::Device(alas_client::DeviceCommand::SetSlim {
                udid: required_limited_string(args, "udid", 64)?,
                on: optional_bool(args, "on")?.ok_or_else(|| "missing required argument 'on'".to_string())?,
            }))
        }
```

  - Tests: add `"device_set_slim"` after `"device_clear_data"` in the tool-name list and the `destructiveHint` list; add `("device_set_slim", json!({ "udid": "U" }), "missing required argument 'on'")` and `("device_set_slim", json!({ "udid": "U", "on": "yes" }), "on must be a boolean")` to the argument-error table.

- [ ] **Step 6: Preamble**
  - Tool list: `"device_set_appearance", "device_set_accessibility", "device_set_network", "device_clear_data", "device_set_slim",` in the source and both lists in `ACPMCPPromptPreambleTests`.
  - Platform sentence: `"device_push, device_set_accessibility and device_set_slim are iOS only; device_set_network and device_clear_data are Android only. "`, preceded by `"To run several simulators at once, slim each with device_set_slim first; it cuts a simulator's memory about 4x. "`.

- [ ] **Step 7: Run**
  - `cargo test --manifest-path AlasCLI/Cargo.toml -p alas -p alas-client`
  - `xcodebuild … -only-testing AlasTests/DeviceAgentControlTests -only-testing AlasTests/ACPMCPPromptPreambleTests test`; check the "Test run with N tests" line names both suites.
  Expected: PASS.

- [ ] **Step 8: Commit** `feat(devices): let agents slim simulators with simslim`

---

### Task 3: The Memory section in the settings popover

**Files:** Modify `Alas/Sources/Devices/DeviceSettingsPopover.swift`.

**Interfaces — Consumes:** `backend.slim(_:)`, `backend.setSlim(_:on:)`, `SimulatorSlimError`, `SimulatorSlim.installCommand`.

- [ ] **Step 1: State**

```swift
    @State private var slim: SimulatorSlimState?
    @State private var slimMissing = false
    @State private var slimApplying = false
    @State private var slimError: String?
```

- [ ] **Step 2: Section**, in `body` after Accessibility, iOS only:

```swift
            if platform == .ios {
                section("Memory") { slimRows }
                Divider()
            }
```

```swift
    // MARK: Memory

    @ViewBuilder
    private var slimRows: some View {
        if slimMissing {
            HStack {
                Text("Slim simulator")
                Spacer()
                Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(true)
            }
            note("Install simslim to cut this simulator's memory about 4x:", tone: "fg-dim")
            HStack(spacing: 6) {
                Text(SimulatorSlim.installCommand)
                    .font(scale.meta.font(design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SimulatorSlim.installCommand, forType: .string)
                }
                .controlSize(.small)
            }
        } else if let slim {
            HStack {
                Text("Slim simulator")
                Spacer()
                if slimApplying { ProgressView().controlSize(.small) }
                Toggle("", isOn: Binding(get: { slim.isSlim }, set: setSlim))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(slimApplying)
            }
            note(Self.slimSummary(slim), tone: "fg-dim")
            if slim.isSlim, !slim.persistent {
                note("Lasts until the simulator restarts on this iOS version.", tone: "fg-faint")
            }
        } else if slimError == nil {
            ProgressView().controlSize(.small)
        }
        if let slimError { note(slimError, tone: "warn") }
    }

    private static func slimSummary(_ slim: SimulatorSlimState) -> String {
        let memory = slim.memoryBytes.map { bytes in
            let gigabytes = (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(2)))
            return slim.processes.map { "\(gigabytes) GB in \($0) processes. " } ?? "\(gigabytes) GB. "
        } ?? ""
        let services = slim.isSlim ? "\(slim.servicesOff) of \(slim.services) background services are off." : "All background services run."
        return memory + services
    }

    private func setSlim(_ on: Bool) {
        slimApplying = true
        mutate(report: { message in
            slimError = message
            slimApplying = false
        }) {
            do {
                slim = try await backend.setSlim(udid, on: on)
                slimError = nil
            } catch {
                slimError = error.localizedDescription
            }
            slimApplying = false
        }
    }
```

- [ ] **Step 3: Load**, in `load()` inside the `platform == .ios` branch after accessibility:

```swift
            do {
                slim = try await backend.slim(udid)
            } catch SimulatorSlimError.notInstalled {
                slimMissing = true
            } catch {
                slimError = error.localizedDescription
            }
```

Read it after the display and accessibility reads so a slow `measure` doesn't hold them up. If `DeviceSettingsPopover` lacks `import AppKit` for `NSPasteboard`, add it (SwiftUI on macOS usually brings it; follow the file's build error).

- [ ] **Step 4: Build** with the AGENTS.md build command. If the design capture covers the popover (`DesignCaptureDevices`' settings panel), capture it and look at the Memory section with the fake slim state.

- [ ] **Step 5: Commit** `feat(devices): add a Slim simulator switch to the simulator settings`

---

### Task 4: Docs and end to end

**Files:** Modify `docs/devices.md`, `docs/plans/2026-11-04-device-panel-design.md` (only if it lists simulator memory as a follow-up).

- [ ] **Step 1: `docs/devices.md`**
  - After the accessibility paragraph in Simulators: "With [simslim](https://github.com/MobAI-App/simslim) installed (`brew install mobai-app/tap/simslim`), the settings' Memory section slims the simulator: simslim turns off about 150 background services it doesn't need, which cuts its memory from about 3.9 GB to under 1 GB, so more simulators fit on the Mac. Siri, Spotlight, iCloud, widgets and the Photos and Contacts pickers stop working; push notifications and universal links keep working. The switch applies without a reboot, and on iOS 18.5 and newer the simulator stays slim across reboots until you turn it off. Alas runs your simslim and never installs it."
  - Agents table, after `device_clear_data`: `| device_set_slim | Slims a simulator with simslim, or brings it back to stock, and returns its memory. iOS only; needs simslim. |`

- [ ] **Step 2: End to end**, with the real simslim on a scratch simulator (create, boot, delete afterwards), against Alas Dev:
  - Open the popover: the Memory section shows "All background services run." with memory.
  - Turn it on: spinner, then about 1 GB and "149 of 173 background services are off."; the screen keeps working.
  - Turn it off: back to "All background services run."
  - Slim it in a terminal with plain `simslim on <udid> --no-reboot` (the full profile); reopen: the switch is on, 173 of 173.
  - With no `simslim` where Alas looks (if Homebrew's is the only one, `mv /opt/homebrew/bin/simslim /tmp/` while testing): reopen the popover; the hint and Copy button show. Put it back and reopen without relaunching Alas Dev: the switch shows.
  - Through the tool: `device_set_slim` on and off from an agent session in Alas Dev with the device setting on; on an Android emulator if one is available, `device_unsupported`.
  Record what ran in the PR description; anything not run is listed as not run.

- [ ] **Step 3: Lint and commit** `docs(devices): describe slimming simulators with simslim`
