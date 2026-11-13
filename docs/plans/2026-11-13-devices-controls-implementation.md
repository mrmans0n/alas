# Devices rotation, recording and hidden device tools: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rotate simulators (you and agents), record their screens (you and
agents), and hide `device_*` tools from sessions started while the setting is
off.

**Architecture:** The interface orientation travels with every frame from
the vendored capture to the app (`DeviceFrame`). One AlasCore type,
`DeviceScreenOrientation`, maps upright points to the portrait panel and
gives the CIImage/CALayer rotation; the screen view, the agent's taps and
swipes, and screenshots all use it. `DeviceRecorder` owns one `simctl io
recordVideo` per simulator. Hiding is an env flag read by the Rust server at
start and a preamble flag.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, Swift Testing, Rust (`AlasCLI`).

**Spec:** `docs/plans/2026-11-13-devices-controls-design.md`

## Global Constraints

- AlasCore must not import AppKit or SwiftUI; anything the app uses from it is `public`.
- Vendored serve-sim files are never edited; only `ThirdParty/serve-sim-native/Sources/ServeSimCore/AlasSimulatorSession.swift`.
- Tests use Swift Testing; extend existing suites; no fixed sleeps; `eventually(_:within:_:)` for polling.
- Frame orientation names (observed on iOS 26.5): `portrait`, `landscape_left`, `landscape_right`, `portrait_upside_down`; anything else counts as portrait.
- UIDeviceOrientation values for `sendOrientation`: portrait 1, portrait_upside_down 2, landscape_right 3, landscape_left 4. Device 4 gives frames named `landscape_left`, device 3 `landscape_right`.
- A `landscape_left` panel frame shows upright after a 90° clockwise turn; `landscape_right` after 90° counterclockwise; upside down after 180°.
- Rotate left (counterclockwise) from portrait: portrait → landscape_left → portrait_upside_down → landscape_right → portrait. Rotate right is the reverse.
- Recording: `simctl io <udid> recordVideo --codec=h264 --force <file>`, stop with SIGINT, wait ≤ 5 s, then terminate; agents' limit 10 minutes; agent files in `~/Library/Caches/Alas/Recordings/`, older than 7 days deleted at launch.
- `swiftformat --lint` must pass on every changed Swift file (CI's "Check formatting"): no semicolons.
- Commit with explicit paths; Conventional Commits; after adding app files run `xcodegen` and commit only the new-file pbxproj hunks.

## Review Focus

- A tap by ref in landscape must land on the element, not its mirror (Task 3 test on the ref path).
- `device_screenshot` pixels after rotating must map back to the same spot (Task 3 test: pixel tap in landscape).
- A simulator that shuts down while recording must not leave the toolbar red or the agent's `stop` hanging (Task 4 test: process exits on its own).
- Starting a recording while another owner records must fail without touching the running one (Task 4 test).
- A session started with the setting off must neither list nor run `device_*` tools, and the preamble must not mention them (Task 5 Rust and preamble tests).

---

### Task 1: Orientation math and new commands (AlasCore)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceScreenOrientation.swift`
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceScreenGeometry.swift`
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Harness/DeviceCommand.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/DeviceScreenGeometryTests.swift` (extend; create the suite there if absent), `DeviceCommandTests.swift`

**Interfaces:**
- Produces:
  - `public enum DeviceScreenOrientation: String, CaseIterable, Sendable { case portrait, landscapeLeft = "landscape_left", landscapeRight = "landscape_right", portraitUpsideDown = "portrait_upside_down" }`
  - `init(frameName: String?)` (unknown → `.portrait`), `isLandscape`, `deviceValue: UInt32`, `rotatedLeft`, `rotatedRight`, `clockwiseQuarterTurns: Int` (turns that make the panel upright: 0, 1, 3, 2), `uprightSize(width:height:) -> (Double, Double)`, `panelPoint(_ upright: DeviceScreenPoint) -> DeviceScreenPoint`.
  - `DeviceScreenGeometry(screenWidth:screenHeight:viewWidth:viewHeight:orientation:)` (orientation defaults to `.portrait`; screen size is the panel size) whose `normalized`/`clamped` return panel points.
  - `DeviceCommand.rotate(udid: String, orientation: DeviceScreenOrientation)` (`device_rotate`) and `DeviceCommand.record(udid: String, start: Bool)` (`device_record`, `action` `start`|`stop`).

- [ ] **Step 1: Failing tests**

```swift
struct DeviceScreenOrientationTests {
    @Test(arguments: [
        // upright top-left corner, and the panel point it lands on
        (DeviceScreenOrientation.portrait, 0.0, 0.0),
        (.landscapeLeft, 0.0, 1.0),
        (.landscapeRight, 1.0, 0.0),
        (.portraitUpsideDown, 1.0, 1.0),
    ])
    func theUprightTopLeftLandsOnThePanel(orientation: DeviceScreenOrientation, x: Double, y: Double) {
        #expect(orientation.panelPoint(.init(x: 0, y: 0)) == .init(x: x, y: y))
    }

    @Test func landscapeSwapsTheSizeAndTheGeometryMapsThroughIt() {
        #expect(DeviceScreenOrientation.landscapeLeft.uprightSize(width: 100, height: 200) == (200, 100))
        // A 200×100 upright screen fills a 200×100 view; its right middle is the panel's top middle.
        let geometry = DeviceScreenGeometry(screenWidth: 100, screenHeight: 200, viewWidth: 200, viewHeight: 100,
                                            orientation: .landscapeLeft)
        #expect(geometry.normalized(x: 200, y: 50) == .init(x: 0.5, y: 0))
    }

    @Test func rotatingLeftFourTimesComesBack() {
        let turns = sequence(first: DeviceScreenOrientation.portrait) { $0.rotatedLeft }.prefix(5).map(\.rawValue)
        #expect(turns == ["portrait", "landscape_left", "portrait_upside_down", "landscape_right", "portrait"])
        #expect(DeviceScreenOrientation(frameName: "weird") == .portrait)
    }
}
```

Derivation for `panelPoint` (panel CW turn makes landscape_left upright, so
upright `(u, v)` came from panel `(v, 1 − u)`):

- portrait: `(u, v)`;
- landscape_left: `(v, 1 − u)`;
- landscape_right: `(1 − v, u)`;
- upside down: `(1 − u, 1 − v)`.

`DeviceCommandTests` rows:
`("device_rotate", #"{"udid":"U","orientation":"landscape_left"}"#, .rotate(udid: "U", orientation: .landscapeLeft))`,
`("device_record", #"{"udid":"U","action":"stop"}"#, .record(udid: "U", start: false))`;
malformed: `("device_rotate", #"{"udid":"U","orientation":"sideways"}"#)`, `("device_record", #"{"udid":"U"}"#)`.

- [ ] **Step 2: Run** `swift test --package-path Packages/AlasCore --filter 'DeviceScreenOrientationTests|DeviceCommandTests'` → compile errors.

- [ ] **Step 3: Implement**

```swift
/// Which way a simulator's interface is turned, named as its frames are.
public enum DeviceScreenOrientation: String, CaseIterable, Sendable {
    case portrait
    case landscapeLeft = "landscape_left"
    case landscapeRight = "landscape_right"
    case portraitUpsideDown = "portrait_upside_down"

    public init(frameName: String?) { self = frameName.flatMap(Self.init(rawValue:)) ?? .portrait }

    public var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }

    /// UIDeviceOrientation, which turns the simulator to this orientation.
    public var deviceValue: UInt32 {
        switch self {
        case .portrait: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        case .landscapeLeft: 4
        }
    }

    /// The device turned 90° counterclockwise.
    public var rotatedLeft: Self {
        switch self {
        case .portrait: .landscapeLeft
        case .landscapeLeft: .portraitUpsideDown
        case .portraitUpsideDown: .landscapeRight
        case .landscapeRight: .portrait
        }
    }

    public var rotatedRight: Self { rotatedLeft.rotatedLeft.rotatedLeft }

    /// Clockwise quarter turns that make the portrait panel's pixels upright.
    public var clockwiseQuarterTurns: Int {
        switch self {
        case .portrait: 0
        case .landscapeLeft: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        }
    }

    public func uprightSize(width: Double, height: Double) -> (Double, Double) {
        isLandscape ? (height, width) : (width, height)
    }

    /// A 0–1 point on the upright screen, as a 0–1 point on the portrait panel.
    public func panelPoint(_ p: DeviceScreenPoint) -> DeviceScreenPoint {
        switch self {
        case .portrait: p
        case .landscapeLeft: .init(x: p.y, y: 1 - p.x)
        case .landscapeRight: .init(x: 1 - p.y, y: p.x)
        case .portraitUpsideDown: .init(x: 1 - p.x, y: 1 - p.y)
        }
    }
}
```

`DeviceScreenGeometry` gains `public let orientation: DeviceScreenOrientation`
(init parameter defaulting to `.portrait`); `unclamped` fits the upright size
(`orientation.uprightSize(width: screenWidth, height: screenHeight)`) and
returns the upright point; `normalized` checks bounds on the upright point
and returns `orientation.panelPoint(_)`; `clamped` clamps the upright point,
then maps.

`DeviceCommand`: cases, `toolName`, `udid`, allowed keys
(`"device_rotate": ["udid", "orientation"]`, `"device_record": ["udid", "action"]`),
`Params` gains `orientation: String?` (`action` exists), decoding:

```swift
        case "device_rotate":
            return .rotate(udid: try udid(), orientation: try enumValue(DeviceScreenOrientation.self, params.orientation ?? ""))
        case "device_record":
            guard let action = params.action, ["start", "stop"].contains(action) else { throw AlasCLIRequestError.malformed }
            return .record(udid: try udid(), start: action == "start")
```

(Use the file's existing `enumValue` helper; if it takes a non-optional
string, guard the nil first.)

- [ ] **Step 4: Run** the same filter → PASS. `swiftformat --lint` the files.
- [ ] **Step 5: Commit** "feat(devices): map rotated simulator screens to their panel".

### Task 2: Frames carry their orientation; rotating; the rotated screen (app + service)

**Files:**
- Modify: `ThirdParty/serve-sim-native/Sources/ServeSimCore/AlasSimulatorSession.swift`
- Modify: `Alas/Sources/Devices/SimServiceProtocol.swift`, `Alas/Sources/SimService/SimServiceHandler.swift`, `Alas/Sources/Devices/SimulatorStreamClient.swift`
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift` (`DeviceInput` only), `Alas/Sources/Devices/DeviceScreenView.swift`, `Alas/Sources/Devices/DeviceStage.swift`, `Alas/Sources/Devices/DeviceScreenshot.swift`, `Alas/Sources/Devices/DevicesSwitcher.swift`, `Alas/Sources/Devices/DevicesTabView.swift`, `Alas/Sources/App/DesignCaptureDevices.swift`, `AlasTests/DeviceAgentControlTests.swift` (fake input)

**Interfaces:**
- Produces:
  - `AlasSimulatorSession.start(onFrame: @escaping @Sendable (CVPixelBuffer, String?) -> Void)` and `rotate(_ deviceOrientation: UInt32) async -> Bool`.
  - `SimServiceProtocol.rotate(udid: String, orientation: UInt32, reply: @escaping @Sendable (String?) -> Void)`; `SimFrameSink.frame(udid: String, surface: IOSurface, orientation: String?)`.
  - App: `struct DeviceFrame { let surface: IOSurface; let orientation: DeviceScreenOrientation }`; `DeviceInput.subscribe(udid:onFrame: @MainActor (DeviceFrame) -> Void, onStop:)`, `lastFrame(udid:) -> DeviceFrame?`, `rotate(udid:to:) async throws` (throws `SimulatorControlError` with the service's message), `deviceOrientation(udid:) -> DeviceScreenOrientation` (last one set, portrait at first).
  - `DeviceScreenshot.png(_ frame: DeviceFrame, maxLongEdge:)` upright; `saveToDesktop(_ frame: DeviceFrame, …)`.

- [ ] **Step 1: Session and service.** In `AlasSimulatorSession`, `start`'s capture callback becomes `{ pixelBuffer, _, _, info in onFrame(pixelBuffer, info.display?.orientation) }`; add

```swift
    /// Turns the device: UIDeviceOrientation 1 portrait, 2 upside down,
    /// 3 landscape right, 4 landscape left. Works without Simulator.app.
    public func rotate(_ deviceOrientation: UInt32) async -> Bool {
        await hid.sendOrientation(orientation: deviceOrientation)
    }
```

`SimServiceHandler.startStream` passes the orientation to
`sink?.frame(udid:surface:orientation:)`; `rotate(udid:orientation:reply:)`
replies nil on success, "The simulator didn't rotate." on false, and "No
stream for this simulator." without a session (as `describe` does).

- [ ] **Step 2: Client.** `SimulatorStreamClient` stores `DeviceFrame`s in
`lastFrames`, delivers `DeviceFrame` to screens, keeps
`deviceOrientations: [String: DeviceScreenOrientation]`, and implements
`rotate(udid:to:)` with the continuation helper `describe` uses; on success
it records the orientation. Update `DeviceInput` and both fake inputs
(tests: `lastFrame` returns `DeviceFrame(surface: frame, orientation: orientation)` with a settable `var orientation = DeviceScreenOrientation.portrait`; `rotate` records the call, sets `orientation`, and appends to `rotations`).

- [ ] **Step 3: Screen view.** `DeviceScreenNSView.show(_ frame: DeviceFrame)`
keeps `orientation`; `geometry` passes it; `layout()` (add an override) sets

```swift
        let (uprightWidth, uprightHeight) = orientation.uprightSize(width: screenSize.width, height: screenSize.height)
        let fit = AVMakeRect(aspectRatio: CGSize(width: uprightWidth, height: uprightHeight), insideRect: bounds)
        displayLayer.setAffineTransform(.identity)
        displayLayer.bounds = CGRect(origin: .zero, size: orientation.isLandscape
            ? CGSize(width: fit.height, height: fit.width) : fit.size)
        displayLayer.position = CGPoint(x: fit.midX, y: fit.midY)
        // CALayer angles are counterclockwise in its unflipped space.
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(orientation.clockwiseQuarterTurns) * .pi / 2))
```

wrapped in `CATransaction.setDisableActions(true)`, and drop
`videoGravity`-based fitting for the rotated case (keep `.resizeAspect`; the
bounds already have the panel's aspect). Call `needsLayout = true` when the
orientation changes. The sign is checked in Task 6's manual pass; if the
screen is upside down there, flip the sign.

- [ ] **Step 4: Stage.** `DeviceStage` reads the orientation from a new
`let orientation: DeviceScreenOrientation` (DevicesTabView passes
`state.simulatorStreams.lastFrame(udid:)?.orientation ?? .portrait`, observed
through a `@State` updated by the screen's frames: add
`var onOrientation: (DeviceScreenOrientation) -> Void` to `DeviceScreenView`,
called when a frame's orientation differs from the last). `fit` swaps the
shape's width and height when landscape, and the corner radius uses
`shape.cornerRadius(forFittedWidth: landscape ? size.height : size.width)`.
The gutter gains two buttons under the existing ones:
`rotate.left` "Rotate left" and `rotate.right` "Rotate right", calling
`Task { try? await client.rotate(udid:to: client.deviceOrientation(udid:).rotatedLeft) }`
(and `rotatedRight`), disabled unless `allowsInput`.

- [ ] **Step 5: Screenshots upright.** `DeviceScreenshot.png` takes a
`DeviceFrame` and applies

```swift
        let turned: CIImage = switch frame.orientation.clockwiseQuarterTurns {
        case 1: image.oriented(.right)
        case 2: image.oriented(.down)
        case 3: image.oriented(.left)
        default: image
        }
