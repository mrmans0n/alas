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
}
