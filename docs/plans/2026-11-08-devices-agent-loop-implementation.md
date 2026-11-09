# Devices agent loop: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agent `device_*` calls wait while the user drives a simulator, and agents and the user can install and launch a built `.app` on it.

**Architecture:** `DeviceAgentControl` gains a per-simulator queue of held calls that hand back releases in order, plus `install`/`launch` actions behind injected closures. AlasCore reads app bundles and wraps `simctl install`/`launch`. The MCP server adds two tools. The simulator screen accepts a dropped `.app`, installed and launched by `DevicePaneModel`.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, Swift Testing, Rust (`AlasCLI`), `xcrun simctl`.

**Spec:** `docs/plans/2026-11-08-devices-agent-loop-design.md`

## Global Constraints

- English everywhere; Conventional Commits; no agent attribution.
- Swift Testing only; follow the AGENTS.md testing policy (no fixed sleeps, no `.serialized`, no extra `@MainActor`, extend existing suites).
- AlasCore must not import AppKit or SwiftUI; anything the app uses from it is `public`.
- Hold limit: 50 s (`holdLimit`, a `DeviceAgentControl` init parameter).
- `simctl install` limit: 90 s.
- Error codes, verbatim: `device_user_active`, `device_cancelled`, `device_app_invalid`, `device_app_wrong_platform`, `device_install_failed`, `device_app_not_installed`, `device_launch_failed`, `device_not_booted`.
- Simulators only; VM takeover is unchanged.
- Run `xcodegen` after adding app files.

## Changes from the spec

Found while planning; each is the conservative choice.

- **Held calls don't count as in flight.** The hold happens first in `perform`, before the device list is read. While the user drives, the Devices tab's own stream keeps the screen running, and the call renews the agent's lease once it goes ahead.
- **The timeout message names "this simulator", not the device's name.** The list is read after the hold, so a simulator shut down or deleted during the takeover is reported correctly (`device_not_booted` / `device_not_found`).
- **A call already queued behind another input call when the user takes over is refused, not held**, as today. Holding it again could push its total wait past Codex's 60 s.
- **`device_install`'s read timeout is `DEVICE_OPEN_READ_TIMEOUT` (330 s), not 120 s:** the 50 s hold plus the 90 s install exceeds 120 s. Codex still stops waiting after 60 s unless the server's `tool_timeout_sec` is raised, so a large install held by a takeover can time out on Codex's side. The tool description tells the agent to retry.
- **The drop goes through `DevicePaneModel.installAndLaunch(_:on:)`, not an `AppState` helper.** It shares `SimulatorAppBundle` and `SimulatorControl` with the tools; the agent path additionally goes through `DeviceAgentControl`.
- **`device_launch` detects a missing app with `simctl get_app_container`.** `simctl launch` reports one only as `FBSOpenApplicationServiceErrorDomain, code=4`, checked on iOS 26.5.

## Review Focus

1. Two sessions' calls held on one simulator: hand back runs them in arrival order. Test in Task 2.
2. An agent's turn cancelled while its call is held: the call leaves the queue, and a later hand back doesn't run it. Test in Task 2.
3. The simulator is shut down while the user drives: the held call then fails with `device_not_booted`, not a confusing simctl error. Test in Task 2.
4. A relative `app_path` with `..` from the agent: it resolves against the worktree, normalized. Test in Task 3.
5. A device build, a folder holding several apps, or a plain folder dragged onto the screen: refused on hover, no outline. Manual check in Task 4. The bundle rules are pinned by Task 1's tests.

---

### Task 1: App bundles and simctl install/launch (AlasCore)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorAppBundle.swift`
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorControl.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/SimulatorAppBundleTests.swift`

**Interfaces:**
- Produces:

```swift
public struct SimulatorAppBundle: Equatable, Sendable {
    public enum Problem: Error, Equatable, Sendable, LocalizedError {
        case notAnApp(path: String), noBundleID(path: String), builtForDevice(name: String)
        public func message(udid: String) -> String   // the agent-facing device_* error
        public var errorDescription: String?          // plain text for the user
    }
    public let url: URL
    public let bundleID: String
    public let name: String
    public init(url: URL, bundleID: String, name: String)
    public static func read(_ url: URL) throws -> SimulatorAppBundle   // throws Problem
}
public enum SimulatorLaunchError: Error, Equatable, LocalizedError { case notInstalled }
extension SimulatorControl {
    public static func install(udid: String, app: URL) async throws
    public static func launch(udid: String, bundleID: String) async throws -> Int32
    static func launchedPID(_ stdout: String, bundleID: String) -> Int32?
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import AlasCore

struct SimulatorAppBundleTests {
    enum Fixture: String, CaseIterable, Sendable {
        case simulator, noPlatform, device, noBundleID, notApp
    }

    private func make(_ fixture: Fixture) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-app-\(UUID().uuidString)")
        let app = root.appendingPathComponent(fixture == .notApp ? "Hello" : "Hello.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleName": "Hello", "CFBundleDisplayName": "Hello World"]
        if fixture != .noBundleID { plist["CFBundleIdentifier"] = "com.example.hello" }
        switch fixture {
        case .simulator: plist["DTPlatformName"] = "iphonesimulator"
        case .device: plist["DTPlatformName"] = "iphoneos"
        default: break
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
        return app
    }

