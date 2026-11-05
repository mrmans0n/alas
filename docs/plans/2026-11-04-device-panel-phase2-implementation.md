# Device panel, phase 2: agent tools

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ACP agents can list, open, read, screenshot and drive the iOS simulator the user sees in the Device tab, through `device_*` tools in the built-in `alas` MCP server, while the user can see who is driving and take over.

**Architecture:** Eight MCP-only tools travel the existing path: `mcp.rs` → `alas_client::Command::Device` → socket → `AlasCLIRequest.Command.device` → `AlasCLICommandRouter` (same caller rule as `computer_*`) → an AppState device controller. The controller reuses phase 1's XPC client for touches, keys and buttons; adds an accessibility snapshot call to `AlasSimService`; keeps an agent "lease" on a device's stream so screenshots work with the Device tab closed; and records who drives each device with the existing `VMDriver` model. The Device tab shows the driver and blocks user input while an agent drives, with Take over / Hand back.

**As built (2026-11-05):** `DeviceCommand` became an enum with associated values (`.tap(udid:target:includeScreenshot:)` and so on) instead of the struct of optionals below, and `DeviceCommand.decode(toolName:data:)` takes the tool name. Snapshot frames are rounded to whole points. The lease test (`theLeaseEndsAfterTheIdleWindow`) was dropped as timer wiring; the end-to-end run checked the lease instead. `device_open` on a never-booted simulator took 139 s in that run.

**Tech stack:** Rust (alas CLI and MCP server), Swift 6, SwiftUI/AppKit, NSXPCConnection, Swift Testing, `cargo test`.

**Spec:** `docs/plans/2026-11-04-device-panel-design.md`, section "Phase 2 outline: agent tools". This plan changes two of its points; see Decisions.

## Decisions (review these)

1. **Tools are always listed and refused when off,** like `computer_*`. The design said "hidden when off", but `tools/list` does not know app settings: hiding needs new plumbing from the app into `McpEnv` plus a refusal for MCP servers started before a change. Refusal: `device_disabled: Device control is off. Ask the user to turn on Settings › Advanced › Experiments › Let agents use the device.`
2. **Take over refuses, it does not pause the agent.** While the user drives, every device call answers `device_user_active: The user is driving this device. Try again after they hand it back.` VM takeover also stops and resumes agent turns (`VMTakeOvers`); devices skip that for now. It goes on the follow-up list.
3. **`device_type` takes ASCII text.** It sends USB HID keys on a US layout (Shift for capitals and symbols, Return for `\n`). Other characters fail with `device_type_unsupported` naming the first one.
4. **Coordinates follow `computer_*`.** `device_snapshot` frames are screen points. `device_tap` and `device_swipe` take either a `ref` from the latest snapshot or `x`/`y` in pixels of the latest `device_screenshot`.
5. **The agent's stream is a lease.** `device_open` and every device call keep the device's stream running for 60 seconds after the agent's last call, so screenshots work with the Device tab closed. The lease then ends; if the tab is not showing the device, the stream stops.
6. **`device_open` shows the device.** It boots the simulator if needed, selects it in the Device tab, and, when the Device panel is on, switches the agent's worktree's right pane to Device and shows the pane, the way `preview_open` opens a tab.

## Spike evidence

On 2026-11-04, a throwaway build of `AlasSimService` with a describe call (since reverted) returned the accessibility tree for an iOS 26.5 home screen: 4245 bytes in 3.9 s cold, 0.76 s warm, element frames in points (`402×874` root). It needs `SimFrameworks.load()` first; without capture running the bridge answered "Device … not found". The host was an ad hoc Alas Dev test host, which almost certainly had no Accessibility grant, so the snapshot does not appear to need that permission [INFERENCE].

## Global constraints

