import Foundation

/// Reads an HTTP response as a bounded byte stream rather than buffering it
/// in full via `URLSession.data(for:)`, which has no byte limit of its own.
/// Used wherever the origin being dialed is attacker-controlled — it
/// travels with a peer's own advertisement, or is one this Mac already
/// stored and dials automatically — since a malicious or compromised
/// endpoint could otherwise make an automatic request consume unbounded
/// memory, or stay occupied indefinitely on a connection that just keeps a
/// trickle of bytes coming.
///
/// The byte cap alone does not bound elapsed time: `timeoutInterval` resets
/// on every chunk received, so an endpoint that sends one byte just inside
/// each interval can keep this running for hours before ever reaching
/// `maxBytes`. `request.timeoutInterval` is therefore raced as an absolute
/// deadline for the whole read, not just relied on as URLSession's own
/// per-chunk timeout — every caller already sets it to the total budget it
/// wants this call to take.
func boundedFetch(_ request: URLRequest, session: URLSession = .shared, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
    try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
        group.addTask {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            var data = Data()
            for try await byte in stream {
                data.append(byte)
                if data.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
            }
            return (data, http)
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(request.timeoutInterval * 1_000_000_000))
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