    @Test(arguments: Fixture.allCases)
    func readsSimulatorBuildsAndRefusesTheRest(_ fixture: Fixture) throws {
        let url = try make(fixture)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        switch fixture {
        case .simulator, .noPlatform:
            #expect(try SimulatorAppBundle.read(url)
                == SimulatorAppBundle(url: url, bundleID: "com.example.hello", name: "Hello World"))
        case .device:
            #expect(throws: SimulatorAppBundle.Problem.builtForDevice(name: "Hello World")) { try SimulatorAppBundle.read(url) }
        case .noBundleID:
            #expect(throws: SimulatorAppBundle.Problem.noBundleID(path: url.path)) { try SimulatorAppBundle.read(url) }
        case .notApp:
            #expect(throws: SimulatorAppBundle.Problem.notAnApp(path: url.path)) { try SimulatorAppBundle.read(url) }
        }
    }

    @Test(arguments: [
        ("com.example.hello: 4021\n", Int32(4021) as Int32?),
        ("com.example.other: 4021\n", nil),
        ("", nil),
    ])
    func launchOutputGivesThePID(stdout: String, pid: Int32?) {
        #expect(SimulatorControl.launchedPID(stdout, bundleID: "com.example.hello") == pid)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path Packages/AlasCore --filter SimulatorAppBundleTests`
Expected: build error, `cannot find 'SimulatorAppBundle' in scope`.

- [ ] **Step 3: Implement `SimulatorAppBundle`**

```swift
import Foundation

/// The parts of a built iOS `.app` that installing it on a simulator needs.
public struct SimulatorAppBundle: Equatable, Sendable {
    public enum Problem: Error, Equatable, Sendable, LocalizedError {
        case notAnApp(path: String)
        case noBundleID(path: String)
        case builtForDevice(name: String)

        /// The error an agent's `device_install` gets; `udid` fills in the build hint.
        public func message(udid: String) -> String {
            switch self {
            case .notAnApp(let path): "device_app_invalid: \(path) is not an app bundle."
            case .noBundleID(let path): "device_app_invalid: \(path) has no bundle ID."
            case .builtForDevice(let name):
                "device_app_wrong_platform: \(name) was built for a device. Build it for the simulator, for example with -destination 'platform=iOS Simulator,id=\(udid)'."
            }
        }

        public var errorDescription: String? {
            switch self {
            case .notAnApp(let path): "\((path as NSString).lastPathComponent) is not an app."
            case .noBundleID(let path): "\((path as NSString).lastPathComponent) has no bundle ID."
            case .builtForDevice(let name): "\(name) was built for a device, not the simulator."
            }
        }
    }

    public let url: URL
    public let bundleID: String
    public let name: String

    public init(url: URL, bundleID: String, name: String) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
    }

    /// Reads `<app>/Info.plist`, which iOS apps keep at the bundle's root. An
    /// app built for a device is refused; one without `DTPlatformName` is left
    /// for `simctl install` to judge.
    public static func read(_ url: URL) throws -> SimulatorAppBundle {
        var isDirectory: ObjCBool = false
        guard url.pathExtension == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { throw Problem.notAnApp(path: url.path) }
        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw Problem.noBundleID(path: url.path)
        }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        if plist["DTPlatformName"] as? String == "iphoneos" { throw Problem.builtForDevice(name: name) }
        return SimulatorAppBundle(url: url, bundleID: bundleID, name: name)
    }
}
```

- [ ] **Step 4: Add install and launch to `SimulatorControl`**

Add after `public struct SimulatorControlError` at the top of the file:

```swift
public enum SimulatorLaunchError: Error, Equatable, LocalizedError {
    case notInstalled

    public var errorDescription: String? { "The app isn't installed on this simulator." }
}
```

Add inside `enum SimulatorControl`, after `shutdown(udid:)`:

```swift
    /// Installs a built `.app`, replacing an installed copy.
    public static func install(udid: String, app: URL) async throws {
        let result = try await Process.run(xcrun, args: ["simctl", "install", udid, app.path], timeout: 90)
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    /// Launches an installed app, ending a running copy first, and returns its pid.
    public static func launch(udid: String, bundleID: String) async throws -> Int32 {
        let result = try await Process.run(
            xcrun, args: ["simctl", "launch", "--terminate-running-process", udid, bundleID], timeout: 60
        )
        if result.exitCode == 0, let pid = launchedPID(result.stdout, bundleID: bundleID) { return pid }
        // simctl's launch error doesn't say the app is missing; its container lookup does.
        let container = try await Process.run(xcrun, args: ["simctl", "get_app_container", udid, bundleID])
        if container.exitCode != 0 { throw SimulatorLaunchError.notInstalled }
        throw SimulatorControlError(result)
    }

    /// simctl prints `<bundle id>: <pid>`.
    static func launchedPID(_ stdout: String, bundleID: String) -> Int32? {
        for line in stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0] == bundleID {
                return Int32(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `swift test --package-path Packages/AlasCore --filter SimulatorAppBundleTests`
Expected: `Test run with 2 tests in 1 suite passed`.

- [ ] **Step 6: Commit**

```bash
git add Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorAppBundle.swift Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorControl.swift Packages/AlasCore/Tests/AlasCoreTests/SimulatorAppBundleTests.swift
git commit -m "feat(devices): read app bundles and install and launch them with simctl"
```

---

### Task 2: Hold agent calls while the user drives

**Files:**
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift`
- Modify: `Alas/Sources/Devices/DeviceStage.swift` (`driverPill`)
- Modify: `AlasCLI/crates/alas/src/mcp.rs` (`DEVICE_DRIVING_NOTE`, line 902)
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift` (the device paragraph; find it with `grep -n "device_user_active means"`)
- Test: `AlasTests/DeviceAgentControlTests.swift`, `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift:154`

**Interfaces:**
- Produces:

```swift
final class DeviceAgentControl {
    static let userDriving: String     // a call already running when the user took over
    static let stillDriving: String    // the hold limit passed
    static let cancelled: String
    init(input:devices:boot:now:sleep:leaseWindow:holdLimit: Duration = .seconds(50))
    /// Sessions whose calls wait for the user to hand `udid` back, first to arrive first.
    func waitingSessions(udid: String) -> [String]
}
```

- [ ] **Step 1: Write the failing tests**

In `DeviceAgentControlTests`, replace `aTakeoverRefusesCallsUntilHandedBack` (lines 77-85). Add these helpers and tests to the main struct:

```swift
    /// For the 50-second hold, suspends until the held call's timer task is
    /// cancelled, which happens when the call is released; other sleeps return at once.
    private static let untilCancelled: @MainActor (Duration) async -> Void = { duration in
        guard duration == .seconds(50) else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        await withTaskCancellationHandler {
            for await _ in stream {}
        } onCancel: {
            continuation.finish()
        }
    }

    /// Yields until `condition` holds; fails the test after 1000 tries.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    @Test func aCallMadeWhileTheUserDrivesRunsAfterHandBack() async {
        let input = FakeInput()
        let control = control(input, sleep: Self.untilCancelled)
        control.takeOver(udid: "on")
        async let call = control.perform(.button(udid: "on", name: .home, includeScreenshot: false), sessionID: "s")
        await until { control.waitingSessions(udid: "on") == ["s"] }
        control.handBack(udid: "on")
        #expect(await call == .ok)
        #expect(control.waitingSessions(udid: "on").isEmpty)
    }

