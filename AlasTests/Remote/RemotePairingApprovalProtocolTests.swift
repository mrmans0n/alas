import CryptoKit
import Foundation
import Testing
@testable import Alas

struct RemotePairingApprovalProtocolTests {
    private let key = Curve25519.Signing.PrivateKey()

    private func peer(id: String = "requester", key: String? = nil,
                      name: String = "Requesting Mac",
                      origins: [String] = ["https://requester.example:8765"]) -> ApprovalPeer {
        ApprovalPeer(serverID: id,
                     publicKey: key ?? Data(repeating: id == "requester" ? 1 : 2, count: 32).base64EncodedString(),
                     name: name,
                     origins: origins)
    }

    private func payload(
        operation: ApprovalOperation = .submit,
        requestID: String = "request-1",
        requester: ApprovalPeer? = nil,
        receiver: ApprovalPeer? = nil,
        attemptNonce: String = String(repeating: "a", count: 64),
        operationNonce: String = String(repeating: "b", count: 64),
        challenge: String = String(repeating: "c", count: 64),
        expiresAtMilliseconds: Int64 = 1_800_000_000_000,
        phase: ApprovalPhase = .pending,
        counterCode: String? = "123456",
        responseDigest: String? = String(repeating: "d", count: 64)
    ) -> ApprovalPayload {
        ApprovalPayload(operation: operation,
                        requestID: requestID,
                        requester: requester ?? peer(),
                        receiver: receiver ?? peer(id: "receiver"),
                        attemptNonce: attemptNonce,
                        operationNonce: operationNonce,
                        challenge: challenge,
                        expiresAtMilliseconds: expiresAtMilliseconds,
                        phase: phase,
                        counterCode: counterCode,
                        responseDigest: responseDigest)
    }

    private func envelope(for payload: ApprovalPayload, reply: Bool = false) throws -> ApprovalEnvelope {
        let signature = try key.signature(for: ApprovalWire.bytes(payload, reply: reply))
        return ApprovalEnvelope(payload: payload, signature: signature.base64EncodedString())
    }

