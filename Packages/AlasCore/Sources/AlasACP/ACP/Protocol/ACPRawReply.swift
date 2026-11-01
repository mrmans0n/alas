import Foundation
import AlasCode
import AlasFoundation
import AlasPlatform

public enum ACPRawReply {
    /// Validates a single newline-framed response without re-encoding its bytes.
    public static func validateFrame(_ frame: Data) throws -> JSONRPCID {
        do {
            guard !frame.contains(10), !frame.contains(13),
                  case .object(let fields) = try LSPJSONValue.decode(from: frame),
                  fields["jsonrpc"] == .string("2.0"), fields["method"] == nil,
                  (fields["result"] == nil) != (fields["error"] == nil),
                  let rawID = fields["id"], let id = exactID(rawID) else {
                throw ACPBrokerRawReplyError.rejected(.invalid)
            }
            if let rawError = fields["error"] {
                guard case .object(let error) = rawError, let code = error["code"],
                      case .number(let token) = code, Int32(token) != nil,
                      case .string? = error["message"] else { throw ACPBrokerRawReplyError.rejected(.invalid) }
            }
            return id
        } catch { throw ACPBrokerRawReplyError.rejected(.invalid) }
    }
    private static func exactID(_ value: LSPJSONValue) -> JSONRPCID? {
        switch value {
        case .string(let id): return .string(id)
        case .number(let token): return Int(token).map(JSONRPCID.number)
        default: return nil
        }
    }
}
