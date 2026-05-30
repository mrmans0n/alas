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

    @Test("clearPendingQueue() removes all .pending items but leaves .sending head")
    func clearPendingKeepsSending() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        s.markQueueHeadSending()
        let snapshot = s.clearPendingQueue()
        #expect(s.queue.count == 1)
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

    @Test("restorePendingSnapshot keeps a .sending head at index 0")
    func restoreSnapshotPreservesSendingHead() {
        // Regression: undo-clicked-while-already-flushing scenario. The
        // restored items must NOT displace an in-flight .sending head; if
        // they did, the in-flight sendNow's popQueueHead would pop the
        // wrong item and the .sending item would be stuck in the queue.
        let s = mkSession()
        s.enqueue(blocks: [.text("in-flight")])
        s.markQueueHeadSending()
        s.restorePendingSnapshot([
            QueuedPrompt(blocks: [.text("restored-a")], status: .pending),
            QueuedPrompt(blocks: [.text("restored-b")], status: .pending),
        ])
        #expect(s.queue.count == 3)
        #expect(s.queue[0].status == .sending)
        #expect(s.queue[0].blocks == [.text("in-flight")])
        #expect(s.queue[1].blocks == [.text("restored-a")])
        #expect(s.queue[2].blocks == [.text("restored-b")])
    }

    @Test("restorePendingSnapshot inserts at the head when no .sending item exists")
    func restoreSnapshotPrependsWhenIdle() {
        let s = mkSession()
        s.enqueue(blocks: [.text("existing-pending")])
        s.restorePendingSnapshot([
            QueuedPrompt(blocks: [.text("restored")], status: .pending),
        ])
        #expect(s.queue.count == 2)
        #expect(s.queue[0].blocks == [.text("restored")])
        #expect(s.queue[1].blocks == [.text("existing-pending")])
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
}
