import CryptoKit
import Foundation
import Testing
@testable import Alas

@MainActor private final class CoordinatorSigner: ApprovalSigning {
    let key = Curve25519.Signing.PrivateKey()
    var rejectsSigning = false
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    func signApproval(_ payload: ApprovalPayload, reply: Bool) -> String? {
        guard !rejectsSigning else { return nil }
        return try? key.signature(for: ApprovalWire.bytes(payload, reply: reply)).base64EncodedString()
    }
}

@MainActor private final class ApprovalFixture {
    var time = Date(timeIntervalSince1970: 1_000)
    let receiverSigner = CoordinatorSigner()
    let requesterSigner = CoordinatorSigner()
    lazy var receiver = peer(receiverSigner, id: "receiver")
    lazy var requester = peer(requesterSigner, id: "requester")
    lazy var coordinator = RemotePairingApprovalCoordinator(
        localPeer: { self.receiver }, signer: receiverSigner, now: { self.time })

    func peer(_ signer: CoordinatorSigner, id: String) -> ApprovalPeer {
        ApprovalPeer(serverID: id, publicKey: signer.publicKey, name: id,
                     origins: ["http://192.168.1.2:8765"])
    }

    func challenge() throws -> ApprovalEnvelope {
        coordinator.setEnabled(true)
        return try coordinator.challenge(requester: requester, attemptNonce: String(repeating: "a", count: 64))
    }

    func request(_ reply: ApprovalEnvelope, operation: ApprovalOperation,
                 nonce: String = String(repeating: "b", count: 64),
                 requester: ApprovalPeer? = nil, signer: CoordinatorSigner? = nil,
                 counterCode: String? = nil) -> ApprovalEnvelope {
        let old = reply.payload
        let payload = ApprovalPayload(
            operation: operation, requestID: old.requestID, requester: requester ?? old.requester,
            receiver: old.receiver, attemptNonce: old.attemptNonce, operationNonce: nonce,
            challenge: old.challenge, expiresAtMilliseconds: old.expiresAtMilliseconds,
            phase: old.phase, counterCode: counterCode, responseDigest: nil)
        return ApprovalEnvelope(payload: payload,
                                signature: (signer ?? requesterSigner).signApproval(payload, reply: false)!)
    }

    func pending() throws -> ApprovalEnvelope {
        try coordinator.receive(request(challenge(), operation: .submit))
    }
}

