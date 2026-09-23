import CryptoKit
import Foundation
import Testing
@testable import Alas

@MainActor
struct RemotePairingApprovalClientTests {
    @MainActor final class Signer: ApprovalSigning {
        let key = Curve25519.Signing.PrivateKey()
        var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
        func signApproval(_ payload: ApprovalPayload, reply: Bool) -> String? {
            try? key.signature(for: ApprovalWire.bytes(payload, reply: reply)).base64EncodedString()
        }
    }

    @MainActor final class Exchange {
        let requesterSigner = Signer()
        let receiverSigner = Signer()
        var time = Date(timeIntervalSince1970: 10_000)
        var receiverOffset: TimeInterval = 0
        var replyDelay: TimeInterval = 0
        var statusCode: Int?
        var errorMessage: String?
        var redeemStatusCode: Int?
        var decision: ApprovalDecision? = .allow
        var failFirstOrigin = false
        var lostReply: ApprovalOperation?
        var cancelOnLoss = false
        var tamper = false
        var oversized = false
        var receiverID = "receiver"
        var afterReply: ((ApprovalOperation) async throws -> Void)?
        var replayStatus = false
        var previousStatus: ApprovalEnvelope?
        var calls: [URLRequest] = []
        var issues = 0
        var sleeps = 0
        var sleepAction: (() throws -> Void)?
        var requester: ApprovalPeer {
            ApprovalPeer(serverID: "requester", publicKey: requesterSigner.publicKey,
                         name: "Requester", origins: ["http://requester:8765"])
        }
        var receiver: ApprovalPeer {
            ApprovalPeer(serverID: receiverID, publicKey: receiverSigner.publicKey,
                         name: "Receiver", origins: ["http://receiver:8765"])
        }
        lazy var coordinator: RemotePairingApprovalCoordinator = {
            let value = RemotePairingApprovalCoordinator(localPeer: { self.receiver },
                signer: receiverSigner, now: { self.time + self.receiverOffset })
            value.setEnabled(true)
            return value
        }()
        var target: RemoteDiscoveredInstanceResolver.ResolvedPeer {
            .init(origins: ["http://offline:8765", "http://receiver:8765"],
                  serverID: "receiver", pairingApprovalVersion: 1)
        }
        func client() -> RemotePairingApprovalClient {
            RemotePairingApprovalClient(fetch: { try await self.fetch($0) }, signer: requesterSigner,
                now: { self.time }, sleep: { _ in
                    self.sleeps += 1
                    self.time += 2
                    try self.sleepAction?()
                    if let decision = self.decision, let entry = self.coordinator.entries.first {
                        self.coordinator.decide(decision, requestID: entry.id)
                    }
                })
        }
        func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            calls.append(request)
            #expect(request.timeoutInterval == 4)
            #expect(request.value(forHTTPHeaderField: "Origin") == nil)
            #expect((request.httpBody?.count ?? 0) <= 16 * 1024)
            if let statusCode {
                let body = errorMessage.map { Data("{\"error\":\"\($0)\"}".utf8) } ?? Data()
                return (body, HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
            }
            if let redeemStatusCode, request.url?.path == "/pair" {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: redeemStatusCode, httpVersion: nil, headerFields: nil)!)
            }
            if failFirstOrigin && request.url?.host == "offline" { throw URLError(.cannotConnectToHost) }
            let data = try #require(request.httpBody)
            let operation: ApprovalOperation
            var reply: Data
            if request.url?.path == "/peer-approval/v1/challenge" {
                let challenge = try JSONDecoder().decode(RemotePairingApprovalHTTP.ChallengeRequest.self, from: data)
                operation = .challenge
                reply = try JSONEncoder().encode(coordinator.challenge(requester: challenge.requester,
                    attemptNonce: challenge.attemptNonce))
            } else if request.url?.path == "/pair" {
                struct Body: Decodable { let approval: ApprovalEnvelope }
                let envelope = try JSONDecoder().decode(Body.self, from: data).approval
                operation = .redeem
                reply = try coordinator.redeem(envelope) {
                    self.issues += 1
                    let body = try JSONSerialization.data(withJSONObject: ["token": "secret-token",
                        "serverId": "receiver", "name": "Receiver", "publicKey": self.receiver.publicKey])
                    return ApprovalIssuedResponse(body: try self.coordinator.pairReply(body: body, for: envelope),
                                                  deviceID: "issued-device")
                }
            } else {
                let envelope = try JSONDecoder().decode(ApprovalEnvelope.self, from: data)
                operation = envelope.payload.operation
                let response = try coordinator.receive(envelope)
                if operation == .status, replayStatus, let previousStatus {
                    reply = try JSONEncoder().encode(previousStatus)
                } else {
                    reply = try JSONEncoder().encode(response)
                }
                if operation == .status { previousStatus = response }
            }
            if operation == .submit { time += replyDelay }
            if lostReply == operation {
                lostReply = nil
                if cancelOnLoss { throw CancellationError() }
                throw URLError(.networkConnectionLost)
            }
            try await afterReply?(operation)
            if tamper {
                var object = try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
                object["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
                reply = try JSONSerialization.data(withJSONObject: object)
            }
            if oversized { reply = Data(repeating: 32, count: 16 * 1024 + 1) }
            return (reply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test(arguments: [-3_600.0, 3_600.0])
    func receiverClockSkewDoesNotPreventApprovalOrRedemption(offset: TimeInterval) async {
        let exchange = Exchange()
        exchange.receiverOffset = offset
        let client = exchange.client()
        let result = await client.request(localPeer: exchange.requester, target: exchange.target, expectedServerID: "receiver")
        guard case .approved(let session) = result else { Issue.record("Expected approval despite clock skew")
        return }
        #expect(session.payload.expiresAtMilliseconds == Int64((10_120 + offset) * 1_000))
        #expect(session.localDeadline == Date(timeIntervalSince1970: 10_120))
        let outcome = await client.redeem(session: session, advertisement: .init(serverId: "requester", name: "Requester",
            origins: exchange.requester.origins, counterCode: "counter", publicKey: exchange.requester.publicKey))
        #expect(outcome == .paired(token: "secret-token", serverId: "receiver", name: "Receiver",
            publicKey: exchange.receiver.publicKey, origin: session.origin))
    }

