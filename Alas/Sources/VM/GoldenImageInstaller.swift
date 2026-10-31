import AlasCore
import Foundation
import Virtualization
import os

/// Downloads the latest supported macOS restore image and installs it into a
/// golden VM bundle under `vmsRoot/golden/<build>/`, then sets it up and
/// seals it without the user through `GoldenProvisioner`. When that cannot
/// finish, the user finishes Setup Assistant inside the golden VM, then
/// `markSetupDone()` seals the bundle so worktree VMs can clone it.
@MainActor
final class GoldenImageInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case installing(Double)
        /// The unattended setup is running on the installed golden.
        case provisioning(step: ProvisioningStep)
        case awaitingSetup(build: String)
        case sealed(build: String)
        case failed(String)
    }

    enum ProvisioningStep: Equatable, Sendable {
        case firstBoot, patching, finishing, verifying, shuttingDown

        /// The progress line the VM tab shows.
        var title: String {
            switch self {
            case .firstBoot: "Preparing macOS: first boot…"
            case .patching, .finishing: "Preparing macOS: setting up the user and helper…"
            case .verifying: "Preparing macOS: checking the helper…"
            case .shuttingDown: "Preparing macOS: finishing…"
            }
        }
    }

    struct InstallerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var phase: Phase = .idle
    /// Why the unattended setup gave up, shown above the manual setup
    /// instructions while the golden awaits setup.
    @Published private(set) var failureNote: String?
    /// The macOS build being installed or set up, once known.
    @Published private(set) var setupBuild: String?
    /// Cancel was asked for and the running setup is winding down.
    @Published private(set) var cancelling = false

    /// The note for a provisioning run the user cancelled.
    static let cancelledNote = "Automatic setup was cancelled. Finish it by hand or click Set up automatically."

    private static let diskImageSize: UInt64 = 64 << 30
    private nonisolated static let partialSuffix = ".partial"

    private let root: URL
    /// Writes the bundle's sealed marker. The app routes it through
    /// `WorktreeVMManager.sealGolden`, which checks and writes under the
    /// registry lock so no Alas process can boot the golden meanwhile.
    private let seal: (VMBundle) throws -> Void
    /// Sets up an installed golden without the user. Nil leaves every
    /// install to the manual setup.
    private let provisioner: GoldenProvisioner?
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "golden-image-installer")
    private var installProgressObservation: NSKeyValueObservation?
    /// The running `start()`, so `cancelSetup()` can cancel it.
    private var setupTask: Task<Void, Never>?

    init(
        root: URL = Paths.vmsRoot,
        seal: @escaping (VMBundle) throws -> Void = GoldenImageInstaller.writeSealedMarker,
        provisioner: GoldenProvisioner? = nil
    ) {
        self.root = root
        self.seal = seal
        self.provisioner = provisioner
        phase = Self.settledPhase(in: Self.goldenRoot(in: root)) ?? .idle
    }

    /// Re-reads a settled phase from disk, which another Alas process may
    /// have changed (sealing the golden image, say). Leaves an install in
    /// progress alone, and a failure message unless a golden awaits setup.
    func reloadFromDisk() {
        let onDisk = Self.settledPhase(in: goldenRoot) ?? .idle
        switch phase {
        case .downloading, .installing, .provisioning: return
        case .failed:
            // A stale failure would hide an installed golden that still
            // needs its setup finished.
            guard case .awaitingSetup = onDisk else { return }
        case .idle, .awaitingSetup, .sealed: break
        }
        if onDisk != phase { phase = onDisk }
        if case .awaitingSetup = onDisk {} else { failureNote = nil }
    }

    /// The phase an earlier launch left on disk: the newest installed golden
    /// is either sealed or still awaiting setup. Nil when none is installed.
    private nonisolated static func settledPhase(in goldenRoot: URL) -> Phase? {
        guard let newest = goldenBundles(in: goldenRoot).last else { return nil }
        let build = newest.url.lastPathComponent
        return newest.isSealed ? .sealed(build: build) : .awaitingSetup(build: build)
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

    /// Completed golden bundles under `root`, oldest build first.
    nonisolated static func goldenBundles(root: URL) -> [VMBundle] {
        goldenBundles(in: goldenRoot(in: root))
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

    /// Installs the newest macOS and sets it up unattended. An installed
    /// golden still awaiting setup (after a relaunch or a fallback) is
    /// set up again from its first boot, never redownloaded.
    func start() async {
        // The work runs in its own task so `cancelSetup()` cancels it and
        // not the caller's.
        guard setupTask == nil else { return }
        let task = Task { await setUp() }
        setupTask = task
        await task.value
        setupTask = nil
        cancelling = false
    }

    /// Stops a download, install or unattended setup in progress. A
    /// download keeps its partial restore image for the next Set up; an
    /// interrupted install is discarded; an unattended setup leaves the
    /// golden stopped and awaiting the manual setup.
    func cancelSetup() {
        guard let setupTask, !cancelling else { return }
        cancelling = true
        setupTask.cancel()
    }

    private func setUp() async {
        #if !arch(arm64)
        phase = .failed(WorktreeVMManager.unsupportedMessage)
        #else
        switch phase {
        case .downloading, .installing, .provisioning: return
        default: break
        }
        // An installed golden still awaiting setup is resumed, never replaced
        // by a newer download that would orphan it.
        var resuming: String?
        if case .awaitingSetup(let build)? = Self.settledPhase(in: goldenRoot) {
            // One reopened by Customize holds the user's changes: only the
            // manual flow finishes it.
            let customizing = WorktreeVMManager.customizingMarker(
                of: VMBundle(url: goldenRoot.appendingPathComponent(build, isDirectory: true)))
            guard provisioner != nil, !FileManager.default.fileExists(atPath: customizing.path) else {
                phase = .awaitingSetup(build: build)
                return
            }
            resuming = build
        }
        // Held through download, install, publication and the unattended
        // setup so two Alas processes never install or patch at once, or
        // drop each other's partial bundle. The kernel releases it if this
        // process dies.
        let installLock: ComputerUseDriverLock
        do {
            installLock = try ComputerUseDriverLock.acquire(
                at: root.appendingPathComponent("install.lock"), label: WorktreeVMManager.defaultOwnerLabel)
        } catch {
            let message: String
            switch error {
            case .held:
                message = "macOS is being set up in another Alas."
            case .unavailable(let reason):
                logger.error("Golden image install lock unavailable: \(reason, privacy: .public)")
                message = "macOS cannot be set up: \(reason)"
            }
            // An installed golden keeps its setup screen, with the reason as
            // its note: a failure would give way to it on the next reload.
            if let resuming {
                failureNote = message
                phase = .awaitingSetup(build: resuming)
            } else {
                phase = .failed(message)
            }
            return
        }
        defer { installLock.release() }
        failureNote = nil
        setupBuild = resuming
        defer { setupBuild = nil }
        let build: String? = if let resuming { resuming } else { await install() }
        if let build { await provision(build: build) }
        #endif
    }

    #if arch(arm64)
    /// Downloads and installs the newest macOS. Returns the build to set up,
    /// or nil when the phase is already settled (sealed or failed).
    private func install() async -> String? {
        phase = .downloading(0)
        var partialBundle: URL?
        do {
            try removeStalePartialBundles()
            let image = try await VZMacOSRestoreImage.latestSupported
            try Task.checkCancellation()
            let build = image.buildVersion
            setupBuild = build
            let bundleURL = goldenRoot.appendingPathComponent(build, isDirectory: true)
            if FileManager.default.fileExists(atPath: bundleURL.path) {
                guard VMBundle(url: bundleURL).isSealed else { return build }
                phase = .sealed(build: build)
                return nil
            }
            guard let requirements = image.mostFeaturefulSupportedConfiguration,
                  requirements.hardwareModel.isSupported
            else {
                throw InstallerError(message: "macOS \(image.operatingSystemVersion.majorVersion) (\(build)) cannot run in a VM on this Mac")
            }

            let ipsw = try await downloadRestoreImage(from: image.url, build: build)
            try Task.checkCancellation()
            try await validateRestoreImage(at: ipsw, build: build)
            try Task.checkCancellation()

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
            do {
                try await install(configuration: configuration, restoreImage: ipsw)
                try Task.checkCancellation()
            } catch let error as VZError where !Task.isCancelled && Self.restoreImageErrors.contains(error.code) {
                discardRestoreImage(at: ipsw)
                throw InstallerError(message: "The macOS restore image could not be installed (\(error.localizedDescription)). Click Set up to download it again.")
            }

            try FileManager.default.moveItem(at: partial, to: bundleURL)
            partialBundle = nil
            logger.info("Installed golden macOS \(build, privacy: .public)")
            return build
        } catch {
            installProgressObservation = nil
            if let partialBundle { try? FileManager.default.removeItem(at: partialBundle) }
            // A cancelled download surfaces as URLError.cancelled, an
            // install as Virtualization's own error: the task says which.
            if Task.isCancelled {
                logger.info("Golden image install cancelled")
                phase = Self.settledPhase(in: goldenRoot) ?? .idle
                return nil
            }
            logger.error("Golden image install failed: \(String(describing: error), privacy: .public)")
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Runs the unattended setup on the installed `build`; whatever it cannot
    /// finish is left to the manual setup, with a note saying why.
    private func provision(build: String) async {
        guard let provisioner else {
            phase = .awaitingSetup(build: build)
            return
        }
        let bundle = VMBundle(url: goldenRoot.appendingPathComponent(build, isDirectory: true))
        phase = .provisioning(step: .firstBoot)
        let outcome = await provisioner.run(bundle: bundle) { [weak self] step in
            self?.phase = .provisioning(step: step)
        }
        switch outcome {
        case .sealed:
            failureNote = nil
            phase = .sealed(build: build)
        case .fallback(let reason):
            failureNote = "Automatic setup couldn't finish (\(reason))."
            phase = .awaitingSetup(build: build)
        case .cancelled:
            failureNote = Self.cancelledNote
            phase = .awaitingSetup(build: build)
        }
    }
    #endif

    /// Seals the golden bundle awaiting setup (or, after a relaunch, the newest
    /// unsealed one). The golden VM must be stopped so its disk is consistent;
    /// `seal` refuses otherwise.
    func markSetupDone() throws {
        let bundle: VMBundle
        if case .awaitingSetup(let build) = phase {
            bundle = VMBundle(url: goldenRoot.appendingPathComponent(build, isDirectory: true))
        } else if let unsealed = Self.goldenBundles(in: goldenRoot).last(where: { !$0.isSealed }) {
            bundle = unsealed
        } else {
            throw InstallerError(message: "No golden VM is awaiting setup")
        }
        try seal(bundle)
        failureNote = nil
        phase = .sealed(build: bundle.url.lastPathComponent)
    }

    nonisolated static func writeSealedMarker(_ bundle: VMBundle) throws {
        try Data(bundle.url.lastPathComponent.utf8).write(to: bundle.sealedMarker, options: .atomic)
    }

    #if arch(arm64)
    /// Install errors that blame the restore image itself, so the cached
    /// download must not be reused.
    private static let restoreImageErrors: Set<VZError.Code> = [.restoreImageLoadFailed, .invalidRestoreImage]

    /// A cached or freshly downloaded IPSW that does not load (truncated,
    /// corrupt, or for another build) is deleted so the next Set up
    /// downloads it again instead of failing the same way forever.
    private func validateRestoreImage(at ipsw: URL, build: String) async throws {
        let loadedBuild: String
        do {
            loadedBuild = try await withCheckedThrowingContinuation { continuation in
                VZMacOSRestoreImage.load(from: ipsw) { result in
                    continuation.resume(with: result.map(\.buildVersion))
                }
            }
        } catch {
            discardRestoreImage(at: ipsw)
            throw InstallerError(message: "The downloaded macOS restore image is damaged (\(error.localizedDescription)). Click Set up to download it again.")
        }
        guard loadedBuild == build else {
            discardRestoreImage(at: ipsw)
            throw InstallerError(message: "The downloaded macOS restore image is build \(loadedBuild), not \(build). Click Set up to download it again.")
        }
    }

    private func discardRestoreImage(at ipsw: URL) {
        do {
            try FileManager.default.removeItem(at: ipsw)
        } catch {
            logger.error("Removing restore image \(ipsw.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Interrupted installs leave `<build>.partial` bundles; they are never
    /// resumable, so drop them before starting over. Only call this holding
    /// the install lock: another process's partial bundle is live.
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
        // Cancelling the installer's progress aborts the install.
        nonisolated(unsafe) let progress = installer.progress
        try await withTaskCancellationHandler {
            try await installer.install()
        } onCancel: {
            progress.cancel()
        }
    }
    #endif
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