- Everything in phase 1's plan "Global constraints" still holds: English, Swift Testing, no `.serialized`/`@MainActor` extras, `xcodegen` after `project.yml` or new app files, Conventional Commits, no agent attribution, vendored serve-sim files untouched (only `AlasSimulatorSession.swift` is ours).
- Rust tests: `cargo test --manifest-path AlasCLI/Cargo.toml -p alas -p alas-client`.
- AlasCore tests: `swift test --package-path Packages/AlasCore --filter <Suite>`.
- App tests: the focused `xcodebuild … -only-testing AlasTests/<Suite> test` command.
- Two literal tool inventories must change together: Rust `tools_list_returns_all_tools` and Swift `ACPMCPPromptPreamble.builtInToolNames` with its `toolNameInventory` test.
- Error codes are a prefix and a colon, like `computer_*`: `device_disabled`, `device_user_active`, `device_not_found`, `device_not_booted`, `device_no_snapshot`, `device_stale_ref`, `device_no_screenshot`, `device_type_unsupported`, `device_unavailable`.
- Limits: snapshot `limit` 1–1000 (default 200), `query` ≤ 256 bytes, `device_type` text ≤ 4096 bytes, swipe `duration_ms` 50–5000 (default 300), screenshot long edge ≤ 1280 px.

## Tools

| Tool | Arguments | Result |
|---|---|---|
| `device_list` | none | `{"devices":[{"udid","name","runtime","state"}]}` from `SimulatorControl.devices()` |
| `device_open` | `udid` | Boots if needed, selects it, starts the lease. `{"udid","name","runtime","state":"booted"}` |
| `device_snapshot` | `udid`, `query?`, `limit?` | `{"screen":{"width","height"},"elements":[{"ref","role","label","value","id","frame","enabled"}],"truncated"}`; frames in points |
| `device_screenshot` | `udid` | Native MCP image plus `{"width","height"}` in image pixels |
| `device_tap` | `udid`, `ref` or `x`+`y`, `include_screenshot?` | `{"ok":true}`, or the screenshot result |
| `device_swipe` | `udid`, `direction` or `from_x`+`from_y`+`to_x`+`to_y`, `duration_ms?`, `include_screenshot?` | same |
| `device_type` | `udid`, `text`, `include_screenshot?` | same |
| `device_button` | `udid`, `name` (`home`, `lock`, `siri`, `side_button`, `app_switcher`), `include_screenshot?` | same |

All are screen-bound (hidden in headless and workspace scopes) and refused for callers that are not worktree ACP agent sessions, exactly like `computer_*`.

## Review focus

1. The user takes over in the middle of an agent's swipe: the swipe stops sending moves, ends the touch, and the call answers `device_user_active`. Task 5, `aTakeoverDuringAnAgentGestureEndsItAndRefuses` (app suite with a fake XPC client).
2. A ref from an earlier snapshot of the same device answers `device_stale_ref` instead of tapping whatever now has its position in the list. Refs carry their snapshot number (`s2e3`). Task 2, `refsCarryTheirSnapshot`; Task 5, `aRefFromAnEarlierSnapshotIsRefused`.
3. `device_tap` with `x`/`y` before any screenshot of that device answers `device_no_screenshot` instead of guessing a scale. Task 5, `tapByPointBeforeAnyScreenshotIsRefused`.
4. `device_type "Hello, World!\n"` presses Shift only around `H`, `W` and `!`, and ends with Return. Task 2, `textBecomesKeyPressesWithShiftWhereNeeded`.
5. The lease ends 60 s after the agent's last call and does not stop a stream the Device tab is still showing. Task 5 (counted subscriptions, already tested in phase 1) and Task 7 manual step 3.

---

### Task 1: Wire format in Rust

**Files:**
- Modify: `AlasCLI/crates/alas-client/src/lib.rs` (`Command`, `build_request`, tests near `vm_commands_serialize_as_params_only_requests`)
- Modify: `AlasCLI/crates/alas/src/mcp.rs` (definitions, scope, mapping, worker, image result, tests)

**Interfaces:**
- Produces:

