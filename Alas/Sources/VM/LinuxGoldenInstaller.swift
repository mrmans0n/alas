import AlasCore
import CryptoKit
import Foundation
import os
#if arch(arm64)
import Virtualization
#endif

/// Builds the sealed Ubuntu golden image under `vmsRoot/golden-linux/<serial>/`
/// without the user: downloads the pinned cloud image, checks it, converts it
/// to a sparse 64 GiB raw disk, boots it once with a cloud-init seed that sets
/// the guest up and powers it off, boots it again to prove the helper answers,
/// then powers it off and seals it.
///
/// Every step goes through an injected seam, so tests drive the pipeline
/// without downloads, disks or VMs. Waits are bounded on the injected clock.
@MainActor
final class LinuxGoldenInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case converting(Double)
        /// The seeded first start, which sets Ubuntu up and powers it off.
        case firstBoot
        /// The second start, checking the helper answers.
        case verifying
        case sealed(serial: String)
        case failed(String)
    }

    enum Reason {
        static let checksum = "The downloaded Ubuntu image didn't match its checksum. Click Set up to download it again."
        static let firstStart = "Ubuntu didn't finish its first start."
        static let helper = "The Alas helper didn't start in Ubuntu."
        static let shutdown = "Ubuntu didn't shut down cleanly."
        static let vmStart = "The Ubuntu VM couldn't start."
        static let held = "Ubuntu is being set up in another Alas."
    }

    struct InstallerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The pipeline's seams.
    struct Steps {
        /// Downloads the pinned image to the destination, resuming an
        /// earlier partial download. Reports progress from any thread.
        var download: @MainActor (URL, @escaping @Sendable (Double) -> Void) async throws -> Void
        /// Whether the file's SHA-256 is the given hex digest.
        var verify: @MainActor (URL, String) async throws -> Bool
        /// (qcow2, raw destination, size to grow to, progress). Stops when
        /// the calling task is cancelled, leaving no destination behind.
        var convert: @MainActor (URL, URL, UInt64, @escaping @Sendable (Double) -> Void) async throws -> Void
        /// Writes the bundle's EFI variable store, machine identifier and MAC.
        var writeIdentity: @MainActor (LinuxVMBundle) throws -> Void
        /// Writes the cloud-init NoCloud seed ISO.
        var makeSeedISO: @MainActor (URL) async throws -> Void
        /// Boots the bundle headless, with the seed ISO attached when given.
        var boot: @MainActor (LinuxVMBundle, URL?) async throws -> Void
        /// Waits until the guest powers itself off. False when it is still
        /// running after the timeout.
        var waitForSelfPoweroff: @MainActor (Duration) async -> Bool
        var helperHello: @MainActor () async throws -> VMGuestHello
        /// Asks the guest to power off from inside. Does not wait.
        var requestGuestPoweroff: @MainActor () async -> Void
        /// Powers the VM off at once; nothing it ran is sealed.
        var stop: @MainActor () async -> Void
        var seal: @MainActor (LinuxVMBundle) throws -> Void
        var sleep: @MainActor (Duration) async -> Void
        var now: @MainActor () -> ContinuousClock.Instant
    }

    /// The seeded start installs a desktop, so it gets a long bound.
    static let firstStartTimeout: Duration = .seconds(20 * 60)
    static let helperTimeout: Duration = .seconds(180)
    static let helperInterval: Duration = .seconds(3)
    static let shutdownTimeout: Duration = .seconds(120)

    @Published private(set) var phase: Phase = .idle
    /// Cancel was asked for and the running setup is winding down.
    @Published private(set) var cancelling = false

    private nonisolated static let partialSuffix = ".partial"
    private let root: URL
    private let steps: Steps
    private var setupTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "linux-golden-installer")

    init(root: URL = Paths.vmsRoot, steps: Steps? = nil) {
        self.root = root
        self.steps = steps ?? Self.liveSteps()
        phase = Self.availableGolden(root: root).map { .sealed(serial: $0.url.lastPathComponent) } ?? .idle
    }

    private nonisolated static func goldenRoot(in root: URL) -> URL {
        root.appendingPathComponent("golden-linux", isDirectory: true)
    }

    private var goldenRoot: URL { Self.goldenRoot(in: root) }
    private var imageRoot: URL { root.appendingPathComponent("linux-images", isDirectory: true) }

    /// The newest sealed Linux golden bundle, or nil when none is built.
    nonisolated static func availableGolden(root: URL = Paths.vmsRoot) -> LinuxVMBundle? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: goldenRoot(in: root), includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter { !$0.lastPathComponent.hasSuffix(partialSuffix) }
            .map(LinuxVMBundle.init(url:))
            .filter(\.isSealed)
            .max { $0.url.lastPathComponent.compare($1.url.lastPathComponent, options: .numeric) == .orderedAscending }
    }

    nonisolated static func writeSealedMarker(_ bundle: LinuxVMBundle) throws {
        try Data(bundle.url.lastPathComponent.utf8).write(to: bundle.sealedMarker, options: .atomic)
    }

    /// Builds and seals the pinned image's golden, unless it already is.
    func start() async {
        guard setupTask == nil else { return }
        let task = Task { await setUp() }
        setupTask = task
        await task.value
        setupTask = nil
        cancelling = false
    }

    /// Stops the setup in progress. A download keeps its partial file for the
    /// next Set up; anything later is discarded and the VM powered off.
    func cancel() {
        guard let setupTask, !cancelling else { return }
        cancelling = true
        setupTask.cancel()
    }

    private func setUp() async {
        #if !arch(arm64)
        phase = .failed(WorktreeVMManager.unsupportedMessage)
        #else
        let serial = LinuxGoldenImage.serial
        let bundleURL = goldenRoot.appendingPathComponent(serial, isDirectory: true)
        if LinuxVMBundle(url: bundleURL).isSealed {
            phase = .sealed(serial: serial)
            return
        }
        // Held for the whole run so two Alas processes never build at once
        // or drop each other's partial bundle. The kernel releases it if
        // this process dies.
        let lock: ComputerUseDriverLock
        do {
            lock = try ComputerUseDriverLock.acquire(
                at: root.appendingPathComponent("install-linux.lock"), label: WorktreeVMManager.defaultOwnerLabel)
        } catch {
            switch error {
            case .held:
                phase = .failed(Reason.held)
            case .unavailable(let reason):
                logger.error("Linux golden install lock unavailable: \(reason, privacy: .public)")
                phase = .failed("Ubuntu cannot be set up: \(reason)")
            }
            return
        }
        defer { lock.release() }

        let partial = LinuxVMBundle(
            url: goldenRoot.appendingPathComponent(serial + Self.partialSuffix, isDirectory: true))
        var booted = false
        do {
            try removeStaleBundles()
            let image = try await downloadImage(serial: serial)

            phase = .converting(0)
            try FileManager.default.createDirectory(at: partial.url, withIntermediateDirectories: true)
            try await steps.convert(image, partial.diskImage, LinuxGoldenImage.diskSize) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .converting = self.phase else { return }
                    self.phase = .converting(fraction)
                }
            }
            try Task.checkCancellation()
            try steps.writeIdentity(partial)
            let seed = partial.url.appendingPathComponent("seed.iso")
            try await steps.makeSeedISO(seed)
            try Task.checkCancellation()

            phase = .firstBoot
            booted = true
            try await boot(partial, seed: seed)
            guard await steps.waitForSelfPoweroff(Self.firstStartTimeout) else {
                throw InstallerError(message: Reason.firstStart)
            }
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: seed)

            phase = .verifying
            try await boot(partial, seed: nil)
            try await waitForHelper()
            await steps.requestGuestPoweroff()
            guard await steps.waitForSelfPoweroff(Self.shutdownTimeout) else {
                throw InstallerError(message: Reason.shutdown)
            }
            booted = false
            try Task.checkCancellation()

            try FileManager.default.moveItem(at: partial.url, to: bundleURL)
            let golden = LinuxVMBundle(url: bundleURL)
            do {
                try steps.seal(golden)
            } catch {
                // Never leave a complete but unsealed golden behind.
                try? FileManager.default.removeItem(at: bundleURL)
                throw error
            }
            logger.info("Linux golden \(serial, privacy: .public) set up unattended")
            phase = .sealed(serial: serial)
        } catch {
            if booted { await steps.stop() }
            try? FileManager.default.removeItem(at: partial.url)
            if Task.isCancelled {
                logger.info("Linux golden setup cancelled")
                phase = .idle
                return
            }
            logger.error("Linux golden setup failed: \(String(describing: error), privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
        #endif
    }

    /// The cached image for `serial`, downloaded first when missing, and
    /// verified against the pinned checksum. A mismatch deletes it.
    private func downloadImage(serial: String) async throws -> URL {
        let image = imageRoot.appendingPathComponent("\(serial).img")
        phase = .downloading(0)
        if !FileManager.default.fileExists(atPath: image.path) {
            try FileManager.default.createDirectory(at: imageRoot, withIntermediateDirectories: true)
            try await steps.download(image) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(fraction)
                }
            }
            try Task.checkCancellation()
        }
        guard try await steps.verify(image, LinuxGoldenImage.sha256) else {
            try? FileManager.default.removeItem(at: image)
            throw InstallerError(message: Reason.checksum)
        }
        try Task.checkCancellation()
        return image
    }

    /// Boots `bundle`, retrying a start Virtualization refused while the
    /// last VM on it still holds its storage locks, which it releases
    /// asynchronously after a stop.
    private func boot(_ bundle: LinuxVMBundle, seed: URL?) async throws {
        let deadline = steps.now() + GoldenProvisioner.storageLockTimeout
        while true {
            do {
                try await steps.boot(bundle, seed)
                break
            } catch where GoldenProvisioner.isVirtualizationFailure(error) && steps.now() < deadline
                && !Task.isCancelled {
                logger.notice("The Linux golden failed to start (VZError \((error as NSError).code, privacy: .public)), its storage may still be locked; retrying the boot")
                await steps.sleep(GoldenProvisioner.storageLockInterval)
            } catch {
                logger.error("Booting the Linux golden failed: \(String(describing: error), privacy: .public)")
                throw InstallerError(message: Reason.vmStart)
            }
        }
        try Task.checkCancellation()
    }

    /// Waits until the helper answers as the Linux helper able to run commands.
    private func waitForHelper() async throws {
        let ready = await GuestSetupSteps.waitUntil(
            timeout: Self.helperTimeout, interval: Self.helperInterval, sleep: steps.sleep, now: steps.now
        ) {
            guard let hello = try? await steps.helperHello() else { return false }
            return Self.isLinuxHelper(hello)
        }
        try Task.checkCancellation()
        guard ready else { throw InstallerError(message: Reason.helper) }
    }

    nonisolated static func isLinuxHelper(_ hello: VMGuestHello) -> Bool {
        hello.guestKind == "linux" && hello.capabilities?.contains("run") == true
    }

    /// Partial bundles from an interrupted run, and any complete bundle left
    /// unsealed, are never resumed. Only call this holding the install lock.
    private func removeStaleBundles() throws {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: goldenRoot, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasSuffix(Self.partialSuffix)
            || !LinuxVMBundle(url: entry).isSealed {
            try fm.removeItem(at: entry)
        }
    }
}

