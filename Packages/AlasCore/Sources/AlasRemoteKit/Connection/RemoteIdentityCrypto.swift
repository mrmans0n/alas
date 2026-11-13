import Foundation
import CryptoKit

/// A Mac's answer to "prove you are the peer this record was paired with".
/// Carries the public half so the verifier can compare it against the key its
/// record is pinned to, and a signature over the verifier's own fresh
/// challenge so the answer cannot be replayed or precomputed.
public struct RemoteIdentityProof: Equatable, Sendable {
    public let challenge: String
    public let publicKey: String
    public let signature: String

    public init(challenge: String, publicKey: String, signature: String) {
        self.challenge = challenge
        self.publicKey = publicKey
        self.signature = signature
    }
}

/// Signing, verification and encoding for peer identity keys.
///
/// The key is Ed25519 (`Curve25519.Signing`): small, fast, and deterministic,
/// so a proof costs nothing on the handshake path. Keys and signatures travel
/// as base64 of their raw representation — never a `SecKey`-style container —
/// so a peer record pins a plain string and a wire frame carries one too.
public enum RemoteIdentityCrypto: Sendable {
    /// Prefixed into every signed payload. A signature is only ever valid for
    /// the purpose it was made for: without this, a signature this Mac
    /// produced for some unrelated protocol (now or later) over
    /// attacker-chosen bytes could be replayed here as an identity proof.
    public static let domain = "alas.peer-identity.v1"

    /// What both sides sign and verify. The `serverId` is inside the payload,
    /// so a proof made by Mac A can never be presented as Mac B's: a
    /// claimant would have to hold A's key *and* be asked about A's identity.
    public static func payload(serverId: String, challenge: String) -> Data {
        Data("\(domain)\n\(serverId)\n\(challenge)".utf8)
    }

    /// Byte length of every `randomChallenge()`. Exposed so a receiver can
    /// reject anything hex-encoding to a different length before doing any
    /// work over it — see `isPlausibleChallenge`.
    public static let challengeByteCount = 32

    /// A fresh 256-bit challenge, hex-encoded. Chosen by the VERIFIER on the
    /// socket that will carry traffic, which is what makes a proof
    /// non-replayable: a recorded proof is bound to a challenge that will
    /// never be asked again.
    public static func randomChallenge() -> String {
        // The system generator is a CSPRNG and cannot fail, which also keeps
        // this file free of `Security` (it must build for iOS with CryptoKit only).
        let bytes = (0..<challengeByteCount).map { _ in UInt8.random(in: .min ... .max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `challenge` could be one this Mac (or a peer running this
    /// same code) actually produced: exactly `challengeByteCount * 2`
    /// lowercase hex characters. Any authenticated socket can otherwise send
    /// a `helloAck` challenge up to the WebSocket message limit and have it
    /// forwarded straight into CryptoKit signing — hashing and signing
    /// attacker-controlled megabytes, repeatedly, on the main actor. This is
    /// meant to be checked BEFORE scheduling a signature, not as a
    /// correctness requirement of `verify` itself, which cares only about
    /// the challenge matching and never depended on its shape.
    public static func isPlausibleChallenge(_ challenge: String) -> Bool {
        let hex = challenge.utf8
        guard hex.count == challengeByteCount * 2 else { return false }
        return hex.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    public static func publicKeyString(_ key: Curve25519.Signing.PublicKey) -> String {
        key.rawRepresentation.base64EncodedString()
    }

    public static func sign(serverId: String, challenge: String,
                     with privateKey: Curve25519.Signing.PrivateKey) -> RemoteIdentityProof? {
        guard let signature = try? privateKey.signature(for: payload(serverId: serverId, challenge: challenge)) else {
            return nil
        }
        return RemoteIdentityProof(
            challenge: challenge,
            publicKey: publicKeyString(privateKey.publicKey),
            signature: signature.base64EncodedString())
    }

    /// Whether `proof` really proves possession of `expectedPublicKey`.
    ///
    /// Every field is checked against what the VERIFIER already knows rather
    /// than against the proof's own claims: the challenge must be the one
    /// this verifier just minted (not one the prover picked), and the public
    /// key must be the one the record was pinned to (not merely one the
    /// prover happens to hold a key for — anybody can sign with their own).
    public static func verify(_ proof: RemoteIdentityProof, serverId: String,
                       expectedPublicKey: String, challenge: String) -> Bool {
        guard proof.challenge == challenge,
              proof.publicKey == expectedPublicKey,
              let rawKey = Data(base64Encoded: expectedPublicKey),
              let rawSignature = Data(base64Encoded: proof.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
        else { return false }
        return key.isValidSignature(rawSignature, for: payload(serverId: serverId, challenge: challenge))
    }

    /// The domain of a redeemer's proof at `POST /pair`. Separate from
    /// `domain`, so a redeem signature never passes as a socket proof or the
    /// reverse.
    public static let redeemDomain = "alas.peer-redeem.v1"

    /// What a redeemer signs: its own server id and the code it redeems. The
    /// responder minted the code, single use and short-lived, so it serves as
    /// the challenge without another round trip.
    public static func redeemPayload(serverId: String, code: String) -> Data {
        Data("\(redeemDomain)\n\(serverId)\n\(code.uppercased())".utf8)
    }

    public static func signRedeem(serverId: String, code: String,
                                  with privateKey: Curve25519.Signing.PrivateKey) -> String? {
        try? privateKey.signature(for: redeemPayload(serverId: serverId, code: code)).base64EncodedString()
    }

    /// Base64 of a 64-byte Ed25519 signature is always 88 characters.
    static let signatureBase64Length = 88

    /// Whether `signature` could be a redeemer's proof at all. Checked before
    /// any verification: the input arrives unauthenticated.
    public static func isPlausibleSignature(_ signature: String) -> Bool {
        signature.utf8.count == signatureBase64Length && Data(base64Encoded: signature)?.count == 64
    }

    /// Whether `signature` proves the holder of `publicKey` redeemed `code`
    /// as `serverId`.
    public static func verifyRedeem(signature: String, serverId: String, code: String, publicKey: String) -> Bool {
        guard isPlausibleSignature(signature),
              let rawKey = Data(base64Encoded: publicKey),
              let rawSignature = Data(base64Encoded: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
        else { return false }
        return key.isValidSignature(rawSignature, for: redeemPayload(serverId: serverId, code: code))
    }
}
