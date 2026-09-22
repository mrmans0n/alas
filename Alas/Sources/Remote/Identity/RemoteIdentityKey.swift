import Foundation
import CryptoKit
import os

/// A Mac's answer to "prove you are the peer this record was paired with".
/// Carries the public half so the verifier can compare it against the key its
/// record is pinned to, and a signature over the verifier's own fresh
/// challenge so the answer cannot be replayed or precomputed.
struct RemoteIdentityProof: Equatable, Sendable {
    let challenge: String
    let publicKey: String
    let signature: String
}

/// Signing, verification and encoding for peer identity keys.
///
/// The key is Ed25519 (`Curve25519.Signing`): small, fast, and deterministic,
/// so a proof costs nothing on the handshake path. Keys and signatures travel
/// as base64 of their raw representation — never a `SecKey`-style container —
/// so a peer record pins a plain string and a wire frame carries one too.
enum RemoteIdentityCrypto {
    /// Prefixed into every signed payload. A signature is only ever valid for
    /// the purpose it was made for: without this, a signature this Mac
    /// produced for some unrelated protocol (now or later) over
    /// attacker-chosen bytes could be replayed here as an identity proof.
    static let domain = "alas.peer-identity.v1"

    /// What both sides sign and verify. The `serverId` is inside the payload,
    /// so a proof made by Mac A can never be presented as Mac B's: a
    /// claimant would have to hold A's key *and* be asked about A's identity.
    static func payload(serverId: String, challenge: String) -> Data {
        Data("\(domain)\n\(serverId)\n\(challenge)".utf8)
    }

    /// Byte length of every `randomChallenge()`. Exposed so a receiver can
    /// reject anything hex-encoding to a different length before doing any
    /// work over it — see `isPlausibleChallenge`.
    static let challengeByteCount = 32

    /// A fresh 256-bit challenge, hex-encoded. Chosen by the VERIFIER on the
    /// socket that will carry traffic, which is what makes a proof
    /// non-replayable: a recorded proof is bound to a challenge that will
    /// never be asked again.
    static func randomChallenge() -> String {
        var bytes = [UInt8](repeating: 0, count: challengeByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // A CSPRNG failure would otherwise yield an all-zero, predictable
        // challenge — one an attacker could have a valid proof for in
        // advance. Fail hard rather than verify against a guessable nonce
        // (precondition fires in release too).
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: cannot generate an identity challenge")
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
    static func isPlausibleChallenge(_ challenge: String) -> Bool {
        let hex = challenge.utf8
        guard hex.count == challengeByteCount * 2 else { return false }
        return hex.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func publicKeyString(_ key: Curve25519.Signing.PublicKey) -> String {
        key.rawRepresentation.base64EncodedString()
    }

    static func sign(serverId: String, challenge: String,
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
    static func verify(_ proof: RemoteIdentityProof, serverId: String,
                       expectedPublicKey: String, challenge: String) -> Bool {
        guard proof.challenge == challenge,
              proof.publicKey == expectedPublicKey,
              let rawKey = Data(base64Encoded: expectedPublicKey),
              let rawSignature = Data(base64Encoded: proof.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
        else { return false }
        return key.isValidSignature(rawSignature, for: payload(serverId: serverId, challenge: challenge))
    }
}

/// Produces proofs for this Mac. Implemented by `RemoteIdentityKeyProvider`;
/// a protocol so the server and its tests can be handed a stub that signs
/// with a known key, or none at all.
@MainActor
protocol RemoteIdentitySigning: AnyObject {
    /// Base64 of this Mac's public key, committed to at pairing time.
    var publicKey: String { get }
    func proof(challenge: String, serverId: String) -> RemoteIdentityProof?
}

/// This Mac's long-lived peer identity key, loaded from `store` on first use
/// and generated there if absent.
///
/// Lazy on purpose: the key is only material once federation is actually
/// exercised, and touching the Keychain at launch (or in every test that
/// builds an `AppState`) would be a cost paid by everyone for a feature most
/// runs never reach.
@MainActor
final class RemoteIdentityKeyProvider: RemoteIdentitySigning {
    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "remote-identity")
    /// The account name this Mac's private key is stored under.
    static let keyAccount = "peer-identity-key"

    private let store: any RemoteSecretStore
    private var cached: Curve25519.Signing.PrivateKey?
    /// Set once a generated key could not be stored. Sticky: `publicKey` is
    /// read for every advertisement and `proof` for every socket, so without
    /// it each of those would mint and discard a fresh key and log again.
    private var cannotPersist = false

    init(store: any RemoteSecretStore = RemoteSecretStores.makeDefault()) {
        self.store = store
    }

    var publicKey: String {
        guard let key = privateKey() else { return "" }
        return RemoteIdentityCrypto.publicKeyString(key.publicKey)
    }

    func proof(challenge: String, serverId: String) -> RemoteIdentityProof? {
        guard !challenge.isEmpty, !serverId.isEmpty, let key = privateKey() else { return nil }
        return RemoteIdentityCrypto.sign(serverId: serverId, challenge: challenge, with: key)
    }

    private func privateKey() -> Curve25519.Signing.PrivateKey? {
        if let cached { return cached }
        if cannotPersist { return nil }
        if let raw = store.secret(for: Self.keyAccount),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            cached = key
            // Re-store the loaded bytes. A no-op when they already came
            // from the primary store, but when `store` fell back to a
            // pre-Keychain plaintext file — an ad-hoc build that later
            // gains Keychain access — this is what actually migrates it:
            // `RemoteKeychainSecretStore.setSecret` writes to Keychain and
            // deletes the fallback copy. Unlike `FilePeerStore`, whose
            // next ordinary `save()` migrates its tokens, nothing else
            // ever calls `setSecret` again for this single long-lived key,
            // so without this the plaintext file would linger indefinitely.
            store.setSecret(raw, for: Self.keyAccount)
            return key
        }
        let fresh = Curve25519.Signing.PrivateKey()
        // A key that cannot be persisted must not be handed out: peers would
        // pin it, then refuse this Mac after the next launch minted a
        // different one, and the user would have no way to tell that apart
        // from an actual impersonation attempt. Better to advertise no key
        // at all — records then stay unverified, which is visible and
        // recoverable.
        guard store.setSecret(fresh.rawRepresentation, for: Self.keyAccount) else {
            cannotPersist = true
            Self.logger.error("Could not persist the peer identity key; peers cannot verify this Mac.")
            return nil
        }
        cached = fresh
        return fresh
    }
}