// MARK: - Live seams

extension LinuxGoldenInstaller {
    /// The pipeline wired to the network, the host's disk tools and a VM this
    /// installer owns. The golden is never in the registry: until it is
    /// sealed it lives in a `.partial` bundle no other path boots.
    static func liveSteps() -> Steps {
        #if arch(arm64)
        let machine = LinuxGoldenMachine()
        #endif
        return Steps(
            download: { destination, progress in
                try await ResumableDownload.run(
                    from: LinuxGoldenImage.url, to: destination, label: "Ubuntu image", onProgress: progress)
            },
            verify: { file, expected in
                try await detached { try sha256Hex(of: file) == expected.lowercased() }
            },
            convert: { source, destination, size, progress in
                try await detached {
                    var lastReported = -1.0
                    try QCOW2Reader(url: source).convertToRaw(at: destination, growTo: size) { fraction in
                        try Task.checkCancellation()
                        if fraction - lastReported >= 0.005 {
                            lastReported = fraction
                            progress(fraction)
                        }
                    }
                }
            },
            writeIdentity: { bundle in
                #if arch(arm64)
                try bundle.writeIdentity()
                #endif
            },
            makeSeedISO: { iso in try await makeSeedISO(at: iso) },
            boot: { bundle, seed in
                #if arch(arm64)
                try await machine.boot(bundle, seed: seed)
                #endif
            },
            waitForSelfPoweroff: { timeout in
                #if arch(arm64)
                await machine.waitForPoweroff(timeout: timeout)
                #else
                true
                #endif
            },
            helperHello: {
                #if arch(arm64)
                try await machine.hello()
                #else
                throw InstallerError(message: WorktreeVMManager.unsupportedMessage)
                #endif
            },
            requestGuestPoweroff: {
                #if arch(arm64)
                await machine.requestPoweroff()
                #endif
            },
            stop: {
                #if arch(arm64)
                await machine.forceStop()
                #endif
            },
            seal: { bundle in try writeSealedMarker(bundle) },
            sleep: { duration in try? await Task.sleep(for: duration) },
            now: { ContinuousClock.now })
    }