    @Test func aHeldCallGivesUpWhenTheHoldLimitPasses() async {
        let control = control(FakeInput())
        control.takeOver(udid: "on")
        let response = await control.perform(.button(udid: "on", name: .home, includeScreenshot: false), sessionID: "s")
        #expect(error(response) == DeviceAgentControl.stillDriving)
    }

    @Test func heldCallsRunInArrivalOrder() async {
        let input = FakeInput()
        let control = control(input, sleep: Self.untilCancelled)
        control.takeOver(udid: "on")
        async let first = control.perform(.type(udid: "on", text: "a", includeScreenshot: false), sessionID: "s")
        await until { control.waitingSessions(udid: "on") == ["s"] }
        async let second = control.perform(.type(udid: "on", text: "b", includeScreenshot: false), sessionID: "t")
        await until { control.waitingSessions(udid: "on") == ["s", "t"] }
        control.handBack(udid: "on")
        #expect(await (first, second) == (.ok, .ok))
        #expect(input.keys.filter(\.down).map(\.usage) == [0x04, 0x05])
    }

    @Test func aCancelledHeldCallLeavesTheQueue() async {
        let input = FakeInput()
        let control = control(input, sleep: Self.untilCancelled)
        control.takeOver(udid: "on")
        let call = Task { await control.perform(.type(udid: "on", text: "a", includeScreenshot: false), sessionID: "s") }
        await until { control.waitingSessions(udid: "on") == ["s"] }
        call.cancel()
        #expect(error(await call.value) == DeviceAgentControl.cancelled)
        #expect(control.waitingSessions(udid: "on").isEmpty)
        control.handBack(udid: "on")
        #expect(input.keys.isEmpty)
    }

    @Test func aSimulatorShutDownDuringTheTakeoverFailsTheHeldCall() async {
        var listed = [Self.booted]
        let control = DeviceAgentControl(
            input: FakeInput(), devices: { listed }, boot: { _ in },
            sleep: Self.untilCancelled
        )
        control.takeOver(udid: "on")
        async let call = control.perform(.button(udid: "on", name: .home, includeScreenshot: false), sessionID: "s")
        await until { !control.waitingSessions(udid: "on").isEmpty }
        listed = [SimulatorDevice(udid: "on", name: "iPhone", runtimeName: "iOS 26.5", state: .shutdown)]
        control.handBack(udid: "on")
        #expect(error(await call)?.hasPrefix("device_not_booted:") == true)
    }