    @Test func encodingIsDeterministicAndSignaturesVerify() throws {
        let value = payload(requester: peer(key: key.publicKey.rawRepresentation.base64EncodedString()))
        let first = ApprovalWire.bytes(value, reply: false)
        let second = ApprovalWire.bytes(value, reply: false)
        #expect(!first.isEmpty)
        #expect(first == second)
        #expect(ApprovalWire.verify(try envelope(for: value),
                                    expectedKey: key.publicKey.rawRepresentation.base64EncodedString(),
                                    reply: false))
    }

    @Test func requestAndReplyHaveDifferentSigningDomains() {
        #expect(ApprovalWire.domain(.submit, reply: false)
                != ApprovalWire.domain(.submit, reply: true))
        #expect(ApprovalWire.domain(.submit, reply: false)
                != ApprovalWire.domain(.redeem, reply: false))
    }

    @Test func everyPayloadFieldIsCoveredByTheSignature() throws {
        let original = payload(requester: peer(
            key: key.publicKey.rawRepresentation.base64EncodedString(),
            origins: ["https://requester.example:8765", "https://second.example"]))
        let signed = try envelope(for: original)
        let mutations = [
            payload(operation: .status, requester: original.requester),
            payload(requestID: "request-2", requester: original.requester),
            payload(requester: peer(id: "requester-2", key: original.requester.publicKey)),
            payload(requester: peer(key: original.requester.publicKey, name: "Other name")),
            payload(requester: peer(key: original.requester.publicKey,
                                    origins: ["https://second.example", "https://requester.example:8765"])),
            payload(requester: peer(key: original.requester.publicKey), receiver: peer(id: "receiver-2")),
            payload(requester: original.requester,
                    receiver: peer(id: "receiver", key: Data(repeating: 3, count: 32).base64EncodedString())),
            payload(requester: original.requester, receiver: peer(id: "receiver", name: "Other receiver")),
            payload(requester: original.requester,
                    receiver: peer(id: "receiver", origins: ["https://receiver.example", "https://other.example"])),
            payload(requester: original.requester, attemptNonce: String(repeating: "e", count: 64)),
            payload(requester: original.requester, operationNonce: String(repeating: "e", count: 64)),
            payload(requester: original.requester, challenge: String(repeating: "e", count: 64)),
            payload(requester: original.requester, expiresAtMilliseconds: original.expiresAtMilliseconds + 1),
            payload(requester: original.requester, phase: .approved),
            payload(requester: original.requester, counterCode: nil),
            payload(requester: original.requester, responseDigest: nil)
        ]
        for mutation in mutations {
            #expect(!ApprovalWire.verify(ApprovalEnvelope(payload: mutation, signature: signed.signature),
                                         expectedKey: original.requester.publicKey,
                                         reply: false))
        }
    }

    @Test func malformedKeysAndSignaturesAreRejected() throws {
        let value = payload(requester: peer(key: key.publicKey.rawRepresentation.base64EncodedString()))
        let signed = try envelope(for: value)
        #expect(!ApprovalWire.verify(signed, expectedKey: "not base64", reply: false))
        #expect(!ApprovalWire.verify(signed,
                                     expectedKey: Data(repeating: 0, count: 31).base64EncodedString(), reply: false))
        #expect(!ApprovalWire.verify(ApprovalEnvelope(payload: value, signature: "not base64"),
                                     expectedKey: value.requester.publicKey, reply: false))
        #expect(!ApprovalWire.verify(ApprovalEnvelope(
            payload: value, signature: Data(repeating: 0, count: 63).base64EncodedString()),
            expectedKey: value.requester.publicKey, reply: false))
    }

    @Test func alternateBase64SpellingCannotAliasAKeyOrBypassSelfPairing() throws {
        let rawKey = key.publicKey.rawRepresentation
        let canonical = rawKey.base64EncodedString()
        var aliasCharacters = Array(canonical)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        let canonicalIndex = try #require(alphabet.firstIndex(of: aliasCharacters[42]))
        aliasCharacters[42] = alphabet[canonicalIndex + 1]
        let alias = String(aliasCharacters)
        #expect(alias != canonical)
        #expect(Data(base64Encoded: alias) == rawKey)

        let value = payload(requester: peer(key: canonical),
                            receiver: peer(id: "receiver", key: alias))
        #expect(ApprovalWire.bytes(value, reply: false).isEmpty)

        let validValue = payload(requester: peer(key: canonical))
        let signed = try envelope(for: validValue)
        #expect(!ApprovalWire.verify(signed, expectedKey: alias, reply: false))
    }

    @Test func invalidPayloadsCannotBeEncodedOrVerified() throws {
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let invalid = [
            payload(requestID: String(repeating: "x", count: 201), requester: peer(key: publicKey)),
            payload(requestID: "request\u{0000}", requester: peer(key: publicKey)),
            payload(requester: peer(key: publicKey, name: String(repeating: "x", count: 201))),
            payload(requester: peer(key: "not base64")),
            payload(requester: peer(key: publicKey, origins: (0..<9).map { "https://\($0).example" })),
            payload(requester: peer(key: publicKey,
                                    origins: ["https://" + String(repeating: "a", count: 193)])),
            payload(requester: peer(key: publicKey, origins: ["ftp://requester.example"])),
            payload(requester: peer(key: publicKey), receiver: peer(id: "requester")),
            payload(requester: peer(key: publicKey), receiver: peer(id: "receiver", key: publicKey)),
            payload(requester: peer(key: publicKey), attemptNonce: "abc"),
            payload(requester: peer(key: publicKey), operationNonce: String(repeating: "G", count: 64)),
            payload(requester: peer(key: publicKey), challenge: String(repeating: "0", count: 62)),
            payload(requester: peer(key: publicKey), counterCode: String(repeating: "x", count: 201)),
            payload(requester: peer(key: publicKey), responseDigest: String(repeating: "x", count: 201))
        ]
        for value in invalid {
            #expect(ApprovalWire.bytes(value, reply: false).isEmpty)
            #expect(!ApprovalWire.verify(ApprovalEnvelope(payload: value,
                                                          signature: Data(repeating: 0, count: 64).base64EncodedString()),
                                         expectedKey: publicKey, reply: false))
        }
    }

    @Test func displayNameRemovesControlsAndBidirectionalFormattingOnly() {
        #expect(ApprovalWire.displayName(" A\u{0000}B\u{202E} C \n") == " AB C ")
        #expect(ApprovalWire.displayName("Mác ") == "Mác ")
    }
}