    /// Runs blocking work off the main actor; cancelling the caller cancels
    /// it, so `Task.checkCancellation()` inside stops it.
    private static func detached<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(operation: body)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the NoCloud seed files to a scratch directory and packs them
    /// into an ISO labelled `cidata`, which cloud-init looks for.
    static func makeSeedISO(at iso: URL) async throws {
        let files = LinuxCloudInit.seedFiles(
            hostname: "alas", account: .alas, instanceID: "alas-golden-\(LinuxGoldenImage.serial)")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cidata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for file in files {
            try Data(file.contents.utf8).write(to: scratch.appendingPathComponent(file.name))
        }
        try? FileManager.default.removeItem(at: iso)
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = [
                "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", iso.path, scratch.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            let stderr = Pipe()
            process.standardError = stderr
            try process.run()
            let message = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw InstallerError(message: "hdiutil makehybrid failed: \(String(decoding: message, as: UTF8.self))")
            }
        }.value
    }
}

#if arch(arm64)
/// The golden VM the live pipeline boots: headless, with the embedded Linux
/// helper shared under the `alas` tag and no slot taken (only macOS VMs count).
@MainActor
private final class LinuxGoldenMachine {
    private var vm: RunningVM?
    private var client: VMGuestClient?
    private var poweredOff = false
    private var poweroffWaiters: [CheckedContinuation<Void, Never>] = []