    @Test func typingStopsAtATakeoverAndSaysHowFarItGot() async {
        let input = FakeInput()
        var sleeps = 0
        var control: DeviceAgentControl!
        // Counts only the pauses between keystrokes; the lease timer sleeps too.
        control = self.control(input) { duration in
            guard duration == .milliseconds(20) else { return }
            sleeps += 1
            if sleeps == 2 { control.takeOver(udid: "on") }
        }
        let response = await control.perform(.type(udid: "on", text: "abcd", includeScreenshot: false), sessionID: "s")
        #expect(error(response)?.hasPrefix("device_user_active:") == true)
        #expect(error(response)?.contains("2 of 4 characters") == true)
        #expect(input.keys.filter(\.down).count == 2)
    }
```

`aSimulatorShutDownDuringTheTakeoverFailsTheHeldCall` builds its own `DeviceAgentControl`; Task 3 adds `install:` and `launch:` to it and to the suite's other constructors.

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/DeviceAgentControlTests test`
Expected: build errors for `waitingSessions`, `stillDriving` and `cancelled`.

- [ ] **Step 3: Implement the hold in `DeviceAgentControl`**

Replace the `userDriving` constant (line 32) with:

```swift
    static let userDriving = "device_user_active: The user took over this simulator. Try again after they hand it back."
    static let stillDriving = "device_user_active: The user is still driving this simulator. Try again in a minute."
    static let cancelled = "device_cancelled: The call was cancelled while it waited for the user to hand the simulator back."
```

Add the state and the init parameter:

```swift
    /// How long a call waits for the user to hand a simulator back; under
    /// Codex's 60-second limit on a tool call.
    @ObservationIgnored private let holdLimit: Duration

    private enum Hold: Sendable { case go, timedOut, cancelled }
    private struct HeldCall {
        let id: UUID
        let sessionID: String
        let resume: CheckedContinuation<Hold, Never>
        let timer: Task<Void, Never>
    }
    /// Calls waiting for the user to hand each simulator back, in arrival order.
    private var held: [String: [HeldCall]] = [:]
```

In `init`, add the parameter `holdLimit: Duration = .seconds(50)` after `leaseWindow`, and set `self.holdLimit = holdLimit`.

Replace `handBack(udid:)`:

```swift
    func handBack(udid: String) {
        takenOver.remove(udid)
        // In arrival order; input calls then queue for the device in the order they resume.
        for call in held.removeValue(forKey: udid) ?? [] {
            call.timer.cancel()
            call.resume.resume(returning: .go)
        }
    }

    func waitingSessions(udid: String) -> [String] {
        held[udid]?.map(\.sessionID) ?? []
    }

    /// Waits while the user drives `udid`: until they hand it back, the hold
    /// limit passes, or the calling task is cancelled.
    private func holdWhileTakenOver(_ udid: String, sessionID: String) async -> Hold {
        guard takenOver.contains(udid) else { return .go }
        guard !Task.isCancelled else { return .cancelled }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let limit = holdLimit
                let timer = Task { [weak self] in
                    await self?.sleep(limit)
                    guard !Task.isCancelled else { return }
                    self?.release(udid, id: id, as: .timedOut)
                }
                held[udid, default: []].append(HeldCall(id: id, sessionID: sessionID, resume: continuation, timer: timer))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(udid, id: id, as: .cancelled) }
        }
    }

    private func release(_ udid: String, id: UUID, as outcome: Hold) {
        guard var calls = held[udid], let index = calls.firstIndex(where: { $0.id == id }) else { return }
        let call = calls.remove(at: index)
        held[udid] = calls.isEmpty ? nil : calls
        call.timer.cancel()
        call.resume.resume(returning: outcome)
    }
```

In `perform`, hold first: right after `guard let udid = command.udid else { return await list() }`, insert:

```swift
        switch await holdWhileTakenOver(udid, sessionID: sessionID) {
        case .go: break
        case .timedOut: return .error(Self.stillDriving)
        case .cancelled: return .error(Self.cancelled)
        }
```

Keep the existing `if userDriving(udid) { return .error(Self.userDriving) }` after the device lookup: a takeover between the hold and that line is refused, not held again.

In `case .type`, report progress. Replace the loop header and its first line:

```swift
            for (index, press) in presses.enumerated() {
                if userDriving(udid) {
                    return .error("device_user_active: The user took over after \(index) of \(presses.count) characters were typed. Check the field before typing the rest.")
                }
```

- [ ] **Step 4: Show a waiting agent in the driver pill**

In `DeviceStage.driverPill`, replace the `case .user, .idle:` branch:

```swift
            case .user, .idle:
                Text("You're driving")
                    .foregroundStyle(theme.color("fg"))
                if let waiting = control.waitingSessions(udid: device.udid).first {
                    Text("· \(agentName(waiting)) is waiting")
                        .foregroundStyle(theme.color("fg-dim"))
                }
                Button("Hand back") { control.handBack(udid: device.udid) }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.color("accent"))
```

- [ ] **Step 5: Tell agents**

`mcp.rs` line 902:

```rust
const DEVICE_DRIVING_NOTE: &str = "The user sees the device in Alas's Devices tab. While they drive it, a call waits up to 50 seconds for them to hand it back; `device_user_active` means it is still theirs: try again later. `device_disabled` means the user hasn't let agents use iOS simulators in Alas's Computer Use settings.";
```

In `ACPMCPPromptPreamble.swift`, replace
`"device_user_active means the user took over the device: wait for them to hand it back. "`
with
`"While the user drives a simulator, a device call waits up to 50 seconds for them to hand it back; device_user_active means it is still theirs: try again later. "`.
In `ACPMCPPromptPreambleTests.swift:154`, expect the new sentence without its trailing space.

- [ ] **Step 6: Run the tests to see them pass**

Run: `xcodebuild … -only-testing AlasTests/DeviceAgentControlTests -only-testing AlasTests/ACPMCPPromptPreambleTests test` (full flags as in Step 2), then `cargo test --manifest-path AlasCLI/Cargo.toml -p alas`.
Expected: all pass; check the `Test run with N tests` line.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Devices AlasTests/DeviceAgentControlTests.swift AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift AlasCLI/crates/alas/src/mcp.rs Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift
git commit -m "feat(devices): hold agent calls while the user drives a simulator"
```

---

### Task 3: `device_install` and `device_launch`

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Harness/DeviceCommand.swift`
- Modify: `Packages/AlasCore/Tests/AlasCoreTests/DeviceCommandTests.swift`
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift` (`builtInToolNames` line 83; the device paragraph)
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift`
- Modify: `Alas/Sources/App/AppState.swift:724-728` (`deviceControl`)
- Modify: `AlasTests/DeviceAgentControlTests.swift`, `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift:318-319`
- Modify: `AlasCLI/crates/alas/src/mcp.rs` (definitions after `device_button` near line 1011; parsing after `"device_button"` near line 1934; tests near lines 4067, 4832, 4941)
- Modify: `AlasCLI/crates/alas-client/src/lib.rs` (`DeviceCommand` line 453, `device_request` line 1129, `read_timeout` line 1697, tests near line 2636)

**Interfaces:**
- Consumes: `SimulatorAppBundle.read`, `SimulatorAppBundle.Problem.message(udid:)`, `SimulatorControl.install`/`launch`, `SimulatorLaunchError.notInstalled` (Task 1); `holdWhileTakenOver` (Task 2).
- Produces: `DeviceCommand.install(udid: String, appPath: String)`, `.launch(udid: String, bundleID: String)`; `DeviceAgentControl.init(input:devices:boot:install:launch:now:sleep:leaseWindow:holdLimit:)` with `install: @escaping (String, URL) async throws -> Void`, `launch: @escaping (String, String) async throws -> Int32`; Rust `alas_client::DeviceCommand::Install { udid: String, app_path: String }`, `::Launch { udid: String, bundle_id: String }`.

- [ ] **Step 1: Write the failing Swift decode tests**

In `DeviceCommandTests.decodesEachActionWithDefaults`, add rows:

```swift
        ("device_install", #"{"udid":"U","app_path":"/b/Hello.app"}"#, .install(udid: "U", appPath: "/b/Hello.app")),
        ("device_launch", #"{"udid":"U","bundle_id":"com.example.hello"}"#, .launch(udid: "U", bundleID: "com.example.hello")),
```

In `refusesWhatAnActionDoesNotTake`, add:

```swift
        ("device_install", #"{"udid":"U"}"#),
        ("device_install", #"{"udid":"U","app_path":"relative/Hello.app"}"#),
        ("device_launch", #"{"udid":"U","bundle_id":""}"#),
        ("device_launch", #"{"udid":"U","bundle_id":"x","include_screenshot":true}"#),
```

- [ ] **Step 2: Implement the Swift command**

In `DeviceCommand`, add the cases after `button`:

```swift
    /// `appPath` is absolute; the MCP server resolves it against the worktree.
    case install(udid: String, appPath: String)
    case launch(udid: String, bundleID: String)
```

Extend `toolName` (`case .install: "device_install"`, `case .launch: "device_launch"`) and `udid` (add `.install(let udid, _), .launch(let udid, _)` to the list). Add `var app_path: String?` and `var bundle_id: String?` to `Params`. Add to `allowed`:

```swift
        "device_install": ["udid", "app_path"],
        "device_launch": ["udid", "bundle_id"],
```

Before `default: // device_button`, add:

```swift
        case "device_install":
            guard let path = params.app_path, path.hasPrefix("/"), path.utf8.count <= 4096 else {
                throw AlasCLIRequestError.malformed
            }
            return .install(udid: try udid(), appPath: path)
        case "device_launch":
            guard let bundleID = params.bundle_id, !bundleID.isEmpty, bundleID.utf8.count <= 255 else {
                throw AlasCLIRequestError.malformed
            }
            return .launch(udid: try udid(), bundleID: bundleID)
```

Add `"device_install", "device_launch",` after `"device_button",` in `builtInToolNames` (line 83). In the device paragraph of the preamble, after the hold sentence from Task 2, add:
`"To run an app, build it for the simulator with xcodebuild, then call device_install and device_launch. "`.

Run: `swift test --package-path Packages/AlasCore --filter DeviceCommandTests`
Expected: pass.

- [ ] **Step 3: Write the failing app tests**

Add to `DeviceAgentControlTests`. Give the `control(_:sleep:)` helper recording fakes:

```swift
    private final class Installs {
        var calls: [String] = []
    }

    private func control(
        _ input: FakeInput, installs: Installs = Installs(),
        sleep: @escaping @MainActor (Duration) async -> Void = { _ in }
    ) -> DeviceAgentControl {
        DeviceAgentControl(
            input: input, devices: { [Self.booted, Self.shutDown] }, boot: { _ in },
            install: { _, app in installs.calls.append("install \(app.lastPathComponent)") },
            launch: { _, bundleID in
                guard bundleID == "com.example.hello" else { throw SimulatorLaunchError.notInstalled }
                installs.calls.append("launch \(bundleID)")
                return 4021
            },
            sleep: sleep
        )
    }
```

Pass `install: { _, _ in }, launch: { _, _ in 0 }` in every other `DeviceAgentControl(...)` call in the suite (`theLeaseOutlastsACommandThatRunsPastItsWindow` and `aSimulatorShutDownDuringTheTakeoverFailsTheHeldCall`). Then:

```swift
    private func appBundle(platform: String) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("alas-\(UUID().uuidString)/Hello.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.hello", "CFBundleName": "Hello", "DTPlatformName": platform]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        return app
    }

    @Test func installAndLaunchAreHeldAndReturnWhatTheAgentNeeds() async throws {
        let app = try appBundle(platform: "iphonesimulator")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let installs = Installs()
        let control = control(FakeInput(), installs: installs, sleep: Self.untilCancelled)
        control.takeOver(udid: "on")
        async let installed = control.perform(.install(udid: "on", appPath: app.path), sessionID: "s")
        await until { control.waitingSessions(udid: "on") == ["s"] }
        #expect(installs.calls.isEmpty)
        control.handBack(udid: "on")
        #expect(await installed == .text([#"{"bundle_id":"com.example.hello","name":"Hello"}"#]))
        #expect(await control.perform(.launch(udid: "on", bundleID: "com.example.hello"), sessionID: "s")
            == .text([#"{"pid":4021}"#]))
        #expect(installs.calls == ["install Hello.app", "launch com.example.hello"])
    }

    @Test func installAndLaunchRefuseWhatTheSimulatorCantRun() async throws {
        let app = try appBundle(platform: "iphoneos")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let installs = Installs()
        let control = control(FakeInput(), installs: installs)
        let wrong = await control.perform(.install(udid: "on", appPath: app.path), sessionID: "s")
        #expect(error(wrong)?.hasPrefix("device_app_wrong_platform:") == true)
        let missing = await control.perform(.launch(udid: "on", bundleID: "com.example.gone"), sessionID: "s")
        #expect(error(missing) == "device_app_not_installed: com.example.gone isn't installed on iPhone.")
        #expect(installs.calls.isEmpty)
    }
```

Run the app tests (command as in Task 2, Step 2). Expected: build errors for the new init parameters.

- [ ] **Step 4: Implement them in `DeviceAgentControl`**

Add stored closures and init parameters after `boot`:

```swift
    @ObservationIgnored private let install: (String, URL) async throws -> Void
    @ObservationIgnored private let launch: (String, String) async throws -> Int32
```

```swift
        install: @escaping (String, URL) async throws -> Void,
        launch: @escaping (String, String) async throws -> Int32,
```

Install and launch take turns with input:

```swift
        let isInput = switch command {
        case .tap, .swipe, .type, .button, .install, .launch: true
        case .list, .open, .snapshot, .screenshot: false
        }
```

Add the cases to the `switch command` in `perform`:

```swift
        case .install(_, let appPath):
            let app: SimulatorAppBundle
            do {
                app = try SimulatorAppBundle.read(URL(fileURLWithPath: appPath))
            } catch let problem as SimulatorAppBundle.Problem {
                return .error(problem.message(udid: udid))
            } catch {
                return .error("device_app_invalid: \(error.localizedDescription)")
            }
            do {
                try await install(udid, app.url)
            } catch {
                return .error("device_install_failed: \(error.localizedDescription)")
            }
            return .text([Self.json(["bundle_id": app.bundleID, "name": app.name])])
        case .launch(_, let bundleID):
            do {
                return .text([Self.json(["pid": Int(try await launch(udid, bundleID))])])
            } catch SimulatorLaunchError.notInstalled {
                return .error("device_app_not_installed: \(bundleID) isn't installed on \(device.name).")
            } catch {
                return .error("device_launch_failed: \(error.localizedDescription)")
            }
```

In `AppState.swift:724-728`:

```swift
    @ObservationIgnored lazy var deviceControl = DeviceAgentControl(
        input: simulatorStreams,
        devices: { try await SimulatorControl.devices() },
        boot: { try await SimulatorControl.boot(udid: $0) },
        install: { try await SimulatorControl.install(udid: $0, app: $1) },
        launch: { try await SimulatorControl.launch(udid: $0, bundleID: $1) }
    )
```

Fix any other exhaustive `switch` over `DeviceCommand` the compiler reports, with the new cases treated like `.button`.

In `ACPMCPPromptPreambleTests.swift:319`, add `"device_install", "device_launch",` after `"device_button",`.

- [ ] **Step 5: Write the failing Rust tests**

In `mcp.rs`, `device_tools_validate_arguments_and_map_to_commands`, add before the error loop:

```rust
        assert_eq!(
            map("device_install", json!({ "udid": "U", "app_path": "build/../out/Hello.app" })).unwrap(),
            Command::Device(DeviceCommand::Install {
                udid: "U".into(),
                app_path: "/wt/out/Hello.app".into()
            })
        );
        assert_eq!(
            map("device_launch", json!({ "udid": "U", "bundle_id": "com.example.hello" })).unwrap(),
            Command::Device(DeviceCommand::Launch {
                udid: "U".into(),
                bundle_id: "com.example.hello".into()
            })
        );
```

and to the error table:

```rust
            ("device_install", json!({ "udid": "U" }), "missing required argument 'app_path'"),
            ("device_launch", json!({ "udid": "U", "bundle_id": "x", "app_path": "/a.app" }), "device_launch does not accept 'app_path'"),
```

Add `"device_install", "device_launch",` after `"device_button",` in the tool-inventory assertion (near line 4068), and to the destructive list at line 4941.

In `alas-client`'s `device_commands_serialize_as_params_only_requests`, add:

```rust
        assert_eq!(
            build(DeviceCommand::Install { udid: udid(), app_path: "/b/Hello.app".into() }),
            ("device_install".into(), serde_json::json!({ "udid": "U-1", "app_path": "/b/Hello.app" }))
        );
        assert_eq!(
            build(DeviceCommand::Launch { udid: udid(), bundle_id: "com.example.hello".into() }),
            ("device_launch".into(), serde_json::json!({ "udid": "U-1", "bundle_id": "com.example.hello" }))
        );
        assert_eq!(
            read_timeout(&Command::Device(DeviceCommand::Install { udid: udid(), app_path: "/a.app".into() })),
            DEVICE_OPEN_READ_TIMEOUT
        );
```

Run: `cargo test --manifest-path AlasCLI/Cargo.toml -p alas -p alas-client`
Expected: build errors for `DeviceCommand::Install`.

- [ ] **Step 6: Implement the Rust side**

`alas-client`, `DeviceCommand`:

```rust
    /// `app_path` is absolute.
    Install {
        udid: String,
        app_path: String,
    },
    Launch {
        udid: String,
        bundle_id: String,
    },
```

`device_request`:

```rust
        DeviceCommand::Install { udid, app_path } => {
            ("device_install", json!({ "udid": udid, "app_path": app_path }))
        }
        DeviceCommand::Launch { udid, bundle_id } => {
            ("device_launch", json!({ "udid": udid, "bundle_id": bundle_id }))
        }
```

`read_timeout`: an install may wait 50 s for the user, then take up to 90 s.

```rust
        Command::Device(DeviceCommand::Open { .. } | DeviceCommand::Install { .. }) => DEVICE_OPEN_READ_TIMEOUT,
```

Mention installs in `DEVICE_OPEN_READ_TIMEOUT`'s doc comment.

`mcp.rs` definitions, after `device_button`:

```rust
        json!({
            "name": "device_install",
            "description": format!("Install a built .app on a booted simulator, replacing an installed copy. Build it for the simulator first, for example with xcodebuild -destination 'platform=iOS Simulator,id=<udid>'. Returns the app's bundle_id and name; then call device_launch. {DEVICE_DRIVING_NOTE}"),
            "annotations": { "readOnlyHint": false, "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "udid": udid,
                    "app_path": { "type": "string", "minLength": 1, "maxLength": 4096, "description": "The .app folder, relative to the worktree root or absolute." }
                },
                "required": ["udid", "app_path"]
            }
        }),
        json!({
            "name": "device_launch",
            "description": format!("Launch an installed app on a booted simulator, ending a running copy first. Returns its pid. {DEVICE_DRIVING_NOTE}"),
            "annotations": { "readOnlyHint": false, "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "udid": udid,
                    "bundle_id": { "type": "string", "minLength": 1, "maxLength": 255, "description": "The app's bundle ID, from device_install." }
                },
                "required": ["udid", "bundle_id"]
            }
        }),
```

Parsing, after `"device_button"`:

```rust
        "device_install" => {
            reject_arguments(args, name, &["udid", "app_path"])?;
            let app_path = required_limited_string(args, "app_path", 4096)?;
            Ok(Command::Device(alas_client::DeviceCommand::Install {
                udid: required_limited_string(args, "udid", 64)?,
                app_path: alas_client::absolutize(std::path::Path::new(worktree_dir), &app_path),
            }))
        }
        "device_launch" => {
            reject_arguments(args, name, &["udid", "bundle_id"])?;
            Ok(Command::Device(alas_client::DeviceCommand::Launch {
                udid: required_limited_string(args, "udid", 64)?,
                bundle_id: required_limited_string(args, "bundle_id", 255)?,
            }))
        }
```

Fix any other exhaustive `match` over `DeviceCommand` the compiler reports.

- [ ] **Step 7: Run all affected tests**

```bash
swift test --package-path Packages/AlasCore --filter 'DeviceCommandTests|SimulatorAppBundleTests'
cargo test --manifest-path AlasCLI/Cargo.toml -p alas -p alas-client
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/DeviceAgentControlTests -only-testing AlasTests/ACPMCPPromptPreambleTests test
```

Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add Packages/AlasCore Alas/Sources AlasTests AlasCLI
git commit -m "feat(devices): let agents install and launch apps on a simulator"
```

---

### Task 4: Drop a `.app` onto the screen

**Files:**
- Modify: `Alas/Sources/Devices/DevicePaneModel.swift`
- Modify: `Alas/Sources/Devices/DeviceScreenView.swift`
- Modify: `Alas/Sources/Devices/DeviceStage.swift`
- Modify: `Alas/Sources/Devices/DevicesTabView.swift` (the `.simulator(_, .booted)` case)

**Interfaces:**
- Consumes: `SimulatorAppBundle.read`, `SimulatorControl.install`/`launch` (Task 1).
- Produces:

```swift
final class DevicePaneModel {
    enum AppInstall: Equatable { case installing(String), launching(String), failed(String) }
    private(set) var appInstalls: [String: AppInstall]   // by UDID
    func installAndLaunch(_ app: URL, on device: SimulatorDevice) async
    func dismissAppInstall(udid: String)
}
struct DeviceScreenView { var onDropApp: (URL) -> Void; var onDropTargeted: (Bool) -> Void }
struct DeviceStage { let appInstall: DevicePaneModel.AppInstall?; let onDropApp: (URL) -> Void; let onDismissAppInstall: () -> Void }
```

No automated test: this is view wiring over Task 1's tested pieces.

- [ ] **Step 1: The model**

Add to `DevicePaneModel`:

```swift
    enum AppInstall: Equatable {
        case installing(String)
        case launching(String)
        case failed(String)
    }

