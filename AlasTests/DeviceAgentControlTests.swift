import AlasCore
import CoreVideo
import Foundation
import IOSurface
import Testing
@testable import Alas

@MainActor
struct DeviceAgentControlTests {
    final class FakeInput: DeviceInput {
        var touches: [(phase: String, point: DeviceScreenPoint)] = []
        var keys: [(usage: UInt32, down: Bool)] = []
        /// Whether the stream was still held when each key was sent.
        var keysWhileStreaming: [Bool] = []
        var subscribed: Set<String> = []
        var subscribeCount = 0
        var onStops: [String: @MainActor (String) -> Void] = [:]
        /// Yields before each `describe` answers, in call order, to finish calls out of order.
        var describeYields: [Int] = []
        let frame = IOSurface(properties: [
            .width: 120, .height: 240, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ])

        func subscribe(udid: String, onFrame: @escaping @MainActor (IOSurface) -> Void,
                       onStop: @escaping @MainActor (String) -> Void) -> UUID {
            subscribed.insert(udid)
            subscribeCount += 1
            onStops[udid] = onStop
            return UUID()
        }
        func unsubscribe(udid: String, token: UUID) { subscribed.remove(udid) }
        func touch(udid: String, phase: String, point: DeviceScreenPoint) { touches.append((phase, point)) }
        func key(udid: String, usage: UInt32, down: Bool) {
            keys.append((usage, down))
            keysWhileStreaming.append(subscribed.contains(udid))
        }
        func button(udid: String, name: String) {}
        func describe(udid: String) async throws -> Data {
            let yields = describeYields.isEmpty ? 0 : describeYields.removeFirst()
            for _ in 0..<yields { await Task.yield() }
            return DeviceAgentControlTests.snapshot
        }
        func lastFrame(udid: String) -> IOSurface? { frame }
    }

    static let booted = SimulatorDevice(udid: "on", name: "iPhone", runtimeName: "iOS 26.5", state: .booted)
    static let shutDown = SimulatorDevice(udid: "off", name: "iPhone", runtimeName: "iOS 26.5", state: .shutdown)

