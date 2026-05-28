import Foundation
import Testing
@testable import Alas

@Suite("ACPSubmitRoute")
struct ACPSubmitRouteTests {
    @Test(".auto + idle + empty queue → sendNow")
    func idleEmptyAuto() {
        let r = ACPSubmitRoute.resolve(intent: .auto, state: .idle, queueEmpty: true, blocksEmpty: false)
        #expect(r == .sendNow)
    }

    @Test(".auto + idle + non-empty queue → enqueue (queue is authoritative once non-empty)")
    func idleNonEmptyAuto() {
        let r = ACPSubmitRoute.resolve(intent: .auto, state: .idle, queueEmpty: false, blocksEmpty: false)
        #expect(r == .enqueue)
    }

    @Test(".auto + streaming → enqueue")
    func streamingAuto() {
        let r = ACPSubmitRoute.resolve(intent: .auto, state: .streaming, queueEmpty: true, blocksEmpty: false)
        #expect(r == .enqueue)
    }

    @Test(".auto + sending → enqueue")
    func sendingAuto() {
        let r = ACPSubmitRoute.resolve(intent: .auto, state: .sending, queueEmpty: true, blocksEmpty: false)
        #expect(r == .enqueue)
    }

    @Test(".auto + awaitingPermission → enqueue")
    func awaitingPermAuto() {
        let r = ACPSubmitRoute.resolve(intent: .auto, state: .awaitingPermission, queueEmpty: true, blocksEmpty: false)
        #expect(r == .enqueue)
    }

    @Test(".steer + busy → steer")
    func steerWhileBusy() {
        let r = ACPSubmitRoute.resolve(intent: .steer, state: .streaming, queueEmpty: false, blocksEmpty: false)
        #expect(r == .steer)
    }

    @Test(".steer + idle + empty queue → sendNow (nothing to interrupt)")
    func steerIdleEmpty() {
        let r = ACPSubmitRoute.resolve(intent: .steer, state: .idle, queueEmpty: true, blocksEmpty: false)
        #expect(r == .sendNow)
    }

    @Test(".steer + idle + non-empty queue → steer (clears queue, sends now)")
    func steerIdleNonEmpty() {
        let r = ACPSubmitRoute.resolve(intent: .steer, state: .idle, queueEmpty: false, blocksEmpty: false)
        #expect(r == .steer)
    }

    @Test("empty blocks → noOp regardless of intent")
    func emptyBlocksNoOp() {
        #expect(ACPSubmitRoute.resolve(intent: .auto,  state: .idle,      queueEmpty: true,  blocksEmpty: true) == .noOp)
        #expect(ACPSubmitRoute.resolve(intent: .steer, state: .streaming, queueEmpty: false, blocksEmpty: true) == .noOp)
    }

    @Test("inFlightSteer forces enqueue even when state looks idle and queue is empty")
    func inFlightSteerForcesEnqueue() {
        // Regression: between userCancel finishing and the steer redirect's
        // sendNow installing itself, the session briefly looks idle+empty.
        // A user submit in that window must queue behind the redirect, not
        // race it with another sendNow.
        let auto = ACPSubmitRoute.resolve(
            intent: .auto, state: .idle, queueEmpty: true, blocksEmpty: false, inFlightSteer: true)
        #expect(auto == .enqueue)
        let steer = ACPSubmitRoute.resolve(
            intent: .steer, state: .idle, queueEmpty: true, blocksEmpty: false, inFlightSteer: true)
        #expect(steer == .enqueue)
    }

    @Test("inFlightSteer still respects noOp for empty composer")
    func inFlightSteerNoOp() {
        let r = ACPSubmitRoute.resolve(
            intent: .auto, state: .idle, queueEmpty: true, blocksEmpty: true, inFlightSteer: true)
        #expect(r == .noOp)
    }
}
