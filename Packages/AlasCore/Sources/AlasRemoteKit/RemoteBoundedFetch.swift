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
public func boundedFetch(_ request: URLRequest, session: URLSession = .shared, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
    try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
        group.addTask {
            #if canImport(FoundationNetworking)
            return try await BoundedDataTask(request: request, configuration: session.configuration, maxBytes: maxBytes).run()
            #else
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            var data = Data()
            for try await byte in stream {
                data.append(byte)
                if data.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
            }
            return (data, http)
            #endif
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(request.timeoutInterval * 1_000_000_000))
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

#if canImport(FoundationNetworking)
/// Linux's URLSession has no `bytes(for:)`; a delegate sees each chunk as it
/// arrives instead and cancels the task once the cap is passed.
private final class BoundedDataTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let maxBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    init(request: URLRequest, configuration: URLSessionConfiguration, maxBytes: Int) {
        self.request = request
        self.configuration = configuration
        self.maxBytes = maxBytes
    }

    func run() async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let over = lock.withLock {
            data.append(chunk)
            return data.count > maxBytes
        }
        if over {
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else if let http = task.response as? HTTPURLResponse {
            finish(.success((lock.withLock { data }, http)))
        } else {
            finish(.failure(URLError(.badServerResponse)))
        }
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
#endif