    /// The app the user dropped on each simulator, while it installs and launches or after it failed.
    private(set) var appInstalls: [String: AppInstall] = [:]

    func installAndLaunch(_ url: URL, on device: SimulatorDevice) async {
        let app: SimulatorAppBundle
        do {
            app = try SimulatorAppBundle.read(url)
        } catch {
            appInstalls[device.udid] = .failed(error.localizedDescription)
            return
        }
        appInstalls[device.udid] = .installing(app.name)
        do {
            try await SimulatorControl.install(udid: device.udid, app: app.url)
            appInstalls[device.udid] = .launching(app.name)
            _ = try await SimulatorControl.launch(udid: device.udid, bundleID: app.bundleID)
            appInstalls[device.udid] = nil
        } catch {
            appInstalls[device.udid] = .failed("Couldn't open \(app.name): \(error.localizedDescription)")
        }
    }

    func dismissAppInstall(udid: String) {
        appInstalls[udid] = nil
    }
```

- [ ] **Step 2: The drop target**

In `DeviceScreenView` (the representable), add `var onDropApp: (URL) -> Void = { _ in }` and `var onDropTargeted: (Bool) -> Void = { _ in }`. Set both in `makeNSView` and `updateNSView`, like `onBlockedClick`. In `makeNSView`, also call `view.registerForDraggedTypes([.fileURL])`.

In `DeviceScreenNSView`, add the same two properties and:

```swift
    /// One `.app` the simulator can run; anything else isn't offered a drop.
    private func droppedApp(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        guard let urls, urls.count == 1, (try? SimulatorAppBundle.read(urls[0])) != nil else { return nil }
        return urls[0]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedApp(sender) != nil else { return [] }
        guard allowsInput else {
            onBlockedClick()
            return []
        }
        onDropTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTargeted(false)
        guard allowsInput, let app = droppedApp(sender) else { return false }
        onDropApp(app)
        return true
    }
```

- [ ] **Step 3: The stage**

Add to `DeviceStage` the inputs `let appInstall: DevicePaneModel.AppInstall?`, `let onDropApp: (URL) -> Void` and `let onDismissAppInstall: () -> Void`, and `@State private var dropTargeted = false`.

Pass `onDropApp: onDropApp, onDropTargeted: { dropTargeted = $0 }` to `DeviceScreenView` in `screen(allowsInput:driver:)`. Give the screen's `ZStack` an overlay for the install pill:

```swift
        .overlay(alignment: .bottom) {
            if let appInstall {
                appInstallPill(appInstall)
                    .padding(.bottom, 12)
            }
        }
```

In `body`, after `.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))`, add:

```swift
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(theme.color("accent"), lineWidth: 2)
                            .opacity(dropTargeted ? 1 : 0)
                    )