    /// The directory holding the embedded `alas-vm-guest-linux` binary.
    static var embeddedHelperDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("alas-vm-guest-linux", isDirectory: true)
    }

    func boot(_ bundle: LinuxVMBundle, seed: URL?) async throws {
        guard let helper = Self.embeddedHelperDirectory else {
            throw LinuxGoldenInstaller.InstallerError(message: "The Linux guest helper is missing from Alas")
        }
        let resources = VMConfigurationFactory.defaultResources(
            hostCPUs: ProcessInfo.processInfo.processorCount, hostMemory: ProcessInfo.processInfo.physicalMemory)
        let configuration = try VMConfigurationFactory.linux(
            bundle: bundle, cpuCount: resources.cpus, memoryBytes: resources.memory, display: .default,
            shares: [VMShare(name: "helper", hostURL: helper, readOnly: true)], seedISO: seed)
        let vm = RunningVM(worktreeID: VMIdentity.linuxGoldenPrefix + bundle.url.lastPathComponent,
                           machine: VirtualizationMachine(configuration: configuration))
        poweredOff = false
        vm.onStopped = { [weak self] error in self?.didStop(clean: error == nil) }
        self.vm = vm
        client = VMGuestClient(connect: { @MainActor [weak vm] in
            guard let vm else { throw LinuxGoldenInstaller.InstallerError(message: "The VM stopped") }
            return try await vm.openGuestConnection(port: VMGuestPort.computerUse)
        })
        try await vm.start()
    }

    /// Waits up to `timeout` for the guest to stop by itself. A cancelled
    /// wait returns at once.
    func waitForPoweroff(timeout: Duration) async -> Bool {
        guard !poweredOff, vm != nil, !Task.isCancelled else { return poweredOff }
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.resumeWaiters()
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { poweroffWaiters.append($0) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWaiters() }
        }
        return poweredOff
    }

    func hello() async throws -> VMGuestHello {
        guard let client else { throw VMGuestClient.Failure.stopped }
        return try await client.hello()
    }

    func requestPoweroff() async {
        guard let client else { return }
        // The connection drops as the guest goes down; no reply is expected.
        _ = try? await client.run("sudo poweroff", timeoutSeconds: 60)
    }

    func forceStop() async {
        try? await vm?.forceStop()
        teardown()
    }

    /// `clean` is false when Virtualization stopped the VM with an error.
    private func didStop(clean: Bool) {
        poweredOff = clean
        teardown()
        resumeWaiters()
    }

    private func teardown() {
        let client = client
        self.client = nil
        vm = nil
        Task { await client?.close() }
    }

    private func resumeWaiters() {
        let waiters = poweroffWaiters
        poweroffWaiters = []
        waiters.forEach { $0.resume() }
    }
}
#endif
