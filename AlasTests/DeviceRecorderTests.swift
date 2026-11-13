import Foundation
import Testing
@testable import Alas

@MainActor
struct DeviceRecorderTests {
    /// Like `LiveScreenRecording`, a stop in a cancelled task can't wait for
    /// simctl to finish the file, so nothing is written.
    final class FakeRecording: ScreenRecording {
        var stopped = false
        var onExit: ((Bool) -> Void)?
        /// Makes `stop` wait until `release` is called, like simctl finishing a file.
        var holds = false
        var release: (() -> Void)?
        func stop() async -> Bool {
            stopped = true
            if holds { await withCheckedContinuation { release = $0.resume } }
            return !Task.isCancelled
        }
    }

    final class Recordings {
        var made: [FakeRecording] = []
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 0)
    }

    static let file = URL(fileURLWithPath: "/tmp/rec.mov")

    /// `limitPasses` lets an agent's 10-minute limit pass at once; otherwise it never does.
    static func recorder(
        _ recordings: Recordings = Recordings(), clock: Clock = Clock(), limitPasses: Bool = false
    ) -> DeviceRecorder {
        DeviceRecorder(
            start: { _, _ in
                let recording = FakeRecording()
                recordings.made.append(recording)
                return recording
            },
            now: { clock.now },
            sleep: { _ in if !limitPasses { await untilCancelled() } }
        )
    }

    private static func untilCancelled() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        await withTaskCancellationHandler {
            for await _ in stream {}
        } onCancel: {
            continuation.finish()
        }
    }

    @Test func stoppingReturnsTheFileAndHowLongItRan() async throws {
        let recordings = Recordings()
        let clock = Clock()
        let recorder = Self.recorder(recordings, clock: clock)
        try recorder.start(udid: "on", owner: .user, file: Self.file)
        clock.now += 12.5
        #expect(try await recorder.stop(udid: "on", owner: .user) == .init(file: Self.file, seconds: 12.5))
        #expect(recordings.made.first?.stopped == true)
        #expect(recorder.owner(udid: "on") == nil)
    }

    @Test func aSecondRecordingIsRefusedAndTheFirstKeepsRunning() throws {
        let recordings = Recordings()
        let recorder = Self.recorder(recordings)
        try recorder.start(udid: "on", owner: .user, file: Self.file)
        #expect(throws: DeviceRecorder.Failure.busy(.user)) {
            try recorder.start(udid: "on", owner: .agent(sessionID: "s"), file: Self.file)
        }
        #expect(recorder.owner(udid: "on") == .user)
        #expect(recordings.made.count == 1)
        #expect(recordings.made.first?.stopped == false)
    }

    @Test func aRecordingThatEndsByItselfIsReturnedOnceToItsOwner() async throws {
        let recordings = Recordings()
        let recorder = Self.recorder(recordings)
        let agent = DeviceRecorder.Owner.agent(sessionID: "s")
        try recorder.start(udid: "on", owner: agent, file: Self.file)
        recordings.made.first?.onExit?(true)
        #expect(recorder.owner(udid: "on") == nil)
        await #expect(throws: DeviceRecorder.Failure.notRecording) { try await recorder.stop(udid: "on", owner: .user) }
        #expect(try await recorder.stop(udid: "on", owner: agent).file == Self.file)
        await #expect(throws: DeviceRecorder.Failure.notRecording) { try await recorder.stop(udid: "on", owner: agent) }
    }

    @Test func anAgentsRecordingEndsAtTheLimit() async throws {
        let recordings = Recordings()
        let recorder = Self.recorder(recordings, limitPasses: true)
        let agent = DeviceRecorder.Owner.agent(sessionID: "s")
        try recorder.start(udid: "on", owner: agent, file: Self.file)
        try await eventually("the limit stops it") { recorder.owner(udid: "on") == nil }
        #expect(recordings.made.first?.stopped == true)
        #expect(try await recorder.stop(udid: "on", owner: agent).file == Self.file)
    }

    @Test func yourRecordingThatEndsByItselfIsHandedOnAtOnce() async throws {
        let recordings = Recordings()
        let recorder = Self.recorder(recordings)
        var handed: [DeviceRecorder.Finished] = []
        recorder.onUserRecordingEnded = { _, finished in handed.append(finished) }
        try recorder.start(udid: "on", owner: .user, file: Self.file)
        await recorder.simulatorStopped(udid: "on")
        #expect(handed.map(\.file) == [Self.file])
        await #expect(throws: DeviceRecorder.Failure.notRecording) { try await recorder.stop(udid: "on", owner: .user) }
    }

    @Test func anotherOwnersRecordingKeepsAnEndedOneForItsOwner() async throws {
        let recordings = Recordings()
        let recorder = Self.recorder(recordings)
        let agent = DeviceRecorder.Owner.agent(sessionID: "s")
        try recorder.start(udid: "on", owner: agent, file: Self.file)
        recordings.made.first?.onExit?(true)
        try recorder.start(udid: "on", owner: .user, file: URL(fileURLWithPath: "/tmp/other.mov"))
        #expect(try await recorder.stop(udid: "on", owner: agent).file == Self.file)
    }

    @Test func aStopWhileARecordingFinishesWaitsForIt() async throws {
        let recordings = Recordings()
        let recorder = Self.recorder(recordings)
        let agent = DeviceRecorder.Owner.agent(sessionID: "s")
        try recorder.start(udid: "on", owner: agent, file: Self.file)
        let recording = try #require(recordings.made.first)
        recording.holds = true
        let shutdown = Task { await recorder.simulatorStopped(udid: "on") }
        try await eventually("simctl is finishing the file") { recording.release != nil }
        async let stopped = recorder.stop(udid: "on", owner: agent)
        await Task.yield()
        recording.release?()
        #expect(try await stopped.file == Self.file)
        await shutdown.value
    }

    @Test func aStoppedRecordingIsReleased() async throws {
        weak var released: FakeRecording?
        do {
            let recordings = Recordings()
            let recorder = Self.recorder(recordings)
            try recorder.start(udid: "on", owner: .user, file: Self.file)
            released = recordings.made.first
            _ = try await recorder.stop(udid: "on", owner: .user)
            recordings.made.removeAll()
        }
        #expect(released == nil)
    }

    @Test func agentRecordingsStartedTogetherGetTheirOwnFiles() {
        let now = Date()
        #expect(DeviceRecorder.agentFile(udid: "on", now: now) != DeviceRecorder.agentFile(udid: "on", now: now))
    }

    @Test func quittingFinishesEveryRecording() async throws {
        let recordings = Recordings()
        let recorder = Self.recorder(recordings)
        var handed: [String] = []
        recorder.onUserRecordingEnded = { udid, _ in handed.append(udid) }
        let agent = DeviceRecorder.Owner.agent(sessionID: "s")
        try recorder.start(udid: "a", owner: .user, file: Self.file)
        try recorder.start(udid: "b", owner: agent, file: Self.file)
        await recorder.stopAll()
        #expect(recordings.made.allSatisfy { $0.stopped })
        #expect(handed == ["a"])
        #expect(recorder.owner(udid: "b") == nil)
    }

    @Test func recordingsOlderThanAWeekAreDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let old = directory.appendingPathComponent("old.mov")
        let recent = directory.appendingPathComponent("recent.mov")
        for file in [old, recent] { FileManager.default.createFile(atPath: file.path, contents: Data()) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: old.path)
        DeviceRecorder.pruneOldRecordings(in: directory, now: now)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["recent.mov"])
    }
}
