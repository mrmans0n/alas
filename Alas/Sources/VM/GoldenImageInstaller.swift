import AlasCore
import Foundation
import Virtualization
import os

/// Downloads the latest supported macOS restore image and installs it into a
/// golden VM bundle under `vmsRoot/golden/<build>/`. The user finishes Setup
/// Assistant inside the golden VM, then `markSetupDone()` seals the bundle so
/// worktree VMs can clone it.
@MainActor
final class GoldenImageInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case installing(Double)
        case awaitingSetup(build: String)
        case sealed(build: String)
        case failed(String)
    }

    struct InstallerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var phase: Phase = .idle

    private static let diskImageSize: UInt64 = 64 << 30
    private nonisolated static let partialSuffix = ".partial"

    private let root: URL
    private let isGoldenRunning: () -> Bool
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "golden-image-installer")
    private var installProgressObservation: NSKeyValueObservation?

    init(root: URL = Paths.vmsRoot, isGoldenRunning: @escaping () -> Bool = { false }) {
        self.root = root
        self.isGoldenRunning = isGoldenRunning
    }

    private nonisolated static func goldenRoot(in root: URL) -> URL {
        root.appendingPathComponent("golden", isDirectory: true)
    }

    private var goldenRoot: URL { Self.goldenRoot(in: root) }
    private var ipswRoot: URL { root.appendingPathComponent("ipsw", isDirectory: true) }

    /// The newest sealed golden bundle, or nil when none has finished setup.
    nonisolated static func availableGolden(root: URL = Paths.vmsRoot) -> VMBundle? {
        goldenBundles(in: goldenRoot(in: root)).last { $0.isSealed }
    }

    /// Completed (non-partial) golden bundles, oldest build first.
    private nonisolated static func goldenBundles(in goldenRoot: URL) -> [VMBundle] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: goldenRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter { url in
                !url.lastPathComponent.hasSuffix(partialSuffix)
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
            .map(VMBundle.init(url:))
    }

    func start() async {
        switch phase {
        case .downloading, .installing: return
        default: break
        }
        phase = .downloading(0)
        var partialBundle: URL?
        do {
            try removeStalePartialBundles()
            let image = try await VZMacOSRestoreImage.latestSupported
            let build = image.buildVersion
            let bundleURL = goldenRoot.appendingPathComponent(build, isDirectory: true)
            if FileManager.default.fileExists(atPath: bundleURL.path) {
                phase = VMBundle(url: bundleURL).isSealed ? .sealed(build: build) : .awaitingSetup(build: build)
                return
            }
            guard let requirements = image.mostFeaturefulSupportedConfiguration,
                  requirements.hardwareModel.isSupported
            else {
                throw InstallerError(message: "macOS \(image.operatingSystemVersion.majorVersion) (\(build)) cannot run in a VM on this Mac")
            }

            let ipsw = try await downloadRestoreImage(from: image.url, build: build)

            phase = .installing(0)
            let partial = goldenRoot.appendingPathComponent(build + Self.partialSuffix, isDirectory: true)
            partialBundle = partial
            let bundle = try createBundle(at: partial, hardwareModel: requirements.hardwareModel)
            let defaults = VMConfigurationFactory.defaultResources(
                hostCPUs: ProcessInfo.processInfo.processorCount,
                hostMemory: ProcessInfo.processInfo.physicalMemory)
            let configuration = try VMConfigurationFactory.macOS(
                bundle: bundle,
                cpuCount: max(defaults.cpus, requirements.minimumSupportedCPUCount),
                memoryBytes: max(defaults.memory, requirements.minimumSupportedMemorySize),
                display: .default)
            try await install(configuration: configuration, restoreImage: ipsw)

            try FileManager.default.moveItem(at: partial, to: bundleURL)
            partialBundle = nil
            logger.info("Installed golden macOS \(build, privacy: .public)")
            phase = .awaitingSetup(build: build)
        } catch {
            installProgressObservation = nil
            if let partialBundle { try? FileManager.default.removeItem(at: partialBundle) }
            logger.error("Golden image install failed: \(String(describing: error), privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Seals the golden bundle awaiting setup (or, after a relaunch, the newest
    /// unsealed one). The golden VM must be stopped so its disk is consistent.
    func markSetupDone() throws {
        guard !isGoldenRunning() else {
            throw InstallerError(message: "Shut down the golden VM before marking setup as done")
        }
        let bundle: VMBundle
        if case .awaitingSetup(let build) = phase {
            bundle = VMBundle(url: goldenRoot.appendingPathComponent(build, isDirectory: true))
        } else if let unsealed = Self.goldenBundles(in: goldenRoot).last(where: { !$0.isSealed }) {
            bundle = unsealed
        } else {
            throw InstallerError(message: "No golden VM is awaiting setup")
        }
        let build = bundle.url.lastPathComponent
        try Data(build.utf8).write(to: bundle.sealedMarker, options: .atomic)
        phase = .sealed(build: build)
    }

    /// Interrupted installs leave `<build>.partial` bundles; they are never
    /// resumable, so drop them before starting over.
    private func removeStalePartialBundles() throws {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: goldenRoot, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasSuffix(Self.partialSuffix) {
            try fm.removeItem(at: entry)
        }
    }

    private func downloadRestoreImage(from url: URL, build: String) async throws -> URL {
        let destination = ipswRoot.appendingPathComponent("\(build).ipsw")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try FileManager.default.createDirectory(at: ipswRoot, withIntermediateDirectories: true)
        try await ResumableDownload.run(from: url, to: destination) { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(fraction)
            }
        }
        return destination
    }

    private func createBundle(at url: URL, hardwareModel: VZMacHardwareModel) throws -> VMBundle {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = VMBundle(url: url)
        try hardwareModel.dataRepresentation.write(to: bundle.hardwareModel)
        try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifier)
        try Data(VZMACAddress.randomLocallyAdministered().string.utf8).write(to: bundle.macAddress)
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: bundle.auxiliaryStorage, hardwareModel: hardwareModel, options: [])
        guard fm.createFile(atPath: bundle.diskImage.path, contents: nil) else {
            throw InstallerError(message: "Could not create \(bundle.diskImage.path)")
        }
        // Sparse: truncating up only reserves the logical size on APFS.
        let disk = try FileHandle(forWritingTo: bundle.diskImage)
        defer { try? disk.close() }
        try disk.truncate(atOffset: Self.diskImageSize)
        return bundle
    }

    private func install(configuration: VZVirtualMachineConfiguration, restoreImage: URL) async throws {
        let virtualMachine = VZVirtualMachine(configuration: configuration)
        let installer = VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: restoreImage)
        installProgressObservation = installer.progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                guard let self, case .installing = self.phase else { return }
                self.phase = .installing(fraction)
            }
        }
        defer { installProgressObservation = nil }
        try await installer.install()
    }
}

/// Streams a large file into `<destination>.partial`, resuming with an HTTP
/// Range request when a partial file already exists, and renames it into place
/// once complete. All mutable state is confined to the session's serial
/// delegate queue.
private final class ResumableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partial: URL
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

    private init(partial: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.partial = partial
        self.onProgress = onProgress
    }

    static func run(
        from url: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let partial = destination.appendingPathExtension("partial")
        let download = ResumableDownload(partial: partial, onProgress: onProgress)
        let complete = try await download.fetch(url)
        if !complete {
            // The server rejected our range (the partial file is stale or
            // longer than the resource): start over once from scratch.
            try? FileManager.default.removeItem(at: partial)
            guard try await ResumableDownload(partial: partial, onProgress: onProgress).fetch(url) else {
                throw GoldenImageInstaller.InstallerError(message: "The restore image server rejected the download")
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
                throw GoldenImageInstaller.InstallerError(message: "Restore image download failed with HTTP \(status)")
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
                message: "Restore image download ended early (\(received) of \(expected) bytes)"))
        } else {
            continuation?.resume()
        }
    }
}