```

before scaling (then translate to the origin: `turned.transformed(by: .init(translationX: -turned.extent.minX, y: -turned.extent.minY))`).
Update `saveToDesktop` and `DevicesActions.saveScreenshot`.

- [ ] **Step 6: Build** `xcodebuild … -quiet build-for-testing` → no errors; run
`-only-testing AlasTests/DeviceAgentControlTests` → existing tests pass.
- [ ] **Step 7: Commit** "feat(devices): turn the simulator screen with its interface".

### Task 3: `device_rotate`, and agents' input in landscape

**Files:**
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift`, `AlasTests/DeviceAgentControlTests.swift`
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift`, `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift`
- Modify: `AlasCLI/crates/alas-client/src/lib.rs`, `AlasCLI/crates/alas/src/mcp.rs`

**Interfaces:**
- Consumes: Task 1's orientation and command; Task 2's `DeviceInput.rotate`, `DeviceFrame`.

- [ ] **Step 1: Failing tests** in `DeviceAgentControlTests`:

```swift
    @Test func rotatingIsHeldDuringATakeoverAndReportsBothOrientations() async throws {
        let input = FakeInput()
        let control = control(input, sleep: Self.untilCancelled)
        control.takeOver(udid: "on")
        async let rotated = control.perform(.rotate(udid: "on", orientation: .landscapeLeft), sessionID: "s")
        try await eventually("held") { control.waitingSessions(udid: "on") == ["s"] }
        #expect(input.rotations.isEmpty)
        control.handBack(udid: "on")
        #expect(await rotated == .text([#"{"device":"landscape_left","interface":"landscape_left"}"#]))
        #expect(input.rotations == [.landscapeLeft])
    }

    @Test func aPortraitOnlyAppReportsItsInterfaceStayedPortrait() async throws {
        let input = FakeInput()
        input.followsRotation = false
        let control = control(input)
        let rotated = await control.perform(.rotate(udid: "on", orientation: .landscapeRight), sessionID: "s")
        #expect(rotated == .text([#"{"device":"landscape_right","interface":"portrait"}"#]))
    }

    @Test(arguments: [true, false])
    func tapsInLandscapeLandOnThePanel(byRef: Bool) async throws { /* see below */ }
