import CryptoKit
import Foundation
import Testing
@testable import Alas

@MainActor
struct RemotePairingApprovalIntegrationTests {
    @Test func signalWaitFinishesOnTimeoutAndCancellation() async throws {
        let signal = ApprovalPairFixture.Signal()
        await #expect(throws: ApprovalPairFixture.Signal.WaitError.timedOut) {
            try await signal.wait(timeout: .milliseconds(10))
        }
        let waiter = Task { try await signal.wait() }
        try await Task.sleep(for: .milliseconds(10))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        // Finishing abandoned waiters must remove their continuations.
        signal.fire()
        try await signal.wait()
    }

    @Test func requestDoesNotGrantAccessBeforeApproval() async throws {
        let pair = ApprovalPairFixture()
        defer { pair.close() }
        let request = Task { await pair.request() }
        try await pair.waitForPendingRequest()
        #expect(pair.devicesA.isEmpty && pair.devicesB.isEmpty)
        #expect(pair.peersA.isEmpty && pair.peersB.isEmpty)
        #expect(pair.callbackRequests.isEmpty)
        #expect(pair.b.coordinator.entries.filter { $0.phase == .pending }.count == 1)
        pair.decline()
        pair.allow()
        #expect(await request.value == .declined)
        #expect(pair.devicesA.isEmpty && pair.devicesB.isEmpty)
        #expect(pair.a.deviceStore.saved.isEmpty && pair.b.deviceStore.saved.isEmpty)
        #expect(pair.peersA.isEmpty && pair.peersB.isEmpty)
    }

    @Test func duplicateAllowAndConflictingDeclineIssueOneReciprocalPair() async throws {
        let pair = ApprovalPairFixture()
        defer { pair.close() }
        let request = Task { await pair.request() }
        try await pair.waitForPendingRequest()
        pair.allow()
        pair.allow()
        pair.decline()
        #expect(await request.value == .paired)
        try pair.expectReciprocalPair()
        #expect(pair.b.coordinator.entries.first?.phase == .paired)
        #expect(pair.callbackRequests.count == 1)
    }

    @Test(arguments: ["cancel", "expiry", "shutdown", "restart"])
    func terminalWaitingAttemptLeavesNoCredentials(reason: String) async throws {
        let pair = ApprovalPairFixture()
        defer { pair.close() }
        let request = Task { await pair.request() }
        try await pair.waitForPendingRequest()
        switch reason {
        case "cancel": await pair.cancel()
        case "expiry": pair.advanceClock(by: 120); pair.pollGate.fire()
        case "shutdown": pair.b.setEnabled(false); pair.pollGate.fire()
        default: pair.b.restartApprovals(); pair.pollGate.fire()
        }
        let result = await request.value
        switch reason {
        case "cancel": #expect(result == .cancelled)
        case "expiry": #expect(result == .expired)
        case "shutdown": #expect(result == .failed(.disabled))
        default: #expect(result == .failed(.invalid))
        }
        #expect(pair.devicesA.isEmpty && pair.devicesB.isEmpty)
        #expect(pair.peersA.isEmpty && pair.peersB.isEmpty)
        #expect(pair.a.peerStore.saved.isEmpty && pair.b.peerStore.saved.isEmpty)
        #expect(pair.callbackRequests.isEmpty)
        #expect(!pair.b.coordinator.entries.contains { $0.phase == .pending })
    }

    @Test func allowDoesNotExtendSubmissionDeadline() async throws {
        let pair = ApprovalPairFixture()
        defer { pair.close() }
        let request = Task { await pair.request() }
        try await pair.waitForPendingRequest()
        pair.advanceClock(by: 119)
        pair.allow()
        // The next two-second poll crosses the original submission deadline.
        #expect(await request.value == .expired)
        pair.b.coordinator.expire()
        #expect(pair.b.coordinator.entries.first?.phase == .expired)
        #expect(pair.devicesA.isEmpty && pair.devicesB.isEmpty)
        #expect(pair.callbackRequests.isEmpty)
    }

    @Test func lostRedeemReplyRetriesExactRequestAcrossSubmissionDeadline() async throws {
        let pair = ApprovalPairFixture()
        defer { pair.close() }
        pair.dropRedeemReply = true
        pair.advanceAfterLostRedeem = 3
        let request = Task { await pair.request() }
        try await pair.waitForPendingRequest()
        pair.advanceClock(by: 117)
        pair.allow()
        #expect(await request.value == .paired)
        try pair.expectReciprocalPair()
        #expect(pair.redeemRequests.count == 2)
        #expect(pair.redeemRequests.first?.httpBody == pair.redeemRequests.last?.httpBody)
        #expect(pair.redeemReplies.count == 2)
        #expect(pair.redeemReplies.first == pair.redeemReplies.last)
        #expect(pair.callbackRequests.count == 1)
        // Exact recovery also stops at the separate 120-second redemption deadline.
        pair.advanceClock(by: 120)
        let retry = try #require(pair.redeemRequests.first)
        let (_, response) = try await pair.fetch(retry, from: pair.a)
        #expect(response.statusCode == 401)
        try pair.expectReciprocalPair()
    }

    @Test(arguments: [false, true])
    func cancellationAfterIssuanceRollsBackOnlyThisAttempt(hasOlderPair: Bool) async throws {
        let pair = ApprovalPairFixture()
        defer { pair.close() }
        if hasOlderPair { #expect(await pair.pairWithCode() == nil) }
        let peersA = pair.peersA, peersB = pair.peersB
        let devicesA = pair.devicesA, devicesB = pair.devicesB
        pair.holdRedeemReply = true
        let request = Task { await pair.request() }
        try await pair.waitForPendingRequest()
        pair.allow()
        try await pair.issued.wait()
        #expect(pair.devicesB.count == devicesB.count + 1)
        request.cancel()
        pair.redeemGate.fire()
        #expect(await request.value != .paired)
        #expect(pair.peersA == peersA && pair.peersB == peersB)
        #expect(pair.devicesA == devicesA && pair.devicesB == devicesB)
        #expect(pair.a.peerStore.saved == peersA && pair.b.peerStore.saved == peersB)
        #expect(pair.a.deviceStore.saved == devicesA && pair.b.deviceStore.saved == devicesB)
    }

    @Test func lostSubmitReplyAndAddressRetryCreateOnePrompt() async throws {
        let pair = ApprovalPairFixture()
        defer { pair.close() }
        pair.tryOfflineOrigin = true
        pair.dropSubmitReply = true
        let request = Task { await pair.request() }
        try await pair.waitForPendingRequest()
        #expect(pair.b.coordinator.entries.count == 1)
        #expect(pair.submitRequests.count == 2)
        #expect(pair.submitRequests.first?.httpBody == pair.submitRequests.last?.httpBody)
        #expect(pair.submitRequests.allSatisfy { $0.url?.host == "10.0.0.2" })
        pair.allow()
        #expect(await request.value == .paired)
        #expect(pair.devicesA.count == 1 && pair.devicesB.count == 1)
    }

    @Test func legacyPeerStillPairsWithCodeAndBrowserCodeRedemption() async throws {
        let pair = ApprovalPairFixture()
        defer { pair.close() }
        let legacy = RemoteDiscoveredInstanceResolver.ResolvedPeer(origins: pair.b.peer.origins,
            serverID: "b", pairingApprovalVersion: nil)
        #expect(await pair.client.request(localPeer: pair.a.peer, target: legacy, expectedServerID: "b") == .failed(.disabled))
        #expect(pair.b.coordinator.entries.isEmpty)
        #expect(await pair.pairWithCode() == nil)
        try pair.expectReciprocalPair()
        let code = pair.b.pairing.beginPairing()
        var browser = URLRequest(url: URL(string: pair.b.peer.origins[0] + "/pair")!)
        browser.httpMethod = "POST"
        browser.setValue("http://localhost:8765", forHTTPHeaderField: "Origin")
        browser.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "deviceName": "Browser"])
        let (body, response) = try await pair.fetch(browser, from: pair.a)
        #expect(response.statusCode == 200)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let token = try #require(object["token"] as? String)
        #expect(pair.b.pairing.validate(token: token) != nil)
        #expect(pair.devicesB.filter { $0.kind == .browser }.count == 1)
        #expect(pair.peersA.count == 1 && pair.peersB.count == 1)
        #expect(pair.b.coordinator.entries.isEmpty)
    }

    @Test func invalidReceiverProofNeverCreatesPromptOrUsesCodePairing() async {
        let pair = ApprovalPairFixture()
        defer { pair.close() }
        pair.tamperChallenge = true
        #expect(await pair.request() == .failed(.unauthorized))
        #expect(pair.submitRequests.isEmpty && pair.redeemRequests.isEmpty)
        #expect(pair.callbackRequests.isEmpty)
        #expect(pair.b.coordinator.entries.allSatisfy { $0.phase == .challenged })
        #expect(pair.devicesA.isEmpty && pair.devicesB.isEmpty)
        #expect(pair.peersA.isEmpty && pair.peersB.isEmpty)
    }
}

