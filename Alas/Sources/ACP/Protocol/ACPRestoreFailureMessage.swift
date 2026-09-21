import Foundation

/// JSON-RPC "Invalid params" (-32602) returned by `session/load`,
/// `session/resume`, or `session/fork` when the request no longer matches
/// the session's stored state — most commonly a `cwd` that differs from
/// where the session was created (OpenCode v2). Surfacing the agent's own
/// message beats the generic "could not be restored" text because it says
/// exactly what's wrong.
enum ACPRestoreFailureMessage {
    private static let invalidParamsCode = -32602

    static func invalidParamsMessage(from error: any Error) -> String? {
        switch error {
        case let error as JSONRPCError where error.code == invalidParamsCode:
            return error.message
        case ACPClientError.jsonrpc(let error) where error.code == invalidParamsCode:
            return error.message
        default:
            return nil
        }
    }
}
