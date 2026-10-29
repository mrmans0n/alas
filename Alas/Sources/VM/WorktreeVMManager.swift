import AlasCore
import CryptoKit
import Foundation
import Observation
import Virtualization
import os

enum VMStartOutcome {
    case running(RunningVM)
    /// Another Alas process runs this VM.
    case runningElsewhere(label: String)
    /// Both macOS slots are taken. Candidates are the worktree ids of VMs this
    /// process has finished booting, least recently used first; empty when
    /// every slot belongs to another process or to a VM still booting here.
    case needsUserChoice(candidates: [String])
}

/// Owns the VMs this process runs, one per worktree, plus the golden VM while
/// its setup is pending. Slots are accounted across processes through the
/// shared `WorktreeVMRegistry`.
@MainActor
@Observable
final class WorktreeVMManager {
    struct VMError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The VM was stopped on request before its boot finished. Not a failure:
    /// callers show the VM as stopped.
    struct StoppedWhileStarting: LocalizedError {
        var errorDescription: String? { "The VM was stopped while it was starting" }
    }

    /// What the registry says about one worktree's VM.
    struct RecordStatus: Equatable {
        var hasVM = false
        /// Label of the other Alas process running it, if any.
        var runningElsewhere: String?
    }

    typealias StartVM = (_ worktreeID: String, _ bundle: VMBundle, _ shares: [VMShare]) async throws -> RunningVM

    /// Registry ids at or under this prefix are golden VMs, not worktrees.
    nonisolated static let goldenIDPrefix = "golden:"

    @ObservationIgnored private let registry: WorktreeVMRegistry
    @ObservationIgnored let root: URL
    @ObservationIgnored private let start: StartVM
    @ObservationIgnored private let ownerLabel: String
    /// True for worktrees that live on a remote host; their VM would have to
    /// run there, which is not supported.
    @ObservationIgnored var isRemoteWorktree: (String) -> Bool = { RemotePath.isReserved($0) }
    /// The checkout directory of a worktree, shared read-only with its VM.
    /// Installed by the app; nil leaves the worktree share out.
    @ObservationIgnored var worktreePath: (String) -> URL? = { _ in nil }
    /// The guest helper and its installer, shared read-only with every VM.
    @ObservationIgnored private let helperDirectory: URL?
    @ObservationIgnored private let logger = Logger(subsystem: "io.nlopez.alas", category: "worktree-vm-manager")

    private(set) var runningVMs: [String: RunningVM] = [:]
    /// The worktree whose tab asked to customize the base image, or
    /// switched to it with Finish customizing; it shows golden setup while
    /// other worktrees keep their own VM. In memory only: after a relaunch
    /// no tab is, until one picks Finish customizing. Cleared by sealing.
    private(set) var customizingFrom: String?
    /// One client per running VM that something has talked to; closed when the VM stops.
    @ObservationIgnored private var guestClients: [String: VMGuestClient] = [:]
    /// Observed so a VM tab can show a boot in progress.
    private var starting: Set<String> = []
    /// Stop or delete requests for VMs that were still booting, honoured once
    /// the boot returns.
    @ObservationIgnored private var pendingAfterBoot: [String: PendingAction] = [:]
    /// Golden builds whose VM a tab has already booted on its own once.
    @ObservationIgnored private var autoStartedGoldenBuilds: Set<String> = []
    /// VMs this process saw shut down by the guest itself, without a forced
    /// power-off or a hypervisor error, keyed to the registry boot generation
    /// of that run. A golden VM may be sealed only while its record is still
    /// at that generation: any later boot, in any process, or a relaunch
    /// voids the evidence that its disk is consistent.
    @ObservationIgnored private var cleanlyShutDown: [String: Int] = [:]

    private enum PendingAction { case stop, delete }

    init(
        registry: WorktreeVMRegistry = WorktreeVMRegistry(),
        root: URL = Paths.vmsRoot,
        ownerLabel: String = WorktreeVMManager.defaultOwnerLabel,
        helperDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("alas-vm-guest", isDirectory: true),
        start: @escaping StartVM = WorktreeVMManager.bootVirtualMachine
    ) {
        self.registry = registry
        self.root = root
        self.ownerLabel = ownerLabel
        self.helperDirectory = helperDirectory
        self.start = start
    }

