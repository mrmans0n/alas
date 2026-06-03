import Foundation

/// Errors surfaced by the remote-control server layer — the WebSocket frame
/// codec, HTTP request parser, pairing service, and connection handling.
enum RemoteServerError: Error, Equatable {
    case protocolViolation(String)
    case unauthorized
    case badRequest(String)
}
