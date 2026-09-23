import Foundation
import Testing
@testable import Alas

@Suite @MainActor struct RemotePairingApprovalPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func pendingExplainsPermissionAndShowsCountdown() {
        let presentation = ApprovalPresentation(entry: entry(.pending), now: now)
        #expect(presentation.title.contains("Office Mac"))
        #expect(presentation.detail.contains("view and control each other's sessions"))
        #expect(presentation.detail.contains("supplied by the requester"))
        #expect(presentation.allowsDecision)
        #expect(presentation.remainingSeconds == 120)
    }

    @Test(arguments: [119.1, 119.999, 120.0, 121.0])
    func expiryDisablesDecisionsAtDeadline(elapsed: Double) {
        let presentation = ApprovalPresentation(entry: entry(.pending), now: now.addingTimeInterval(elapsed))
        #expect(presentation.allowsDecision == (elapsed < 120))
        #expect(presentation.remainingSeconds == (elapsed < 120 ? 1 : 0))
    }

    @Test(arguments: [ApprovalPhase.approved, .redeeming, .expired, .failed, .paired, .declined, .cancelled])
    func onlyPendingCanBeDecided(phase: ApprovalPhase) {
        let presentation = ApprovalPresentation(entry: entry(phase), now: now)
        #expect(!presentation.allowsDecision)
        if phase == .approved || phase == .redeeming {
            #expect(presentation.title.contains("Pairing with"))
            #expect(!presentation.title.contains("Paired with"))
        }
        if phase == .failed { #expect(presentation.detail.contains("new request")) }
        if phase == .expired { #expect(presentation.title.contains("expired")) }
        if phase == .paired { #expect(presentation.title.contains("Paired with")) }
    }

    @Test func sanitizesControlsWithoutChangingSignedPayload() throws {
        let original = entry(.pending, name: "Office\n\u{202E} Mac\u{0000}")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(original.payload)
        let presentation = ApprovalPresentation(entry: original, now: now)
        #expect(presentation.title == "\"Office Mac\" wants to pair")
        #expect(try encoder.encode(original.payload) == bytes)
        #expect(original.payload.requester.name == "Office\n\u{202E} Mac\u{0000}")
    }

    @Test func boundsLongUnicodeNamesWithoutBreakingCharacters() {
        let presentation = ApprovalPresentation(entry: entry(.pending, name: String(repeating: "👩🏽‍💻", count: 250)), now: now)
        #expect(presentation.title == "\"" + String(repeating: "👩🏽‍💻", count: 200) + "\" wants to pair")
    }

    private func entry(_ phase: ApprovalPhase, name: String = "Office Mac") -> RemotePairingApprovalCoordinator.Entry {
        let peer = ApprovalPeer(serverID: "requester", publicKey: "key", name: name, origins: ["http://192.168.1.2:8765"])
        let receiver = ApprovalPeer(serverID: "receiver", publicKey: "other", name: "This Mac", origins: [])
        let payload = ApprovalPayload(operation: .submit, requestID: "request", requester: peer, receiver: receiver,
            attemptNonce: "attempt", operationNonce: "operation", challenge: "challenge",
            expiresAtMilliseconds: 1_120_000, phase: phase, counterCode: nil, responseDigest: nil)
        return .init(id: "request", payload: payload, phase: phase)
    }
}
