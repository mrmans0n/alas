import Foundation
import CryptoKit
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasRemoteKit

/// Produces proofs for this Mac. Implemented by `RemoteIdentityKeyProvider`;
/// a protocol so the server and its tests can be handed a stub that signs
/// with a known key, or none at all.
@MainActor
public protocol RemoteIdentitySigning: AnyObject {
    /// Base64 of this Mac's public key, committed to at pairing time.
    var publicKey: String { get }
    func proof(challenge: String, serverId: String) -> RemoteIdentityProof?
    /// This Mac's proof, as `serverId`, that it redeems `code`.
    func redeemProof(code: String, serverId: String) -> String?
}

public extension RemoteIdentitySigning {
    func redeemProof(code: String, serverId: String) -> String? { nil }
}

/// This Mac's long-lived peer identity key, loaded from `store` on first use
/// and generated there if absent.
///
/// Lazy on purpose: the key is only material once federation is actually
/// exercised, and touching the Keychain at launch (or in every test that
/// builds an `AppState`) would be a cost paid by everyone for a feature most
/// runs never reach.
@MainActor
public final class RemoteIdentityKeyProvider: RemoteIdentitySigning, ApprovalSigning {
    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "remote-identity")
    /// The account name this Mac's private key is stored under.
    public static let keyAccount = "peer-identity-key"

    private let store: any RemoteSecretStore
    private var cached: Curve25519.Signing.PrivateKey?
    /// Set once a generated key could not be stored. Sticky: `publicKey` is
    /// read for every advertisement and `proof` for every socket, so without
    /// it each of those would mint and discard a fresh key and log again.
    private var cannotPersist = false

    public init(store: any RemoteSecretStore = RemoteSecretStores.makeDefault()) {
        self.store = store
    }

    public var publicKey: String {
        guard let key = privateKey() else { return "" }
        return RemoteIdentityCrypto.publicKeyString(key.publicKey)
    }

    public func proof(challenge: String, serverId: String) -> RemoteIdentityProof? {
        guard !challenge.isEmpty, !serverId.isEmpty, let key = privateKey() else { return nil }
        return RemoteIdentityCrypto.sign(serverId: serverId, challenge: challenge, with: key)
    }

    public func redeemProof(code: String, serverId: String) -> String? {
        guard !code.isEmpty, !serverId.isEmpty, let key = privateKey() else { return nil }
        return RemoteIdentityCrypto.signRedeem(serverId: serverId, code: code, with: key)
    }

    public func signApproval(_ payload: ApprovalPayload, reply: Bool) -> String? {
        let transcript = ApprovalWire.bytes(payload, reply: reply)
        guard !transcript.isEmpty, let key = privateKey(),
              let signature = try? key.signature(for: transcript)
        else { return nil }
        return signature.base64EncodedString()
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
