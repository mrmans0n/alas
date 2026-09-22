import Foundation
import CryptoKit

/// The optional `peer` object an Alas instance adds to `POST /pair`. Browsers
/// omit it. `counterCode` is a code the redeeming instance minted on itself so
/// the responder can pair back; the responder's own counter-redeem sends nil.
struct RemotePeerAdvertisement: Codable, Equatable, Sendable {
    let serverId: String
    let name: String
    let origins: [String]
    let counterCode: String?
    /// The key the sender claims its records should be pinned to. A CLAIM,
    /// not proof: a public key is public, so anyone can name someone else's.
    /// It is only ever used to cross-check what the responder's own pair-back
    /// independently PROVES — a request that advertises one key and whose
    /// endpoint then proves another is refused rather than reconciled.
    /// Absent from an older peer's advertisement.
    let publicKey: String?

    init(serverId: String, name: String, origins: [String], counterCode: String?,
         publicKey: String? = nil) {
        self.serverId = serverId
        self.name = name
        self.origins = origins
        self.counterCode = counterCode
        self.publicKey = publicKey
    }

    /// Whether an advertised key could be a real Ed25519 public key at all.
    /// Nil passes: an older peer advertises none, and the record it produces
    /// is simply left unverified.
    static func isPlausiblePublicKey(_ value: String?) -> Bool {
        guard let value else { return true }
        guard let raw = Data(base64Encoded: value) else { return false }
        return (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil
    }
}

/// What the server hands the app after a peer redeemed a code here.
struct RemotePeerPairingRequest: Equatable, Sendable {
    let peerServerId: String
    let peerName: String
    let origins: [String]
    /// The key the redeeming peer claimed, carried through unverified. The
    /// responder's own pair-back is what turns it into proof.
    let peerPublicKey: String?
    let counterCode: String?
    /// The `RemoteDevice.id` just created for the peer on this Mac.
    let localDeviceId: String
    /// The code this exchange redeemed — the counter-code the corresponding
    /// `addPeer` attempt minted on itself, when this request is that
    /// attempt's own reciprocal callback arriving. Ties a confirmation to
    /// the ONE attempt it actually belongs to: a `serverId` alone cannot
    /// distinguish a stray, unrelated attempt's callback (one whose own
    /// `/pair` reply never made it back) from the current attempt's own.
    let redeemedCode: String

    init(peerServerId: String, peerName: String, origins: [String],
         peerPublicKey: String? = nil, counterCode: String?,
         localDeviceId: String, redeemedCode: String) {
        self.peerServerId = peerServerId
        self.peerName = peerName
        self.origins = origins
        self.peerPublicKey = peerPublicKey
        self.counterCode = counterCode
        self.localDeviceId = localDeviceId
        self.redeemedCode = redeemedCode
    }
}
