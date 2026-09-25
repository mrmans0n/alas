import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Alas

struct NextPromptModelStoreTests {
    @Test func verifiedInstallAvoidsReplacementDownload() async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        await fixture.store.install()
        let lease = try await fixture.store.acquireVerifiedLease()
        defer { lease.close() }
        #expect(try Data(contentsOf: lease.directory.appendingPathComponent("weights")) == fixture.originalWeights)
        #expect(fixture.transport.requestCount == 0)
    }

    @Test func corruptFreshInstallIsNotLoadableAndRetrySucceeds() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.removeTemporaryRoot() }
        fixture.transport.mode.withLock { $0 = .corrupt }
        await fixture.store.install()
        #expect(await fixture.store.state == .failed(.integrity))
        await #expect(throws: NextPromptModelFailure.self) { try await fixture.store.acquireVerifiedLease() }
        fixture.transport.mode.withLock { $0 = .valid }
        await fixture.store.install()
        let lease = try await fixture.store.acquireVerifiedLease()
        lease.close()
        #expect(await fixture.store.state == .ready)
    }

    @Test func corruptOrMissingInstalledAssetsAreRejected() async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let file = fixture.directory.appendingPathComponent("weights")
        try Data("bad".utf8).write(to: file)
        await #expect(throws: NextPromptModelFailure.self) { try await fixture.store.acquireVerifiedLease() }
        try FileManager.default.removeItem(at: file)
        await fixture.store.inspect()
        #expect(await fixture.store.state == .failed(.integrity))
        fixture.transport.mode.withLock { $0 = .valid }
        await fixture.store.install()
        let lease = try await fixture.store.acquireVerifiedLease()
        #expect(try Data(contentsOf: file) == fixture.originalWeights)
        lease.close()
    }

    @Test func unsafeManifestNeverWrites() async throws {
        for asset in [NextPromptModelAsset(path: "../outside", bytes: 1, sha256: String(repeating: "a", count: 64)),
                      NextPromptModelAsset(path: "weights", bytes: -1, sha256: String(repeating: "a", count: 64)),
                      NextPromptModelAsset(path: "weights", bytes: 1, sha256: String(repeating: "A", count: 64))] {
            let fixture = try ModelStoreFixture(assets: [asset])
            defer { fixture.removeTemporaryRoot() }
            await fixture.store.install()
            #expect(await fixture.store.state == .failed(.invalidManifest))
            #expect(fixture.transport.requestCount == 0)
        }
    }

    @Test func symlinkRootAndLeafAreRejected() async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        let store = NextPromptModelStore(root: link, manifest: fixture.manifest, transport: fixture.transport)
        await store.install()
        #expect(await store.state == .failed(.invalidPath))
        let file = fixture.directory.appendingPathComponent("weights")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.root.appendingPathComponent("unrelated"))
        await #expect(throws: NextPromptModelFailure.self) { try await fixture.store.acquireVerifiedLease() }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("unrelated"), encoding: .utf8) == "keep")
    }

    @Test func oversizedInterruptedAndDiskFullTransfersNeverPublish() async throws {
        for mode in [FixtureTransport.Mode.oversized, .interrupted, .diskFull] {
            let fixture = try ModelStoreFixture()
            defer { fixture.removeTemporaryRoot() }
            fixture.transport.mode.withLock { $0 = mode }
            await fixture.store.install()
            let expected: NextPromptModelFailure = mode == .oversized ? .integrity : mode == .diskFull ? .insufficientSpace : .network
            #expect(await fixture.store.state == .failed(expected))
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        }
    }

    @Test func cancellationDrainsBeforeCleanupAndExplicitRetryWorks() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.removeTemporaryRoot() }
        fixture.transport.mode.withLock { $0 = .waitForCancellation }
        let installation = Task { await fixture.store.install() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !fixture.transport.started.withLock({ $0 }), ContinuousClock.now < deadline { await Task.yield() }
        try #require(fixture.transport.started.withLock { $0 })
        await fixture.store.cancelDownload()
        await installation.value
        #expect(fixture.transport.drained.withLock { $0 })
        #expect(await fixture.store.state == .notInstalled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".staging-") })
        fixture.transport.mode.withLock { $0 = .valid }
        await fixture.store.install()
        #expect(await fixture.store.state == .ready)
    }

    @Test func cancelledReuseReportsRetainedVerifiedRevision() async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        var states = await fixture.store.states().makeAsyncIterator()
        _ = await states.next()
        let installation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await fixture.store.install()
        }
        await installation.value
        #expect(await fixture.store.state == .ready)
        #expect(await states.next() == .ready)
        #expect(fixture.transport.requestCount == 0)
        let lease = try await fixture.store.acquireVerifiedLease()
        defer { lease.close() }
        #expect(try Data(contentsOf: lease.directory.appendingPathComponent("weights")) == fixture.originalWeights)
    }

    @Test func cancelledReplacementReportsRetainedCorruptRevision() async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let retained = Data("corrupt".utf8)
        let file = fixture.directory.appendingPathComponent("weights")
        try retained.write(to: file)
        fixture.transport.mode.withLock { $0 = .waitForCancellation }
        var states = await fixture.store.states().makeAsyncIterator()
        _ = await states.next()
        let installation = Task { await fixture.store.install() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !fixture.transport.started.withLock({ $0 }), ContinuousClock.now < deadline { await Task.yield() }
        try #require(fixture.transport.started.withLock { $0 })
        await fixture.store.cancelDownload()
        await installation.value
        #expect(fixture.transport.drained.withLock { $0 })
        #expect(await fixture.store.state == .failed(.integrity))
        #expect(await states.next() == .failed(.integrity))
        #expect(try Data(contentsOf: file) == retained)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".staging-") })
        await #expect(throws: NextPromptModelFailure.integrity) { try await fixture.store.acquireVerifiedLease() }
    }

    @Test func capacityPreflightAvoidsTransfer() async throws {
        let fixture = try ModelStoreFixture(capacity: { _ in 0 })
        defer { fixture.removeTemporaryRoot() }
        await fixture.store.install()
        #expect(await fixture.store.state == .failed(.insufficientSpace))
        #expect(fixture.transport.requestCount == 0)
    }

    @Test func downloaderRejectsUntrustedRedirectsAndPartialResponses() throws {
        for url in ["http://huggingface.co/file", "https://evil.huggingface.co/file", "https://huggingface.co.evil.test/file", "https://user@huggingface.co/file", "https://us.aws.cdn.hf.co:444/file"] {
            #expect(throws: NextPromptModelFailure.self) { try NextPromptModelDownload.validate(URL(string: url)!) }
        }
        try NextPromptModelDownload.validate(URL(string: "https://us.aws.cdn.hf.co/xet-bridge-us/68939c367fb5d97aea556aa6/4ae82815c30780b930535c80899215a15651b182544ed87eda312d596abd6983?signature=secret")!)
        for url in ["https://huggingface.co/unrelated/repository", "https://us.aws.cdn.hf.co/other-model"] {
            #expect(throws: NextPromptModelFailure.self) { try NextPromptModelDownload.validate(URL(string: url)!) }
        }
        #expect(throws: NextPromptModelFailure.self) { try NextPromptModelDownload.validateStatus(206) }
    }
    @Test func manifestRejectsDuplicateAssetsAndWrongPins() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.removeTemporaryRoot() }
        for manifest in [NextPromptModelManifest(model: "other/model", revision: fixture.manifest.revision, assets: fixture.manifest.assets),
                         NextPromptModelManifest(model: fixture.manifest.model, revision: "main", assets: fixture.manifest.assets),
                         NextPromptModelManifest(model: fixture.manifest.model, revision: fixture.manifest.revision, assets: fixture.manifest.assets + fixture.manifest.assets)] {
            let store = NextPromptModelStore(root: fixture.root, manifest: manifest, transport: fixture.transport)
            await store.install()
            #expect(await store.state == .failed(.invalidManifest))
        }
        #expect(fixture.transport.requestCount == 0)
    }

    @Test func retryCleansOnlyOwnedStagingAndKeepsCorruptRevisionUntilReplacement() async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let before = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.systemFileNumber] as? NSNumber
        let owned = fixture.root.appendingPathComponent(".staging-\(fixture.manifest.revision)-\(UUID().uuidString)")
        let unrelated = fixture.root.appendingPathComponent(".staging-unrelated")
        for url in [owned, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("partial".utf8).write(to: url.appendingPathComponent("partial"))
        }
        try Data("bad".utf8).write(to: fixture.directory.appendingPathComponent("weights"))
        await fixture.store.install()
        #expect(await fixture.store.state == .failed(.integrity))
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("weights")) == Data("bad".utf8))
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("partial").path))
        fixture.transport.mode.withLock { $0 = .valid }
        await fixture.store.install()
        let lease = try await fixture.store.acquireVerifiedLease()
        #expect(lease.generation != before?.uint64Value)
        lease.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter { $0.hasPrefix(".staging-\(fixture.manifest.revision)-") }.isEmpty)
    }

    @Test func symlinkParentAndLockCannotEscapeRoot() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.removeTemporaryRoot() }
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        let store = NextPromptModelStore(root: link.appendingPathComponent("nested"), manifest: fixture.manifest, transport: fixture.transport)
        await store.install()
        #expect(await store.state == .failed(.invalidPath))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("nested").path))
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(".lock"), withDestinationURL: fixture.root.appendingPathComponent("unrelated"))
        await fixture.store.install()
        #expect(await fixture.store.state == .failed(.invalidPath))
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("unrelated"), encoding: .utf8) == "keep")
    }

    @Test func inspectionAndStateStreamDoNotDownload() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.removeTemporaryRoot() }
        var states = await fixture.store.states().makeAsyncIterator()
        #expect(await states.next() == .notInstalled)
        await fixture.store.inspect()
        #expect(await states.next() == .notInstalled)
        #expect(fixture.transport.requestCount == 0)
        await fixture.store.install()
        #expect(await states.next() == .ready)
        try await fixture.store.remove()
        #expect(await states.next() == .notInstalled)
    }

    @Test func nativeSessionBoundsResponsesAndDrainsCancellation() async throws {
        for mode in [ModelURLProtocol.Mode.valid, .partial, .oversized, .interrupted, .redirect, .cancel] {
            let fixture = try ModelStoreFixture()
            defer { fixture.removeTemporaryRoot() }
            ModelURLProtocol.control.withLock { $0 = .init(mode: mode) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ModelURLProtocol.self]
            let store = NextPromptModelStore(root: fixture.root, manifest: fixture.manifest,
                                             transport: NextPromptModelDownload(configuration: configuration))
            let installation = Task { await store.install() }
            if mode == .cancel {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !ModelURLProtocol.control.withLock({ $0.started }), ContinuousClock.now < deadline { await Task.yield() }
                try #require(ModelURLProtocol.control.withLock { $0.started })
                await store.cancelDownload()
            }
            await installation.value
            switch mode {
            case .valid:
                let lease = try await store.acquireVerifiedLease()
                #expect(try Data(contentsOf: lease.directory.appendingPathComponent("weights")) == fixture.originalWeights)
                lease.close()
            case .cancel:
                #expect(ModelURLProtocol.control.withLock { $0.stopped })
                #expect(await store.state == .notInstalled)
            case .oversized: #expect(await store.state == .failed(.integrity))
            default: #expect(await store.state == .failed(.network))
            }
            #expect(ModelURLProtocol.control.withLock { $0.requests } == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".staging-") })
        }
    }

    @Test func progressIsBoundedAcrossSmallNetworkChunks() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.removeTemporaryRoot() }
        let url = fixture.root.appendingPathComponent("progress")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let data = Data(repeating: 1, count: 2 * 1024 * 1024)
        let asset = NextPromptModelAsset(path: "weights", bytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let progress = Mutex<[Int64]>([])
        let sink = NextPromptModelSink(handle: handle, asset: asset) { received in progress.withLock { $0.append(received) } }
        for _ in 0..<2048 { try sink.receive(Data(repeating: 1, count: 1024)) }
        try sink.finish()
        let updates = progress.withLock { $0 }
        #expect(updates == [1_048_576, 2_097_152])
    }
}