@Suite @MainActor struct RemotePairingApprovalCoordinatorTests {
    @Test func nearExpiryRedemptionCanRecoverLostReplyAndCancelAfterReciprocalSuccess() throws {
        let f = ApprovalFixture()
        let pending = try f.pending()
        f.coordinator.decide(.allow, requestID: pending.payload.requestID)
        f.time.addTimeInterval(119)
        let approved = try f.coordinator.receive(f.request(pending, operation: .status))
        let request = f.request(approved, operation: .redeem, counterCode: "counter")
        let body = Data("pair credentials".utf8)
        let bytes = try f.coordinator.redeem(request) {
            ApprovalIssuedResponse(body: try f.coordinator.pairReply(body: body, for: request), deviceID: "device")
        }
        f.coordinator.complete(requestID: request.payload.requestID, succeeded: true)
        f.time.addTimeInterval(10)
        let recovered = try f.coordinator.redeem(request) {
            Issue.record("An exact retry must not issue twice")
            return ApprovalIssuedResponse(body: Data(), deviceID: "wrong")
        }
        #expect(recovered == bytes)
        let reply = try JSONDecoder().decode(ApprovalPairReply.self, from: recovered)
        #expect(reply.pairBody == body)
        #expect(ApprovalWire.verify(reply.proof, expectedKey: f.receiver.publicKey, reply: true))
        _ = try f.coordinator.receive(f.request(reply.proof, operation: .status))
        var cancelled = false
        f.coordinator.onCancelRedeeming = { _ in cancelled = true }
        let cancelReply = try f.coordinator.receive(f.request(reply.proof, operation: .cancel))
        #expect(cancelReply.payload.phase == .cancelled)
        #expect(cancelled)
        #expect(throws: ApprovalFailure.self) {
            try f.coordinator.redeem(request) { ApprovalIssuedResponse(body: Data(), deviceID: "wrong") }
        }
    }

    @Test func completedPairingRetrySurvivesShutdownUntilRedeemDeadline() throws {
        let f = ApprovalFixture()
        let pending = try f.pending()
        f.coordinator.decide(.allow, requestID: pending.payload.requestID)
        let approved = try f.coordinator.receive(f.request(pending, operation: .status))
        let request = f.request(approved, operation: .redeem, counterCode: "counter")
        let bytes = try f.coordinator.redeem(request) {
            ApprovalIssuedResponse(body: Data("pair credentials".utf8), deviceID: "device")
        }
        f.coordinator.complete(requestID: request.payload.requestID, succeeded: true)
        f.coordinator.setEnabled(false)
        #expect(f.coordinator.entries.first?.phase == .paired)
        let recovered = try f.coordinator.redeem(request) {
            Issue.record("A completed exact retry must not issue twice")
            return ApprovalIssuedResponse(body: Data(), deviceID: "wrong")
        }
        #expect(recovered == bytes)
        f.time.addTimeInterval(120)
        f.coordinator.expire()
        #expect(throws: ApprovalFailure.disabled) {
            try f.coordinator.redeem(request) {
                Issue.record("Expired retry cache issued credentials")
                return ApprovalIssuedResponse(body: Data(), deviceID: "wrong")
            }
        }
    }

    @Test(arguments: [ApprovalPhase.pending, .declined, .expired, .cancelled])
    func unauthorizedPhasesNeverIssue(phase: ApprovalPhase) throws {
        let f = ApprovalFixture()
        let pending = try f.pending()
        if phase == .declined { f.coordinator.decide(.decline, requestID: pending.payload.requestID) }
        if phase == .expired { f.time.addTimeInterval(121) }
        if phase == .cancelled { f.coordinator.cancelAll() }
        let request = f.request(pending, operation: .redeem, counterCode: "counter")
        #expect(throws: ApprovalFailure.self) {
            try f.coordinator.redeem(request) {
                Issue.record("Unauthorized redemption issued credentials")
                return ApprovalIssuedResponse(body: Data(), deviceID: "device")
            }
        }
    }

    @Test func expiredApprovalRedemptionReportsExpiry() throws {
        let f = ApprovalFixture()
        let pending = try f.pending()
        f.coordinator.decide(.allow, requestID: pending.payload.requestID)
        let approved = try f.coordinator.receive(f.request(pending, operation: .status))
        f.time.addTimeInterval(121)
        let request = f.request(approved, operation: .redeem, counterCode: "counter")
        #expect(throws: ApprovalFailure.expired) {
            try f.coordinator.redeem(request) {
                Issue.record("Expired redemption issued credentials")
                return ApprovalIssuedResponse(body: Data(), deviceID: "device")
            }
        }
    }

    @Test func redeemRejectsChangedMetadataAndWrongKey() throws {
        let f = ApprovalFixture()
        let pending = try f.pending()
        f.coordinator.decide(.allow, requestID: pending.payload.requestID)
        let approved = try f.coordinator.receive(f.request(pending, operation: .status))
        let altered = ApprovalPeer(serverID: f.requester.serverID, publicKey: f.requester.publicKey,
                                   name: f.requester.name, origins: ["http://192.168.1.9:8765"])
        for request in [f.request(approved, operation: .redeem, signer: CoordinatorSigner(), counterCode: "code"),
                        f.request(approved, operation: .redeem, requester: altered, counterCode: "code")] {
            #expect(throws: ApprovalFailure.unauthorized) {
                try f.coordinator.redeem(request) { ApprovalIssuedResponse(body: Data(), deviceID: "device") }
            }
        }
    }

    @Test func redemptionIssuesOnceAndCancellationInvalidatesRetry() throws {
        let f = ApprovalFixture()
        let pending = try f.pending()
        f.coordinator.decide(.allow, requestID: pending.payload.requestID)
        let approved = try f.coordinator.receive(f.request(pending, operation: .status))
        let p = approved.payload
        let payload = ApprovalPayload(operation: .redeem, requestID: p.requestID, requester: p.requester,
            receiver: p.receiver, attemptNonce: p.attemptNonce, operationNonce: String(repeating: "c", count: 64),
            challenge: p.challenge, expiresAtMilliseconds: p.expiresAtMilliseconds,
            phase: p.phase, counterCode: "COUNTER", responseDigest: nil)
        let request = ApprovalEnvelope(payload: payload, signature: f.requesterSigner.signApproval(payload, reply: false)!)
        var issued = 0
        let issue = { issued += 1
        return ApprovalIssuedResponse(body: Data("reply".utf8), deviceID: "device") }
        #expect(try f.coordinator.redeem(request, issue: issue) == Data("reply".utf8))
        #expect(try f.coordinator.redeem(request, issue: issue) == Data("reply".utf8))
        #expect(issued == 1)
        #expect(f.coordinator.entries.first?.phase == .redeeming)
        var cancelled: String?
        f.coordinator.onCancelRedeeming = { cancelled = $0 }
        f.coordinator.cancelAll()
        #expect(cancelled == p.requestID)
        #expect(throws: ApprovalFailure.self) { try f.coordinator.redeem(request, issue: issue) }
        #expect(issued == 1)
    }

    @Test(arguments: [119.999, 120.0, 300.0])
    func allowChecksSubmissionDeadline(elapsed: Double) throws {
        let fixture = ApprovalFixture()
        let pending = try fixture.pending()
        fixture.time.addTimeInterval(elapsed)
        fixture.coordinator.decide(.allow, requestID: pending.payload.requestID)
        #expect(fixture.coordinator.entries.first?.phase == (elapsed < 120 ? .approved : .expired))
        #expect(fixture.coordinator.entries.first?.payload.expiresAtMilliseconds == 1_120_000)
    }

    @Test func disabledCoordinatorRejectsChallenges() {
        let fixture = ApprovalFixture()
        fixture.coordinator.setEnabled(false)
        #expect(throws: ApprovalFailure.disabled) {
            try fixture.coordinator.challenge(requester: fixture.requester, attemptNonce: String(repeating: "a", count: 64))
        }
        #expect(fixture.coordinator.entries.isEmpty)
    }

    @Test func exactSubmissionRetryReusesReplyAndDeadline() throws {
        let f = ApprovalFixture()
        let challenge = try f.challenge()
        let submit = f.request(challenge, operation: .submit)
        let reply = try f.coordinator.receive(submit)
        f.time.addTimeInterval(10)
        #expect(try f.coordinator.receive(submit) == reply)
        #expect(f.coordinator.entries.count == 1)
        #expect(reply.payload.challenge != challenge.payload.challenge)
        #expect(ApprovalWire.verify(reply, expectedKey: f.receiver.publicKey, reply: true))
        #expect(reply.payload.counterCode == nil)
        #expect(reply.payload.responseDigest == nil)
    }

    @Test func decisionsAreFinalAndDoNotExtendDeadline() throws {
        for decision in [ApprovalDecision.allow, .decline] {
            let f = ApprovalFixture()
            let pending = try f.pending()
            f.coordinator.decide(decision, requestID: pending.payload.requestID)
            f.coordinator.decide(.allow, requestID: pending.payload.requestID)
            f.coordinator.decide(.decline, requestID: pending.payload.requestID)
            #expect(f.coordinator.entries.first?.phase == (decision == .allow ? .approved : .declined))
            #expect(f.coordinator.entries.first?.payload.expiresAtMilliseconds == 1_120_000)
        }
    }

    @Test func signedIdentityMutationAndWrongKeyAreRejected() throws {
        let f = ApprovalFixture()
        let challenge = try f.challenge()
        let mutated = ApprovalPeer(serverID: f.requester.serverID, publicKey: f.requester.publicKey,
                                   name: "Changed", origins: f.requester.origins)
        #expect(throws: ApprovalFailure.unauthorized) {
            try f.coordinator.receive(f.request(challenge, operation: .submit, requester: mutated))
        }
        #expect(throws: ApprovalFailure.unauthorized) {
            try f.coordinator.receive(f.request(challenge, operation: .submit, signer: CoordinatorSigner()))
        }
        #expect(f.coordinator.entries.first?.phase == .challenged)
    }

    @Test func consumedChallengeCannotAuthorizeAnotherOperation() throws {
        let f = ApprovalFixture()
        let challenge = try f.challenge()
        _ = try f.coordinator.receive(f.request(challenge, operation: .submit))
        #expect(throws: ApprovalFailure.conflict) {
            try f.coordinator.receive(f.request(challenge, operation: .cancel))
        }
        #expect(f.coordinator.entries.first?.phase == .pending)
    }

    @Test func statusThrottlesWithoutConsumingChallenge() throws {
        let f = ApprovalFixture()
        let pending = try f.pending()
        let first = try f.coordinator.receive(f.request(pending, operation: .status))
        let secondRequest = f.request(first, operation: .status, nonce: String(repeating: "c", count: 64))
        #expect(throws: ApprovalFailure.throttled) { try f.coordinator.receive(secondRequest) }
        #expect(ApprovalFailure.throttled.retryAfterSeconds == 2)
        f.time.addTimeInterval(1)
        let second = try f.coordinator.receive(secondRequest)
        #expect(second.payload.challenge != first.payload.challenge)
        #expect(throws: ApprovalFailure.conflict) {
            try f.coordinator.receive(f.request(pending, operation: .status))
        }
    }

    @Test func shutdownInvalidatesApprovalAndCachedReply() throws {
        let f = ApprovalFixture()
        let pending = try f.pending()
        f.coordinator.decide(.allow, requestID: pending.payload.requestID)
        let status = f.request(pending, operation: .status)
        #expect(try f.coordinator.receive(status).payload.phase == .approved)
        f.coordinator.setEnabled(false)
        #expect(f.coordinator.entries.first?.phase == .cancelled)
        #expect(throws: ApprovalFailure.disabled) { try f.coordinator.receive(status) }
        f.coordinator.setEnabled(true)
        #expect(try f.coordinator.receive(status).payload.phase == .cancelled)
    }

    @Test func retriesReflectLocalDeclineAndExpiry() throws {
        for decline in [true, false] {
            let f = ApprovalFixture()
            let challenge = try f.challenge()
            let submit = f.request(challenge, operation: .submit)
            _ = try f.coordinator.receive(submit)
            if decline {
                f.coordinator.decide(.decline, requestID: challenge.payload.requestID)
            } else {
                f.time.addTimeInterval(120)
            }
            #expect(try f.coordinator.receive(submit).payload.phase == (decline ? .declined : .expired))
        }
    }

    @Test func keyRotationCannotBypassGlobalAdmission() throws {
        let f = ApprovalFixture()
        f.coordinator.setEnabled(true)
        for index in 0..<10 {
            let peer = f.peer(CoordinatorSigner(), id: "peer-\(index)")
            _ = try f.coordinator.challenge(requester: peer, attemptNonce: String(repeating: "a", count: 64))
        }
        #expect(throws: ApprovalFailure.throttled) {
            try f.coordinator.challenge(requester: f.requester, attemptNonce: String(repeating: "a", count: 64))
        }
        f.time.addTimeInterval(60)
        #expect(try f.challenge().payload.phase == .challenged)
    }

    @Test func onlyThreePendingPromptsAndOnePerKey() throws {
        let f = ApprovalFixture()
        _ = try f.pending()
        #expect(throws: ApprovalFailure.conflict) {
            try f.coordinator.challenge(requester: f.requester, attemptNonce: String(repeating: "d", count: 64))
        }
        for index in 0..<3 {
            let signer = CoordinatorSigner()
            let challenge = try f.coordinator.challenge(requester: f.peer(signer, id: "other-\(index)"),
                                                      attemptNonce: String(repeating: "a", count: 64))
            let submit = f.request(challenge, operation: .submit, signer: signer)
            if index < 2 {
                _ = try f.coordinator.receive(submit)
            } else {
                #expect(throws: ApprovalFailure.capacity) { try f.coordinator.receive(submit) }
                f.time.addTimeInterval(120)
                f.coordinator.expire()
                #expect(f.coordinator.entries.allSatisfy { $0.phase == .expired })
            }
        }
    }

    @Test func declineCooldownAndPerKeySubmissionLimit() throws {
        let f = ApprovalFixture()
        let pending = try f.pending()
        f.coordinator.decide(.decline, requestID: pending.payload.requestID)
        #expect(throws: ApprovalFailure.throttled) { try f.challenge() }
        f.time.addTimeInterval(60)
        for _ in 0..<5 {
            let next = try f.pending()
            _ = try f.coordinator.receive(f.request(next, operation: .cancel))
        }
        let challenge = try f.challenge()
        #expect(throws: ApprovalFailure.throttled) {
            try f.coordinator.receive(f.request(challenge, operation: .submit))
        }
    }

    @Test func challengeDeadlineAndTerminalRetention() throws {
        let f = ApprovalFixture()
        var released: [String] = []
        f.coordinator.onReleaseAttempt = { released.append($0) }
        let challenge = try f.challenge()
        f.time.addTimeInterval(30)
        #expect(throws: ApprovalFailure.expired) {
            try f.coordinator.receive(f.request(challenge, operation: .submit))
        }
        #expect(f.coordinator.entries.first?.phase == .expired)
        f.time.addTimeInterval(120)
        f.coordinator.expire()
        #expect(f.coordinator.entries.isEmpty)
        #expect(released == [challenge.payload.requestID])
    }

    @Test func submissionLimitSpansAdmissionWindowBoundary() throws {
        let f = ApprovalFixture()
        f.coordinator.setEnabled(true)
        var challenges: [(CoordinatorSigner, ApprovalEnvelope)] = []
        for index in 0..<10 {
            let signer = CoordinatorSigner()
            let challenge = try f.coordinator.challenge(requester: f.peer(signer, id: "peer-\(index)"),
                                                      attemptNonce: String(repeating: "a", count: 64))
            challenges.append((signer, challenge))
        }
        f.time.addTimeInterval(20)
        for (signer, challenge) in challenges {
            let pending = try f.coordinator.receive(f.request(challenge, operation: .submit, signer: signer))
            _ = try f.coordinator.receive(f.request(pending, operation: .cancel, signer: signer))
        }
        f.time.addTimeInterval(40)
        let next = try f.challenge()
        #expect(throws: ApprovalFailure.throttled) {
            try f.coordinator.receive(f.request(next, operation: .submit))
        }
        f.time.addTimeInterval(20)
        #expect(try f.coordinator.receive(f.request(next, operation: .submit)).payload.phase == .pending)
    }

    @Test func expiryFreesPromptCapacityBeforeAdmission() throws {
        let f = ApprovalFixture()
        f.coordinator.setEnabled(true)
        for index in 0..<3 {
            let signer = CoordinatorSigner()
            let challenge = try f.coordinator.challenge(requester: f.peer(signer, id: "peer-\(index)"),
                                                      attemptNonce: String(repeating: "a", count: 64))
            _ = try f.coordinator.receive(f.request(challenge, operation: .submit, signer: signer))
        }
        f.time.addTimeInterval(120)
        #expect(try f.pending().payload.phase == .pending)
        #expect(f.coordinator.entries.filter { $0.phase == .pending }.count == 1)
    }

    @Test func signingFailureLeavesSubmissionRetryable() throws {
        let f = ApprovalFixture()
        let challenge = try f.challenge()
        let submit = f.request(challenge, operation: .submit)
        f.receiverSigner.rejectsSigning = true
        #expect(throws: ApprovalFailure.unauthorized) { try f.coordinator.receive(submit) }
        #expect(f.coordinator.entries.first?.phase == .challenged)
        f.receiverSigner.rejectsSigning = false
        #expect(try f.coordinator.receive(submit).payload.phase == .pending)
    }

    @Test func cancellationInvalidatesPendingAndApprovedRequests() throws {
        for allow in [true, false] {
            let f = ApprovalFixture()
            let pending = try f.pending()
            if allow { f.coordinator.decide(.allow, requestID: pending.payload.requestID) }
            let cancelled = try f.coordinator.receive(f.request(pending, operation: .cancel))
            #expect(cancelled.payload.phase == .cancelled)
            f.coordinator.decide(.allow, requestID: pending.payload.requestID)
            #expect(f.coordinator.entries.first?.phase == .cancelled)
            #expect(cancelled.payload.counterCode == nil)
            #expect(cancelled.payload.responseDigest == nil)
        }
    }

    @Test func duplicateCurrentChallengeSubmissionDoesNotSpendQuota() throws {
        let f = ApprovalFixture()
        var pending = try f.pending()
        for _ in 0..<10 {
            pending = try f.coordinator.receive(f.request(pending, operation: .submit))
            #expect(pending.payload.phase == .pending)
            #expect(pending.payload.expiresAtMilliseconds == 1_120_000)
        }
        #expect(f.coordinator.entries.count == 1)
    }

    @Test func invalidChallengeDoesNotSpendAdmissionQuota() throws {
        let f = ApprovalFixture()
        f.coordinator.setEnabled(true)
        for _ in 0..<20 {
            #expect(throws: ApprovalFailure.invalid) {
                try f.coordinator.challenge(requester: f.requester, attemptNonce: "bad")
            }
        }
        #expect(try f.challenge().payload.phase == .challenged)
    }
}
