import CryptoKit
import Foundation

/// The APNs collapse id of a session's push, which the phone also uses as
/// the notification's identifier, so a clear ping can remove it. A gateway
/// and the session's origin host derive the same one.
public enum RemotePushID {
    /// base64url, unpadded, of the first 24 bytes of SHA-256 over
    /// `"<originServerId>\0<sessionId>"`: 32 characters.
    public static func collapseId(originServerId: String, sessionId: String) -> String {
        let digest = SHA256.hash(data: Data("\(originServerId)\u{0}\(sessionId)".utf8))
        return Data(digest.prefix(24)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}