```rust
pub enum DeviceCommand {
    List,
    Open { udid: String },
    Snapshot { udid: String, query: Option<String>, limit: u64 },
    Screenshot { udid: String },
    Tap { udid: String, target: DeviceTarget, include_screenshot: bool },
    Swipe { udid: String, gesture: DeviceSwipe, duration_ms: u64, include_screenshot: bool },
    Type { udid: String, text: String, include_screenshot: bool },
    Button { udid: String, name: String, include_screenshot: bool },
}
pub enum DeviceTarget { Ref(String), Point { x: f64, y: f64 } }
pub enum DeviceSwipe { Direction(String), Points { from_x: f64, from_y: f64, to_x: f64, to_y: f64 } }
impl DeviceCommand { pub fn includes_screenshot(&self) -> bool }
// Command::Device(DeviceCommand)
```

Wire: `command` is the tool name (`device_tap`), all arguments in `params`, e.g. `{"udid":"…","ref":"s2e3","include_screenshot":true}` or `{"udid":"…","x":120.5,"y":300}`.

- [ ] **Step 1: Failing client test.** In `alas-client/src/lib.rs` tests, add `device_commands_serialize_as_params_only_requests`: build each variant with `build_request(Command::Device(…), None, None)` and assert `command` and `params` (list → `{}`; snapshot default limit appears as `200`; swipe with `Direction("up")` → `{"udid","direction":"up","duration_ms":300,"include_screenshot":false}`).
- [ ] **Step 2: Failing MCP tests** in `mcp.rs` tests:
  - `device_tools_validate_arguments_and_map_to_commands`: one accepted call per tool; refusals for an unknown key (`device_tap does not accept 'window_id'`), `ref` together with `x`, `x` without `y`, `direction` together with `from_x`, an unknown button, `limit` 0 and 1001, empty `text`.
  - `device_screenshot_result_extracts_mcp_image_and_keeps_metadata_text` and `device_action_with_include_screenshot_returns_mcp_image`, copying the computer versions.
  - Extend `headless_scope_hides_screen_bound_tools` and `computer_tools_are_read_only_and_absent_from_relays_and_workspace_mode` (or a device twin) with `device_*`.
  - Add the eight names to `tools_list_returns_all_tools` after `vm_status`, in table order.
- [ ] **Step 3: Run and see them fail.** `cargo test --manifest-path AlasCLI/Cargo.toml -p alas -p alas-client device`.
- [ ] **Step 4: Implement the client.** Add `DeviceCommand`, `DeviceTarget`, `DeviceSwipe`, `Command::Device`, and a `device_request(&DeviceCommand) -> Request` arm in `build_request` that sets `Request::new("device_…")` and `params`. `includes_screenshot` is true for `Screenshot` and for actions with `include_screenshot`.
- [ ] **Step 5: Implement the server.**
  - `device_tool_definitions()` after `vm_tool_definitions()` in `all_tool_definitions` (line 616). Descriptions state the coordinate rule (decision 4), ref lifetime ("valid until the next device_snapshot of that device"), `device_user_active`, and that `device_open` boots and shows the device. `device_list`, `device_snapshot`, `device_screenshot` get `"readOnlyHint": true`; the rest `"readOnlyHint": false, "destructiveHint": true`.
  - `is_headless_hidden`: add `name.starts_with("device_")`. Leave `is_workspace_tool` alone.
  - `command_for_tool`: one arm per tool using `reject_arguments`, `required_limited_string(args, "udid", 64)`, `optional_bounded_u64`, `optional_enum`, `optional_bool`, and a new `optional_coordinate(args, key) -> Result<Option<f64>, String>` (finite, ≥ 0, ≤ 100000).
  - `runs_on_worker`: add `Command::Device(..)`.
  - `tool_result`: add `|| matches!(command, Command::Device(device) if device.includes_screenshot())`.
  - `success_message`: `Command::Device(_) => "Done.".into()` for bare-ok replies.
- [ ] **Step 6: Run the tests.** Expected: PASS, including the updated inventory test.
- [ ] **Step 7: Commit.** `feat(devices): add device tools to the built-in MCP server`