    @Test(arguments: [-3_600.0, 3_600.0], [false, true])
    func delayedSubmitRepliesAndRetriesKeepOriginalLocalDeadline(offset: TimeInterval, retry: Bool) async {
        let exchange = Exchange()
        exchange.receiverOffset = offset
        exchange.replyDelay = 10
        exchange.lostReply = retry ? .submit : nil
        exchange.decision = nil
        let client = exchange.client()
        let result = await client.request(localPeer: exchange.requester, target: exchange.target, expectedServerID: "receiver")
        #expect(result == .expired)
        #expect(client.session?.localDeadline == Date(timeIntervalSince1970: 10_120))
        #expect(exchange.time == Date(timeIntervalSince1970: 10_120))
        let submits = exchange.calls.filter { $0.url?.lastPathComponent == "submit" }
        #expect(submits.count == (retry ? 2 : 1))
        if retry { #expect(submits.first?.httpBody == submits.last?.httpBody) }
    }

    @Test(arguments: [-3_600.0, 3_600.0], [117.0, 119.0])
    func allowNearExpiryKeepsReceiverDeadline(offset: TimeInterval, elapsed: TimeInterval) async {
        let exchange = Exchange()
        exchange.receiverOffset = offset
        exchange.afterReply = { operation in
            if operation == .submit {
                exchange.time += elapsed
                if let entry = exchange.coordinator.entries.first { exchange.coordinator.decide(.allow, requestID: entry.id) }
            }
        }
        let client = exchange.client()
        let result = await client.request(localPeer: exchange.requester, target: exchange.target, expectedServerID: "receiver")
        if elapsed == 119 { #expect(result == .expired)
        return }
        guard case .approved(let session) = result else { Issue.record("Expected approval before deadline")
        return }
        // The receiver advances independently before redemption and refuses the stale authorization.
        exchange.receiverOffset += 2
        let outcome = await client.redeem(session: session, advertisement: .init(serverId: "requester", name: "Requester",
            origins: exchange.requester.origins, counterCode: "counter", publicKey: exchange.requester.publicKey))
        #expect(outcome == .identityUnproven)
        #expect(exchange.issues == 0)
    }

    @Test func httpGoneMapsToExpiredResult() async {
        let exchange = Exchange()
        exchange.statusCode = 410
        #expect(await exchange.client().request(localPeer: exchange.requester, target: exchange.target,
            expectedServerID: "receiver") == .expired)
    }

    @Test func httpCapacityConflictMapsToCapacityResult() async {
        let exchange = Exchange()
        exchange.statusCode = 409
        exchange.errorMessage = "request capacity reached"
        #expect(await exchange.client().request(localPeer: exchange.requester, target: exchange.target,
            expectedServerID: "receiver") == .failed(.capacity))
    }

    @Test func genericHttpConflictRemainsConflict() async {
        let exchange = Exchange()
        exchange.statusCode = 409
        #expect(await exchange.client().request(localPeer: exchange.requester, target: exchange.target,
            expectedServerID: "receiver") == .failed(.conflict))
    }

    @Test(arguments: [(410, RemotePeerPairer.Outcome.approvalExpired),
                      (403, .approvalDisabled)])
    func redemptionPreservesApprovalFailure(statusCode: Int, expected: RemotePeerPairer.Outcome) async {
        let exchange = Exchange()
        let client = exchange.client()
        guard case .approved(let session) = await client.request(localPeer: exchange.requester, target: exchange.target,
                                                                  expectedServerID: "receiver") else {
            Issue.record("Expected approval")
            return
        }
        exchange.redeemStatusCode = statusCode
        let outcome = await client.redeem(session: session, advertisement: .init(serverId: "requester", name: "Requester",
            origins: exchange.requester.origins, counterCode: "counter", publicKey: exchange.requester.publicKey))
        #expect(outcome == expected)
    }

    @Test func pendingApprovalPinsIdentityAndRedeemsOnlyAfterAllow() async throws {
        let exchange = Exchange()
        exchange.failFirstOrigin = true
        let client = exchange.client()
        let result = await client.request(localPeer: exchange.requester, target: exchange.target, expectedServerID: "receiver")
        guard case .approved(let session) = result else { Issue.record("Expected approval")
        return }
        #expect(session.receiverKey == exchange.receiver.publicKey)
        #expect(session.origin == "http://receiver:8765")
        #expect(exchange.issues == 0)
        #expect(exchange.sleeps >= 1)
        let ad = RemotePeerAdvertisement(serverId: "requester", name: "Requester",
            origins: exchange.requester.origins, counterCode: "counter-secret", publicKey: exchange.requester.publicKey)
        let outcome = await client.redeem(session: session, advertisement: ad)
        #expect(outcome == .paired(token: "secret-token", serverId: "receiver", name: "Receiver",
                                  publicKey: exchange.receiver.publicKey, origin: session.origin))
        #expect(exchange.issues == 1)
        #expect(!String(describing: session).contains("counter-secret"))
    }

    @Test(arguments: [ApprovalDecision.decline, .allow])
    func decisionsAndExpiry(decision: ApprovalDecision) async {
        let exchange = Exchange()
        exchange.decision = decision
        if decision == .allow { exchange.sleepAction = { exchange.time += 120 } }
        let result = await exchange.client().request(localPeer: exchange.requester, target: exchange.target, expectedServerID: "receiver")
        if decision == .decline { #expect(result == .declined) } else { #expect(result == .expired) }
        #expect(exchange.issues == 0)
    }

    @Test func invalidAndOldTargetsNeverSubmit() async {
        let exchange = Exchange()
        let client = exchange.client()
        #expect(await client.request(localPeer: exchange.requester, target: exchange.target,
                                     expectedServerID: "wrong") == .failed(.unauthorized))
        let old = RemoteDiscoveredInstanceResolver.ResolvedPeer(origins: exchange.target.origins,
            serverID: "receiver", pairingApprovalVersion: nil)
        #expect(await client.request(localPeer: exchange.requester, target: old,
                                     expectedServerID: "receiver") == .failed(.disabled))
        #expect(exchange.calls.isEmpty)
    }

    @Test func tamperedReplyCannotEstablishSession() async {
        let exchange = Exchange()
        exchange.tamper = true
        #expect(await exchange.client().request(localPeer: exchange.requester, target: exchange.target,
                                               expectedServerID: "receiver") == .failed(.unauthorized))
        #expect(exchange.coordinator.entries.allSatisfy { $0.phase == .challenged })
    }

    @Test func repeatedStatusNonceIsRejected() async {
        let exchange = Exchange()
        exchange.decision = nil
        exchange.replayStatus = true
        #expect(await exchange.client().request(localPeer: exchange.requester, target: exchange.target,
                                               expectedServerID: "receiver") == .failed(.unauthorized))
        #expect(exchange.issues == 0)
    }

    @Test(arguments: [ApprovalOperation.submit, .status])
    func lostRepliesRetryExactEnvelopeWithoutDuplicatePrompt(operation: ApprovalOperation) async {
        let exchange = Exchange()
        exchange.lostReply = operation
        let result = await exchange.client().request(localPeer: exchange.requester, target: exchange.target, expectedServerID: "receiver")
        guard case .approved = result else { Issue.record("Expected recovered approval")
        return }
        let calls = exchange.calls.filter { $0.url?.lastPathComponent == operation.rawValue }
        #expect(calls.count >= 2)
        #expect(calls[0].httpBody == calls[1].httpBody)
        #expect(exchange.coordinator.entries.count == 1)
    }

    @Test(arguments: [ApprovalOperation.submit, .status, .redeem])
    func cancellationRecoversLostReplyThenCancelsCurrentChallenge(operation: ApprovalOperation) async throws {
        let exchange = Exchange()
        let client = exchange.client()
        if operation != .redeem { exchange.lostReply = operation
        exchange.cancelOnLoss = true }
        let result = await client.request(localPeer: exchange.requester, target: exchange.target, expectedServerID: "receiver")
        if operation == .redeem {
            guard case .approved(let session) = result else { Issue.record("Expected approval")
            return }
            exchange.lostReply = .redeem
            exchange.cancelOnLoss = true
            _ = await client.redeem(session: session, advertisement: .init(serverId: "requester", name: "Requester",
                origins: exchange.requester.origins, counterCode: "counter", publicKey: exchange.requester.publicKey))
            #expect(exchange.issues == 1)
        } else { #expect(result == .cancelled) }
        #expect(exchange.coordinator.entries.first?.phase == .cancelled)
        let operations = exchange.calls.filter { $0.url?.lastPathComponent == operation.rawValue || (operation == .redeem && $0.url?.path == "/pair") }
        #expect(operations.count == 2)
        #expect(operations[0].httpBody == operations[1].httpBody)
    }

    @Test func cancellationDuringSleepCancelsPendingRequest() async {
        let exchange = Exchange()
        exchange.sleepAction = { throw CancellationError() }
        #expect(await exchange.client().request(localPeer: exchange.requester, target: exchange.target,
                                               expectedServerID: "receiver") == .cancelled)
        #expect(exchange.coordinator.entries.first?.phase == .cancelled)
    }

    @Test func signedChallengeForAnotherServerCannotSubmit() async {
        let exchange = Exchange()
        exchange.receiverID = "wrong"
        #expect(await exchange.client().request(localPeer: exchange.requester, target: exchange.target,
                                               expectedServerID: "receiver") == .failed(.unauthorized))
        #expect(exchange.coordinator.entries.allSatisfy { $0.phase == .challenged })
    }

    @Test func oversizedReplyCannotSubmit() async {
        let exchange = Exchange()
        exchange.oversized = true
        #expect(await exchange.client().request(localPeer: exchange.requester, target: exchange.target,
                                               expectedServerID: "receiver") == .failed(.invalid))
        #expect(exchange.coordinator.entries.allSatisfy { $0.phase == .challenged })
    }

    @Test func taskCancellationDuringFetchRecoversReplyWithoutCancelledCleanupTask() async throws {
        let exchange = Exchange()
        var suspended = false
        exchange.afterReply = { operation in
            if operation == .submit && !suspended {
                suspended = true
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let client = exchange.client()
        let task = Task { await client.request(localPeer: exchange.requester, target: exchange.target, expectedServerID: "receiver") }
        for _ in 0..<100 where !suspended { try await Task.sleep(for: .milliseconds(10)) }
        #expect(suspended)
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(exchange.coordinator.entries.first?.phase == .cancelled)
    }
}
