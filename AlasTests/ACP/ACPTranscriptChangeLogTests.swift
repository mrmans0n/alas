import Testing
import Foundation
@testable import Alas

@MainActor
struct ACPTranscriptChangeLogTests {
    @Test func recordsNothingWhileNotTracking() {
        let log = ACPTranscriptChangeLog()
        log.record(index: 3)
        #expect(log.latestVersion == 0)
        #expect(log.changes(since: 0) == .none)
    }

    @Test func recordsDirtyIndicesWhileTracking() {
        let log = ACPTranscriptChangeLog()
        log.retainTracking()
        log.record(index: 3)
        log.record(index: 5)
        #expect(log.changes(since: 0) == .dirty([3, 5]))
        #expect(log.changes(since: log.latestVersion) == .none)
    }

    @Test func consecutiveSameIndexCoalescesIntoOneEntry() {
        let log = ACPTranscriptChangeLog()
        log.retainTracking()
        let consumed = log.latestVersion
        for _ in 0..<100 { log.record(index: 7) }   // streaming burst
        #expect(log.changes(since: consumed) == .dirty([7]))
        // A consumer that read mid-burst still sees the entry (version was bumped in place).
        let mid = log.latestVersion - 10
        #expect(log.changes(since: mid) == .dirty([7]))
    }

    @Test func structuralChangeBumpsEpochAndForcesResync() {
        let log = ACPTranscriptChangeLog()
        log.retainTracking()
        log.record(index: 1)
        let consumed = log.latestVersion
        let epochBefore = log.epoch
        log.recordStructural()
        #expect(log.epoch == epochBefore + 1)
        #expect(log.changes(since: consumed) == .resync)
        #expect(log.changes(since: log.latestVersion) == .none)
    }

    @Test func prunedHistoryForcesResync() {
        let log = ACPTranscriptChangeLog()
        log.retainTracking()
        log.record(index: 0)
        let consumed = log.latestVersion
        // Overflow the ring: alternate indices so entries don't coalesce.
        for i in 0..<(ACPTranscriptChangeLog.maxEntries + 10) {
            log.record(index: 1 + (i % 2))
        }
        #expect(log.changes(since: consumed) == .resync)
    }

    @Test func releasingLastTrackerClearsEntries() {
        let log = ACPTranscriptChangeLog()
        log.retainTracking()
        log.retainTracking()
        log.record(index: 2)
        let consumed = 0
        log.releaseTracking()
        #expect(log.changes(since: consumed) == .dirty([2]))   // still one tracker
        log.releaseTracking()
        #expect(log.isTracking == false)
        let versionBefore = log.latestVersion
        log.record(index: 9)                                    // ignored while untracked
        #expect(log.latestVersion == versionBefore)
        // A stale consumer from before the release must resync, not read a gap.
        #expect(log.changes(since: consumed) == .resync)
    }

    // MARK: - ACPTranscript hooks

    private func makeTrackedTranscript(messageCount: Int) -> ACPTranscript {
        let t = ACPTranscript()
        t.messages = (0..<messageCount).map { i in
            .user(id: UUID(), messageId: "u\(i)", text: "m\(i)", attachments: [])
        }
        t.changeLog.retainTracking()
        return t
    }

    @Test func appendIsRecordedAsDirtyIndex() {
        let t = makeTrackedTranscript(messageCount: 3)
        let consumed = t.changeLog.latestVersion
        t.messages.append(.systemNotice(id: UUID(), text: "notice"))
        #expect(t.changeLog.changes(since: consumed) == .dirty([3]))
    }

    @Test func inPlaceMutationKeepingIdentityIsRecordedAsDirty() {
        let t = ACPTranscript()
        var tc = ACPMessage.ToolCall(toolCallId: "tc1", title: "read", status: "in_progress", content: "", preview: "")
        t.messages = [.toolCall(tc)]
        t.changeLog.retainTracking()
        let consumed = t.changeLog.latestVersion
        tc.status = "completed"
        t.messages[0] = .toolCall(tc)
        #expect(t.changeLog.changes(since: consumed) == .dirty([0]))
        #expect(t.changeLog.epoch == 0)
    }

    @Test func removalIsStructural() {
        let t = makeTrackedTranscript(messageCount: 3)
        let epochBefore = t.changeLog.epoch
        t.messages.removeLast()
        #expect(t.changeLog.epoch == epochBefore + 1)
    }

    @Test func identityChangeAtExistingIndexIsStructural() {
        let t = makeTrackedTranscript(messageCount: 3)
        let epochBefore = t.changeLog.epoch
        // Prepending shifts every identity; the diff sees index 0's stableId change.
        t.messages.insert(.systemNotice(id: UUID(), text: "older"), at: 0)
        #expect(t.changeLog.epoch == epochBefore + 1)
    }

    @Test func streamingChangeIsRecordedWithoutArrayMutation() {
        let t = ACPTranscript()
        let buf = StreamingText("hel")
        t.messages = [.agent(id: UUID(), messageId: "a1", buf)]
        t.changeLog.retainTracking()
        let consumed = t.changeLog.latestVersion
        let tickBefore = t.streamingTick
        buf.append("lo")                    // no didSet fires (identity equality)
        t.noteStreamingChange(at: 0)
        #expect(t.streamingTick == tickBefore &+ 1)
        #expect(t.changeLog.changes(since: consumed) == .dirty([0]))
    }

    @Test func untrackedTranscriptPaysNoDiffAndRecordsNothing() {
        let t = ACPTranscript()
        t.messages = [.systemNotice(id: UUID(), text: "x")]
        t.messages.append(.systemNotice(id: UUID(), text: "y"))
        #expect(t.changeLog.latestVersion == 0)
    }
}
