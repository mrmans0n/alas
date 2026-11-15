import Crypto
import Foundation

/// Names a pending request by its content, not its wire id, which a fresh
/// follow may change. A permission alert carries it so its Allow or Deny can
/// only answer the request the user saw. The content includes the permission's
/// `toolCallId`, so a repeat of the same command is a different request.
public enum RemoteRequestIdentity {
    /// Hex SHA-256 of the payload's JSON without `requestId`, keys sorted.
    public static func of<P: Encodable>(_ payload: P) -> String? {
        guard let data = try? JSONEncoder().encode(payload),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object["requestId"] = nil
        guard let canonical = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return nil }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}