/// Only HTTP transport, the clock, persistence, and post-pair sockets are replaced.
/// Both directions route bytes through the production responder and pairer.
@MainActor private final class ApprovalPairFixture {
    enum Result: Equatable {
        case paired, declined, cancelled, expired
        case failed(ApprovalFailure), pairingFailed(RemotePeerManager.AddError)
    }
    @MainActor final class Signal {
        enum WaitError: Error { case timedOut }
        private var fired = false
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        func wait(timeout: Duration = .seconds(5)) async throws {
            try Task.checkCancellation()
            if fired { return }
            let id = UUID()
            let watchdog = Task { @MainActor in
                do { try await Task.sleep(for: timeout) } catch { return }
                self.finish(id, result: .failure(WaitError.timedOut))
            }
            defer { watchdog.cancel() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiters[id] = continuation }
                }
            } onCancel: {
                Task { @MainActor in self.finish(id, result: .failure(CancellationError())) }
            }
        }
        private func finish(_ id: UUID, result: Swift.Result<Void, Error>) {
            waiters.removeValue(forKey: id)?.resume(with: result)
        }
        func cancel() {
            let continuations = waiters.values
            waiters.removeAll()
            for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        }
        func fire() {
            fired = true
            let continuations = waiters.values
            waiters.removeAll()
            for continuation in continuations { continuation.resume() }
        }
    }
    @MainActor final class Signer: ApprovalSigning {
        let key = Curve25519.Signing.PrivateKey()
        var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
        func signApproval(_ payload: ApprovalPayload, reply: Bool) -> String? {
            try? key.signature(for: ApprovalWire.bytes(payload, reply: reply)).base64EncodedString()
        }
    }
    @MainActor final class Socket: RemotePeerConnecting {
        var state: RemotePeerConnection.State = .idle
        func connect() {}
        func disconnect() {}
        func send(_ message: RemoteClientMessage) {}
    }
    @MainActor final class Peer {
        let id: String
        let origin: String
        let signer = Signer()
        let deviceStore = InMemoryDeviceStore()
        let peerStore = InMemoryPeerStore()
        unowned let fixture: ApprovalPairFixture
        var enabled = true
        var callbacks: [Task<Void, Never>] = []
        var peer: ApprovalPeer { .init(serverID: id, publicKey: signer.publicKey, name: "Mac " + id, origins: [origin]) }
        lazy var pairing = RemotePairingService(store: deviceStore, now: { self.fixture.time })
        lazy var manager = RemotePeerManager(store: peerStore, pairing: pairing,
            pairer: RemotePeerPairer(fetch: { try await self.fixture.fetch($0, from: self) }),
            reciprocalConfirmationTimeout: 1,
            localIdentity: { .init(serverId: self.id, name: self.peer.name, origins: self.peer.origins, publicKey: self.signer.publicKey) },
            makeConnection: { _, _ in Socket() }, now: { self.fixture.time })
        lazy var coordinator = makeCoordinator()
        init(id: String, origin: String, fixture: ApprovalPairFixture) {
            self.id = id; self.origin = origin; self.fixture = fixture
        }
        func makeCoordinator() -> RemotePairingApprovalCoordinator {
            let value = RemotePairingApprovalCoordinator(localPeer: { self.peer }, signer: signer, now: { self.fixture.time })
            value.setEnabled(enabled)
            value.onCancelRedeeming = { [weak self] in self?.manager.cancelApprovedPairing(requestID: $0) }
            value.onReleaseAttempt = { [weak self] in self?.manager.releaseApprovedPairing(requestID: $0) }
            pairing.onDeviceRevoked = { [weak value] in value?.invalidate(deviceID: $0) }
            return value
        }
        func setEnabled(_ value: Bool) { enabled = value; coordinator.setEnabled(value) }
        func restartApprovals() { coordinator = makeCoordinator() }
        func responder() -> RemoteHTTPResponder {
            var result = RemoteHTTPResponder(pairing: pairing,
                assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
                diagnostics: { .init(appName: "Alas", port: 8765, addresses: [], usesPlainHTTP: true,
                    pairedDeviceCount: self.pairing.devices.count, serverId: self.id, name: self.peer.name,
                    pairingApprovalVersion: self.enabled ? 1 : nil) })
            result.acceptsPeers = { self.enabled }
            result.identity = { .init(serverId: self.id, name: self.peer.name, hubEnabled: true, federationEnabled: true) }
            result.identityProof = { RemoteIdentityCrypto.sign(serverId: self.id, challenge: $0, with: self.signer.key) }
            result.approval = RemotePairingApprovalHTTP(coordinator: coordinator, enabled: { self.enabled })
            result.onPeerPaired = { request in
                self.manager.notePeerPairingArrived(serverId: request.peerServerId, localDeviceId: request.localDeviceId)
                self.callbacks.append(Task { await self.manager.handleInboundPeer(request) })
            }
            result.onApprovedPeerPaired = { request, requestID, localPeer in
                self.manager.noteApprovedPeerPairingArrived(requestID: requestID, request: request, localPeer: localPeer)
                self.callbacks.append(Task {
                    let success = await self.manager.handleInboundApprovedPeer(requestID: requestID)
                    self.coordinator.complete(requestID: requestID, succeeded: success)
                })
            }
            return result
        }
    }
    var time = Date(timeIntervalSince1970: 10_000)
    lazy var a = Peer(id: "a", origin: "http://10.0.0.1:8765", fixture: self)
    lazy var b = Peer(id: "b", origin: "http://10.0.0.2:8765", fixture: self)
    let pending = Signal(), pollGate = Signal(), issued = Signal(), redeemGate = Signal()
    var dropRedeemReply = false, dropSubmitReply = false, holdRedeemReply = false, tryOfflineOrigin = false
    var tamperChallenge = false
    var advanceAfterLostRedeem: TimeInterval = 0
    var redeemRequests: [URLRequest] = [], submitRequests: [URLRequest] = [], callbackRequests: [URLRequest] = []
    var redeemReplies: [Data] = []
    var devicesA: [RemoteDevice] { a.pairing.devices }
    var devicesB: [RemoteDevice] { b.pairing.devices }
    var peersA: [RemotePeer] { a.manager.peers }
    var peersB: [RemotePeer] { b.manager.peers }
    lazy var client = RemotePairingApprovalClient(fetch: { try await self.fetch($0, from: self.a) }, signer: a.signer,
        now: { self.time }, sleep: { @MainActor _ in
            self.pending.fire()
            try await self.pollGate.wait()
            self.advanceClock(by: 2)
        })

    func request() async -> Result {
        let origins = (tryOfflineOrigin ? ["http://offline:8765"] : []) + b.peer.origins
        let result = await client.request(localPeer: a.peer,
            target: .init(origins: origins, serverID: "b", pairingApprovalVersion: 1), expectedServerID: "b")
        switch result {
        case .approved(let session):
            let error = await a.manager.addApprovedPeer(expectedPeer: session.payload.receiver, localPeer: a.peer) {
                await self.client.redeem(session: session, advertisement: $0)
            }
            if error != nil || Task.isCancelled { await client.cancel(session: session) }
            await finishCallbacks()
            return error.map(Result.pairingFailed) ?? .paired
        case .declined: return .declined
        case .cancelled: return .cancelled
        case .expired: return .expired
        case .failed(let failure): return .failed(failure)
        }
    }
    func waitForPendingRequest() async throws { try await pending.wait() }
    func allow() { decide(.allow) }
    func decline() { decide(.decline) }
    private func decide(_ decision: ApprovalDecision) {
        if let entry = b.coordinator.entries.first { b.coordinator.decide(decision, requestID: entry.id) }
        pollGate.fire()
    }
    func cancel() async {
        if let session = client.session { await client.cancel(session: session) }
        pollGate.fire()
    }
    func advanceClock(by seconds: TimeInterval) {
        time += seconds
        a.coordinator.expire(); b.coordinator.expire()
    }
    func pairWithCode() async -> RemotePeerManager.AddError? {
        let result = await a.manager.addPeer(code: b.pairing.beginPairing(), origins: b.peer.origins)
        await finishCallbacks()
        return result
    }
    func finishCallbacks() async {
        for task in b.callbacks { await task.value }
        for task in a.callbacks { await task.value }
    }
    func close() {
        for signal in [pending, pollGate, issued, redeemGate] { signal.cancel() }
        for task in a.callbacks + b.callbacks { task.cancel() }
        a.manager.disconnectAll(); b.manager.disconnectAll()
    }
    func expectReciprocalPair() throws {
        #expect(devicesA.count == 1 && devicesB.count == 1)
        let peerA = try #require(peersA.first), peerB = try #require(peersB.first)
        #expect(peersA.count == 1 && peersB.count == 1)
        #expect(peerA.serverId == "b" && peerB.serverId == "a")
        #expect(peerA.publicKey == b.signer.publicKey && peerB.publicKey == a.signer.publicKey)
        #expect(b.pairing.validate(token: peerA.token) == peerB.localDeviceId)
        #expect(a.pairing.validate(token: peerB.token) == peerA.localDeviceId)
        #expect(a.peerStore.saved == peersA && b.peerStore.saved == peersB)
        #expect(a.deviceStore.saved == devicesA && b.deviceStore.saved == devicesB)
    }
    func fetch(_ request: URLRequest, from source: Peer) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        if url.host == "offline" { throw URLError(.cannotConnectToHost) }
        let target = url.host == "10.0.0.1" ? a : b
        #expect(url.host == "10.0.0.1" || url.host == "10.0.0.2")
        let isRedeem = url.path == "/pair" && source === a && request.httpBody.map {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["approval"] != nil
        } == true
        if source === b { callbackRequests.append(request) }
        if isRedeem { redeemRequests.append(request) }
        if url.path.hasSuffix("/submit") { submitRequests.append(request) }
        let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        let response = target.responder().response(for: HTTPRequest(method: request.httpMethod ?? "GET", path: url.path,
            query: [:], headers: headers), body: request.httpBody ?? Data())
        let separator = try #require(response.range(of: Data("\r\n\r\n".utf8)))
        let head = String(decoding: response[..<separator.lowerBound], as: UTF8.self)
        let status = try #require(Int(head.split(separator: " ")[1]))
        var body = Data(response[separator.upperBound...])
        #expect(body.count <= 16 * 1024)
        if tamperChallenge && url.path.hasSuffix("/challenge") {
            var object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            object["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
            body = try JSONSerialization.data(withJSONObject: object)
        }
        if isRedeem {
            redeemReplies.append(body)
            // Complete real reciprocal callbacks before delivering the original reply,
            // exercising the manager's early-confirmation buffering as well.
            await finishCallbacks()
            if holdRedeemReply { issued.fire(); try await redeemGate.wait() }
            if dropRedeemReply {
                dropRedeemReply = false
                advanceClock(by: advanceAfterLostRedeem)
                throw URLError(.networkConnectionLost)
            }
        }
        if url.path.hasSuffix("/submit"), dropSubmitReply {
            dropSubmitReply = false
            throw URLError(.networkConnectionLost)
        }
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
