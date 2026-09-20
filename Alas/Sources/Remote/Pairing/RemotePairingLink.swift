import Foundation

/// The string encoded in the pairing QR and copied by "Copy pairing link":
///
///     http://<preferred-host>:<port>/?code=<CODE>&hosts=<origin1>,<origin2>,…
///
/// A fresh phone scanning it lands on `base` and pairs as before; a hub
/// pastes it and tries every origin in `hosts` in order, preferred first.
enum RemotePairingLink {
    static func build(base: String, code: String, addresses: [RemoteAdvertisedAddress]) -> String {
        var origins = [base]
        for address in addresses where !origins.contains(address.url) {
            origins.append(address.url)
        }
        let hosts = origins.map(encodeOrigin).joined(separator: ",")
        return "\(base)/?code=\(code)&hosts=\(hosts)"
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything outside RFC 3986 unreserved characters, so
    /// the comma separating origins is never ambiguous.
    static func encodeOrigin(_ origin: String) -> String {
        origin.addingPercentEncoding(withAllowedCharacters: unreserved) ?? origin
    }
}
