import Foundation
import Testing
@testable import Alas

@MainActor
struct ReviewSessionSelectionPersisterTests {
    @Test func coalescesBurstIntoSingleLatestWrite() async throws {
        let persister = ReviewSessionSelectionPersister(debounceNanos: 20_000_000)
        var writes: [String] = []

        persister.schedule { writes.append("first") }
        persister.schedule { writes.append("second") }
        persister.schedule { writes.append("third") }
        #expect(writes.isEmpty)

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(writes == ["third"])
    }

    @Test func flushRunsPendingWriteImmediatelyAndOnlyOnce() async throws {
        let persister = ReviewSessionSelectionPersister(debounceNanos: 20_000_000)
        var writes: [String] = []

        persister.schedule { writes.append("pending") }
        persister.flush()
        #expect(writes == ["pending"])

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(writes == ["pending"])
    }

    @Test func flushWithoutPendingWriteIsNoOp() {
        let persister = ReviewSessionSelectionPersister(debounceNanos: 20_000_000)
        persister.flush()
    }

    // MARK: - mergingSelectedFile

    @Test func mergingSelectedFileOverridesOnlySelectionAndTimestamp() {
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "aaa",
            title: "Review aaa"
        )
        let latest = ReviewSessionRecord(
            id: target.id,
            target: target,
            selectedFileID: DiffReviewFileID(namespace: "commit", path: "A.swift"),
            status: .sent,
            handoffs: [],
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 2)
        )
        let newFileID = DiffReviewFileID(namespace: "commit", path: "B.swift")
        let now = Date(timeIntervalSince1970: 99)

        let merged = ReviewSessionTabView.mergingSelectedFile(into: latest, fileID: newFileID, now: now)

        #expect(merged.selectedFileID == newFileID)
        #expect(merged.updatedAt == now)
        #expect(merged.target == latest.target)
        #expect(merged.status == latest.status)
    }

    @Test func mergingSelectedFileIsANoOpWhenSelectionAlreadyMatches() {
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "aaa",
            title: "Review aaa"
        )
        let fileID = DiffReviewFileID(namespace: "commit", path: "A.swift")
        let latest = ReviewSessionRecord(
            id: target.id,
            target: target,
            selectedFileID: fileID,
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 2)
        )

        let merged = ReviewSessionTabView.mergingSelectedFile(into: latest, fileID: fileID, now: .init(timeIntervalSince1970: 99))

        // No selection change means no write-worthy mutation: updatedAt must
        // not bump on every redundant flush.
        #expect(merged == latest)
    }

    /// Reproduces the race a debounced flush can hit: another path (e.g.
    /// `AppState.persistReviewRetargeting`) replaces this session's stored
    /// record — under a *new* id — while a selection write is still
    /// pending. The flush must merge onto whatever is live at flush time,
    /// not resurrect the record the replace just removed or clobber its
    /// fresher fields.
    @Test func flushMergesOntoRecordReplacedDuringTheDebounceWindow() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)

        let oldTarget = ReviewSessionTarget.commit(
            worktreeID: "wt-1", repositoryPath: URL(fileURLWithPath: "/repo"), sha: "aaa", title: "Review aaa"
        )
        let originalRecord = ReviewSessionRecord(
            id: oldTarget.id,
            target: oldTarget,
            selectedFileID: DiffReviewFileID(namespace: "commit", path: "A.swift"),
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 1)
        )
        try store.save(originalRecord)

        // A selection change is scheduled while `originalRecord.id` is still
        // the live id — this is the id a debounced flush would capture.
        let scheduledSessionID = originalRecord.id
        let pendingFileID = DiffReviewFileID(namespace: "commit", path: "B.swift")

        // Before the flush fires, a retarget replaces the record under a
        // new id, carrying forward a handoff the flush must not lose.
        let newTarget = ReviewSessionTarget.commit(
            worktreeID: "wt-1", repositoryPath: URL(fileURLWithPath: "/repo"), sha: "bbb", title: "Review bbb"
        )
        let handoff = ReviewFeedbackHandoff(
            id: "handoff-1",
            sessionID: newTarget.id,
            commentIDs: ["draft-1"],
            target: .existingSession(worktreeID: "wt-1", sessionID: "acp-1", title: "Codex"),
            createdAt: .init(timeIntervalSince1970: 5),
            promptRevision: "revision-1",
            status: .sent
        )
        let retargetedRecord = ReviewSessionRecord(
            id: newTarget.id,
            target: newTarget,
            selectedFileID: originalRecord.selectedFileID,
            handoffs: [handoff],
            createdAt: originalRecord.createdAt,
            updatedAt: .init(timeIntervalSince1970: 5)
        )
        try store.replace(id: originalRecord.id, with: retargetedRecord)

        // The flush: load whatever is live via the id captured at schedule
        // time (following the replacement), then merge the pending
        // selection onto it.
        let latest = try #require(try store.load(id: scheduledSessionID))
        let merged = ReviewSessionTabView.mergingSelectedFile(into: latest, fileID: pendingFileID, now: .init(timeIntervalSince1970: 9))
        try store.save(merged)

        let reloaded = try #require(try store.load(id: scheduledSessionID))
        #expect(reloaded.id == newTarget.id)
        #expect(reloaded.target == newTarget)
        #expect(reloaded.handoffs == [handoff])
        #expect(reloaded.selectedFileID == pendingFileID)
    }

    /// Reproduces the other half of the flush race: `recordSessionHandoff`
    /// reassigns the view's in-memory record from a fresh disk load, which
    /// reverts `selectedFileID` to whatever was on disk before the pending
    /// selection write flushes. The flush must persist the selection
    /// captured when it was scheduled, not read it back off a record that
    /// may have just been reverted underneath it. Uses the real
    /// `ReviewSessionHandoffPersistence.record` — the same function
    /// `recordSessionHandoff` calls — composed with a real store.
    @Test func flushPersistsTheScheduledSelectionEvenAfterAHandoffRevertsRecord() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)

        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1", repositoryPath: URL(fileURLWithPath: "/repo"), sha: "aaa", title: "Review aaa"
        )
        let fileA = DiffReviewFileID(namespace: "commit", path: "A.swift")
        let fileB = DiffReviewFileID(namespace: "commit", path: "B.swift")
        let originalRecord = ReviewSessionRecord(
            id: target.id,
            target: target,
            selectedFileID: fileA,
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 1)
        )
        try store.save(originalRecord)

        // The user selects B: in-memory record updates immediately, and the
        // debounced write captures B — but hasn't flushed to disk yet, so
        // disk still has A.
        let recordAfterSelection = originalRecord.selectingFile(fileB, now: .init(timeIntervalSince1970: 2))
        let scheduledFileID = fileB

        // Before the flush fires, a send completes. recordSessionHandoff's
        // real code path reloads from disk (still selectedFileID == A) in
        // preference to the in-memory record, reverting the local snapshot.
        let handoff = ReviewFeedbackHandoff(
            id: "handoff-1",
            sessionID: target.id,
            commentIDs: ["draft-1"],
            target: .existingSession(worktreeID: "wt-1", sessionID: "acp-1", title: "Codex"),
            createdAt: .init(timeIntervalSince1970: 3),
            promptRevision: "revision-1",
            status: .sent
        )
        let recordAfterHandoff = ReviewSessionHandoffPersistence.record(
            handoff,
            currentRecord: recordAfterSelection,
            sessionStore: store,
            persistsState: true,
            now: { .init(timeIntervalSince1970: 3) }
        )
        // Confirms the precondition: the handoff path really does revert
        // the local selection back to what was on disk.
        #expect(recordAfterHandoff?.selectedFileID == fileA)

        // The flush: merge the selection captured at schedule time onto
        // whatever is live in the store now (the handoff-updated record).
        let latest = try #require(try store.load(id: target.id))
        let merged = ReviewSessionTabView.mergingSelectedFile(
            into: latest, fileID: scheduledFileID, now: .init(timeIntervalSince1970: 4)
        )
        try store.save(merged)

        let reloaded = try #require(try store.load(id: target.id))
        #expect(reloaded.selectedFileID == fileB)
        #expect(reloaded.handoffs == [handoff])
    }

    @Test func scheduleAfterFlushStartsFreshDebounce() async throws {
        let persister = ReviewSessionSelectionPersister(debounceNanos: 20_000_000)
        var writes: [String] = []

        persister.schedule { writes.append("first") }
        persister.flush()
        persister.schedule { writes.append("second") }
        #expect(writes == ["first"])

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(writes == ["first", "second"])
    }
}
