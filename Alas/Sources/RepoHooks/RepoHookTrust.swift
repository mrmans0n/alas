import CryptoKit
import Foundation

enum RepoHookTrust {
    private static let version = "alas-repo-hook-trust-v1"

    static func hash(event: RepoHookEvent, bytes: Data) -> String {
        var payload = Data("\(version)\u{0}\(event.rawValue)\u{0}".utf8)
        payload.append(bytes)
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
