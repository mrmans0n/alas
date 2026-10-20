import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

/// Errors surfaced by the remote-control server layer — the WebSocket frame
/// codec, HTTP request parser, pairing service, and connection handling.
public enum RemoteServerError: Error, Equatable, Sendable {
    case protocolViolation(String)
    case unauthorized
    case badRequest(String)
}