```

Add the pill, styled like `driverPill`:

```swift
    private func appInstallPill(_ install: DevicePaneModel.AppInstall) -> some View {
        HStack(spacing: 6) {
            switch install {
            case .installing(let name), .launching(let name):
                ProgressView().controlSize(.mini)
                Text(install == .installing(name) ? "Installing \(name)…" : "Launching \(name)…")
                    .foregroundStyle(theme.color("fg"))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.color("warn"))
                Text(message)
                    .foregroundStyle(theme.color("fg"))
                Button("Dismiss", action: onDismissAppInstall)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.color("accent"))
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .lineLimit(2)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .background(theme.color("bg-2").opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.color("line"), lineWidth: 0.5))
        .padding(.horizontal, 12)
    }
```

In `DevicesTabView`'s `.simulator(let device, .booted)` case, pass:

```swift
                appInstall: model.appInstalls[device.udid],
                onDropApp: { url in Task { await model.installAndLaunch(url, on: device) } },
                onDismissAppInstall: { model.dismissAppInstall(udid: device.udid) }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build`
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Devices
git commit -m "feat(devices): install and launch an app dropped on the simulator"
```

---

### Task 5: Docs and checking it end to end

**Files:**
- Modify: `docs/devices.md`
- Modify: `docs/plans/2026-11-04-device-panel-design.md` (Follow-up work)

