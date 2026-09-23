import CryptoKit
import Foundation

enum ApprovalOperation: String, Codable, Sendable {
    case challenge, submit, status, cancel, redeem
}

enum ApprovalPhase: String, Codable, Sendable {
    case challenged, pending, approved, redeeming, paired
    case declined, cancelled, expired, failed
}

struct ApprovalPeer: Codable, Equatable, Sendable {
    let serverID: String
    let publicKey: String
    let name: String
    let origins: [String]
}

struct ApprovalPayload: Codable, Equatable, Sendable {
    let operation: ApprovalOperation
    let requestID: String
    let requester: ApprovalPeer
    let receiver: ApprovalPeer
    let attemptNonce: String
    let operationNonce: String
    let challenge: String
    let expiresAtMilliseconds: Int64
    let phase: ApprovalPhase
    let counterCode: String?
    let responseDigest: String?
}

struct ApprovalEnvelope: Codable, Equatable, Sendable {
    let payload: ApprovalPayload
    let signature: String
}

struct ApprovalPairReply: Codable, Equatable, Sendable {
    let pairBody: Data
    let proof: ApprovalEnvelope
}

@MainActor
protocol ApprovalSigning {
    var publicKey: String { get }
    func signApproval(_ payload: ApprovalPayload, reply: Bool) -> String?
}

enum ApprovalWire {
    private static let maximumTextLength = 200
    private static let maximumJSONSize = 16 * 1024
    private static let publicKeyByteCount = 32
    private static let signatureByteCount = 64
    private static let nonceByteCount = 32

    static func domain(_ operation: ApprovalOperation, reply: Bool) -> String {
        "alas.peer-approval.v1.\(operation.rawValue).\(reply ? "reply" : "request")"
    }

    /// Returns an empty value when any field is unsuitable for the wire.
    static func bytes(_ payload: ApprovalPayload, reply: Bool) -> Data {
        guard isValid(payload) else { return Data() }

        var data = Data()
        appendString(domain(payload.operation, reply: reply), to: &data)
        appendString(payload.operation.rawValue, to: &data)
        appendString(payload.requestID, to: &data)
        appendPeer(payload.requester, to: &data)
        appendPeer(payload.receiver, to: &data)
        appendString(payload.attemptNonce, to: &data)
        appendString(payload.operationNonce, to: &data)
        appendString(payload.challenge, to: &data)
        appendInt64(payload.expiresAtMilliseconds, to: &data)
        appendString(payload.phase.rawValue, to: &data)
        appendOptionalString(payload.counterCode, to: &data)
        appendOptionalString(payload.responseDigest, to: &data)
        return data
    }

    static func verify(_ envelope: ApprovalEnvelope, expectedKey: String, reply: Bool) -> Bool {
        guard let rawKey = Data(base64Encoded: expectedKey), rawKey.count == publicKeyByteCount,
              rawKey.base64EncodedString() == expectedKey,
              let rawSignature = Data(base64Encoded: envelope.signature),
              rawSignature.count == signatureByteCount,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
        else { return false }
        let transcript = bytes(envelope.payload, reply: reply)
        guard !transcript.isEmpty else { return false }
        return key.isValidSignature(rawSignature, for: transcript)
    }

    static func displayName(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            scalar.properties.generalCategory != .control && !isBidirectionalFormatting(scalar)
        })
    }

    private static func isValid(_ payload: ApprovalPayload) -> Bool {
        guard isValidIdentifier(payload.requestID),
              let requesterKey = validatedPublicKey(for: payload.requester),
              let receiverKey = validatedPublicKey(for: payload.receiver),
              payload.requester.serverID != payload.receiver.serverID,
              requesterKey != receiverKey,
              isHexNonce(payload.attemptNonce), isHexNonce(payload.operationNonce),
              isHexNonce(payload.challenge),
              isValidOptionalText(payload.counterCode),
              isValidOptionalText(payload.responseDigest),
              let encoded = try? JSONEncoder().encode(payload), encoded.count <= maximumJSONSize
        else { return false }
        return true
    }

    private static func validatedPublicKey(for peer: ApprovalPeer) -> Data? {
        guard isValidIdentifier(peer.serverID), isValidText(peer.name),
              let key = Data(base64Encoded: peer.publicKey), key.count == publicKeyByteCount,
              key.base64EncodedString() == peer.publicKey,
              !peer.origins.isEmpty, peer.origins.count <= RemotePairingLink.maxOrigins
        else { return nil }
        guard peer.origins.allSatisfy({ origin in
            isValidText(origin) && RemotePairingLink.normalizeOrigin(origin) == origin
        }) else { return nil }
        return key
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        isValidText(value) && !value.isEmpty && !value.unicodeScalars.contains {
            $0.properties.generalCategory == .control
        }
    }

    private static func isValidText(_ value: String) -> Bool {
        value.count <= maximumTextLength && value.utf8.count <= UInt32.max
    }

    private static func isValidOptionalText(_ value: String?) -> Bool {
        value.map(isValidText) ?? true
    }

    private static func isHexNonce(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == nonceByteCount * 2 && bytes.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func isBidirectionalFormatting(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    private static func appendPeer(_ peer: ApprovalPeer, to data: inout Data) {
        appendString(peer.serverID, to: &data)
        appendString(peer.publicKey, to: &data)
        appendString(peer.name, to: &data)
        var count = UInt32(peer.origins.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for origin in peer.origins { appendString(origin, to: &data) }
    }

    private static func appendOptionalString(_ value: String?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        appendString(value, to: &data)
    }

    private static func appendInt64(_ value: Int64, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    static func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}