```

Write the last one as two cases in one parameterized test over the target
(`.ref("s1e2")` after a `device_snapshot` whose root is 874×402 with the
cell's center at (201, 346) → upright (0.23, 0.861); and `.point(x:y:)` after a
`device_screenshot` taken with `input.orientation = .landscapeLeft`, at the
screenshot's upright pixel (width × 0.25, height × 0.5)). Expected panel
points: `landscapeLeft.panelPoint(upright)`. Assert on
`input.touches.first?.point` with an accuracy of 0.001. Use a landscape
snapshot fixture: copy `snapshot` with the root frame 874×402 and the cell
frame unchanged. The fake's `rotate` sets `orientation` only when
`followsRotation` is true.

- [ ] **Step 2: Run** → fail/compile errors.

- [ ] **Step 3: Implement.**
  - `isInput`: `.rotate` true, `.record` false (Task 4 handles `.record`).
  - `.rotate(_, let orientation)`: `try await input.rotate(udid:to:)`
    (error → `device_rotate_failed: <message>`); then poll
    `input.lastFrame(udid:)?.orientation == orientation` every 50 ms up to
    2 s via `sleep`; return
    `{"device": orientation.rawValue, "interface": (lastFrame?.orientation ?? .portrait).rawValue}`.
  - `resolve(_:udid:)` and `swipeEnds`: map every resulting point through
    `currentOrientation(udid).panelPoint(_)`, where
    `currentOrientation` is `input.lastFrame(udid:)?.orientation ?? .portrait`.
    Direction swipes are upright points before mapping.
  - `screenshot(_:)` passes the `DeviceFrame` to `DeviceScreenshot.png`.
- [ ] **Step 4: Preamble.** Add `"device_rotate"` after `"device_clipboard"`
  in `builtInToolNames` (and `"device_record"`, used by Task 4), and the
  sentence `+ "Rotate with device_rotate and record the screen with device_record. "`
  after the clipboard sentence. Update the inventory test.
- [ ] **Step 5: Rust.** `alas-client`: `DeviceCommand::Rotate { udid, orientation: String }`
  and `Record { udid, action: String }` (both `includes_screenshot` false),
  requests `{udid, orientation}` / `{udid, action}`, serialize tests.
  `mcp.rs` definitions after `device_clipboard`:
  - `device_rotate`: "Turn the simulator to an orientation, as rotating the
    device. Returns the device orientation and the interface's: an app that
    supports only portrait stays portrait. After rotating, take a new
    device_screenshot or device_snapshot; x/y and refs follow the screen as
    it looks. {DEVICE_DRIVING_NOTE}", `orientation` enum of the four names,
    destructive.
  - `device_record` (Task 4 writes its parsing; add the definition now):
    "Record the simulator's screen as a video. start begins a recording;
    stop ends it and returns the file path and length in seconds. A
    recording ends by itself after 10 minutes or when the simulator shuts
    down; stop still returns it. Recording doesn't touch the screen, so it
    works while the user drives.", `action` enum `start`/`stop`,
    `readOnlyHint: false, destructiveHint: false`.
  Parsing both with `reject_arguments`, `optional_enum(...)?.ok_or("missing required argument '…'")`.
  Tests: mapping asserts, an error row each, inventory list.
- [ ] **Step 6: Run** cargo, `DeviceAgentControlTests`, `ACPMCPPromptPreambleTests`, swiftformat lint.
- [ ] **Step 7: Commit** "feat(devices): let agents rotate simulators".

### Task 4: Recording

**Files:**
- Create: `Alas/Sources/Devices/DeviceRecorder.swift`
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift`, `Alas/Sources/App/AppState.swift`, `Alas/Sources/App/DesignCaptureDevices.swift`, `Alas/Sources/Devices/DevicesSwitcher.swift`, `Alas/Sources/Right/RightPaneView.swift`, `Alas/Sources/Devices/DevicePaneModel.swift` (shutdown hook)
- Modify: `AlasCLI/crates/alas/src/mcp.rs` (parsing)
- Test: `AlasTests/DeviceAgentControlTests.swift` (agent paths), `AlasTests/DeviceRecorderTests.swift` (new type)

