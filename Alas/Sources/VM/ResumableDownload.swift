import Foundation

/// Streams a large file into `<destination>.partial`, resuming with an HTTP
/// Range request when a partial file already exists, and renames it into place
/// once complete. All mutable state is confined to the session's serial
/// delegate queue. `label` names the file in errors ("restore image").
final class ResumableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partial: URL
    private let label: String
    private let onProgress: @Sendable (Double) -> Void
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private var handle: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var lastReported: Double = -1
    private var failure: Error?
    private var rangeNotSatisfiable = false
    private var continuation: CheckedContinuation<Void, Error>?

    private init(partial: URL, label: String, onProgress: @escaping @Sendable (Double) -> Void) {
        self.partial = partial
        self.label = label
        self.onProgress = onProgress
    }

    private var capitalizedLabel: String { label.prefix(1).uppercased() + label.dropFirst() }

    static func run(
        from url: URL, to destination: URL, label: String = "restore image",
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let partial = destination.appendingPathExtension("partial")
        let download = ResumableDownload(partial: partial, label: label, onProgress: onProgress)
        let complete = try await download.fetch(url)
        if !complete {
            // The server rejected our range (the partial file is stale or
            // longer than the resource): start over once from scratch.
            try? FileManager.default.removeItem(at: partial)
            guard try await ResumableDownload(partial: partial, label: label, onProgress: onProgress).fetch(url) else {
                throw GoldenImageInstaller.InstallerError(message: "The \(label) server rejected the download")
            }
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    /// Returns false when the server answered 416 to a resume request.
    private func fetch(_ url: URL) async throws -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: partial.path) {
            guard fm.createFile(atPath: partial.path, contents: nil) else {
                throw GoldenImageInstaller.InstallerError(message: "Could not create \(partial.path)")
            }
        }
        let existing = (try fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
        var request = URLRequest(url: url)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    self.continuation = continuation
                    self.received = existing
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
        return !rangeNotSatisfiable
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch status {
            case 206:
                let handle = try FileHandle(forWritingTo: partial)
                try handle.seekToEnd()
                self.handle = handle
                if response.expectedContentLength >= 0 {
                    expected = received + response.expectedContentLength
                }
            case 200:
                let handle = try FileHandle(forWritingTo: partial)
                try handle.truncate(atOffset: 0)
                self.handle = handle
                received = 0
                expected = response.expectedContentLength
            case 416:
                rangeNotSatisfiable = true
                completionHandler(.cancel)
                return
            default:
                throw GoldenImageInstaller.InstallerError(message: "\(capitalizedLabel) download failed with HTTP \(status)")
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        guard expected > 0 else { return }
        let fraction = min(Double(received) / Double(expected), 1)
        if fraction - lastReported >= 0.001 {
            lastReported = fraction
            onProgress(fraction)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let continuation = continuation
        self.continuation = nil
        if rangeNotSatisfiable {
            continuation?.resume()
        } else if let failure = failure ?? error {
            continuation?.resume(throwing: failure)
        } else if expected >= 0, received != expected {
            continuation?.resume(throwing: GoldenImageInstaller.InstallerError(
                message: "\(capitalizedLabel) download ended early (\(received) of \(expected) bytes)"))
        } else {
            continuation?.resume()
        }
    }
}
