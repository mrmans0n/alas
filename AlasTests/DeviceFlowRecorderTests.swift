import AlasCore
import Foundation
import Testing
@testable import Alas

@MainActor
struct DeviceFlowRecorderTests {
    @Test func theUsersInputBecomesSteps() async throws {
        let backend = DeviceAgentControlTests.FakeBackend()
        backend.front = "com.example.hello"
        let recorder = DeviceFlowRecorder()
        await recorder.start(udid: "emulator-5554", backend: backend)
        // The General cell's center, (201, 346) on a 402×874 screen.
        let general = DeviceScreenPoint(x: 201.0 / 402, y: 346.0 / 874)
        recorder.gesture("emulator-5554", from: general, to: general)
        recorder.typed("emulator-5554", "hi\u{7F}o\u{F700}\r")
        recorder.typed("emulator-5554", "more")
        recorder.pressed("emulator-5554", .back)
        recorder.gesture("emulator-5554", from: DeviceScreenPoint(x: 0.5, y: 0.8), to: DeviceScreenPoint(x: 0.5, y: 0.2))
        recorder.typed("emulator-5554", "end")
        // A scroll's events add up to one swipe, the way the content moved, before the next step.
        recorder.scrolled("emulator-5554", dx: 1, dy: -4)
        recorder.scrolled("emulator-5554", dx: 0, dy: -30)
        recorder.pressed("emulator-5554", .home)
        recorder.scrolled("emulator-5554", dx: -12, dy: 2)
        let flow = try #require(recorder.stop("emulator-5554"))
        #expect(flow.appID == "com.example.hello")
        #expect(flow.steps == [
            .launchApp(nil), .tapOn(.text("General")), .inputText("ho"), .pressKey(.enter), .inputText("more"),
            .pressKey(.back), .swipe(.up), .inputText("end"), .swipe(.up), .pressKey(.home), .swipe(.left),
        ])
        #expect(!recorder.isRecording("emulator-5554"))
    }
}
