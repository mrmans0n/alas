import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscript streaming tick throttle")
struct ACPTranscriptTests {
    @Test("streamingTickAction throttle decisions")
    func streamingTickThrottleDecisions() {
        typealias T = ACPTranscript
        #expect(T.streamingTickAction(elapsedSincePublish: 1.0, hasPendingDrain: false) == .publishNow)
        #expect(T.streamingTickAction(elapsedSincePublish: 0.01, hasPendingDrain: false)
            == .scheduleDrain(after: T.streamingTickMinInterval - 0.01))
        #expect(T.streamingTickAction(elapsedSincePublish: 0.01, hasPendingDrain: true) == .drop)
    }

    @Test("streamingTickAction publishes exactly at the min interval boundary")
    func streamingTickAtBoundary() {
        typealias T = ACPTranscript
        #expect(T.streamingTickAction(elapsedSincePublish: T.streamingTickMinInterval, hasPendingDrain: false)
            == .publishNow)
    }

    @Test("streamingTickAction with pending drain always drops regardless of elapsed time")
    func streamingTickPendingDrainAlwaysDrops() {
        typealias T = ACPTranscript
        #expect(T.streamingTickAction(elapsedSincePublish: 5.0, hasPendingDrain: true) == .drop)
    }

    @Test("noteStreamingChange publishes immediately for the first chunk")
    func firstChunkPublishesImmediately() {
        let t = ACPTranscript()
        t.messages.append(.systemNotice(id: UUID(), text: "x"))
        let before = t.streamingTick
        t.noteStreamingChange(at: 0)
        #expect(t.streamingTick == before &+ 1)
    }

    @Test("noteStreamingChange coalesces a fast burst and still delivers a trailing tick")
    func burstCoalescesWithTrailingDelivery() async throws {
        let t = ACPTranscript()
        t.messages.append(.systemNotice(id: UUID(), text: "x"))

        // First call publishes immediately.
        t.noteStreamingChange(at: 0)
        let afterFirst = t.streamingTick

        // Rapid-fire subsequent calls within the same throttle window must not
        // publish synchronously — they should coalesce into a pending drain.
        for _ in 0..<20 {
            t.noteStreamingChange(at: 0)
        }
        #expect(t.streamingTick == afterFirst)

        // The trailing drain must eventually fire even though no further chunk
        // arrives after the burst ends.
        let deadline = Date().addingTimeInterval(1.0)
        while t.streamingTick == afterFirst, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(t.streamingTick == afterFirst &+ 1)
    }

    @Test("noteStreamingChange records the change log entry on every call, unthrottled")
    func changeLogRecordingStaysUnthrottled() {
        let t = ACPTranscript()
        t.messages.append(.systemNotice(id: UUID(), text: "x"))
        t.changeLog.retainTracking()
        defer { t.changeLog.releaseTracking() }

        let startVersion = t.changeLog.latestVersion
        for _ in 0..<5 {
            t.noteStreamingChange(at: 0)
        }

        // Every call recorded a changeLog entry even though streamingTick
        // publishes were throttled — five calls means five version bumps
        // (coalesced into one dirty index since they share index 0).
        #expect(t.changeLog.latestVersion == startVersion &+ 5)
        if case .dirty(let indices) = t.changeLog.changes(since: startVersion) {
            #expect(indices == [0])
        } else {
            Issue.record("expected dirty changes at index 0")
        }
    }
}