---

### Task 2: Requests, snapshots and text in AlasCore

**Files:**
- Create: `Packages/AlasCore/Sources/AlasAgentKit/Harness/DeviceCommand.swift`
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Harness/AlasCLIRequest.swift` (case + `device_` prefix decoding next to `computer_`, line ~768)
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceSnapshot.swift`
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceTextInput.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/DeviceCommandTests.swift`, `DeviceSnapshotTests.swift`, `DeviceTextInputTests.swift`

**Interfaces:**
- Produces:

```swift
public struct DeviceCommand: Equatable, Sendable {
    public enum Action: String, Sendable { case list, open, snapshot, screenshot, tap, swipe, type, button }
    public enum Target: Equatable, Sendable { case ref(String), point(x: Double, y: Double) }
    public enum Swipe: Equatable, Sendable {
        case direction(DeviceSwipeDirection)
        case points(fromX: Double, fromY: Double, toX: Double, toY: Double)
    }
    public let action: Action
    public let udid: String?          // nil only for .list
    public let query: String?
    public let limit: Int             // snapshot, default 200
    public let target: Target?        // tap
    public let swipe: Swipe?          // swipe
    public let durationMs: Int        // swipe, default 300
    public let text: String?          // type
    public let button: String?        // button
    public let includeScreenshot: Bool
    public static func decode(action: Action, data: Data) throws -> DeviceCommand
}
public enum DeviceSwipeDirection: String, Sendable { case up, down, left, right }
// AlasCLIRequest.Command: case device(DeviceCommand)

public struct DeviceElement: Equatable, Sendable {
    public let ref: String, role: String, label: String?, value: String?, id: String?
    public let x: Double, y: Double, width: Double, height: Double
    public let enabled: Bool
}
public struct DeviceSnapshot: Equatable, Sendable {
    public let screenWidth: Double, screenHeight: Double
    public let elements: [DeviceElement]
    /// serve-sim's `describeUI` JSON: an array whose first node is the application, frames in points.
    /// `generation` numbers this device's snapshots; refs are `s<generation>e<index>`.
    public static func parse(_ json: Data, generation: Int) throws -> DeviceSnapshot
    public let generation: Int
    public func filtered(query: String?, limit: Int) -> (elements: [DeviceElement], truncated: Bool)
    public func element(ref: String) -> DeviceElement?
    /// The element's center, 0 to 1 across the screen.
    public func center(of element: DeviceElement) -> DeviceScreenPoint
    public func json(query: String?, limit: Int) -> String
}

public enum DeviceTextInput {
    public struct Press: Equatable, Sendable { public let usage: UInt32; public let shift: Bool }
    /// Nil names the first character the US HID layout can't type.
    public static func presses(for text: String) -> Result<[Press], DeviceTextInputError>
}
public struct DeviceTextInputError: Error, Equatable { public let character: Character }
```

- Snapshot rules: depth-first; skip the root application node (its frame is the screen); keep a node when it has a non-empty label, value or id, or its `type` is one of `Button`, `TextField`, `SecureTextField`, `SearchField`, `Switch`, `Slider`, `Cell`, `Link`, `Tab`; refs `s<generation>e1`, `s<generation>e2`, … in that order; `role` is `role_description`, falling back to `type`. Query matches role, label, value and id, case-insensitively.
- Text rules: `a`–`z` → 0x04…0x1D; `A`–`Z` → same with shift; `1`–`9`,`0` → 0x1E…0x27; space 0x2C; `\n` 0x28; `\t` 0x2B; `-=[]\;'` `` ` `` `,./` → their unshifted usages; `_+{}|:"~<>?!@#$%^&*()` → the same keys with shift.