struct ModelStoreFixture {
    let root: URL
    let originalWeights = Data("original weights".utf8)
    let manifest: NextPromptModelManifest
    let transport: FixtureTransport
    let store: NextPromptModelStore
    var directory: URL { root.appendingPathComponent(manifest.revision) }

    init(assets: [NextPromptModelAsset]? = nil, capacity: @escaping @Sendable (Int32) throws -> Int64 = { try NextPromptModelStore.availableCapacity($0) }) throws {
        root = URL(fileURLWithPath: "/private/tmp/alas-model-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: root.appendingPathComponent("unrelated"))
        manifest = NextPromptModelManifest(model: NextPromptModelManifest.pinnedModel, revision: NextPromptModelManifest.pinnedRevision,
            assets: assets ?? [.init(path: "weights", bytes: Int64(originalWeights.count), sha256: SHA256.hash(data: originalWeights).map { String(format: "%02x", $0) }.joined())])
        transport = FixtureTransport(bytes: originalWeights)
        store = NextPromptModelStore(root: root, manifest: manifest, transport: transport, capacity: capacity)
    }

    static func verifiedInstall() throws -> Self {
        let fixture = try Self()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false)
        try fixture.originalWeights.write(to: fixture.directory.appendingPathComponent("weights"))
        fixture.transport.mode.withLock { $0 = .corrupt }
        return fixture
    }

