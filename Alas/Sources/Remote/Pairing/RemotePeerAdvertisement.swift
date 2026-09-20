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
}