- [ ] **Step 1: Failing tests.**
  - `DeviceCommandTests`: `decodesEachActionWithDefaults` (one request JSON per action, parameterized), `rejectsParamsAnActionDoesNotTake`, `tapNeedsExactlyOneTarget`, `swipeNeedsADirectionOrBothPoints`.
  - `DeviceSnapshotTests` with a fixture literal shaped like the spike output (application root 402×874, a Maps widget button, a labelled cell, an unlabelled group, a text field): `keepsLabelledAndInteractiveNodesInOrder`, `refsCarryTheirSnapshot` (generation 2 gives `s2e1`…; `element(ref: "s1e1")` on it is nil), `centerIsAFractionOfTheScreen`, `queryAndLimitFilter` (parameterized).
  - `DeviceTextInputTests`: `textBecomesKeyPressesWithShiftWhereNeeded` with `"Hello, World!\n"`, `stopsAtTheFirstCharacterItCannotType` with `"café"`.
- [ ] **Step 2: Run, see failures** (`cannot find 'DeviceCommand'`).
- [ ] **Step 3: Implement** the three files and the `AlasCLIRequest` case. `DeviceCommand.decode` follows `ComputerUseCommand.decode`: decode a `Params` struct with every optional field, reject keys outside the action's allowed set (`AlasCLIRequestError.malformed`), apply defaults, validate ranges.
- [ ] **Step 4: Run the three suites plus `ComputerUseCommandTests`.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(devices): decode device tool requests and read simulator snapshots`

---

### Task 3: Snapshot over XPC

**Files:**
- Modify: `ThirdParty/serve-sim-native/Sources/ServeSimCore/AlasSimulatorSession.swift` (ours)
- Modify: `Alas/Sources/Devices/SimServiceProtocol.swift`, `Alas/Sources/SimService/SimServiceHandler.swift`, `Alas/Sources/Devices/SimulatorStreamClient.swift`

**Interfaces:**
- Produces: `public static func describeUI(udid: String) throws -> Data` on `AlasSimulatorSession` (calls `SimFrameworks.load()` then `AccessibilityBridge.shared.describeUI(udid:)`); XPC `func describe(udid: String, reply: @escaping @Sendable (Data?, String?) -> Void)`, run on a global queue in the service; `SimulatorStreamClient.describe(udid:) async throws -> Data`, and `SimulatorStreamClient.lastFrame(udid:) -> IOSurface?` (the client keeps the newest frame per watched device).

No unit test: this forwards to vendored code. Task 7 runs it.

- [ ] **Step 1:** Add the static facade method; it loads the frameworks itself so it works without a running capture.
- [ ] **Step 2:** Add `describe` to the protocol, the handler (`DispatchQueue.global(qos: .userInitiated).async`) and the client (a checked continuation; an XPC error or a nil reply throws `device_unavailable: …`).
- [ ] **Step 3:** In `SimulatorStreamClient.deliver`, store `lastFrames[udid] = surface` before fanning out; clear it when the device's last subscriber leaves.
- [ ] **Step 4:** Build. Commit: `feat(devices): read a simulator's accessibility tree through AlasSimService`

---

