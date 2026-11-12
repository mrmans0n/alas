import AlasCore
import Foundation
import Testing
@testable import Alas

@MainActor
struct DevicePasteboardTests {
    /// Records each call, and the keys sent so far, in one ordered log.
    final class FakePasteboard: SimulatorPasteboardControl, @unchecked Sendable {
        var text = "old"
        var accessBefore = SimulatorPasteAccess.notSet
        var log: [String] = []
        var onRead: () -> Void = {}
        func read(udid: String) async throws -> String { onRead(); log.append("read"); return text }
        func write(udid: String, text: String) async throws { log.append("write \(text)"); self.text = text }
        func access(udid: String, bundleID: String) async -> SimulatorPasteAccess { accessBefore }
        func setAccess(udid: String, bundleID: String, _ action: SimulatorPrivacyAction) async throws {
            log.append("\(action.rawValue) \(bundleID)")
        }
    }

    private func pasteboard(
        _ fake: FakePasteboard, input: DeviceAgentControlTests.FakeInput = .init(), front: String? = "com.example.app",
        sleep: @escaping @MainActor (Duration) async -> Void = { _ in }
    ) -> DevicePasteboard {
        DevicePasteboard(input: input, pasteboard: fake, frontmostApp: { _ in front }, sleep: sleep)
    }

    @Test(arguments: [
        (SimulatorPasteAccess.notSet, true, ["grant com.example.app", "write é", "write old", "reset com.example.app"]),
        (.allowed, true, ["write é", "write old"]),
        (.denied, true, ["grant com.example.app", "write é", "write old", "revoke com.example.app"]),
        (.notSet, false, ["grant com.example.app", "write é", "reset com.example.app"]),
    ])
    func aPastePutsThePermissionAndTextBack(before: SimulatorPasteAccess, restoreText: Bool, calls: [String]) async throws {
        let fake = FakePasteboard()
        fake.accessBefore = before
        let input = DeviceAgentControlTests.FakeInput()
        let pasteboard = pasteboard(fake, input: input)
        let paste = try await pasteboard.open(udid: "on", keepText: restoreText)
        try await pasteboard.paste("é", in: paste)
        await pasteboard.close(paste)
        #expect(fake.log.filter { $0 != "read" } == calls)
        #expect(input.keys.map(\.usage) == [0xE3, 0x19, 0x19, 0xE3])
    }

    @Test func withNoAppInFrontItPastesWithoutAGrant() async throws {
        let fake = FakePasteboard()
        let input = DeviceAgentControlTests.FakeInput()
        let pasteboard = pasteboard(fake, input: input, front: nil)
        let paste = try await pasteboard.open(udid: "on", keepText: false)
        try await pasteboard.paste("é", in: paste)
        await pasteboard.close(paste)
        #expect(fake.log == ["write é"])
        #expect(input.keys.count == 4)
    }

    @Test func copyReturnsTheNewTextOrNilWhenNothingChanges() async throws {
        let fake = FakePasteboard()
        let pasteboard = pasteboard(fake)
        #expect(try await pasteboard.copy(udid: "on") == nil)
        var reads = 0
        fake.onRead = { reads += 1; if reads == 3 { fake.text = "selected" } }
        #expect(try await pasteboard.copy(udid: "on") == "selected")
    }

    @Test func aCopyWaitsForAPasteOnTheSameSimulator() async throws {
        let fake = FakePasteboard()
        let pasteboard = pasteboard(fake)
        let paste = try await pasteboard.open(udid: "on", keepText: true)
        let copy = Task { try await pasteboard.copy(udid: "on") }
        for _ in 0..<20 { await Task.yield() }
        #expect(fake.log == ["read", "grant com.example.app"])
        try await pasteboard.paste("é", in: paste)
        await pasteboard.close(paste)
        _ = try await copy.value
        #expect(fake.log.prefix(5) == ["read", "grant com.example.app", "write é", "write old", "reset com.example.app"])
    }
}
