import CryptoKit
import Foundation
import Synchronization

protocol NextPromptModelTransport: Sendable {
    /// Return only after all writes have stopped, including on cancellation.
    func download(_ url: URL, into sink: NextPromptModelSink) async throws
}

final class NextPromptModelSink: Sendable {
    private struct State {
        var hash = SHA256()
        var received: Int64 = 0
        var reported: Int64 = 0
    }
    private let state = Mutex(State())
    private let handle: FileHandle
    private let asset: NextPromptModelAsset
    private let progress: @Sendable (Int64) -> Void

    init(handle: FileHandle, asset: NextPromptModelAsset, progress: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle
        self.asset = asset
        self.progress = progress
    }

    func receive(_ data: Data) throws {
        let received = try state.withLock { value -> Int64? in
            guard Int64(data.count) <= asset.bytes - value.received else { throw NextPromptModelFailure.integrity }
            try handle.write(contentsOf: data)
            value.hash.update(data: data)
            value.received += Int64(data.count)
            guard value.received == asset.bytes || value.received - value.reported >= 1024 * 1024 else { return nil }
            value.reported = value.received
            return value.received
        }
        if let received { progress(received) }
    }

    func finish() throws {
        try state.withLock { value in
            let digest = value.hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard value.received == asset.bytes, digest == asset.sha256 else { throw NextPromptModelFailure.integrity }
            try handle.synchronize()
        }
    }
}

struct NextPromptModelDownload: NextPromptModelTransport {
    let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    static func validate(_ url: URL) throws {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              ["huggingface.co", "us.aws.cdn.hf.co"].contains(url.host ?? "") else {
            throw NextPromptModelFailure.network
        }
        let model = NextPromptModelManifest.pinnedModel
        let revision = NextPromptModelManifest.pinnedRevision
        if url.host == "huggingface.co" {
            let prefixes = ["/\(model)/resolve/\(revision)/", "/api/resolve-cache/models/\(model)/\(revision)/"]
            guard prefixes.contains(where: { url.path.hasPrefix($0) && !url.path.dropFirst($0.count).contains("/") && !url.lastPathComponent.isEmpty }) else {
                throw NextPromptModelFailure.network
            }
        } else {
            // Exact paths observed by HEAD at the pinned revision. These are Xet object IDs,
            // not SHA-256 file digests; the sink separately verifies the manifest digest.
            let prefix = "/xet-bridge-us/68939c367fb5d97aea556aa6/"
            let objects = ["4ae82815c30780b930535c80899215a15651b182544ed87eda312d596abd6983",
                           "6aec39639a0a2d1ca966356b8c2b8426a484f80ff80731f44fa8482040713bdf"]
            guard objects.contains(where: { url.path == prefix + $0 }) else { throw NextPromptModelFailure.network }
        }
    }

    static func validateStatus(_ status: Int) throws {
        guard status == 200 else { throw NextPromptModelFailure.network }
    }

    func download(_ url: URL, into sink: NextPromptModelSink) async throws {
        try Self.validate(url)
        try await Transfer(sink: sink, configuration: configuration).run(url)
    }

    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Control {
            var task: URLSessionDataTask?
            var cancelled = false
        }
        private let control = Mutex(Control())
        private let sink: NextPromptModelSink
        private let configuration: URLSessionConfiguration
        // These properties are accessed only on the serial delegate queue after run starts.
        private var continuation: CheckedContinuation<Void, Error>?
        private var failure: Error?
        private var accepted = false

        init(sink: NextPromptModelSink, configuration: URLSessionConfiguration) {
            self.sink = sink
            self.configuration = configuration.copy() as! URLSessionConfiguration
        }

        func run(_ url: URL) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    let configuration = self.configuration
                    configuration.httpAdditionalHeaders = nil
                    configuration.httpCookieStorage = nil
                    configuration.httpShouldSetCookies = false
                    configuration.urlCredentialStorage = nil
                    configuration.urlCache = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    configuration.timeoutIntervalForRequest = 60
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    var request = URLRequest(url: url)
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    let task = session.dataTask(with: request)
                    control.withLock { value in
                        value.task = task
                        if value.cancelled { task.cancel() }
                        task.resume()
                    }
                }
            } onCancel: {
                self.control.withLock { value in
                    value.cancelled = true
                    value.task?.cancel()
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            do {
                guard let url = request.url else { throw NextPromptModelFailure.network }
                try NextPromptModelDownload.validate(url)
                // Rebuild the request so credentials and cookies cannot cross a redirect.
                var clean = URLRequest(url: url)
                clean.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                completionHandler(clean)
            } catch {
                failure = error
                completionHandler(nil)
                task.cancel()
            }
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                              ? .performDefaultHandling : .rejectProtectionSpace, nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            do {
                guard let response = response as? HTTPURLResponse else { throw NextPromptModelFailure.network }
                try NextPromptModelDownload.validateStatus(response.statusCode)
                accepted = true
                completionHandler(.allow)
            } catch {
                failure = error
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil, accepted else { return }
            do { try sink.receive(data) }
            catch { failure = error; dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            // URLSession invokes completion after the serial queue has drained all data callbacks.
            session.finishTasksAndInvalidate()
            control.withLock { $0.task = nil }
            if let error = failure ?? error { continuation?.resume(throwing: error) }
            else if !accepted { continuation?.resume(throwing: NextPromptModelFailure.network) }
            else { continuation?.resume() }
            continuation = nil
        }
    }
}
