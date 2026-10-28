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

    typealias StartVM = (_ worktreeID: String, _ bundle: VMBundle) async throws -> RunningVM

    /// Registry ids at or under this prefix are golden VMs, not worktrees.
    nonisolated static let goldenIDPrefix = "golden:"

    @ObservationIgnored private let registry: WorktreeVMRegistry
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let start: StartVM
    @ObservationIgnored private let ownerLabel: String
    /// True for worktrees that live on a remote host; their VM would have to
    /// run there, which is not supported.
    @ObservationIgnored var isRemoteWorktree: (String) -> Bool = { RemotePath.isReserved($0) }
    @ObservationIgnored private let logger = Logger(subsystem: "io.nlopez.alas", category: "worktree-vm-manager")

    private(set) var runningVMs: [String: RunningVM] = [:]
    /// Observed so a VM tab can show a boot in progress.
    private var starting: Set<String> = []
    /// Stop or delete requests for VMs that were still booting, honoured once
    /// the boot returns.
    @ObservationIgnored private var pendingAfterBoot: [String: PendingAction] = [:]
    /// Golden builds whose VM a tab has already booted on its own once.
    @ObservationIgnored private var autoStartedGoldenBuilds: Set<String> = []

    private enum PendingAction { case stop, delete }

    init(
        registry: WorktreeVMRegistry = WorktreeVMRegistry(),
        root: URL = Paths.vmsRoot,
        ownerLabel: String = WorktreeVMManager.defaultOwnerLabel,
        start: @escaping StartVM = WorktreeVMManager.bootVirtualMachine
    ) {
        self.registry = registry
        self.root = root
        self.ownerLabel = ownerLabel
        self.start = start
    }

    static var defaultOwnerLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Alas"
    }

    static func bootVirtualMachine(worktreeID: String, bundle: VMBundle) async throws -> RunningVM {
        let resources = VMConfigurationFactory.defaultResources(
            hostCPUs: ProcessInfo.processInfo.processorCount,
            hostMemory: ProcessInfo.processInfo.physicalMemory)
        let configuration = try VMConfigurationFactory.macOS(
            bundle: bundle, cpuCount: resources.cpus, memoryBytes: resources.memory, display: .default)
        let vm = RunningVM(worktreeID: worktreeID, machine: VirtualizationMachine(configuration: configuration))
        try await vm.start()
        return vm
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

    func isStarting(_ id: String) -> Bool {
        starting.contains(id)
    }

    func runningGolden() -> RunningVM? {
        runningVMs.first { $0.key.hasPrefix(Self.goldenIDPrefix) }?.value
    }

    /// True when any Alas process (release and dev builds share the registry)
    /// runs a golden VM, so its disk must not be sealed. An unreadable
    /// registry counts as running.
    func goldenRunsAnywhere() -> Bool {
        if runningGolden() != nil { return true }
        guard vmsExist else { return false }
        guard let records = try? registry.snapshot() else { return true }
        return records.contains { $0.id.hasPrefix(Self.goldenIDPrefix) && $0.runOwner != nil }
    }

    // MARK: - Lifecycle

    /// Clones the newest sealed golden image for `worktreeID` and records it.
    /// Does not boot the VM. A no-op when the worktree already has one.
    func createVM(worktreeID: String) throws {
        guard !isRemoteWorktree(worktreeID) else {
            throw VMError(message: "VMs are only available for worktrees on this Mac, not on a remote host")
        }
        guard !hasVM(worktreeID) else { return }
        guard let golden = GoldenImageInstaller.availableGolden(root: root) else {
            throw VMError(message: "Install and finish setting up the golden macOS image first")
        }
        let destination = Self.bundleURL(forWorktree: worktreeID, root: root)
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
        do {
            try registry.update { records in
                records.removeAll { $0.id == worktreeID }
                records.append(WorktreeVMRecord(
                    id: worktreeID, goldenBuild: golden.url.lastPathComponent, bundlePath: bundle.url.path,
                    createdAt: now, lastUsedAt: now))
            }
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
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
            let bundlePath: String? = try registry.update { records in
                guard let index = records.firstIndex(where: { $0.id == worktreeID }) else { return nil }
                if let owner = records[index].runOwner, !(me.map(owner.isSameProcess(as:)) ?? false) {
                    throw VMError(message: "it is running in \(owner.label)")
                }
                return records.remove(at: index).bundlePath
            }
            let bundle = bundlePath.map { URL(fileURLWithPath: $0) }
                ?? Self.bundleURL(forWorktree: worktreeID, root: root)
            if FileManager.default.fileExists(atPath: bundle.path) {
                try FileManager.default.removeItem(at: bundle)
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
    func startGolden(build: String) async throws -> VMStartOutcome {
        let id = Self.goldenIDPrefix + build
        let bundlePath = root.appendingPathComponent("golden", isDirectory: true)
            .appendingPathComponent(build, isDirectory: true).path
        return try await startRecorded(id: id) { records in
            guard !records.contains(where: { $0.id == id }) else { return }
            let now = Date()
            records.append(WorktreeVMRecord(
                id: id, goldenBuild: build, bundlePath: bundlePath, createdAt: now, lastUsedAt: now))
        }
    }

    func stopGolden() async {
        for id in runningVMs.keys where id.hasPrefix(Self.goldenIDPrefix) {
            await stopVM(worktreeID: id)
        }
    }

    // MARK: - Internals

    /// `<root>/worktrees/<name>-<hash>/`: a readable, filesystem-safe name from
    /// the worktree's last path component plus a digest of the full id.
    static func bundleURL(forWorktree worktreeID: String, root: URL) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let leaf = URL(fileURLWithPath: worktreeID).lastPathComponent
        let name = String(leaf.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let digest = SHA256.hash(data: Data(worktreeID.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(name.isEmpty ? digest : "\(name.prefix(64))-\(digest)", isDirectory: true)
    }

    private enum Admission {
        case boot(VMBundle)
        case outcome(VMStartOutcome)
    }

    /// Decides under the registry lock and reserves the slot by recording this
    /// process as owner before booting, so two processes cannot both take the
    /// last slot. The reservation is released if the boot fails.
    private func startRecorded(
        id: String, ensureRecord: ((inout [WorktreeVMRecord]) -> Void)?
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
            ensureRecord?(&records)
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
                return .boot(VMBundle(url: URL(fileURLWithPath: records[index].bundlePath)))
            case .alreadyRunningHere:
                throw VMError(message: "This VM is already starting")
            case .runningElsewhere(let label):
                return .outcome(.runningElsewhere(label: label))
            case .needsUserChoice(let candidates):
                return .outcome(.needsUserChoice(candidates: candidates.filter(localIDs.contains)))
            }
        }
        let bundle: VMBundle
        switch admission {
        case .outcome(let outcome): return outcome
        case .boot(let booting): bundle = booting
        }

        starting.insert(id)
        let booted: Result<RunningVM, Error>
        do {
            booted = .success(try await start(id, bundle))
        } catch {
            booted = .failure(error)
        }
        starting.remove(id)
        let pending = pendingAfterBoot.removeValue(forKey: id)
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
            do {
                try await vm.forceStop()
            } catch {
                logger.error("Stopping VM \(id, privacy: .public) after boot failed: \(String(describing: error), privacy: .public)")
            }
            clearOwner(id)
            if pending == .delete { removeRecordAndBundle(id) }
            if pending == .stop { throw StoppedWhileStarting() }
            throw VMError(message: "The VM was \(abort) while it was starting")
        }
        vm.onStopped = { [weak self] error in
            if let error {
                self?.logger.error("VM \(id, privacy: .public) stopped with error: \(String(describing: error), privacy: .public)")
            }
            self?.didStop(id)
        }
        runningVMs[id] = vm
        return .running(vm)
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
