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

    private func control(_ input: FakeInput, sleep: @escaping @MainActor (Duration) async -> Void = { _ in }) -> DeviceAgentControl {
        DeviceAgentControl(
            input: input, devices: { [Self.booted, Self.shutDown] }, boot: { _ in }, sleep: sleep
        )
    }

    private func error(_ response: AlasCLIResponse) -> String? {
        if case .error(let message) = response { return message }
        return nil
    }

    @Test(arguments: [
        (DeviceCommand.snapshot(udid: "gone", query: nil, limit: 200), "device_not_found"),
        (.tap(udid: "off", target: .point(x: 1, y: 1), includeScreenshot: false), "device_not_booted"),
    ])
    func refusesUnknownAndShutDownDevices(command: DeviceCommand, code: String) async {
        let response = await control(FakeInput()).perform(command, sessionID: "s")
        #expect(error(response)?.hasPrefix(code + ":") == true)
    }

    @Test func aTakeoverRefusesCallsUntilHandedBack() async {
        let input = FakeInput()
        let control = control(input)
        control.takeOver(udid: "on")
        let refused = await control.perform(.button(udid: "on", name: .home, includeScreenshot: false), sessionID: "s")
        #expect(error(refused)?.hasPrefix("device_user_active:") == true)
        control.handBack(udid: "on")
        #expect(await control.perform(.button(udid: "on", name: .home, includeScreenshot: false), sessionID: "s") == .ok)
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
