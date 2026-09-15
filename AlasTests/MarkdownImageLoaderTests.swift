import Testing
import AppKit
import Foundation
@testable import Alas

struct MarkdownImageLoaderTests {
    @Test func loadsLocalRelativeImage() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-md-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("dot.png")
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        img.unlockFocus()
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: imageURL)
        }

        let loader = MarkdownImageLoader()
        let loaded = loader.loadLocal(src: "dot.png", baseDirectory: tmp)
        #expect(loaded != nil)
    }

    @Test func missingLocalImageReturnsNil() {
        let loader = MarkdownImageLoader()
        let baseDir = URL(fileURLWithPath: "/tmp")
        #expect(loader.loadLocal(src: "definitely-not-here-\(UUID().uuidString).png", baseDirectory: baseDir) == nil)
    }

    @Test func classifySrcRemote() {
        switch MarkdownImageLoader.classify("https://example.com/a.png") {
        case .remote(let url): #expect(url.absoluteString == "https://example.com/a.png")
        default: Issue.record("expected .remote for https://")
        }
        switch MarkdownImageLoader.classify("http://example.com/a.png") {
        case .remote(let url): #expect(url.absoluteString == "http://example.com/a.png")
        default: Issue.record("expected .remote for http://")
        }
    }

    @Test func classifySrcLocal() {
        switch MarkdownImageLoader.classify("./a.png") {
        case .local(let s): #expect(s == "./a.png")
        default: Issue.record("expected .local for ./a.png")
        }
        switch MarkdownImageLoader.classify("subdir/image.png") {
        case .local(let s): #expect(s == "subdir/image.png")
        default: Issue.record("expected .local for subdir/image.png")
        }
    }

    @Test func classifySrcEmptyIsInvalid() {
        switch MarkdownImageLoader.classify("") {
        case .invalid: break
        default: Issue.record("expected .invalid for empty string")
        }
    }

    @MainActor
    @Test func remoteLoadsShareInFlightRequest() async throws {
        let imageData = try #require(makePNGData())
        MarkdownImageLoaderURLProtocol.reset(responseData: imageData)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MarkdownImageLoaderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let loader = MarkdownImageLoader(session: session)
        let url = try #require(URL(string: "https://example.com/badge.png"))

        let completions = CompletionCounter()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let recordCompletion: @MainActor @Sendable (NSImage?) -> Void = { image in
                #expect(image != nil)
                if completions.increment() == 2 {
                    continuation.resume()
                }
            }

            #expect(loader.loadRemote(url: url, completion: recordCompletion) == nil)
            #expect(loader.loadRemote(url: url, completion: recordCompletion) == nil)
        }

        #expect(MarkdownImageLoaderURLProtocol.requestCount == 1)
        #expect(loader.loadRemote(url: url) { _ in
            Issue.record("cached remote load should return synchronously")
        } != nil)
        #expect(MarkdownImageLoaderURLProtocol.requestCount == 1)
    }

    private func makePNGData() -> Data? {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Response payload and request tally shared by every stub protocol instance.
///
/// Safe under `@unchecked Sendable`: `data` and `count` are only ever read or written
/// inside `lock`.
private final class MarkdownImageLoaderStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var count = 0

    var requestCount: Int {
        lock.withLock { count }
    }

    func reset(responseData: Data) {
        lock.withLock {
            data = responseData
            count = 0
        }
    }

    /// Counts one request and returns the payload to serve for it.
    func consumeRequest() -> Data {
        lock.withLock {
            count += 1
            return data
        }
    }
}

private final class MarkdownImageLoaderURLProtocol: URLProtocol {
    private static let state = MarkdownImageLoaderStubState()

    static var requestCount: Int {
        state.requestCount
    }

    static func reset(responseData: Data) {
        state.reset(responseData: responseData)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let responseData = Self.state.consumeRequest()
        if let url = request.url,
           let response = HTTPURLResponse(
               url: url,
               statusCode: 200,
               httpVersion: nil,
               headerFields: ["Content-Type": "image/png"]
           ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Counts completion callbacks delivered from a concurrently-executing closure.
///
/// Safe under `@unchecked Sendable`: `value` is only ever read or written inside `lock`.
private final class CompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Increments the tally and returns the new count.
    @discardableResult
    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