### Task 4: Settings and caller routing

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasModel/Persistence/AppConfig.swift` (`deviceAgentsEnabled`, same five places as `devicePanelEnabled`)
- Modify: `Alas/Sources/Settings/AdvancedPane.swift` (second row under Device panel: "Let agents use the device", disabled while Device panel is off)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCLICommandRouter.swift` (`deviceCommand: (DeviceCommand, String) async -> AlasCLIResponse`, dispatched through `computerUseCaller` with refusal `device_unsupported_caller: Device tools are only available to ACP agent sessions.`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCLICommandRouter+Headless.swift` (add `.device` to the screen-bound set)
- Modify: `Alas/Sources/App/AppState.swift` `makeCLICommandRouter()` (wire `deviceCommand` to `performDeviceCommand(_:sessionID:)`, Task 5)
- Test: extend `AlasTests/WebPreviewAutomationRoutingTests.swift` `computerCommandsRefuseNonACPCallers` to also send a `device_tap`; extend `Packages/AlasCore/Tests/AlasCoreTests/HeadlessCLIRouterTests.swift` with a device command.

- [ ] **Step 1:** Extend both tests; run; see them fail.
- [ ] **Step 2:** Implement; `performDeviceCommand` can return `.error("device_unavailable: not implemented")` until Task 5 lands in the same branch.
- [ ] **Step 3:** Run both suites. Commit: `feat(devices): route device tools from agent sessions`

---

### Task 5: The device controller

**Files:**
- Create: `Alas/Sources/Devices/AppState+Devices.swift`
- Create: `Alas/Sources/Devices/DeviceAgentControl.swift`
- Modify: `Alas/Sources/Devices/DevicePaneModel.swift` (driver state)
- Modify: `Packages/AlasCore/Sources/AlasPlatform/VM/VMDriving.swift` (add `DeviceDriverMessages.userDriving`)

**Interfaces:**
- Consumes: `DeviceCommand`, `DeviceSnapshot`, `DeviceTextInput` (Task 2); `describe`, `lastFrame` (Task 3); `VMDriver.current`, `VMDriver.decision`.
- Produces:

```swift
@MainActor protocol DeviceInput: AnyObject {          // SimulatorStreamClient conforms
    func subscribe(udid: String, onFrame: @escaping @MainActor (IOSurface) -> Void,
                   onStop: @escaping @MainActor (String) -> Void) -> UUID
    func unsubscribe(udid: String, token: UUID)
    func touch(udid: String, phase: String, point: DeviceScreenPoint)
    func key(udid: String, usage: UInt32, down: Bool)
    func button(udid: String, name: String)
    func describe(udid: String) async throws -> Data
    func lastFrame(udid: String) -> IOSurface?
}
@MainActor final class DeviceAgentControl {
    init(input: DeviceInput, devices: @escaping () async throws -> [SimulatorDevice],
         boot: @escaping (String) async throws -> Void, now: @escaping () -> Date = Date.init)
    func perform(_ command: DeviceCommand, sessionID: String) async -> AlasCLIResponse
    func driver(udid: String) -> VMDriver
    func takeOver(udid: String)
    func handBack(udid: String)
}
```

Behavior:
- Every call except `device_list` checks, in order: device exists (`device_not_found`), booted (`device_not_booted`, except `device_open`), driver (`device_user_active` when taken over). Then it records `(sessionID, tool, now)` as the device's last agent call and marks it in flight for the call's duration.
- Lease: the first call on a device subscribes with no-op handlers; each call reschedules a 60 s release Task; the release unsubscribes.
- Snapshot: `describe` → `DeviceSnapshot.parse(_, generation:)` with the device's next generation number → stored per udid (replacing the previous) → `json(query:limit:)`.
- Screenshot: waits up to 5 s for `lastFrame`, scales to a 1280 px long edge with Core Image, PNG, records the image size per udid, returns `{"width","height","image":{"mime_type":"image/png","data":…}}` as `.text([json])`.
- Tap: ref → `snapshot.center(of:)` (`device_no_snapshot` / `device_stale_ref`); point → divide by the recorded screenshot size (`device_no_screenshot`); begin, 50 ms, end.
- Swipe: direction → from and to at 25% and 75% of the screen across the middle; points → screenshot pixels; begin, a move every 16 ms over `durationMs`, end. Before each move it rechecks the driver; a takeover ends the touch at the current point and returns `device_user_active`.
- Type: `DeviceTextInput.presses`; per press, Shift down if needed, key down, key up, Shift up; 20 ms between presses.
- Button: `client.button`.
- `include_screenshot`: after the action, wait 300 ms, then return the screenshot result.
- `device_open`: boot through `SimulatorControl.boot` when shut down, set `devicePane.selectedUDID`, start the lease, and when `config.devicePanelEnabled` is on, set the session's worktree right pane to `.device` and make the right pane visible.
- Settings gate in `AppState.performDeviceCommand`: both `devicePanelEnabled` and `deviceAgentsEnabled` must be on, else `device_disabled`.

- [ ] **Step 1: Failing tests** in `AlasTests/DeviceAgentControlTests.swift` with a `FakeDeviceInput` that records calls and serves a fixture snapshot and a 120×240 IOSurface:
  - `refusesUnknownAndShutDownDevices` (parameterized).
  - `aTakeoverRefusesTheNextCall` and `handingBackLetsCallsThrough`.
  - `aTakeoverDuringAnAgentGestureEndsItAndRefuses`: start a 500 ms swipe, take over after the first move, expect a final `end` touch and `device_user_active`.
  - `tapByRefAndByPointMapToTheSameScreenFraction`.
  - `aRefFromAnEarlierSnapshotIsRefused`: snapshot twice, tap a ref from the first, expect `device_stale_ref` and no touch.
  - `tapByPointBeforeAnyScreenshotIsRefused`.
  - `typingSendsShiftOnlyAroundShiftedCharacters`.
  - `theLeaseEndsAfterTheIdleWindow` with an injected clock and an injected `sleep` the test controls (no real waiting).
- [ ] **Step 2: Run, see failures.**
- [ ] **Step 3: Implement** `DeviceAgentControl`, the `DeviceInput` conformance on `SimulatorStreamClient`, `AppState.deviceControl` (created next to `simulatorStreams`), and `performDeviceCommand`.
- [ ] **Step 4: Run the suite plus `RightPaneTabTests`.** Commit: `feat(devices): let agents drive a simulator`

---

### Task 6: Show who is driving

**Files:**
- Modify: `Alas/Sources/Devices/DeviceTabView.swift`, `Alas/Sources/Devices/DeviceScreenView.swift`
- Reuse: `VMDriverStatus.make(driver:agentName:now:)` from `Alas/Sources/VM/VMTabScreen.swift`

**Interfaces:**
- Consumes: `DeviceAgentControl.driver/takeOver/handBack`.
- Produces: `DeviceScreenView(allowsInput: Bool, onBlockedClick: () -> Void)`.

No new test: `VMDriverStatus.make` and `VMDriver` are already tested; the view only renders them.

- [ ] **Step 1:** Under the device picker, a status row from `VMDriverStatus.make(driver:agentName:now:)` (agent name from the session, as the VM tab resolves it) with Take over / Hand back buttons, refreshed every second while visible.
- [ ] **Step 2:** `DeviceScreenNSView` ignores mouse and key events while `allowsInput` is false (releasing anything held when it flips), and calls `onBlockedClick` on a click, which shows "Take over to use the device" for 2 seconds.
- [ ] **Step 3:** Build. Commit: `feat(devices): show when an agent drives the simulator`

---

### Task 7: Agent guidance, docs, and an end-to-end check

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift` (`builtInToolNames` + a short Device section shown when the session can use computer tools)
- Modify: `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift` (`toolNameInventory`, guidance phrase test)
- Modify: `docs/devices.md` (agent control, settings, takeover, tool list), `docs/headless-host.md:228-231` (add `vm_*` and `device_*` to the hidden list)
- Modify: `docs/plans/2026-11-04-device-panel-design.md` (check off the phase 2 outline, add "pause agent turns on takeover" to Follow-up work)

- [ ] **Step 1:** Update the preamble and its tests; run `ACPMCPPromptPreambleTests`.
- [ ] **Step 2:** Docs.
- [ ] **Step 3: End to end.** A throwaway test in the app test host (deleted before commit) that drives `AppState.performDeviceCommand` against a freshly created iOS simulator: list, open (boots it), snapshot, tap a ref (Settings), screenshot, swipe up, type in search, button home, take over then a refused call, hand back, and confirm the lease ends after 60 s with no Device tab open. Then a real agent check: run Alas Dev on a scratch profile (`open -n --env ALAS_APP_SUPPORT_DIR=…`), turn both settings on, and ask an agent session to open Settings › General on a simulator. The user does this step; computer use cannot drive Alas Dev.
- [ ] **Step 4: Commit.** `docs(devices): document agent device control`