    /// An application root of 402×874 points with a button and a cell centered at (201, 346).
    static let snapshot = Data(#"""
    [{"type":"Application","frame":{"x":0,"y":0,"width":402,"height":874},"children":[
      {"type":"Button","role_description":"button","AXLabel":"Maps","frame":{"x":24,"y":88,"width":168,"height":191}},
      {"type":"Cell","role_description":"cell","AXLabel":"General","frame":{"x":16,"y":320,"width":370,"height":52}}
    ]}]
    """#.utf8)

    private final class Installs {
        var calls: [String] = []
    }

    final class FakeLogs: SimulatorLogsControl, @unchecked Sendable {
        var front: String? = "com.example.hello"
        var lines: [SimulatorLogLine] = []
        var queries: [SimulatorLogQuery] = []
        func frontmostApp(udid: String) async -> String? { front }
        func executables(udid: String) async throws -> [String: String] { ["com.example.hello": "Hello"] }
        func logShow(udid: String, query: SimulatorLogQuery, seconds: Int) async throws -> [SimulatorLogLine] {
            queries.append(query)
            return lines
        }
        func crashReports(udid: String, bundleID: String?, since: Date) async -> [SimulatorCrashReport] { [] }
    }

    static func line(_ message: String) -> SimulatorLogLine {
        SimulatorLogLine(time: "12:00:00.000", level: "default", process: "Hello", pid: 1, subsystem: nil, category: nil, message: message)
    }

    private func logsJSON(_ response: AlasCLIResponse) throws -> [String: Any] {
        guard case .text(let text) = response else {
            Issue.record("Expected logs, got \(response)")
            return [:]
        }
        return try #require(JSONSerialization.jsonObject(with: Data(text.joined().utf8)) as? [String: Any])
    }

    @Test func logsFollowTheForegroundAppAndAreNotHeldDuringATakeover() async throws {
        let logs = FakeLogs()
        logs.lines = [Self.line("one"), Self.line("Fatal error: two"), Self.line("three")]
        let control = control(FakeInput(), logs: logs)
        control.takeOver(udid: "on")
        let json = try logsJSON(await control.perform(
            .logs(udid: "on", sinceSeconds: 60, bundleID: nil, level: .default, includeApple: false, query: "FATAL", limit: 200),
            sessionID: "s"
        ))
        #expect(json["app"] as? String == "com.example.hello")
        #expect((json["lines"] as? [[String: Any]])?.map { $0["message"] as? String } == ["Fatal error: two"])
        #expect(json["truncated"] as? Bool == false)
        #expect(logs.queries == [SimulatorLogQuery(executable: "Hello")])
    }

    @Test func logsKeepTheNewestLinesUpToTheLimit() async throws {
        let logs = FakeLogs()
        logs.lines = (1...5).map { Self.line("\($0)") }
        let json = try logsJSON(await control(FakeInput(), logs: logs).perform(
            .logs(udid: "on", sinceSeconds: 60, bundleID: nil, level: .default, includeApple: false, query: nil, limit: 2),
            sessionID: "s"
        ))
        #expect((json["lines"] as? [[String: Any]])?.map { $0["message"] as? String } == ["4", "5"])
        #expect(json["truncated"] as? Bool == true)
    }

    @Test(arguments: [
        (nil as String?, nil as String?, "device_no_app: No app is in front on iPhone. Pass bundle_id."),
        ("com.example.gone", "com.example.hello", "device_app_not_installed: com.example.gone isn't installed on iPhone."),
    ])
    func logsNeedAnApp(bundleID: String?, front: String?, message: String) async {
        let logs = FakeLogs()
        logs.front = front
        let response = await control(FakeInput(), logs: logs).perform(
            .logs(udid: "on", sinceSeconds: 60, bundleID: bundleID, level: .default, includeApple: false, query: nil, limit: 200),
            sessionID: "s"
        )
        #expect(error(response) == message)
    }

    final class FakeSettings: SimulatorSettingsControl, @unchecked Sendable {
        var calls: [String] = []
        var installed: Set<String> = ["com.example.hello"]
        var read = SimulatorDisplaySettings(appearance: .value(.light), textSize: .value(.large), increaseContrast: .unsupported)

        func display(udid: String) async throws -> SimulatorDisplaySettings { read }
        func setDisplay(
            udid: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?
        ) async throws -> SimulatorDisplaySettings {
            calls.append("display \(appearance?.rawValue ?? "-")")
            if let appearance { read.appearance = .value(appearance) }
            return read
        }
        func setPermission(udid: String, bundleID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws {
            calls.append("privacy \(action.rawValue) \(service.rawValue) \(bundleID)")
        }
        func setLocation(udid: String, _ location: SimulatorLocation?) async throws { calls.append("location") }
        func push(udid: String, bundleID: String, payload: Data) async throws { calls.append("push \(bundleID)") }
        func openURL(udid: String, url: String) async throws { calls.append("open \(url)") }
        func userApps(udid: String) async throws -> [SimulatorApp] { [] }
        func isInstalled(udid: String, bundleID: String) async -> Bool { installed.contains(bundleID) }
    }

    private func control(
        _ input: FakeInput, installs: Installs = Installs(), settings: FakeSettings = FakeSettings(),
        logs: FakeLogs = FakeLogs(),
        pasteboard: DevicePasteboardTests.FakePasteboard = .init(),
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
            settings: settings,
            logs: logs,
            pasteboard: DevicePasteboard(input: input, pasteboard: pasteboard, frontmostApp: { _ in "com.example.app" }, sleep: sleep),
            sleep: sleep
        )
    }

    @Test func settingsAreHeldDuringATakeoverAndReturnWhatSimctlReadBack() async throws {
        let settings = FakeSettings()
        let control = control(FakeInput(), settings: settings, sleep: Self.untilCancelled)
        control.takeOver(udid: "on")
        async let changed = control.perform(
            .setAppearance(udid: "on", appearance: .dark, textSize: nil, increaseContrast: nil), sessionID: "s"
        )
        try await eventually("call is held") { control.waitingSessions(udid: "on") == ["s"] }
        #expect(settings.calls.isEmpty)
        control.handBack(udid: "on")
        #expect(await changed == .text([#"{"appearance":"dark","increase_contrast":"unsupported","text_size":"large"}"#]))
    }

    @Test(arguments: [
        DeviceCommand.setPermission(udid: "on", bundleID: "com.example.gone", service: .photos, action: .grant),
        .push(udid: "on", bundleID: "com.example.gone", payload: #"{"aps":{}}"#),
    ])
    func permissionsAndPushNeedTheAppInstalled(command: DeviceCommand) async {
        let settings = FakeSettings()
        let response = await control(FakeInput(), settings: settings).perform(command, sessionID: "s")
        #expect(error(response) == "device_app_not_installed: com.example.gone isn't installed on iPhone.")
        #expect(settings.calls.isEmpty)
    }

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
        try await eventually("install is held") { control.waitingSessions(udid: "on") == ["s"] }
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

    private func error(_ response: AlasCLIResponse) -> String? {
        if case .error(let message) = response { return message }
        return nil
    }

    private static func pasteboard(_ input: FakeInput = FakeInput()) -> DevicePasteboard {
        DevicePasteboard(input: input, pasteboard: DevicePasteboardTests.FakePasteboard(), frontmostApp: { _ in nil })
    }

    @Test func typingPastesWhatTheKeyboardLacksAndPutsThePasteboardBackOnce() async throws {
        let input = FakeInput()
        let pasteboard = DevicePasteboardTests.FakePasteboard()
        let control = control(input, pasteboard: pasteboard)
        let response = await control.perform(.type(udid: "on", text: "a é b ☕️\n", includeScreenshot: false), sessionID: "s")
        #expect(error(response) == nil)
        let downs = input.keys.filter(\.down).map(\.usage)
        // a, space, ⌘V, space, b, space, ⌘V, Return
        #expect(downs == [0x04, 0x2C, 0xE3, 0x19, 0x2C, 0x05, 0x2C, 0xE3, 0x19, 0x28])
        #expect(pasteboard.log == ["read", "grant com.example.app", "write é", "write ☕️", "write old", "reset com.example.app"])
    }

    @Test func aTakeoverWhileTypingStillPutsThePasteboardBack() async throws {
        let input = FakeInput()
        let pasteboard = DevicePasteboardTests.FakePasteboard()
        let control = control(input, pasteboard: pasteboard)
        pasteboard.onRead = { control.takeOver(udid: "on") }
        let response = await control.perform(.type(udid: "on", text: "é then more", includeScreenshot: false), sessionID: "s")
        #expect(error(response)?.hasPrefix("device_user_active") == true)
        #expect(pasteboard.log.suffix(2) == ["write old", "reset com.example.app"])
    }

    @Test func clipboardReadsAreNotHeldDuringATakeoverButWritesAre() async throws {
        let pasteboard = DevicePasteboardTests.FakePasteboard()
        let control = control(FakeInput(), pasteboard: pasteboard, sleep: Self.untilCancelled)
        control.takeOver(udid: "on")
        let read = await control.perform(.clipboard(udid: "on", text: nil), sessionID: "s")
        #expect(read == .text([#"{"text":"old"}"#]))
        async let write = control.perform(.clipboard(udid: "on", text: "new"), sessionID: "s")
        try await eventually("write is held") { control.waitingSessions(udid: "on") == ["s"] }
        control.handBack(udid: "on")
        #expect(await write == .text([#"{"ok":true}"#]))
        #expect(pasteboard.text == "new")
    }

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

    @Test(arguments: [
        (DeviceCommand.snapshot(udid: "gone", query: nil, limit: 200), "device_not_found"),
        (.tap(udid: "off", target: .point(x: 1, y: 1), includeScreenshot: false), "device_not_booted"),
    ])
    func refusesUnknownAndShutDownDevices(command: DeviceCommand, code: String) async {
        let response = await control(FakeInput()).perform(command, sessionID: "s")
        #expect(error(response)?.hasPrefix(code + ":") == true)
    }

    @Test func aCallMadeWhileTheUserDrivesRunsAfterHandBack() async throws {
        let input = FakeInput()
        let control = control(input, sleep: Self.untilCancelled)
        control.takeOver(udid: "on")
        async let call = control.perform(.button(udid: "on", name: .home, includeScreenshot: false), sessionID: "s")
        try await eventually("call is held") { control.waitingSessions(udid: "on") == ["s"] }
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

    /// Released calls keep their order even when the first one's device listing
    /// finishes last.
    @Test func heldCallsRunInArrivalOrder() async throws {
        let input = FakeInput()
        var listings = 0
        let control = DeviceAgentControl(
            input: input,
            devices: {
                listings += 1
                let yields = listings == 1 ? 50 : 0
                for _ in 0..<yields { await Task.yield() }
                return [Self.booted]
            },
            boot: { _ in }, install: { _, _ in }, launch: { _, _ in 0 }, settings: FakeSettings(), logs: FakeLogs(),
            pasteboard: Self.pasteboard(),
            sleep: Self.untilCancelled
        )
        control.takeOver(udid: "on")
        async let first = control.perform(.type(udid: "on", text: "a", includeScreenshot: false), sessionID: "s")
        try await eventually("first call is held") { control.waitingSessions(udid: "on") == ["s"] }
        async let second = control.perform(.type(udid: "on", text: "b", includeScreenshot: false), sessionID: "t")
        try await eventually("both calls are held") { control.waitingSessions(udid: "on") == ["s", "t"] }
        control.handBack(udid: "on")
        #expect(await (first, second) == (.ok, .ok))
        #expect(input.keys.filter(\.down).map(\.usage) == [0x04, 0x05])
    }

    @Test func aCancelledHeldCallLeavesTheQueue() async throws {
        let input = FakeInput()
        let control = control(input, sleep: Self.untilCancelled)
        control.takeOver(udid: "on")
        let call = Task { await control.perform(.type(udid: "on", text: "a", includeScreenshot: false), sessionID: "s") }
        try await eventually("call is held") { control.waitingSessions(udid: "on") == ["s"] }
        call.cancel()
        #expect(error(await call.value) == DeviceAgentControl.cancelled)
        #expect(control.waitingSessions(udid: "on").isEmpty)
        control.handBack(udid: "on")
        #expect(input.keys.isEmpty)
    }

    @Test func aSimulatorShutDownDuringTheTakeoverFailsTheHeldCall() async throws {
        var listed = [Self.booted]
        let control = DeviceAgentControl(
            input: FakeInput(), devices: { listed }, boot: { _ in },
            install: { _, _ in }, launch: { _, _ in 0 }, settings: FakeSettings(), logs: FakeLogs(),
            pasteboard: Self.pasteboard(), sleep: Self.untilCancelled
        )
        control.takeOver(udid: "on")
        async let call = control.perform(.button(udid: "on", name: .home, includeScreenshot: false), sessionID: "s")
        try await eventually("call is held") { !control.waitingSessions(udid: "on").isEmpty }
        listed = [SimulatorDevice(udid: "on", name: "iPhone", runtimeName: "iOS 26.5", state: .shutdown)]
        control.handBack(udid: "on")
        #expect(error(await call)?.hasPrefix("device_not_booted:") == true)
    }

    /// A takeover, or the agent cancelling the call, stops typing between
    /// keystrokes and says how far it got.
    @Test(arguments: [false, true])
    func typingStopsAndSaysHowFarItGot(cancelled: Bool) async {
        let input = FakeInput()
        var sleeps = 0
        var control: DeviceAgentControl!
        var call: Task<AlasCLIResponse, Never>!
        // Counts only the pauses between keystrokes; the lease timer sleeps too.
        control = self.control(input) { duration in
            guard duration == .milliseconds(20) else { return }
            sleeps += 1
            guard sleeps == 2 else { return }
            if cancelled { call.cancel() } else { control.takeOver(udid: "on") }
        }
        call = Task { await control.perform(.type(udid: "on", text: "abcd", includeScreenshot: false), sessionID: "s") }
        let response = await call.value
        #expect(error(response)?.hasPrefix(cancelled ? "device_cancelled:" : "device_user_active:") == true)
        #expect(error(response)?.contains("2 of 4 characters") == true)
        #expect(input.keys.filter(\.down).count == 2)
    }

    @Test func aTakeoverDuringAnAgentGestureEndsItAndRefuses() async {
        let input = FakeInput()
        var sleeps = 0
        var control: DeviceAgentControl!
        control = self.control(input) { _ in
            sleeps += 1
            if sleeps == 2 { control.takeOver(udid: "on") }
        }
        let response = await control.perform(
            .swipe(udid: "on", gesture: .direction(.up), durationMs: 500, includeScreenshot: false), sessionID: "s"
        )
        #expect(error(response)?.hasPrefix("device_user_active:") == true)
        #expect(input.touches.first?.phase == "begin")
        #expect(input.touches.last?.phase == "end")
        #expect(input.touches.count < 10)
    }

    @Test func tapByRefAndByPointMapToTheSameScreenFraction() async {
        let input = FakeInput()
        let control = control(input)
        _ = await control.perform(.snapshot(udid: "on", query: nil, limit: 200), sessionID: "s")
        _ = await control.perform(.screenshot(udid: "on"), sessionID: "s")
        #expect(await control.perform(.tap(udid: "on", target: .ref("s1e2"), includeScreenshot: false), sessionID: "s") == .ok)
        // The cell's center is (201, 346) points on a 402×874 screen; the screenshot is 120×240 pixels.
        let point = DeviceScreenPoint(x: 201.0 / 402, y: 346.0 / 874)
        #expect(await control.perform(
            .tap(udid: "on", target: .point(x: point.x * 120, y: point.y * 240), includeScreenshot: false), sessionID: "s"
        ) == .ok)
        let downs = input.touches.filter { $0.phase == "begin" }.map(\.point)
        #expect(downs.count == 2)
        #expect(abs(downs[0].x - downs[1].x) < 1e-9 && abs(downs[0].y - downs[1].y) < 1e-9)
    }

    @Test func aRefFromAnEarlierSnapshotIsRefused() async {
        let input = FakeInput()
        let control = control(input)
        _ = await control.perform(.snapshot(udid: "on", query: nil, limit: 200), sessionID: "s")
        _ = await control.perform(.snapshot(udid: "on", query: nil, limit: 200), sessionID: "s")
        let response = await control.perform(.tap(udid: "on", target: .ref("s1e2"), includeScreenshot: false), sessionID: "s")
        #expect(error(response)?.hasPrefix("device_stale_ref:") == true)
        #expect(input.touches.isEmpty)
    }

    @Test func tapByPointBeforeAnyScreenshotIsRefused() async {
        let input = FakeInput()
        let response = await control(input).perform(
            .tap(udid: "on", target: .point(x: 10, y: 10), includeScreenshot: false), sessionID: "s"
        )
        #expect(error(response)?.hasPrefix("device_no_screenshot:") == true)
        #expect(input.touches.isEmpty)
    }

    @Test func typingSendsShiftOnlyAroundShiftedCharacters() async {
        let input = FakeInput()
        #expect(await control(input).perform(.type(udid: "on", text: "aB", includeScreenshot: false), sessionID: "s") == .ok)
        #expect(input.keys.map(\.usage) == [0x04, 0x04, 0xE1, 0x05, 0x05, 0xE1])
        #expect(input.keys.map(\.down) == [true, false, true, true, false, false])
    }
}

extension DeviceAgentControlTests {
    /// A command that outlasts the lease window must keep its stream, or the
    /// service drops the session that delivers its input.
    @Test func theLeaseOutlastsACommandThatRunsPastItsWindow() async {
        let input = FakeInput()
        let window = Duration.seconds(60)
        let control = DeviceAgentControl(
            input: input, devices: { [Self.booted] }, boot: { _ in },
            install: { _, _ in }, launch: { _, _ in 0 }, settings: FakeSettings(), logs: FakeLogs(),
            pasteboard: Self.pasteboard(input),
            // The lease window passes at once; each typing pause lets it fire.
            sleep: { duration in
                guard duration != window else { return }
                for _ in 0..<5 { await Task.yield() }
            },
            leaseWindow: window
        )
        #expect(await control.perform(.type(udid: "on", text: "abcdef", includeScreenshot: false), sessionID: "s") == .ok)
        #expect(input.keysWhileStreaming.count == 12)
        #expect(input.keysWhileStreaming.allSatisfy { $0 })
    }

    /// Two snapshots in flight get different refs, and the older one never
    /// replaces the newer when it finishes last.
    @Test func overlappingSnapshotsKeepTheirRefsApart() async {
        let input = FakeInput()
        input.describeYields = [20, 0]
        let control = control(input)
        async let first = control.perform(.snapshot(udid: "on", query: nil, limit: 200), sessionID: "s")
        async let second = control.perform(.snapshot(udid: "on", query: nil, limit: 200), sessionID: "s")
        let (older, newer) = await (first, second)
        guard case .text(let olderLines) = older, case .text(let newerLines) = newer else {
            Issue.record("Both snapshots should succeed")
            return
        }
        let olderRefs = olderLines.joined().contains("\"s1e") ? "s1" : "s2"
        let newerRefs = newerLines.joined().contains("\"s1e") ? "s1" : "s2"
        #expect(olderRefs != newerRefs)
        let stale = await control.perform(.tap(udid: "on", target: .ref("s1e2"), includeScreenshot: false), sessionID: "s")
        #expect(error(stale)?.hasPrefix("device_stale_ref:") == true)
        #expect(await control.perform(.tap(udid: "on", target: .ref("s2e2"), includeScreenshot: false), sessionID: "s") == .ok)
    }
}

extension DeviceAgentControlTests {
    /// A stream that stopped must not stay counted for the agent, or nothing
    /// can start it again.
    @Test func aStoppedStreamDropsTheLeaseSoTheNextCallRestartsIt() async {
        let input = FakeInput()
        let control = control(input)
        #expect(await control.perform(.button(udid: "on", name: .home, includeScreenshot: false), sessionID: "s") == .ok)
        #expect(input.subscribeCount == 1)
        input.onStops["on"]?("The simulator stream stopped.")
        #expect(!input.subscribed.contains("on"))
        #expect(await control.perform(.button(udid: "on", name: .home, includeScreenshot: false), sessionID: "s") == .ok)
        #expect(input.subscribeCount == 2)
    }
}

extension DeviceAgentControlTests {
    /// Two agent calls to one simulator run one after the other, never interleaved.
    @Test func overlappingInputCallsDoNotInterleave() async {
        let input = FakeInput()
        let control = control(input) { _ in await Task.yield() }
        async let first = control.perform(.type(udid: "on", text: "ab", includeScreenshot: false), sessionID: "s")
        async let second = control.perform(.type(udid: "on", text: "cd", includeScreenshot: false), sessionID: "t")
        #expect(await (first, second) == (.ok, .ok))
        let downs = input.keys.filter(\.down).map(\.usage)
        #expect(downs == [0x04, 0x05, 0x06, 0x07] || downs == [0x06, 0x07, 0x04, 0x05])
    }

    /// The user's own install holds the simulator: an agent call started while
    /// it runs goes after it, never in the middle.
    @Test func anAgentCallWaitsForTheUsersInstall() async throws {
        let input = FakeInput()
        let control = control(input)
        let (finish, finishInstall) = AsyncStream<Void>.makeStream()
        let started = Installs()
        let install = Task {
            await control.whileUserHoldsInput(udid: "on") {
                started.calls.append("install")
                for await _ in finish {}
            }
        }
        try await eventually("install runs") { started.calls == ["install"] }
        async let typed = control.perform(.type(udid: "on", text: "a", includeScreenshot: false), sessionID: "s")
        // The call counts as in flight before it waits for its input turn.
        try await eventually("agent call is waiting") {
            if case .agent = control.driver(udid: "on") { true } else { false }
        }
        #expect(input.keys.isEmpty)
        finishInstall.finish()
        #expect(await install.value)
        #expect(await typed == .ok)
        #expect(input.keys.filter(\.down).map(\.usage) == [0x04])
    }

    @Test func theUsersInstallIsRefusedWhileAnAgentDrives() async {
        let control = control(FakeInput())
        #expect(await control.perform(.button(udid: "on", name: .home, includeScreenshot: false), sessionID: "s") == .ok)
        var ran = false
        #expect(await control.whileUserHoldsInput(udid: "on") { ran = true } == false)
        #expect(!ran)
    }
}