**Interfaces:**
- Produces:

```swift
/// One running `recordVideo`.
protocol ScreenRecording: AnyObject {
    /// SIGINT, then wait up to 5 s; true when the file was written.
    func stop() async -> Bool
    /// Called once when the process exits by itself.
    var onExit: (@MainActor (Bool) -> Void)? { get set }
}

@MainActor @Observable
final class DeviceRecorder {
    enum Owner: Equatable { case user, agent(sessionID: String) }
    struct Finished: Equatable { let file: URL; let seconds: Double }
    enum Failure: Error, Equatable { case busy(Owner), notRecording, failed(String) }

    init(start: @escaping (String, URL) throws -> any ScreenRecording, now: @escaping () -> Date = Date.init,
         sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         agentLimit: Duration = .seconds(600))
    func owner(udid: String) -> Owner?
    func start(udid: String, owner: Owner, file: URL) throws(Failure)
    func stop(udid: String, owner: Owner) async throws(Failure) -> Finished
    /// The simulator shut down: stop its recording and keep the file for its owner.
    func simulatorStopped(udid: String) async
}
```

  `stop` on a recording that already ended returns its kept `Finished` once;
  a second `stop` throws `.notRecording`. `start` with any owner present
  throws `.busy(owner)`.
- `LiveScreenRecording` runs `Process` (`/usr/bin/xcrun simctl io <udid> recordVideo --codec=h264 --force <file>`), stop sends `interrupt()`, waits for termination up to 5 s, else `terminate()` and returns false.
- `AppState.deviceRecorder`; `DeviceAgentControl(…, recorder: DeviceRecorder, …)`.