    static var defaultOwnerLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Alas"
    }

    static func bootVirtualMachine(worktreeID: String, bundle: VMBundle, shares: [VMShare]) async throws -> RunningVM {
        let resources = VMConfigurationFactory.defaultResources(
            hostCPUs: ProcessInfo.processInfo.processorCount,
            hostMemory: ProcessInfo.processInfo.physicalMemory)
        let configuration = try VMConfigurationFactory.macOS(
            bundle: bundle, cpuCount: resources.cpus, memoryBytes: resources.memory, display: .default,
            shares: shares)
        // Diagnostic for suspend and resume, which a later plan builds on:
        // whether this configuration, shares included, supports save/restore.
        do {
            try configuration.validateSaveRestoreSupport()
            vmLogger.notice("VM \(worktreeID, privacy: .public) supports save/restore with \(shares.count) shares")
        } catch {
            vmLogger.notice("VM \(worktreeID, privacy: .public) does not support save/restore with \(shares.count) shares: \(String(describing: error), privacy: .public)")
        }
        let vm = RunningVM(worktreeID: worktreeID, machine: VirtualizationMachine(configuration: configuration))
        try await vm.start()
        return vm
    }

    private static let vmLogger = Logger(subsystem: "io.nlopez.alas", category: "vm")

    // MARK: - Shared folders

    /// `<root>/transfer/<name>-<hash>/`, named like the worktree's VM bundle:
    /// the one folder the guest can write back to the host.
    func transferDirectory(forWorktree worktreeID: String) -> URL {
        root.appendingPathComponent("transfer", isDirectory: true)
            .appendingPathComponent(Self.directoryName(forWorktree: worktreeID), isDirectory: true)
    }

    /// The folders a VM sees under `/Volumes/My Shared Files`: the guest
    /// helper (read-only) for every VM, plus the worktree checkout
    /// (read-only) and a writable transfer folder, created here, for
    /// worktree VMs. A helper or worktree directory that does not exist is
    /// left out, since the VM would refuse to boot with it.
    func shares(forWorktree id: String) throws -> [VMShare] {
        var shares: [VMShare] = []
        func addIfPresent(_ name: String, _ url: URL?) {
            guard let url, FileManager.default.fileExists(atPath: url.path) else {
                logger.error("Not sharing \(name, privacy: .public) with VM \(id, privacy: .public): \(url?.path ?? "no directory", privacy: .public) does not exist")
                return
            }
            shares.append(VMShare(name: name, hostURL: url, readOnly: true))
        }
        addIfPresent("helper", helperDirectory)
        guard !id.hasPrefix(Self.goldenIDPrefix) else { return shares }
        addIfPresent("worktree", worktreePath(id))
        let transfer = transferDirectory(forWorktree: id)
        try FileManager.default.createDirectory(at: transfer, withIntermediateDirectories: true)
        shares.append(VMShare(name: "transfer", hostURL: transfer, readOnly: false))
        return shares
    }

    // MARK: - Queries

    func hasVM(_ worktreeID: String) -> Bool {
        guard vmsExist else { return false }
        return (try? registry.snapshot().contains { $0.id == worktreeID }) ?? false
    }

    /// False until the first VM is installed, so queries and worktree
    /// deletion do not create the VM directory for users who never use VMs.
    private var vmsExist: Bool { FileManager.default.fileExists(atPath: root.path) }

    func running(_ worktreeID: String) -> RunningVM? {
        runningVMs[worktreeID]
    }

    /// The client for the guest helper of a VM this process runs; nil when it does not run here.
    func guestClient(for worktreeID: String) -> VMGuestClient? {
        guard let vm = runningVMs[worktreeID] else { return nil }
        if let client = guestClients[worktreeID] { return client }
        let client = VMGuestClient(connect: { @MainActor [weak vm] in
            guard let vm else { throw VMError(message: "The VM stopped") }
            return try await vm.openGuestConnection(port: VMGuestPort.computerUse)
        })
        guestClients[worktreeID] = client
        return client
    }

    /// One registry read for a VM tab: whether the worktree has a VM and
    /// which other process, if any, runs it.
    func recordStatus(_ worktreeID: String) -> RecordStatus {
        guard vmsExist, let record = (try? registry.snapshot())?.first(where: { $0.id == worktreeID }) else {
            return RecordStatus()
        }
        let me = VMRunOwner.current(label: ownerLabel)
        let elsewhere = record.runOwner.flatMap { owner in
            me.map(owner.isSameProcess(as:)) == true ? nil : owner.label
        }
        return RecordStatus(hasVM: true, runningElsewhere: elsewhere)
    }

    /// True the first time it is asked for `build`, so the golden VM boots by
    /// itself once per setup rather than every time a VM tab appears.
    func claimGoldenAutoStart(build: String) -> Bool {
        autoStartedGoldenBuilds.insert(build).inserted
    }

    /// The newest sealed golden image under this manager's root.
    func availableGolden() -> VMBundle? {
        GoldenImageInstaller.availableGolden(root: root)
    }

    func isStarting(_ id: String) -> Bool {
        starting.contains(id)
    }

    func runningGolden() -> RunningVM? {
        runningVMs.first { $0.key.hasPrefix(Self.goldenIDPrefix) }?.value
    }

    /// True when any Alas process (release and dev builds share the registry)
    /// runs or boots a golden VM, so its disk must not be sealed or unsealed. Call it
    /// inside a registry transaction.
    private func goldenRunsAnywhere(_ records: [WorktreeVMRecord]) -> Bool {
        runningGolden() != nil
            || starting.contains { $0.hasPrefix(Self.goldenIDPrefix) }
            || records.contains { $0.id.hasPrefix(Self.goldenIDPrefix) && $0.runOwner != nil }
    }

    // MARK: - Lifecycle

    /// Clones the newest sealed golden image for `worktreeID` and records it.
    /// Does not boot the VM. A no-op when the worktree already has one.
    func createVM(worktreeID: String) throws {
        guard !isRemoteWorktree(worktreeID) else {
            throw VMError(message: "VMs are only available for worktrees on this Mac, not on a remote host")
        }
        let root = root
        guard let golden = availableGolden() else {
            // A worktree that already has a VM needs no golden image.
            guard try !(vmsExist && registry.snapshot().contains { $0.id == worktreeID }) else { return }
            throw VMError(message: "Install and finish setting up the golden macOS image first")
        }
        let destination = Self.bundleURL(forWorktree: worktreeID, root: root)
        // The check, stale-bundle cleanup, clone and record all happen under
        // the registry lock, so another Alas process creating the same VM
        // can neither delete this bundle as stale nor overwrite its record.
        // An unreadable registry throws rather than passing for "no VM".
        // If saving the record fails, the clone stays behind as a stale
        // bundle; removing it outside the lock could delete another
        // process's fresh clone, and the next create replaces it anyway.
        try registry.update { records in
            guard !records.contains(where: { $0.id == worktreeID }) else { return }
            // Re-checked under the lock unsealing takes: another process may
            // have reopened the golden, and booted it, since the read above.
            guard golden.isSealed, !goldenRunsAnywhere(records),
                  GoldenImageInstaller.availableGolden(root: root)?.url == golden.url
            else {
                throw VMError(message: "The base image is being customized. Finish customizing it first.")
            }
            // A bundle without a record is left over from an interrupted
            // create or delete; cloning over it would fail forever.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            let bundle: VMBundle
            do {
                bundle = try VMBundle.cloneForWorktree(
                    golden: golden, to: destination,
                    newMachineIdentifier: VZMacMachineIdentifier().dataRepresentation,
                    newMACAddress: VZMACAddress.randomLocallyAdministered().string)
            } catch let error as NSError
                where error.domain == NSPOSIXErrorDomain && [Int(EXDEV), Int(ENOTSUP)].contains(error.code)
            {
                throw VMError(message: "The golden image and worktree VMs must be on the same APFS volume (\(error.localizedDescription))")
            }
            let now = Date()
            records.append(WorktreeVMRecord(
                id: worktreeID, goldenBuild: golden.url.lastPathComponent, bundlePath: bundle.url.path,
                createdAt: now, lastUsedAt: now))
        }
    }

    func startVM(worktreeID: String) async throws -> VMStartOutcome {
        try await startRecorded(id: worktreeID, ensureRecord: nil)
    }

    /// Stops `other` (which must run in this process) and starts `worktreeID`.
    func startVM(worktreeID: String, pausing other: String) async throws -> RunningVM {
        guard runningVMs[other] != nil else {
            throw VMError(message: "The VM to pause is not running in this window")
        }
        try await stop(other, force: false)
        switch try await startVM(worktreeID: worktreeID) {
        case .running(let vm):
            return vm
        case .runningElsewhere(let label):
            throw VMError(message: "This VM is already running in \(label)")
        case .needsUserChoice:
            throw VMError(message: "No VM slot is free; another Alas window took it")
        }
    }

    /// Shuts the VM down. A VM still booting is stopped once its boot returns.
    func stopVM(worktreeID: String) async {
        do {
            try await stop(worktreeID, force: false)
        } catch {
            logger.error("Stopping VM \(worktreeID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Throws when the VM is still running afterwards; it then stays tracked
    /// and keeps its slot.
    private func stop(_ id: String, force: Bool) async throws {
        if starting.contains(id) {
            if pendingAfterBoot[id] == nil { pendingAfterBoot[id] = .stop }
            return
        }
        guard let vm = runningVMs[id] else { return }
        do {
            if force { try await vm.forceStop() } else { try await vm.stop() }
        } catch {
            guard vm.state == .stopped || vm.state == .error else { throw error }
        }
        didStop(id)
    }

    /// Forces the VM off if it runs here (its disk is discarded anyway), then
    /// removes its bundle and record. A VM another process is running is left
    /// alone; one still booting is deleted once its boot returns.
    func deleteVM(worktreeID: String) async {
        if starting.contains(worktreeID) {
            pendingAfterBoot[worktreeID] = .delete
            return
        }
        do {
            try await stop(worktreeID, force: true)
        } catch {
            logger.error("Deleting VM \(worktreeID, privacy: .public) failed, it is still running: \(String(describing: error), privacy: .public)")
            return
        }
        removeRecordAndBundle(worktreeID)
    }

    private func removeRecordAndBundle(_ worktreeID: String) {
        guard vmsExist else { return }
        let me = VMRunOwner.current(label: ownerLabel)
        do {
            // The bundle goes under the registry lock too, so a concurrent
            // create of the same worktree cannot clone into it in between.
            try registry.update { records in
                let index = records.firstIndex { $0.id == worktreeID }
                if let index, let owner = records[index].runOwner, !(me.map(owner.isSameProcess(as:)) ?? false) {
                    throw VMError(message: "it is running in \(owner.label)")
                }
                let bundle = index.map { URL(fileURLWithPath: records[$0].bundlePath) }
                    ?? Self.bundleURL(forWorktree: worktreeID, root: root)
                if FileManager.default.fileExists(atPath: bundle.path) {
                    try FileManager.default.removeItem(at: bundle)
                }
                let transfer = transferDirectory(forWorktree: worktreeID)
                if !worktreeID.hasPrefix(Self.goldenIDPrefix), FileManager.default.fileExists(atPath: transfer.path) {
                    try FileManager.default.removeItem(at: transfer)
                }
                if let index { records.remove(at: index) }
            }
        } catch {
            logger.error("Deleting VM \(worktreeID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stops every VM this process runs. Called on quit so registry owners clear.
    func stopAll() async {
        await withTaskGroup(of: Void.self) { group in
            for id in runningVMs.keys {
                group.addTask { await self.stopVM(worktreeID: id) }
            }
        }
    }

    // MARK: - Golden VM

    /// Boots the golden VM so the user can finish Setup Assistant. It takes a
    /// slot like any worktree VM.
    /// Refuses a sealed image: worktree VMs clone its disk, so it must not
    /// change after sealing.
    func startGolden(build: String) async throws -> VMStartOutcome {
        let id = Self.goldenIDPrefix + build
        let bundleURL = goldenBundleURL(build: build)
        guard !VMBundle(url: bundleURL).isSealed else {
            throw VMError(message: "This macOS image is already set up")
        }
        let bundlePath = bundleURL.path
        return try await startRecorded(id: id) { records in
            // Checked again under the registry lock: sealing happens under
            // it too, so a golden sealed since the check above never boots.
            guard !VMBundle(url: bundleURL).isSealed else {
                throw VMError(message: "This macOS image is already set up")
            }
            guard !records.contains(where: { $0.id == id }) else { return }
            let now = Date()
            records.append(WorktreeVMRecord(
                id: id, goldenBuild: build, bundlePath: bundlePath, createdAt: now, lastUsedAt: now))
        }
    }

    enum GoldenShutdown: Equatable {
        /// This process saw the guest shut down cleanly (now or earlier): safe
        /// to seal.
        case clean
        /// The guest did not shut down when asked; the VM is still running.
        case stillRunning
        /// The VM is stopped, but there is no evidence its guest shut down
        /// cleanly: it was forced off, stopped with an error, or stopped
        /// before this process launched.
        case forcedOff
    }

    /// Asks the golden VM to shut down before sealing. Never forces it: a disk
    /// pulled from under a running macOS must not become every clone's base.
    /// `.clean` requires having seen the guest shut down cleanly.
    func shutDownGoldenForSealing(build: String) async -> GoldenShutdown {
        let id = Self.goldenIDPrefix + build
        if starting.contains(id) { return .stillRunning }
        if let vm = runningVMs[id] {
            guard await vm.stopGracefully() else { return .stillRunning }
            // `onStopped` normally untracks it; make sure before sealing.
            didStop(id)
        }
        return cleanlyShutDown[id] != nil ? .clean : .forcedOff
    }

    /// Seals a golden bundle once this process saw its guest shut down
    /// cleanly. The running check, the marker write and dropping the golden
    /// record (only customizing boots it again) are one registry transaction, the
    /// same lock boot admission takes, so no Alas process can boot the golden
    /// between the check and the seal.
    func sealGolden(_ bundle: VMBundle) throws {
        let id = Self.goldenIDPrefix + bundle.url.lastPathComponent
        try registry.update { records in
            guard !goldenRunsAnywhere(records) else {
                throw VMError(message: "Shut down the golden VM before marking setup as done")
            }
            // A boot in any process since the clean shutdown bumped the
            // generation; checked before the record is dropped below.
            guard let generation = cleanlyShutDown[id],
                  records.first(where: { $0.id == id })?.bootGeneration == generation
            else {
                throw VMError(message: "macOS was powered off without shutting down. Start it, shut down macOS from the Apple menu, then click Done.")
            }
            try GoldenImageInstaller.writeSealedMarker(bundle)
            records.removeAll { $0.id == id }
            // Spent: should the image be customized again, from this process
            // or another, sealing it needs a new clean shutdown.
            cleanlyShutDown.removeValue(forKey: id)
        }
        customizingFrom = nil
    }

    /// Shows golden setup on `worktreeID`'s tab while the base image is
    /// being customized, typically after a relaunch forgot which tab it was.
    func finishCustomizing(from worktreeID: String) {
        customizingFrom = worktreeID
    }

    /// Reopens the newest sealed golden image for changes: the next VM tab
    /// shows golden setup, and Done seals it again through `sealGolden`,
    /// after a new clean shutdown. Worktree VMs already cloned from it are
    /// independent copies and stay as they are. The running check, removing
    /// the sealed marker and bumping the golden's boot generation are one
    /// registry transaction, the same lock boot admission and sealing take.
    /// `worktreeID`'s tab then shows golden setup.
    func unsealGoldenForCustomizing(from worktreeID: String) throws {
        let root = root
        try registry.update { records in
            guard !GoldenImageInstaller.goldenBundles(root: root).contains(where: { !$0.isSealed }) else {
                throw VMError(message: "A macOS image is already awaiting setup. Finish it before customizing.")
            }
            guard let golden = GoldenImageInstaller.availableGolden(root: root) else {
                throw VMError(message: "There is no base image to customize")
            }
            guard !goldenRunsAnywhere(records) else {
                throw VMError(message: "The base image is running. Shut it down before customizing it.")
            }
            let build = golden.url.lastPathComponent
            let id = Self.goldenIDPrefix + build
            try FileManager.default.removeItem(at: golden.sealedMarker)
            // Sealing dropped the record. A recreated one starts above any
            // generation an earlier record reached, so no process's old
            // clean-shutdown evidence can match it.
            if let index = records.firstIndex(where: { $0.id == id }) {
                records[index].bootGeneration = (records[index].bootGeneration ?? 0) + 1
            } else {
                let now = Date()
                records.append(WorktreeVMRecord(
                    id: id, goldenBuild: build, bundlePath: golden.url.path, createdAt: now, lastUsedAt: now,
                    bootGeneration: Int(now.timeIntervalSince1970 * 1000)))
            }
            cleanlyShutDown.removeValue(forKey: id)
            autoStartedGoldenBuilds.remove(build)
        }
        customizingFrom = worktreeID
    }

    private func goldenBundleURL(build: String) -> URL {
        root.appendingPathComponent("golden", isDirectory: true).appendingPathComponent(build, isDirectory: true)
    }

    // MARK: - Internals

    /// `<root>/worktrees/<name>-<hash>/`: a readable, filesystem-safe name from
    /// the worktree's last path component plus a digest of the full id.
    static func bundleURL(forWorktree worktreeID: String, root: URL) -> URL {
        root.appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(directoryName(forWorktree: worktreeID), isDirectory: true)
    }

    private static func directoryName(forWorktree worktreeID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let leaf = URL(fileURLWithPath: worktreeID).lastPathComponent
        let name = String(leaf.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let digest = SHA256.hash(data: Data(worktreeID.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return name.isEmpty ? digest : "\(name.prefix(64))-\(digest)"
    }

    private enum Admission {
        case boot(VMBundle, generation: Int)
        case outcome(VMStartOutcome)
    }

    /// Decides under the registry lock and reserves the slot by recording this
    /// process as owner before booting, so two processes cannot both take the
    /// last slot. The reservation is released if the boot fails.
    private func startRecorded(
        id: String, ensureRecord: ((inout [WorktreeVMRecord]) throws -> Void)?
    ) async throws -> VMStartOutcome {
        if let vm = runningVMs[id] { return .running(vm) }
        guard !starting.contains(id) else {
            throw VMError(message: "This VM is already starting")
        }
        guard let me = VMRunOwner.current(label: ownerLabel) else {
            throw VMError(message: "Could not identify this Alas process, so the VM cannot be tracked")
        }
        let localIDs = Set(runningVMs.keys)
        let admission: Admission = try registry.update { records in
            try ensureRecord?(&records)
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw VMError(message: "This worktree has no VM")
            }
            // An owner that is this process but not in memory is a leftover
            // of a failed boot: reclaim it.
            var decisionRecords = records
            if let owner = records[index].runOwner, owner.isSameProcess(as: me), !localIDs.contains(id) {
                decisionRecords[index].runOwner = nil
            }
            switch VMSlotPolicy.decide(requesting: id, records: decisionRecords, me: me) {
            case .start:
                records[index].runOwner = me
                records[index].lastUsedAt = Date()
                let generation = (records[index].bootGeneration ?? 0) + 1
                records[index].bootGeneration = generation
                return .boot(VMBundle(url: URL(fileURLWithPath: records[index].bundlePath)), generation: generation)
            case .alreadyRunningHere:
                throw VMError(message: "This VM is already starting")
            case .runningElsewhere(let label):
                return .outcome(.runningElsewhere(label: label))
            case .needsUserChoice(let candidates):
                return .outcome(.needsUserChoice(candidates: candidates.filter(localIDs.contains)))
            }
        }
        let bundle: VMBundle
        let generation: Int
        switch admission {
        case .outcome(let outcome): return outcome
        case .boot(let booting, let bootGeneration): (bundle, generation) = (booting, bootGeneration)
        }

        // `id` stays in `starting` until the VM is tracked or fully cleaned
        // up, so no second start can reclaim the slot and boot another
        // machine on the same disk meanwhile.
        starting.insert(id)
        defer { starting.remove(id) }
        // Whatever this VM's last stop was, booting it again voids it.
        cleanlyShutDown.removeValue(forKey: id)
        let booted: Result<RunningVM, Error>
        do {
            booted = .success(try await start(id, bundle, try shares(forWorktree: id)))
        } catch {
            booted = .failure(error)
        }
        var pending = pendingAfterBoot.removeValue(forKey: id)
        let vm: RunningVM
        switch booted {
        case .failure(let error):
            clearOwner(id)
            if pending == .delete { removeRecordAndBundle(id) }
            throw error
        case .success(let bootedVM):
            vm = bootedVM
        }
        // Stopped or deleted while booting, or the record vanished: never keep
        // a VM the registry does not count.
        let abort: String? = switch pending {
        case .delete: "deleted"
        case .stop: "stopped"
        case nil: ownsRecord(id, me) ? nil : "removed"
        }
        if let abort {
            var forceStopError: Error?
            do {
                try await vm.forceStop()
            } catch {
                forceStopError = error
            }
            // A delete requested while it was being forced off still applies.
            if pendingAfterBoot.removeValue(forKey: id) == .delete { pending = .delete }
            if let forceStopError, vm.state != .stopped, vm.state != .error {
                // Still running: keep it tracked and counted rather than
                // losing a live VM. Its bundle stays.
                logger.error("Stopping VM \(id, privacy: .public) after boot failed: \(String(describing: forceStopError), privacy: .public)")
                if pending == .delete {
                    logger.error("Not deleting VM \(id, privacy: .public): it is still running")
                }
                track(vm, id: id, generation: generation)
                throw VMError(message: "The VM was \(abort) while it was starting, but it could not be stopped: \(forceStopError.localizedDescription)")
            }
            clearOwner(id)
            if pending == .delete { removeRecordAndBundle(id) }
            if pending == .stop { throw StoppedWhileStarting() }
            throw VMError(message: "The VM was \(abort) while it was starting")
        }
        track(vm, id: id, generation: generation)
        return .running(vm)
    }

    private func track(_ vm: RunningVM, id: String, generation: Int) {
        vm.onStopped = { [weak self, weak vm] error in
            if let error {
                self?.logger.error("VM \(id, privacy: .public) stopped with error: \(String(describing: error), privacy: .public)")
            }
            // A VM already released gives no evidence, so it is not clean.
            if error == nil, vm?.wasForcedOff == false {
                self?.cleanlyShutDown[id] = generation
            } else {
                self?.cleanlyShutDown.removeValue(forKey: id)
            }
            self?.didStop(id)
        }
        runningVMs[id] = vm
    }

    /// Whether the record still exists with this process as owner. A registry
    /// that cannot be read keeps the VM rather than killing it.
    private func ownsRecord(_ id: String, _ me: VMRunOwner) -> Bool {
        do {
            return try registry.update { records in
                records.first { $0.id == id }?.runOwner?.isSameProcess(as: me) ?? false
            }
        } catch {
            logger.error("Checking VM owner for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return true
        }
    }

    private func didStop(_ id: String) {
        if let client = guestClients.removeValue(forKey: id) {
            Task { await client.close() }
        }
        guard runningVMs.removeValue(forKey: id) != nil else { return }
        clearOwner(id)
    }

    private func clearOwner(_ id: String) {
        guard let me = VMRunOwner.current(label: ownerLabel) else { return }
        do {
            try registry.update { records in
                guard let index = records.firstIndex(where: { $0.id == id }),
                      let owner = records[index].runOwner, owner.isSameProcess(as: me)
                else { return }
                records[index].runOwner = nil
            }
        } catch {
            logger.error("Clearing VM owner for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}