    func removeTemporaryRoot() { try? FileManager.default.removeItem(at: root) }
}

final class FixtureTransport: NextPromptModelTransport, Sendable {
    enum Mode: Sendable { case valid, corrupt, oversized, interrupted, diskFull, waitForCancellation }
    let mode = Mutex(Mode.valid)
    let started = Mutex(false)
    let drained = Mutex(false)
    let requests = Mutex(0)
    let bytes: Data
    var requestCount: Int { requests.withLock { $0 } }
    init(bytes: Data) { self.bytes = bytes }
    func download(_ url: URL, into sink: NextPromptModelSink) async throws {
        requests.withLock { $0 += 1 }
        started.withLock { $0 = true }
        defer { drained.withLock { $0 = true } }
        switch mode.withLock({ $0 }) {
        case .valid: try sink.receive(bytes)
        case .corrupt: try sink.receive(Data(repeating: 0, count: bytes.count))
        case .oversized: try sink.receive(bytes + Data([0]))
        case .interrupted:
            try sink.receive(Data(bytes.prefix(1)))
            throw URLError(.networkConnectionLost)
        case .diskFull: throw POSIXError(.ENOSPC)
        case .waitForCancellation:
            try sink.receive(Data(bytes.prefix(1)))
            try await Task.sleep(for: .seconds(60))
        }
    }
}

private final class ModelURLProtocol: URLProtocol {
    enum Mode { case valid, partial, oversized, interrupted, redirect, cancel }
    struct Control {
        let mode: Mode
        var requests = 0
        var started = false
        var stopped = false
    }
    static let control = Mutex(Control(mode: .valid))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.control.withLock { value in
            value.requests += 1
            value.started = true
            return value.mode
        }
        let url = request.url!
        if mode == .redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://unrelated.invalid/model")!), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: mode == .partial ? 206 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let bytes = Data("original weights".utf8)
        client?.urlProtocol(self, didLoad: mode == .oversized ? bytes + Data([0]) : mode == .cancel ? Data(bytes.prefix(1)) : bytes)
        if mode == .cancel { return }
        if mode == .interrupted { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.control.withLock { $0.stopped = true } }
}