- [ ] **Step 1: Failing tests.** `DeviceRecorderTests` with a `FakeRecording` (`stopped = false`, `stop()` sets it and returns `succeeds`):
  - start then stop returns the file and `seconds` from the injected clock;
  - a second start for the same simulator throws `.busy(.user)` and leaves the first running;
  - a recording whose `onExit(true)` fires is returned by the owner's next `stop`, and the recorder no longer lists an owner;
  - an agent recording stops after `agentLimit` (inject `sleep` that returns at once for that duration).
  In `DeviceAgentControlTests`: `device_record` start/stop while the user drives isn't held and returns `{"recording":true}` then `{"path":…,"seconds":…}`; stop with nothing running → `device_not_recording: …`.

- [ ] **Step 2: Run** → fail.

- [ ] **Step 3: Implement** `DeviceRecorder.swift` as above (a dictionary
  `[String: Running]` with owner, start date, file, recording and limit
  task; `[String: [Owner: Finished]]` for finished ones). Agent files:
  `FileManager.default.urls(for: .cachesDirectory…)/Alas/Recordings/<udid>-<yyyyMMdd-HHmmss>.mov`,
  created on demand; at `AppState` init, delete files there older than 7
  days (a `static func pruneOldRecordings(in:now:)` on `DeviceRecorder`,
  covered by one test with a temp directory and `setAttributes(modificationDate:)`).
  `DeviceAgentControl` answers `.record` before the hold (like `.logs`):
  booted check, then start/stop, mapping failures to
  `device_recording_busy: <You|agent name> is recording <device>.`,
  `device_not_recording: No recording of <device> is running.`,
  `device_record_failed: <reason>`.
