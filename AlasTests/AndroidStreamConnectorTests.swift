import AlasCore
import Foundation
import Testing
@testable import Alas

struct AndroidStreamConnectorTests {
    struct Refused: Error {}

    @Test func itRetriesUntilTheServerAnswers() async throws {
        // adb refuses, then accepts and hangs up twice, then the server answers.
        var answers: [Result<Int?, Refused>] = [.failure(Refused()), .success(nil), .success(nil), .success(7)]
        let socket = try await AndroidStreamConnector.connect(pause: {}) { try answers.removeFirst().get() }
        #expect(socket == 7)
        #expect(answers.isEmpty)
    }

    @Test func itGivesUpWhenTheServerNeverAnswers() async {
        await #expect(throws: AndroidStreamError.serverDidNotStart) {
            try await AndroidStreamConnector.connect(attempts: 3, pause: {}) { nil as Int? }
        }
    }
}

/// A fake `adb` that logs its arguments, then runs the shell `case` arms given.
private func fakeADB(_ cases: String) throws -> (adb: String, log: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alas-fake-adb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("log")
    let adb = dir.appendingPathComponent("adb")
    try """
    #!/bin/sh
    echo "$*" >> "\(log.path)"
    case "$*" in
      \(cases)
    esac
    """.write(to: adb, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
    return (adb.path, log)
}

private func logged(_ log: URL) -> String {
    (try? String(contentsOf: log, encoding: .utf8)) ?? ""
}

/// An Android screen session against a fake `adb`.
@MainActor // AndroidScreenSession is main-actor isolated.
struct AndroidScreenSessionTests {
    @Test func stoppingWhileItStartsRemovesWhatItGoesOnToCreate() async throws {
        let fake = try fakeADB(#"*" forward tcp:0 "*) sleep 0.5; echo 51234 ;;"#)
        let session = AndroidScreenSession(
            serial: "emulator-5554", control: AndroidControl(sdk: AndroidSDK(root: nil, adb: fake.adb, emulator: nil)),
            serverJar: URL(fileURLWithPath: "/dev/null")
        )
        let starting = Task { await session.start() }
        // Stopped while adb sets up the forward, whose port arrives afterwards.
        try await eventually("forwarding", within: .seconds(5)) {
            ((try? String(contentsOf: fake.log, encoding: .utf8)) ?? "").contains("forward tcp:0")
        }
        session.stop()
        await starting.value
        try await eventually("forward removed", within: .seconds(5)) {
            ((try? String(contentsOf: fake.log, encoding: .utf8)) ?? "").contains("forward --remove tcp:51234")
        }
        #expect(!((try? String(contentsOf: fake.log, encoding: .utf8)) ?? "").contains("app_process"))
    }
}

@MainActor // AndroidStreamClient is main-actor isolated.
struct AndroidStreamClientTests {
    /// Retry gives the screen a new view, which SwiftUI may subscribe before
    /// the old one goes: a stream that stopped must start again regardless.
    @Test func aScreenSubscribingAfterTheStreamStoppedStartsItAgain() {
        var starts = 0
        let client = AndroidStreamClient(control: {
            starts += 1
            return nil // No SDK: each start stops at once, which is what the screens see.
        })
        var stops: [String] = []
        _ = client.subscribe(udid: "emulator-5554", onFrame: { _ in }, onStop: { _ in stops.append("old") })
        _ = client.subscribe(udid: "emulator-5554", onFrame: { _ in }, onStop: { _ in stops.append("new") })
        #expect(starts == 2)
        #expect(stops.contains("new"))
    }
}

@MainActor // The recording and the reply are main-actor isolated.
struct AndroidRecordingAndClipboardTests {
    @Test func aRecordingThatCannotBePulledStaysOnTheDevice() async throws {
        // screenrecord ends at once; the pull fails.
        let fake = try fakeADB(#"*" pull "*) exit 1 ;;"#)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("alas-\(UUID().uuidString).mp4")
        let recording = try AndroidScreenRecording(
            control: AndroidControl(sdk: AndroidSDK(root: nil, adb: fake.adb, emulator: nil)), serial: "S", file: file
        )
        var written: Bool?
        recording.onExit = { written = $0 }
        try await eventually("ended", within: .seconds(5)) { written != nil }
        #expect(written == false)
        #expect(logged(fake.log).contains(" pull "))
        #expect(!logged(fake.log).contains(" rm "))
    }

    @Test func anOlderRequestsTimeoutDoesNotEndANewerOne() async throws {
        var timers: [CheckedContinuation<Void, Never>] = []
        let reply = LatestReply<String> { _ in await withCheckedContinuation { timers.append($0) } }
        async let first = reply.request(timeout: .seconds(2)) {}
        try await eventually("first timer", within: .seconds(5)) { timers.count == 1 }
        reply.deliver("one")
        #expect(await first == "one")
        async let second = reply.request(timeout: .seconds(2)) {}
        try await eventually("second timer", within: .seconds(5)) { timers.count == 2 }
        timers[0].resume() // The first request's timeout fires late.
        reply.deliver("two")
        #expect(await second == "two")
        timers[1].resume()
    }
}
