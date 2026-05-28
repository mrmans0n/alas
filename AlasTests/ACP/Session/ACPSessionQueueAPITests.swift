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
}