- [ ] **Step 4: Toolbar.** `DevicesActions` gains `recorder: DeviceRecorder`
  and `agentName: (String) -> String`; a `ToolbarBtn` before the camera:
  `record.circle` "Record screen" when idle; `stop.circle.fill` tinted
  `theme.color("danger")` "Stop recording" while you record; disabled with
  tooltip "<agent> is recording" while an agent does. Stopping copies the
  file from a temp location to the Desktop as
  "Simulator Recording - <device> - <yyyy-MM-dd 'at' HH.mm.ss>.mov" and shows
  the existing notice text "Saved to Desktop". `DevicePaneModel.refresh()`
  calls `recorder.simulatorStopped(udid:)` for devices no longer booted (pass
  the recorder in from `AppState` via a closure property
  `onShutDown: (String) -> Void`).
- [ ] **Step 5: Rust parsing** for `device_record` and tests (definition came in Task 3).
- [ ] **Step 6: Run** `DeviceRecorderTests`, `DeviceAgentControlTests`, cargo, `build-for-testing`, lint. xcodegen (new-file hunks).
- [ ] **Step 7: Commit** "feat(devices): record simulator screens".

### Task 5: Hide device tools when the setting is off

**Files:**
- Modify: `AlasCLI/crates/alas/src/mcp.rs`
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/BuiltInAlasMCP.swift`, `AlasMCPHTTPSupervisor.swift`, `ACPMCPPromptPreamble.swift`
- Modify: `Packages/AlasCore/Sources/AlasAgents/ACP/Session/ACPSessionManager.swift`
- Modify: `Alas/Sources/App/AppState.swift` (the worktree injection at the `mcpHTTPSupervisor.endpoint(` call that passes `parentSessionId`, and the manager setup next to `computerUseAvailable`)
- Test: `mcp.rs` tests, `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift`

- [ ] **Step 1: Failing tests.**
  - Rust: `env_from` with `ALAS_MCP_DEVICES=0` → `tools/list` has no `device_*` and `tools/call` `device_list` replies the error message starting with `device_disabled:`; without the variable, `device_list` is listed.
  - Preamble: `text(builtInTools: .full, …, deviceToolsAvailable: false)` contains no "device_" and no "Device tools".
- [ ] **Step 2: Rust.** `McpEnv.devices: bool` (`get("ALAS_MCP_DEVICES") != Some("0")`, default true, in `Clone` and every literal). `ToolScope::NoDevices` returned by `tool_scope()` instead of `All` when `!devices`; `allows`: `!name.starts_with("device_")`; `rejection`: `(-32602, "device_disabled: Agents can't use iOS simulators. Ask the user to turn on Settings › Computer Use › Let agents use iOS simulators.".into())`.
- [ ] **Step 3: Swift.** `BuiltInAlasMCP.injection(…, deviceTools: Bool = true)` adds `ALAS_MCP_DEVICES=0` to the stdio env when false; `AlasMCPHTTPSupervisor.endpoint(…, deviceTools: Bool = true)` and `environment(…, deviceTools:)` likewise. `ACPMCPPromptPreamble.text(…, deviceToolsAvailable: Bool = true)` threads it to both renderers, and the device paragraph is added only when `computerUseAvailable && deviceToolsAvailable` (the CLI renderer has no device paragraph; just thread it). `ACPSessionManager` gains `public var deviceToolsAvailable: @MainActor () -> Bool = { true }`, read where `computerUseAvailable` is passed. `AppState` sets it to `{ [weak self] in self?.config.deviceAgentsEnabled ?? false }` and passes `deviceTools: self.config.deviceAgentsEnabled` to both worktree injection calls and the supervisor call. Workspace and headless paths stay as they are.
- [ ] **Step 4: Run** cargo, `ACPMCPPromptPreambleTests`, `swift test --package-path Packages/AlasCore --filter ACPMCPPromptPreamble` if an AlasCore suite exists, build.
- [ ] **Step 5: Commit** "feat(devices): hide device tools from sessions while agents may not use simulators".

### Task 6: End-to-end check and docs

- [ ] **Step 1: Throwaway app-host test** (`AlasTests/DeviceControlsScratch.swift`, deleted after): with the real `SimulatorStreamClient`, `DeviceAgentControl` and `DeviceRecorder` on the booted iPhone 17:
  1. launch Safari on `https://example.com`; `device_record start`;
  2. `device_rotate landscape_left` → print the reply;
  3. `device_screenshot` → write the PNG to `/tmp/alas-clip/agent-landscape.png` (expect landscape, upright);
  4. `device_snapshot` then tap the "Learn more" link's ref (find it by label) → after 2 s, `device_snapshot` again and print whether the page changed;
  5. `device_rotate portrait`; `device_record stop` → print path and seconds, `ffprobe` the file.
- [ ] **Step 2: Docs.** `docs/devices.md`: a paragraph after the ⌘C/⌘V one: "The rotate buttons below the hardware buttons turn the device left or right; the screen turns with the app, so an app that supports only portrait stays upright. The record button in the toolbar records the screen until you click it again, and saves the video to the Desktop." Tool table rows: `device_rotate` "Turns the device; returns the device and interface orientations." and `device_record` "Starts or stops a screen recording; stop returns the video's path." Under the setting paragraph: "With the setting off, sessions you start don't get the device_* tools at all; sessions already running keep them and get device_disabled." Tick rotation and recording in `docs/plans/2026-11-04-device-panel-design.md`.
- [ ] **Step 3: Commit** "docs(devices): describe rotation, recording and hidden device tools".
- [ ] **Step 4: Manual pass**: rotate buttons (screen upright both ways, taps land), a portrait-only app (Hello.app) stays upright, record and stop (file on the Desktop), an agent rotating and recording, and a new session with the setting off lists no device tools.
