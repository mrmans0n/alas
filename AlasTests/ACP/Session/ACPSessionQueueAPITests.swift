import Combine
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSession queue API")
struct ACPSessionQueueAPITests {
    private func mkSession() -> ACPSession {
        ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
    }

    @Test("queue starts empty")
    func empty() {
        #expect(mkSession().queue.isEmpty)
    }

    @Test("enqueue(blocks:) appends a pending item")
    func enqueue() {
        let s = mkSession()
        s.enqueue(blocks: [.text("hello")])
        #expect(s.queue.count == 1)
        #expect(s.queue[0].status == .pending)
        #expect(s.queue[0].blocks == [.text("hello")])
    }

    @Test("normal prompts stay ahead of scheduled prompts")
    func normalPromptsStayAheadOfScheduledPrompts() {
        let s = mkSession()
        s.enqueueScheduled(
            blocks: [.text("tomorrow")],
            scheduledAt: Date(timeIntervalSince1970: 200)
        )
        s.enqueueScheduled(
            blocks: [.text("later today")],
            scheduledAt: Date(timeIntervalSince1970: 100)
        )
        s.enqueue(blocks: [.text("now")])

        #expect(s.queue.map(\.blocks) == [
            [.text("now")],
            [.text("later today")],
            [.text("tomorrow")],
        ])
    }

    @Test("remove(id:) drops matching item, leaves others")
    func remove() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        let firstId = s.queue[0].id
        s.removeFromQueue(id: firstId)
        #expect(s.queue.count == 1)
        #expect(s.queue[0].blocks == [.text("b")])
    }

    @Test("move(from:to:) reorders within pending region")
    func move() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        s.enqueue(blocks: [.text("c")])
        s.moveInQueue(from: 0, to: 2)
        #expect(s.queue.map { $0.blocks } == [[.text("b")], [.text("c")], [.text("a")]])
    }

    @Test("moving a normal prompt cannot put it behind a scheduled prompt")
    func moveKeepsNormalPromptsAheadOfScheduledPrompts() {
        let s = mkSession()
        s.enqueue(blocks: [.text("now")])
        s.enqueueScheduled(blocks: [.text("later")], scheduledAt: .distantFuture)

        s.moveInQueue(from: 0, to: 1)
        #expect(s.queue.map(\.blocks) == [[.text("now")], [.text("later")]])
    }

    @Test("move(from:to:) refuses to move a .sending head")
    func moveSendingNoop() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        s.markQueueHeadSending()
        s.moveInQueue(from: 0, to: 1)
        #expect(s.queue[0].status == .sending)
        #expect(s.queue[0].blocks == [.text("a")])
    }

    @Test("forceQueueItem promotes a pending tail item to the head")
    func forceQueueItemPromotesPendingTail() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        let id = s.queue[1].id

        #expect(s.forceQueueItem(id: id))
        #expect(s.queue.map { $0.blocks } == [[.text("b")], [.text("a")]])
        #expect(s.queue[0].status == .pending)
    }

    @Test("forcing a scheduled prompt sends it now")
    func forceScheduledPromptClearsDeadline() {
        let s = mkSession()
        s.enqueueScheduled(
            blocks: [.text("later")],
            scheduledAt: Date(timeIntervalSince1970: 200)
        )

        #expect(s.forceQueueItem(id: s.queue[0].id))
        #expect(s.queue[0].scheduledAt == nil)
    }

    @Test("forceQueueItem clears a previous queue error")
    func forceQueueItemClearsError() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.queue[0].lastError = "network"
        let id = s.queue[0].id
        let operationKey = s.queue[0].brokerOperationKey

        #expect(s.forceQueueItem(id: id))
        #expect(s.queue[0].id == id)
        #expect(s.queue[0].lastError == nil)
        #expect(s.queue[0].status == .pending)
        #expect(s.queue[0].brokerOperationKey == operationKey)
    }

    @Test("terminal queue errors advance the retry broker operation key")
    func terminalQueueErrorAdvancesBrokerOperationKey() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.markQueueHeadSending()
        let operationKey = s.queue[0].brokerOperationKey

        s.setQueueHeadError("terminal", advancesBrokerOperationAttempt: true)
        #expect(s.queue[0].brokerOperationKey != operationKey)

        let retryKey = s.queue[0].brokerOperationKey
        #expect(s.forceQueueItem(id: s.queue[0].id))
        #expect(s.queue[0].brokerOperationKey == retryKey)
    }

    @Test("forceQueueItem refuses a .sending item")
    func forceQueueItemRefusesSending() {
        let s = mkSession()
        s.enqueue(blocks: [.text("in-flight")])
        s.enqueue(blocks: [.text("next")])
        s.markQueueHeadSending()
        let id = s.queue[0].id

        #expect(!s.forceQueueItem(id: id))
        #expect(s.queue.map { $0.blocks } == [[.text("in-flight")], [.text("next")]])
        #expect(s.queue[0].status == .sending)
    }

    @Test("forceQueueItem inserts after a .sending head")
    func forceQueueItemInsertsAfterSendingHead() {
        let s = mkSession()
        s.enqueue(blocks: [.text("in-flight")])
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        s.markQueueHeadSending()
        let id = s.queue[2].id

        #expect(s.forceQueueItem(id: id))
        #expect(s.queue.map { $0.blocks } == [[.text("in-flight")], [.text("b")], [.text("a")]])
        #expect(s.queue[0].status == .sending)
        #expect(s.queue[1].status == .pending)
    }

    @Test("setQueueHeadError keeps a forced item ahead of a failed in-flight head")
    func setQueueHeadErrorKeepsForcedItemAheadOfFailedHead() {
        let s = mkSession()
        s.enqueue(blocks: [.text("in-flight")])
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("forced")])
        s.markQueueHeadSending()
        let id = s.queue[2].id

        #expect(s.forceQueueItem(id: id))
        s.setQueueHeadError("network")

        #expect(s.queue.map { $0.blocks } == [[.text("forced")], [.text("in-flight")], [.text("a")]])
        #expect(s.queue[0].lastError == nil)
        #expect(s.queue[1].lastError == "network")
        #expect(s.queue[1].status == .pending)
    }

    @Test("setQueueHeadError leaves failed head first when the forced item was removed")
    func setQueueHeadErrorFallsBackWhenForcedItemRemoved() {
        let s = mkSession()
        s.enqueue(blocks: [.text("in-flight")])
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("forced")])
        s.markQueueHeadSending()
        let id = s.queue[2].id

        #expect(s.forceQueueItem(id: id))
        s.removeFromQueue(id: id)
        s.setQueueHeadError("network")

        #expect(s.queue.map { $0.blocks } == [[.text("in-flight")], [.text("a")]])
        #expect(s.queue[0].lastError == "network")
    }

    @Test("forceQueueItem resets recorded failed prompts it bypasses")
    func forceQueueItemResetsBypassedRecordedFailures() {
        let s = mkSession()
        s.enqueue(blocks: [.text("failed")])
        s.enqueue(blocks: [.text("clean")])
        s.enqueue(blocks: [.text("forced")])
        s.queue[0].lastError = "network"
        s.queue[0].transcriptRecorded = true
        s.queue[1].transcriptRecorded = true
        let id = s.queue[2].id

        #expect(s.forceQueueItem(id: id))
        #expect(s.queue.map { $0.blocks } == [[.text("forced")], [.text("failed")], [.text("clean")]])
        #expect(s.queue[1].lastError == "network")
        #expect(s.queue[1].transcriptRecorded == false)
        #expect(s.queue[2].transcriptRecorded == true)
    }

    @Test("forceQueueItem keeps sending head recorded when bypassing failed pending prompt")
    func forceQueueItemKeepsSendingHeadRecorded() {
        let s = mkSession()
        s.enqueue(blocks: [.text("in-flight")])
        s.enqueue(blocks: [.text("failed")])
        s.enqueue(blocks: [.text("forced")])
        s.markQueueHeadSending()
        s.queue[0].transcriptRecorded = true
        s.queue[1].lastError = "network"
        s.queue[1].transcriptRecorded = true
        let id = s.queue[2].id

        #expect(s.forceQueueItem(id: id))
        #expect(s.queue.map { $0.blocks } == [[.text("in-flight")], [.text("forced")], [.text("failed")]])
        #expect(s.queue[0].transcriptRecorded == true)
        #expect(s.queue[2].transcriptRecorded == false)
    }

    @Test("forceQueueItem returns false for an unknown id")
    func forceQueueItemUnknown() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])

        #expect(!s.forceQueueItem(id: UUID()))
        #expect(s.queue.map { $0.blocks } == [[.text("a")]])
    }

    @Test("clearPendingQueue() removes the user's .pending items but leaves .sending head and delegated prompts")
    func clearPendingKeepsSendingAndDelegated() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        s.enqueue(blocks: [.text("report")], delegatedSource: ACPDelegatedPromptSource(sessionId: "child", messageId: "m"))
        s.markQueueHeadSending()
        let snapshot = s.clearPendingQueue()
        #expect(s.queue.map { $0.blocks } == [[.text("a")], [.text("report")]])
        #expect(s.queue[0].status == .sending)
        #expect(snapshot.map { $0.blocks } == [[.text("b")]])
    }

    @Test("markQueueHeadSending flips .pending to .sending; clears lastError")
    func markHeadSending() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.setQueueHeadError("boom")
        s.markQueueHeadSending()
        #expect(s.queue[0].status == .sending)
        #expect(s.queue[0].lastError == nil)
    }

    @Test("markQueueHeadSending does not claim broker dispatch")
    func markHeadSendingDoesNotClaimBrokerDispatch() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])

        _ = s.markQueueHeadSending()

        #expect(s.queue[0].status == .sending)
        #expect(s.queue[0].dispatchedBrokerGeneration == nil)
    }

    @Test("popQueueHead removes the head when it's .sending; returns it")
    func popHead() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        s.markQueueHeadSending()
        let popped = s.popQueueHead()
        #expect(popped?.blocks == [.text("a")])
        #expect(s.queue.count == 1)
        #expect(s.queue[0].blocks == [.text("b")])
    }

    @Test("setQueueHeadError flips .sending back to .pending and records the message")
    func setHeadError() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.markQueueHeadSending()
        s.setQueueHeadError("network")
        #expect(s.queue[0].status == .pending)
        #expect(s.queue[0].lastError == "network")
    }

    @Test("terminal broker failure drops dispatch provenance from the next attempt")
    func terminalBrokerFailureDropsDispatchProvenance() {
        let s = mkSession()
        let oldGeneration = ACPBrokerGeneration(rawValue: 7)
        let nextGeneration = ACPBrokerGeneration(rawValue: 8)
        s.enqueue(blocks: [.text("terminal failure")])
        _ = s.markQueueHeadSending()
        #expect(s.queue[0].dispatchedBrokerGeneration == nil)
        #expect(s.markQueueHeadDispatched(id: s.queue[0].id, brokerGeneration: oldGeneration))
        #expect(s.queue[0].dispatchedBrokerGeneration == oldGeneration)

        s.setQueueHeadError("terminal", advancesBrokerOperationAttempt: true)

        #expect(s.queue[0].status == .pending)
        #expect(s.queue[0].brokerOperationAttempt == 1)
        #expect(s.queue[0].dispatchedBrokerGeneration == nil)
        #expect(!s.markQueuedPromptsUncertain(afterBrokerGeneration: nextGeneration))
        #expect(!s.queue[0].deliveryUncertain)
    }

    @Test("editQueueItem(id:blocks:) replaces blocks of a .pending item only")
    func editPending() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        let id = s.queue[0].id
        s.editQueueItem(id: id, blocks: [.text("a2")])
        #expect(s.queue[0].blocks == [.text("a2")])
    }

    @Test("editQueueItem refuses to edit a .sending item")
    func editSendingRefused() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.markQueueHeadSending()
        let id = s.queue[0].id
        s.editQueueItem(id: id, blocks: [.text("a2")])
        #expect(s.queue[0].blocks == [.text("a")])
    }

    @Test("restoreQueue normalizes .sending → .pending")
    func restoreNormalizes() {
        let s = mkSession()
        let sending = QueuedPrompt(blocks: [.text("a")], status: .sending)
        let pending = QueuedPrompt(blocks: [.text("b")], status: .pending)
        s.restoreQueue([sending, pending])
        #expect(s.queue.map { $0.status } == [.pending, .pending])
        #expect(s.queue.map { $0.blocks } == [[.text("a")], [.text("b")]])
    }

    enum UncertainOrigin: CaseIterable {
        /// `.sending` at quit with no dispatch provenance.
        case legacyRestore
        /// Dispatched on a broker generation the reconnect cannot adopt.
        case brokerGenerationChange
        /// Marked uncertain on an earlier reconnect, before the reply was stored.
        case earlierReconnect
    }

    @Test("an uncertain recorded prompt the transcript shows answered is dropped",
          arguments: UncertainOrigin.allCases)
    func uncertainDeliveredPromptDropped(origin: UncertainOrigin) {
        let s = mkSession()
        let generation: ACPBrokerGeneration? = origin == .legacyRestore ? nil : ACPBrokerGeneration(rawValue: 7)
        var delivered = QueuedPrompt(
            blocks: [.text("first")], status: .sending, transcriptRecorded: true,
            dispatchedBrokerGeneration: generation)
        var unsent = QueuedPrompt(
            blocks: [.text("second")], status: .sending, dispatchedBrokerGeneration: generation)
        if origin == .earlierReconnect {
            delivered.markDeliveryUncertain()
            unsent.markDeliveryUncertain()
        }
        s.deliveredQueuedPromptIDs = [delivered.id]

        var dropped = s.restoreQueue([delivered, unsent], markLegacySendingUncertain: true)
        if origin == .brokerGenerationChange {
            dropped = s.markQueuedPromptsUncertain(afterBrokerGeneration: ACPBrokerGeneration(rawValue: 8))
        }

        #expect(dropped)
        #expect(s.queue.map(\.id) == [unsent.id])
        #expect(s.queue[0].deliveryUncertain)
    }

    enum RetainedUncertainPrompt: CaseIterable {
        /// Steering records the row first and persists the item as uncertain;
        /// the running turn's output after that row does not prove delivery.
        case unconfirmedSteeredFollowUp
        /// The turn produced partial output, then failed; Retry must survive.
        case failedAfterPartialOutput
    }

    @Test("an answered-looking uncertain prompt that may still need Retry survives restore",
          arguments: RetainedUncertainPrompt.allCases)
    func uncertainPromptNeedingRetrySurvives(_ kind: RetainedUncertainPrompt) {
        let s = mkSession()
        var item: QueuedPrompt
        switch kind {
        case .unconfirmedSteeredFollowUp:
            item = QueuedPrompt(blocks: [.text("also this")], status: .sending, transcriptRecorded: true)
            item.markDeliveryUncertain()
        case .failedAfterPartialOutput:
            item = QueuedPrompt(blocks: [.text("do it")], lastError: "connection reset",
                                transcriptRecorded: true,
                                dispatchedBrokerGeneration: ACPBrokerGeneration(rawValue: 7))
        }
        s.deliveredQueuedPromptIDs = [item.id]

        s.restoreQueue([item], markLegacySendingUncertain: true)
        s.markQueuedPromptsUncertain(afterBrokerGeneration: ACPBrokerGeneration(rawValue: 8))

        #expect(s.queue.map(\.id) == [item.id])
    }

    @Test("deliveredRecordedPromptIDs needs agent output after a once-dispatched recorded prompt",
          arguments: [(answered: true, attempt: 0, dispatches: 1, delivered: true),
                      (answered: false, attempt: 0, dispatches: 1, delivered: false),
                      // A resend reuses the row: earlier output proves only the
                      // first dispatch, whether or not the retry advanced the attempt.
                      (answered: true, attempt: 1, dispatches: 1, delivered: false),
                      (answered: true, attempt: 0, dispatches: 2, delivered: false)])
    func deliveredRecordedPromptIDs(answered: Bool, attempt: Int, dispatches: Int, delivered: Bool) {
        let item = QueuedPrompt(blocks: [.text("ship it")], transcriptRecorded: true,
                                brokerOperationAttempt: attempt, dispatchCount: dispatches)
        var transcript: [ACPMessageWire] = [
            .user(messageId: nil, text: "earlier", attachments: [], delegatedSource: nil),
            .agent(messageId: nil, text: "ok", phase: nil, metadata: nil),
            .user(messageId: nil, text: "ship it", attachments: [], delegatedSource: nil),
        ]
        if answered {
            transcript.append(.agent(messageId: nil, text: "shipping", phase: nil, metadata: nil))
        }

        let ids = QueuedPrompt.deliveredRecordedPromptIDs(in: [item], transcript: transcript)

        #expect(ids == (delivered ? [item.id] : []))
    }

    @Test("enqueue(blocks:draft:) stores the structured draft on the item")
    func enqueueWithDraft() {
        let s = mkSession()
        let draft = ACPComposerDraft(segments: [.text("hi")])
        s.enqueue(blocks: [.text("hi")], draft: draft)
        #expect(s.queue[0].draft == draft)
    }

    @Test("takeForEditing removes a pending item and returns its restorable draft")
    func takeForEditingPending() {
        let s = mkSession()
        let draft = ACPComposerDraft(segments: [.text("edit me")])
        s.enqueue(blocks: [.text("edit me")], draft: draft)
        let id = s.queue[0].id
        let restored = s.takeForEditing(id: id)
        #expect(restored == draft)
        #expect(s.queue.isEmpty)
    }

    @Test("takeForEditing refuses a .sending item and leaves the queue intact")
    func takeForEditingSendingNoop() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.markQueueHeadSending()
        let id = s.queue[0].id
        #expect(s.takeForEditing(id: id) == nil)
        #expect(s.queue.count == 1)
        #expect(s.queue[0].status == .sending)
    }

    @Test("takeForEditing returns nil for an unknown id")
    func takeForEditingUnknown() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        #expect(s.takeForEditing(id: UUID()) == nil)
        #expect(s.queue.count == 1)
    }

    @Test("takeForEditing is lossless where the blocks heuristic would misclaim a literal @name")
    func takeForEditingLossless() {
        let s = mkSession()
        // Draft: a literal "@here" the user typed, then a real chip for a file named "here".
        let draft = ACPComposerDraft(segments: [
            .text("ping @here and "),
            .mention(displayName: "here", uri: "file:///here")
        ])
        // The lossy wire form `extract`+`blocks` would produce for that draft.
        let blocks: [ACPContentBlock] = [
            .text("ping @here and @here "),
            .resourceLink(uri: "file:///here", name: "here")
        ]
        // Heuristic inverse misclaims the FIRST "@here " (the literal) — the bug.
        #expect(ACPComposerDraft(blocks: blocks) != draft)
        // With the stored draft, restore is exact — the fix.
        s.enqueue(blocks: blocks, draft: draft)
        #expect(s.takeForEditing(id: s.queue[0].id) == draft)
    }

    @Test("editQueueItem clears the stored draft so a later edit reflects the new blocks")
    func editQueueItemClearsDraft() {
        let s = mkSession()
        s.enqueue(blocks: [.text("old")],
                  draft: ACPComposerDraft(segments: [.text("old")]))
        let id = s.queue[0].id
        s.editQueueItem(id: id, blocks: [.text("new")])
        #expect(s.queue[0].draft == nil)
        // With the draft cleared, restorableDraft is the heuristic over the new
        // blocks. Assert the concrete expected segments (not the same
        // initializer) so this proves the structure rather than Equatable reflexivity.
        #expect(s.queue[0].restorableDraft == ACPComposerDraft(segments: [.text("new")]))
    }

    @Test("takeForEditing on a draft-less pending item returns the blocks heuristic")
    func takeForEditingFallsBackWhenNoDraft() {
        let s = mkSession()
        // Enqueued without a draft (legacy/recovery path): restore must fall
        // back to the heuristic inverse of the blocks.
        let blocks: [ACPContentBlock] = [.text("see @File.swift "),
                                         .resourceLink(uri: "file:///File.swift", name: "File.swift")]
        s.enqueue(blocks: blocks)
        let restored = s.takeForEditing(id: s.queue[0].id)
        #expect(restored == ACPComposerDraft(segments: [
            .text("see "),
            .mention(displayName: "File.swift", uri: "file:///File.swift"),
        ]))
        #expect(s.queue.isEmpty)
    }

    @Test("the usage-limit resume item sits at the pending head and is never duplicated")
    func upsertUsageLimitResume() {
        let session = mkSession()
        session.enqueue(blocks: [.text("later")])
        let limit = ACPUsageLimit(detectedAt: Date(), resetsAt: nil, resetSource: .unknown, probeAttempt: 0, resettable: true)
        let first = Date().addingTimeInterval(900)
        session.upsertUsageLimitResume(limit: limit, scheduledAt: first)
        var bumped = limit
        bumped.probeAttempt = 1
        session.upsertUsageLimitResume(limit: bumped, scheduledAt: first.addingTimeInterval(900))

        #expect(session.queue.count == 2)
        #expect(session.queue[0].usageLimit == bumped)
        #expect(session.queue[0].scheduledAt == first.addingTimeInterval(900))
        #expect(session.queue[0].blocks == [.text(ACPUsageLimitResumePolicy.continueText)])
        // A resume already in flight is left alone.
        session.queue[0].status = .sending
        session.upsertUsageLimitResume(limit: limit, scheduledAt: first)
        #expect(session.queue.count == 2)
        #expect(session.queue[0].usageLimit == bumped)
        session.queue[0].status = .pending
        #expect(session.removeUsageLimitResume())
        #expect(session.queue.map(\.blocks) == [[.text("later")]])
    }

    @Test("forcing an item the usage limit holds releases it; the rest stay held")
    func forceReleasesUsageLimitHold() throws {
        let session = mkSession()
        session.enqueue(blocks: [.text("a")])
        session.enqueue(blocks: [.text("b")])
        session.usageLimit = ACPUsageLimit(detectedAt: Date(), resetsAt: nil, resetSource: .unknown,
                                           probeAttempt: 0, resettable: true)
        let b = try #require(session.queue.last)
        #expect(b.isHeld(by: session.usageLimit))

        #expect(session.forceQueueItem(id: b.id))
        #expect(session.queue.map(\.blocks) == [[.text("b")], [.text("a")]])
        #expect(session.queue.map { $0.isHeld(by: session.usageLimit) } == [false, true])
    }

    @Test("restoring a queue with a resume item restores the Limited state")
    func restoreQueueRestoresUsageLimitFromResumeItem() throws {
        let limit = ACPUsageLimit(detectedAt: Date(), resetsAt: Date().addingTimeInterval(600),
                                  resetSource: .structured, probeAttempt: 0, resettable: true)
        let item = QueuedPrompt(blocks: [.text(ACPUsageLimitResumePolicy.continueText)],
                                scheduledAt: Date().addingTimeInterval(660), usageLimit: limit)
        let roundTripped = try JSONDecoder().decode(QueuedPrompt.self, from: JSONEncoder().encode(item))
        let session = mkSession()
        session.restoreQueue([roundTripped])
        #expect(session.usageLimit == limit)
    }

    @Test("a restored limit is never published ahead of its resume item")
    func restoreQueuePublishesResumeItemBeforeLimit() {
        let limit = ACPUsageLimit(detectedAt: Date(), resetsAt: nil, resetSource: .unknown,
                                  probeAttempt: 0, resettable: true)
        let item = QueuedPrompt(blocks: [.text(ACPUsageLimitResumePolicy.continueText)],
                                scheduledAt: Date().addingTimeInterval(900), usageLimit: limit)
        let session = mkSession()
        var resumeScheduledAtEachLimit: [Bool] = []
        // `@Published` emits in willSet, after the queue it reads was stored.
        let observation = session.$usageLimit.dropFirst().sink { published in
            guard published != nil else { return }
            resumeScheduledAtEachLimit.append(session.usageLimitResumeItem != nil)
        }
        defer { observation.cancel() }

        session.restoreQueue([item], markLegacySendingUncertain: true, persistedUsageLimit: limit)

        #expect(session.usageLimit == limit)
        #expect(!resumeScheduledAtEachLimit.isEmpty)
        #expect(!resumeScheduledAtEachLimit.contains(false))
    }
}