- [ ] **Step 1: Throwaway app.** In `/tmp/alas-hello`, write a UIKit `main.swift` that shows a label. Build it for the simulator:
  - `xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator main.swift -o Hello.app/Hello`
  - Write an `Info.plist` with `CFBundleIdentifier` `com.example.hello`, `CFBundleExecutable` `Hello`, `CFBundleName` `Hello`, `DTPlatformName` `iphonesimulator` and `UILaunchScreen` `{}`.
  - Sign it ad hoc: `codesign -s - Hello.app`.
- [ ] **Step 2: Through the real stack.** Write a throwaway app-host test, `AlasTests/DeviceInstallScratch.swift`, that builds a `DeviceAgentControl` the way `AppState` does. On the booted simulator it runs `.install` with `/tmp/alas-hello/Hello.app`, then `.launch` with `com.example.hello`, and prints both responses. Expect `{"bundle_id":"com.example.hello","name":"Hello"}`, then a pid. A `simctl io <udid> screenshot` shows the label. Delete the test and `/tmp/alas-hello`, then run `xcodegen`.
- [ ] **Step 3: Docs.**
  - `docs/devices.md`:
    - add `device_install` ("Installs a built .app on a booted simulator and returns its bundle ID") and `device_launch` ("Launches an installed app, ending a running copy first") to the table;
    - in "Simulators", add a sentence on dropping a `.app` onto the screen;
    - in "Agents", replace the takeover sentences with how calls wait up to 50 seconds and then fail with `device_user_active`.
  - Design doc follow-ups:
    - tick "Install and launch an app (…)", and add "Agents and drag and drop; run scripts not yet.";
    - tick "Pause the agent's turn on takeover…", and add "Built as held calls (up to 50 s) for simulators; VMs still refuse.".
- [ ] **Step 4: Commit.** `docs(devices): describe held calls and installing apps`
- [ ] **Step 5: Manual pass in Alas Dev (the user):**
  1. Drag `Hello.app` onto the screen; also drag a plain folder and confirm nothing lights up.
  2. Have an agent build, install and launch an app.
  3. Take over while it works: the pill says it is waiting. Hand back, and its call goes ahead.
