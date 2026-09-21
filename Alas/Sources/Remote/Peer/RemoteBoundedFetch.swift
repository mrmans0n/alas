import Foundation

/// Reads an HTTP response as a bounded byte stream rather than buffering it
/// in full via `URLSession.data(for:)`, which has no byte limit of its own.
/// Used wherever the origin being dialed is attacker-controlled — it
/// travels with a peer's own advertisement, or is one this Mac already
/// stored and dials automatically — since a malicious or compromised
/// endpoint could otherwise make an automatic request consume unbounded
/// memory, or stay occupied indefinitely on a connection that just keeps a
/// trickle of bytes coming. The per-request timeout alone does not catch
/// this: it only bounds a stalled connection, not a slow-but-steady one.
func boundedFetch(_ request: URLRequest, session: URLSession = .shared, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
    let (stream, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var data = Data()
    for try await byte in stream {
        data.append(byte)
        if data.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
    }
    return (data, http)
}
