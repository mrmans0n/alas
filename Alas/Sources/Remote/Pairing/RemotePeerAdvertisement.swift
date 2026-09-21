import Foundation

/// The optional `peer` object an Alas instance adds to `POST /pair`. Browsers
/// omit it. `counterCode` is a code the redeeming instance minted on itself so
/// the responder can pair back; the responder's own counter-redeem sends nil.
struct RemotePeerAdvertisement: Codable, Equatable, Sendable {
    let serverId: String
    let name: String
    let origins: [String]
    let counterCode: String?
}

/// What the server hands the app after a peer redeemed a code here.
struct RemotePeerPairingRequest: Equatable, Sendable {
    let peerServerId: String
    let peerName: String
    let origins: [String]
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
}
