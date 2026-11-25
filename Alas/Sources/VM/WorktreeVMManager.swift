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

/// How `pauseVM` left a VM.
enum VMPauseOutcome: Equatable {
    /// Its machine state was saved and it stopped; the next start restores it.
    case saved
    /// It stopped without a saved state: it can't save one (Linux, a golden, or a configuration
    /// without save/restore support), or saving failed. The next start cold-boots.
    case stopped
    /// Nothing changed: it wasn't running here, was still booting, or couldn't be stopped.
    case notRunning
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
        /// Where its bundle is, when it has one.
        var bundlePath: String?
        /// When the VM was paused with its state saved; nil unless it is paused.
        var pausedAt: Date?
        /// The clean point Reset to clean goes back to; nil until one is taken.
        var cleanPoint: VMCleanPoint?
        var fromProjectBase = false
    }

    /// Boots VM `worktreeID`, or restores it from `restoringFrom` and resumes it. A restore that
    /// failed with the machine stopped throws `RestoreFailed`, so the caller can cold-boot instead.
    typealias StartVM = (
        _ worktreeID: String, _ bundle: VMBundle, _ shares: [VMShare], _ restoringFrom: URL?
    ) async throws -> RunningVM

    /// A disk operation succeeded, but the VM couldn't start again afterwards.
    struct RestartFailed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Restoring a saved machine state failed, and the machine it was restored into is stopped.
    struct RestoreFailed: Error {
        let underlying: Error
    }

    /// Where a paused VM's bundle keeps its saved machine state.
    nonisolated static func savedStateURL(of bundle: VMBundle) -> URL {
        bundle.url.appendingPathComponent("state.vzvmsave")
    }

    /// `state.json` beside the saved state: the disk it was saved with (`VMSavedState.Info`). A
    /// state restores only with it. Kept in the bundle, not the registry, which older builds
    /// rewrite with the fields they know.
    nonisolated static func savedStateInfoURL(of bundle: VMBundle) -> URL {
        bundle.url.appendingPathComponent("state.json")
    }

    /// An empty file in a new VM's bundle until its clean point is taken: each start until then
    /// runs the project's guest setup script first. VMs created before it existed have none.
    nonisolated static func firstBootMarker(of bundle: VMBundle) -> URL {
        bundle.url.appendingPathComponent("first-boot-pending")
    }

    /// Whether the bundle holds a paused VM's saved state that is still valid for its disk: an
    /// older build that cold-booted the VM since changed the disk, so the VM no longer resumes
    /// where it was. A start removes such a stale state.
    nonisolated static func isPaused(_ bundle: VMBundle) -> Bool {
        guard FileManager.default.fileExists(atPath: savedStateURL(of: bundle).path),
              let info = readSavedStateInfo(of: bundle), let disk = diskModified(bundle) else { return false }
        return VMSavedState.isValid(pausedDiskStamp: info.diskStamp, currentDiskModified: disk)
    }

    /// How long quitting waits for the running macOS VMs to save their state, all together.
    /// Those still saving then are stopped as before.
    @ObservationIgnored var quitPauseBound: Duration = .seconds(20)
    /// The clock `runningSince` is read with; tests replace it.
    @ObservationIgnored var now: () -> Date = Date.init

    /// Registry ids at or under this prefix are golden VMs, not worktrees.
    nonisolated static let goldenIDPrefix = "golden:"

    /// macOS guests need Apple silicon: Virtualization.framework has no Mac
    /// platform on Intel, so there the VM feature is unavailable.
    #if arch(arm64)
    nonisolated static let isSupported = true
    #else
    nonisolated static let isSupported = false
    #endif
    nonisolated static let unsupportedMessage = "macOS VMs need a Mac with Apple silicon"

    @ObservationIgnored private let registry: WorktreeVMRegistry
    @ObservationIgnored let root: URL
    @ObservationIgnored private let projectBases: ProjectVMBaseStore
    @ObservationIgnored private let start: StartVM
    @ObservationIgnored private let ownerLabel: String
    /// True for worktrees that live on a remote host; their VM would have to
    /// run there, which is not supported.
    @ObservationIgnored var isRemoteWorktree: (String) -> Bool = { RemotePath.isReserved($0) }
    /// The checkout directory of a worktree, shared read-only with its VM.
    /// Installed by the app; nil leaves the worktree share out.
    @ObservationIgnored var worktreePath: (String) -> URL? = { _ in nil }
    /// Called with a VM's registry id once it stopped here, however it stopped. A clean point's
    /// or reset's own stop counts only if the VM is still stopped when the operation ends.
    @ObservationIgnored var onVMStopped: (String) -> Void = { _ in }
    /// Called with a VM's registry id when a delete of it is accepted, before it runs.
    @ObservationIgnored var onVMDeleted: (String) -> Void = { _ in }
    /// Clones a clean point file into the bundle; tests make it fail.
    @ObservationIgnored var cloneCleanFile: (URL, URL) throws -> Void = { try VMBundle.cloneFile($0, to: $1) }
    /// Whether VM `id` runs its project's first-boot setup. Such a VM is never offered to pause for
    /// a slot, and quitting stops it instead of pausing it, so its setup runs again on the next start.
    @ObservationIgnored var isRunningSetup: (String) -> Bool = { _ in false }
    /// The local Git project of this worktree, including when it has no setup script.
    @ObservationIgnored var projectVMOwner: (String) -> (projectID: String, setupScriptHash: String?)? = { _ in nil }
    /// Set once quitting began: no VM starts after `stopAll`.
    @ObservationIgnored private(set) var isQuitting = false
    /// Called with a VM's registry id once it started running here, booted or restored.
    @ObservationIgnored var onVMStarted: (String) -> Void = { _ in }
    /// The guest helper and its installer, shared read-only with every macOS VM.
    @ObservationIgnored private let helperDirectory: URL?
    /// The Linux guest helper, shared read-only with every Linux VM.
    @ObservationIgnored private let linuxHelperDirectory: URL?
    @ObservationIgnored private let logger = Logger(subsystem: "io.nlopez.alas", category: "worktree-vm-manager")
    /// Turns sshd off on a stopped VM's disk, attached on the host. Called
    /// under a disk claim by `turnOffLeftoverSSH`.
    @ObservationIgnored var disableSSHOffline: @MainActor (VMBundle) async throws -> Void
    /// Sends VM `id`'s guest helper a command that takes the guest down; whether it was sent.
    @ObservationIgnored var sendGuestShutdown: @MainActor (_ id: String, _ command: String) async -> Bool = { _, _ in false }

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
    /// Retain the registry owner between the stop callback and the project state commit.
    @ObservationIgnored private var publishingDrafts: Set<String> = []
    private(set) var projectBaseRevision = 0
    private(set) var projectDraftSetupErrors: [UUID: String] = [:]
    private var projectDraftRuns: [UUID: DraftSetupRun] = [:]
    private struct DraftSetupRun {
        let token: UUID
        let task: Task<Void, Never>
    }

    @ObservationIgnored var makeDraftSetup: (@MainActor (WorktreeVMManager) -> VMFirstBootSetup)?

    private func draftSetup() -> VMFirstBootSetup {
        if let makeDraftSetup { return makeDraftSetup(self) }
        return VMFirstBootSetup(
            manager: self, waitForHelper: { [self] in await waitForSetupHelper(recordID: $0) },
            runScript: { [self] id, script, timeout in
                guard let client = guestClient(recordID: id) else { throw VMGuestClient.Failure.stopped }
                return try await client.run(script, timeoutSeconds: timeout)
            })
    }

    /// Goldens whose disk this process has attached on the host for the
    /// unattended setup. Their registry record names this process as owner,
    /// so other processes see them as running; this set keeps this process
    /// from taking that for a leftover and booting them.
    @ObservationIgnored private var diskClaims: Set<String> = []

    /// Running VMs whose guest helper was found missing or out of date, by
    /// a VM tab's check or `vm_status`. Cleared when the VM stops.
    private(set) var helpersNeedingUpdate: Set<String> = []
    /// VMs whose helper `updateHelper` is reinstalling.
    private(set) var updatingHelpers: Set<String> = []
    /// Running Linux VMs whose installed helper was last found unlike the one this build shares.
    /// Kept until a check compares them again, the helper is updated, or the VM stops.
    @ObservationIgnored private var linuxHelpersDiffering: Set<String> = []
    /// Why the last helper update of a VM failed, until the next one or dismissal.
    private(set) var helperUpdateFailures: [String: String] = [:]

    private enum PendingAction { case stop, delete }

    /// When each VM running here started, by registry id, on `now`'s clock.
    @ObservationIgnored private var startedAt: [String: Date] = [:]
    /// VMs whose state is being saved; observed so a VM tab shows the pause.
    private(set) var pausing: Set<String> = []
    @ObservationIgnored private var pauses: [String: Task<VMPauseOutcome, Never>] = [:]
    /// VMs whose clean point is being taken or reset to; observed so a VM tab disables its actions.
    private(set) var diskOperations: Set<String> = []
    /// VMs that stopped during their own disk operation. `onVMStopped` hears of it only if the
    /// operation leaves them stopped: its own stop and restart end nothing, a take over included.
    @ObservationIgnored private var stoppedForDiskOperation: Set<String> = []
    /// Starts waiting for a VM's disk operation to finish.
    @ObservationIgnored private var diskOperationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(
        registry: WorktreeVMRegistry = WorktreeVMRegistry(),
        root: URL = Paths.vmsRoot,
        ownerLabel: String = WorktreeVMManager.defaultOwnerLabel,
        helperDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("alas-vm-guest", isDirectory: true),
        linuxHelperDirectory: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("alas-vm-guest-linux", isDirectory: true),
        start: @escaping StartVM = WorktreeVMManager.bootVirtualMachine
    ) {
        self.registry = registry
        self.root = root
        self.projectBases = ProjectVMBaseStore(root: root)
        self.ownerLabel = ownerLabel
        self.helperDirectory = helperDirectory
        self.linuxHelperDirectory = linuxHelperDirectory
        self.start = start
        disableSSHOffline = { bundle in try await Self.disableSSHOnDisk(bundle, root: root) }
        sendGuestShutdown = { [weak self] id, command in
            guard let client = self?.existingGuestClient(for: id) else { return false }
            return await client.request(command)
        }
    }

    private static func disableSSHOnDisk(_ bundle: VMBundle, root: URL) async throws {
        let image = bundle.diskImage
        try await Task.detached {
            let session = try VMDiskSession.open(diskImage: image, root: root)
            let result = Result { try VMGuestPatcher.disableSSH(dataVolume: session.dataVolume) }
            guard session.close() else { throw VMDiskSession.DetachFailed() }
            try result.get()
        }.value
    }

    static var defaultOwnerLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Alas"
    }

    /// Boots VM `worktreeID` (a registry record id), configured for the guest its id names, or
    /// restores it from `restoringFrom` and resumes it.
    static func bootVirtualMachine(
        worktreeID: String, bundle: VMBundle, shares: [VMShare], restoringFrom state: URL?
    ) async throws -> RunningVM {
        let guest = VMIdentity.parse(recordID: worktreeID).guest
        let resources = VMConfigurationFactory.defaultResources(
            hostCPUs: ProcessInfo.processInfo.processorCount,
            hostMemory: ProcessInfo.processInfo.physicalMemory)
        let configuration = switch guest {
        case .macOS:
            try VMConfigurationFactory.macOS(
                bundle: bundle, cpuCount: resources.cpus, memoryBytes: resources.memory, display: .default,
                shares: shares)
        case .linux:
            try VMConfigurationFactory.linux(
                bundle: LinuxVMBundle(url: bundle.url), cpuCount: resources.cpus, memoryBytes: resources.memory,
                display: .default, shares: shares, seedISO: nil)
        }
        // Whether this configuration, shares included, supports save/restore, which pausing
        // needs. Linux guests never save state.
        var supportsSaveRestore = false
        #if arch(arm64)
        do {
            try configuration.validateSaveRestoreSupport()
            supportsSaveRestore = guest == .macOS
            vmLogger.notice("VM \(worktreeID, privacy: .public) supports save/restore with \(shares.count) shares")
        } catch {
            vmLogger.notice("VM \(worktreeID, privacy: .public) does not support save/restore with \(shares.count) shares: \(String(describing: error), privacy: .public)")
        }
        #endif
        let machine = VirtualizationMachine(configuration: configuration)
        let vm = RunningVM(worktreeID: worktreeID, machine: machine, supportsSaveRestore: supportsSaveRestore)
        guard let state else {
            try await vm.start()
            return vm
        }
        // The configuration changed since the save (a share went away, say): cold-boot.
        guard supportsSaveRestore else {
            throw RestoreFailed(underlying: VMError(message: "This configuration doesn't support save/restore"))
        }
        do {
            try await vm.restoreState(from: state)
            try await vm.resume()
        } catch {
            // A restored machine left paused would share the disk with the cold boot that follows.
            if machine.state != .stopped, machine.state != .error {
                do {
                    try await machine.stop()
                } catch {
                    throw VMError(message: "The VM couldn't be resumed or stopped: \(error.localizedDescription)")
                }
            }
            throw RestoreFailed(underlying: error)
        }
        return vm
    }

    private static let vmLogger = Logger(subsystem: "io.nlopez.alas", category: "vm")

    // MARK: - Shared folders

    /// `<root>/transfer/<name>-<hash>[-linux]/`, named like the worktree's VM
    /// bundle: the one folder the guest can write back to the host.
    func transferDirectory(forWorktree worktreeID: String, guest: VMGuestOS = .macOS) -> URL {
        let id = VMIdentity.recordID(worktree: worktreeID, guest: guest)
        let recordedPath = (try? registry.read())?.records.first { $0.id == id }?.bundlePath
        return transferDirectory(forWorktree: worktreeID, guest: guest, bundlePath: recordedPath)
    }

    private func transferDirectory(forWorktree worktreeID: String, guest: VMGuestOS, bundlePath: String?) -> URL {
        let canonical = Self.directoryName(forWorktree: worktreeID, guest: guest)
        let leaf = bundlePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? canonical
        return root.appendingPathComponent("transfer", isDirectory: true)
            .appendingPathComponent(leaf.hasPrefix(canonical + ".reset-") ? leaf : canonical, isDirectory: true)
    }

    /// The folders a VM sees under `/Volumes/My Shared Files` (macOS) or
    /// `/mnt/alas` (Linux): its guest's helper (read-only) for every VM, plus
    /// the worktree checkout (read-only) and a writable transfer folder,
    /// created here, for worktree VMs. A helper or worktree directory that
    /// does not exist is left out, since the VM would refuse to boot with it.
    func shares(forWorktree worktreeID: String, guest: VMGuestOS = .macOS) throws -> [VMShare] {
        try shares(forRecord: VMIdentity.recordID(worktree: worktreeID, guest: guest))
    }

    func shares(forRecord recordID: String, bundlePath: String? = nil) throws -> [VMShare] {
        let (id, guest) = VMIdentity.parse(recordID: recordID)
        var shares: [VMShare] = []
        func addIfPresent(_ name: String, _ url: URL?) {
            guard let url, FileManager.default.fileExists(atPath: url.path) else {
                logger.error("Not sharing \(name, privacy: .public) with VM \(id, privacy: .public): \(url?.path ?? "no directory", privacy: .public) does not exist")
                return
            }
            shares.append(VMShare(name: name, hostURL: url, readOnly: true))
        }
        addIfPresent("helper", guest == .linux ? linuxHelperDirectory : helperDirectory)
        guard !id.hasPrefix(Self.goldenIDPrefix) else { return shares }
        let transfer: URL
        if let draftID = VMIdentity.projectDraftID(recordID: recordID) {
            transfer = projectDraftTransferDirectory(draftID)
        } else {
            addIfPresent("worktree", worktreePath(id))
            transfer = bundlePath.map { transferDirectory(forWorktree: id, guest: guest, bundlePath: $0) }
                ?? transferDirectory(forWorktree: id, guest: guest)
        }
        try FileManager.default.createDirectory(at: transfer, withIntermediateDirectories: true)
        shares.append(VMShare(name: "transfer", hostURL: transfer, readOnly: false))
        return shares
    }

    // MARK: - Queries

    /// The guests the worktree has a VM of, read without locking or writing the registry, so it
    /// is cheap enough for every computer use call; nil when the registry can't be read. A
    /// record a newer build wrote under the plain worktree id counts as macOS, and so does a
    /// clone bundle on disk, so a VM worktree never passes for one without a VM. The alias stub
    /// kept for builds that predate Linux guests does not count. An unreadable registry is
    /// quarantined once by a locked snapshot and read again.
    func vmKinds(forWorktree worktreeID: String) -> Set<VMGuestOS>? {
        guard VMIdentity.projectDraftID(recordID: worktreeID) == nil else { return [] }
        guard vmsExist else { return [] }
        let ids = (try? registry.recordIDs(includingLinuxAliases: false)) ?? {
            _ = try? registry.snapshot()
            return try? registry.recordIDs(includingLinuxAliases: false)
        }()
        let guests: [VMGuestOS] = [.macOS, .linux]
        let onDisk = Set(guests.filter { guest in
            FileManager.default.fileExists(atPath: Self.bundleURL(forWorktree: worktreeID, guest: guest, root: root).path)
        })
        // Unreadable even after quarantine: the bundles on disk are all that is known.
        guard let ids else { return onDisk.isEmpty ? nil : onDisk }
        return onDisk.union(guests.filter { ids.contains(VMIdentity.recordID(worktree: worktreeID, guest: $0)) })
    }

    /// False until the first VM is installed, so queries and worktree
    /// deletion do not create the VM directory for users who never use VMs.
    private var vmsExist: Bool { FileManager.default.fileExists(atPath: root.path) }

    /// The VM running here; nil while it is being paused, so an agent call waits for the pause
    /// through a start, which then restores it. Its tab reads `runningVMs` to keep the screen.
    func running(_ worktreeID: String, guest: VMGuestOS = .macOS) -> RunningVM? {
        let id = VMIdentity.recordID(worktree: worktreeID, guest: guest)
        return pausing.contains(id) ? nil : runningVMs[id]
    }

    /// The guest client already made for a VM this process runs, without creating one.
    /// `worktreeID` is the VM's registry id (`VMIdentity.recordID`).
    func existingGuestClient(for worktreeID: String) -> VMGuestClient? {
        runningVMs[worktreeID] == nil ? nil : guestClients[worktreeID]
    }

    /// The client for the guest helper of a VM this process runs; nil when it does not run here.
    func guestClient(for worktreeID: String, guest: VMGuestOS = .macOS) -> VMGuestClient? {
        guestClient(recordID: VMIdentity.recordID(worktree: worktreeID, guest: guest))
    }

    func guestClient(recordID worktreeID: String) -> VMGuestClient? {
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
    func recordStatus(_ worktreeID: String, guest: VMGuestOS = .macOS) -> RecordStatus {
        recordStatus(recordID: VMIdentity.recordID(worktree: worktreeID, guest: guest))
    }

    private func recordStatus(recordID id: String) -> RecordStatus {
        guard vmsExist, let record = (try? registry.snapshot())?.first(where: { $0.id == id }) else {
            return RecordStatus()
        }
        let me = VMRunOwner.current(label: ownerLabel)
        let elsewhere = record.runOwner.flatMap { owner in
            me.map(owner.isSameProcess(as:)) == true ? nil : owner.label
        }
        let bundle = VMBundle(url: URL(fileURLWithPath: record.bundlePath))
        let pausedAt = record.guestOS == .macOS && Self.isPaused(bundle) ? Self.savedAt(Self.savedStateURL(of: bundle)) : nil
        return RecordStatus(
            hasVM: true, runningElsewhere: elsewhere, bundlePath: record.bundlePath, pausedAt: pausedAt,
            cleanPoint: Self.readCleanPoint(of: bundle), fromProjectBase: record.goldenBuild.hasPrefix(Self.projectBasePrefix))
    }

    /// When the state file was saved; nil when there is none. Read with `stat`, which never
    /// answers from a cache.
    private static func savedAt(_ file: URL) -> Date? {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
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

    /// Whether VM `recordID`, running here, can save its machine state.
    func supportsSaveRestore(recordID: String) -> Bool {
        runningVMs[recordID]?.supportsSaveRestore ?? false
    }

    /// When VM `recordID` started running here; nil when it doesn't run here.
    func runningSince(_ recordID: String) -> Date? {
        startedAt[recordID]
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

    private nonisolated static let projectBasePrefix = "project-base:"

    enum MacOSSource { case projectBase, shared, unavailable }

    func macOSSource(worktreeID: String) throws -> MacOSSource {
        if let owner = projectVMOwner(worktreeID), try projectBases.status(projectID: owner.projectID).base != nil {
            return .projectBase
        }
        return availableGolden() == nil ? .unavailable : .shared
    }

    /// A named guest command may opt in to the saved project base, never to the default.
    func createFromProjectBaseIfPresent(worktreeID: String) throws -> Bool {
        guard !isRemoteWorktree(worktreeID), let owner = projectVMOwner(worktreeID),
              try projectBases.status(projectID: owner.projectID).base != nil else { return false }
        return try createMacOSVM(worktreeID, fromTemplate: false, sharedAllowed: false)
    }

    /// Clones the selected source without booting. An existing record wins over source selection.
    func createVM(worktreeID: String, guest: VMGuestOS = .macOS, fromTemplate: Bool = true) throws {
        guard VMIdentity.projectDraftID(recordID: worktreeID) == nil else {
            throw VMError(message: "Open the project base window to manage this setup VM")
        }
        guard !isRemoteWorktree(worktreeID) else {
            throw VMError(message: "VMs are only available for worktrees on this Mac, not on a remote host")
        }
        if guest == .linux { return try createLinuxVM(worktreeID: worktreeID, fromTemplate: fromTemplate) }
        _ = try createMacOSVM(worktreeID, fromTemplate: fromTemplate, sharedAllowed: true)
    }

    private func createMacOSVM(_ id: String, fromTemplate: Bool, sharedAllowed: Bool) throws -> Bool {
        let destination = Self.bundleURL(forWorktree: id, root: root)
        return try registry.update(syncingLinuxAliasFor: id) { records in
            guard !records.contains(where: { $0.id == id }) else { return true }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            guard let build = try cloneMacOS(id, to: destination, records: records, fromTemplate: fromTemplate,
                                             sharedAllowed: sharedAllowed) else { return false }
            let date = now()
            records.append(WorktreeVMRecord(
                id: id, goldenBuild: build, bundlePath: destination.path, createdAt: date, lastUsedAt: date))
            return true
        }
    }

    /// The caller holds the registry lock, which also excludes shared image customization.
    private func cloneMacOS(
        _ id: String, to destination: URL, records: [WorktreeVMRecord], fromTemplate: Bool, sharedAllowed: Bool = true
    ) throws -> String? {
        if let owner = projectVMOwner(id), let base = try projectBases.withProject(owner.projectID, {
            guard $0.state.base != nil else { return nil as ProjectVMBaseStore.Base? }
            do {
                let base = try $0.cloneBase(to: destination, identity: Self.newMacIdentity())
                let bundle = VMBundle(url: destination)
                try writeCleanPoint(id, bundle: bundle, setupScriptHash: base?.provenance.scriptHash)
                return base
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }) {
            return Self.projectBasePrefix + base.id.uuidString
        }
        guard sharedAllowed else { return nil }
        guard let golden = availableGolden() else {
            throw VMError(message: "Install and finish setting up the golden macOS image first")
        }
        guard !goldenRunsAnywhere(records) else {
            throw VMError(message: "The base image is being customized. Finish customizing it first.")
        }
        let build = golden.url.lastPathComponent
        if fromTemplate, (try? Self.withTemplatesLocked(root: root, {
            matchingTemplate(worktreeID: id, guest: .macOS, goldenBuild: build, goldenSealedMarker: golden.sealedMarker)
                .flatMap { template in
                    cloneFromTemplate(id, template: template, to: destination) {
                        let identity = Self.newMacIdentity()
                        return try VMBundle.cloneForWorktree(
                            golden: golden, to: destination,
                            newMachineIdentifier: identity.machineIdentifier, newMACAddress: identity.macAddress,
                            diskFrom: template.slot.appendingPathComponent("disk.img"),
                            auxiliaryStorageFrom: template.slot.appendingPathComponent("aux.img"))
                    }
                }
        })) != nil { return build }

        let identity = Self.newMacIdentity()
        do {
            let bundle = try VMBundle.cloneForWorktree(
                golden: golden, to: destination,
                newMachineIdentifier: identity.machineIdentifier, newMACAddress: identity.macAddress)
            try Self.markFirstBootPending(bundle)
            Self.writeGoldenStamp(of: golden.sealedMarker, into: bundle)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && [Int(EXDEV), Int(ENOTSUP)].contains(error.code) {
            throw VMError(message: "The golden image and worktree VMs must be on the same APFS volume (\(error.localizedDescription))")
        }
        return build
    }

    private static func newMacIdentity() -> VMBundle.CloneIdentity {
        .init(machineIdentifier: newMachineIdentifier(), macAddress: VZMACAddress.randomLocallyAdministered().string)
    }

    /// Clones the newest sealed Linux golden for `worktreeID`, like `createVM`
    /// does for macOS. A sealed Linux golden never changes or goes away (it
    /// has no customize flow, and setup only removes unsealed bundles), so
    /// unlike the macOS golden it needs no registry record to protect a clone
    /// in flight; it is re-checked under the lock all the same.
    private func createLinuxVM(worktreeID: String, fromTemplate: Bool) throws {
        #if arch(arm64)
        let root = root
        let id = VMIdentity.recordID(worktree: worktreeID, guest: .linux)
        guard let golden = LinuxGoldenInstaller.availableGolden(root: root) else {
            guard try !(vmsExist && registry.snapshot().contains { $0.id == id }) else { return }
            throw VMError(message: "Set up the Ubuntu image first")
        }
        let destination = Self.bundleURL(forWorktree: worktreeID, guest: .linux, root: root)
        try registry.update(syncingLinuxAliasFor: worktreeID) { records in
            guard !records.contains(where: { $0.id == id }) else { return }
            guard golden.isSealed, LinuxGoldenInstaller.availableGolden(root: root)?.url == golden.url else {
                throw VMError(message: "The Ubuntu image changed. Try again.")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            let fromTemplate = !fromTemplate ? nil : (try? Self.withTemplatesLocked(root: root) {
                matchingTemplate(
                    worktreeID: worktreeID, guest: .linux, goldenBuild: golden.url.lastPathComponent,
                    goldenSealedMarker: golden.sealedMarker
                ).flatMap { template in
                    cloneFromTemplate(id, template: template, to: destination) {
                        VMBundle(url: try LinuxVMBundle.cloneForWorktree(
                            golden: golden, to: destination, diskFrom: template.slot.appendingPathComponent("disk.img")).url)
                    }
                }
            }) ?? nil
            let bundle: LinuxVMBundle
            if let fromTemplate {
                bundle = LinuxVMBundle(url: fromTemplate.url)
            } else {
                do {
                    bundle = try LinuxVMBundle.cloneForWorktree(golden: golden, to: destination)
                } catch let error as NSError
                    where error.domain == NSPOSIXErrorDomain && [Int(EXDEV), Int(ENOTSUP)].contains(error.code)
                {
                    throw VMError(message: "The Ubuntu image and worktree VMs must be on the same APFS volume (\(error.localizedDescription))")
                }
                try Self.markFirstBootPending(VMBundle(url: bundle.url))
                Self.writeGoldenStamp(of: golden.sealedMarker, into: VMBundle(url: bundle.url))
            }
            let now = Date()
            records.append(WorktreeVMRecord(
                id: id, guestOS: .linux, goldenBuild: VMIdentity.linuxGoldenPrefix + golden.url.lastPathComponent,
                bundlePath: bundle.url.path, createdAt: now, lastUsedAt: now))
        }
        #else
        throw VMError(message: Self.unsupportedMessage)
        #endif
    }

    /// `keepingSSH` is only for `VMHelperUpdater`, whose boot needs the sshd
    /// it just turned on; every other start first turns off sshd an
    /// interrupted setup or update left on.
    func startVM(worktreeID: String, guest: VMGuestOS = .macOS, keepingSSH: Bool = false) async throws -> VMStartOutcome {
        let id = VMIdentity.recordID(worktree: worktreeID, guest: guest)
        guard VMIdentity.projectDraftID(recordID: id) == nil else {
            throw VMError(message: "Open the project base window to start its setup VM")
        }
        if !keepingSSH { try await turnOffLeftoverSSHBeforeBoot(id: id) }
        return try await startRecorded(id: id, ensureRecord: nil)
    }

    /// A VM already running or booting here keeps its disk to itself.
    private func turnOffLeftoverSSHBeforeBoot(id: String) async throws {
        guard runningVMs[id] == nil, !starting.contains(id) else { return }
        try await turnOffLeftoverSSH(id: id)
    }

    /// Pauses `other` (which must run in this process) and starts `worktreeID`.
    func startVM(worktreeID: String, pausing other: String) async throws -> RunningVM {
        try await pauseForSlot(other)
        if worktreeID.hasPrefix(Self.goldenIDPrefix) {
            switch try await startGolden(build: String(worktreeID.dropFirst(Self.goldenIDPrefix.count))) {
            case .running(let vm): return vm
            case .runningElsewhere(let label): throw VMError(message: "This VM is already running in \(label)")
            case .needsUserChoice: throw VMError(message: "No VM slot is free; another Alas window took it")
            }
        }
        switch try await startVM(worktreeID: worktreeID) {
        case .running(let vm):
            return vm
        case .runningElsewhere(let label):
            throw VMError(message: "This VM is already running in \(label)")
        case .needsUserChoice:
            throw VMError(message: "No VM slot is free; another Alas window took it")
        }
    }

    private func pauseForSlot(_ id: String) async throws {
        guard runningVMs[id] != nil else { throw VMError(message: "The VM to pause is not running in this window") }
        guard !isSetupRunning(recordID: id), !diskOperations.contains(id) else {
            throw VMError(message: "The VM to pause is running setup or working on its disk")
        }
        if await pauseVM(recordID: id) == .notRunning, runningVMs[id] != nil {
            throw VMError(message: "The VM to pause couldn't be stopped")
        }
    }

    /// Shuts the VM down. A VM still booting is stopped once its boot returns.
    func stopVM(worktreeID: String, guest: VMGuestOS = .macOS) async {
        await stopRecorded(VMIdentity.recordID(worktree: worktreeID, guest: guest))
    }

    /// Shuts down every VM of a worktree, both guests at once, so the wait is one guest's.
    func stopVMs(forWorktree worktreeID: String) async {
        await withTaskGroup(of: Void.self) { group in
            for guest in [VMGuestOS.macOS, .linux] {
                group.addTask { await self.stopVM(worktreeID: worktreeID, guest: guest) }
            }
        }
    }

    private func stopRecorded(_ id: String) async {
        do {
            try await stop(id, force: false)
        } catch {
            logger.error("Stopping VM \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Throws when the VM is still running afterwards; it then stays tracked
    /// and keeps its slot. A pause in progress finishes first: stopping a machine mid-save
    /// would leave a partial state file.
    private func stop(_ id: String, force: Bool) async throws {
        if let pause = pauses[id] { _ = await pause.value }
        try await stopNow(id, force: force)
    }

    private func stopNow(_ id: String, force: Bool) async throws {
        if starting.contains(id) {
            if pendingAfterBoot[id] == nil { pendingAfterBoot[id] = .stop }
            return
        }
        guard let vm = runningVMs[id] else { return }
        do {
            if force { try await vm.forceStop() } else { try await vm.stop(requestingShutdown: guestPoweroff(id)) }
        } catch {
            guard vm.state == .stopped || vm.state == .error else { throw error }
        }
        didStop(id)
    }

    /// How a Linux VM whose helper is connected is asked to shut down: Xfce
    /// may swallow the power button, which would leave the stop to force its
    /// ext4 disk off. Nil for macOS VMs and when no helper is connected, which
    /// press the power button.
    private func guestPoweroff(_ id: String) -> (@MainActor () async -> Bool)? {
        guard VMIdentity.parse(recordID: id).guest == .linux, let client = existingGuestClient(for: id) else { return nil }
        return { await client.requestPoweroff() }
    }

    /// Forces the VM off if it runs here (its disk is discarded anyway), then
    /// removes its bundle and record. A VM another process is running is left
    /// alone; one still booting is deleted once its boot returns. Returns why
    /// the VM was left in place, as a phrase, if it was.
    @discardableResult
    func deleteVM(worktreeID: String, guest: VMGuestOS = .macOS) async -> String? {
        let worktreeID = VMIdentity.recordID(worktree: worktreeID, guest: guest)
        guard VMIdentity.projectDraftID(recordID: worktreeID) == nil else {
            return "open the project base window to discard its draft"
        }
        guard !diskClaims.contains(worktreeID) else {
            logger.error("Not deleting VM \(worktreeID, privacy: .public): its disk is attached for an update")
            return "its disk is attached for an update; try again once that finishes"
        }
        onVMDeleted(worktreeID)
        if starting.contains(worktreeID) {
            pendingAfterBoot[worktreeID] = .delete
            return nil
        }
        do {
            try await stop(worktreeID, force: true)
        } catch {
            logger.error("Deleting VM \(worktreeID, privacy: .public) failed, it is still running: \(String(describing: error), privacy: .public)")
            return "it couldn't be stopped (\(error.localizedDescription))"
        }
        return removeRecordAndBundle(worktreeID)
    }

    /// Deletes every VM of a worktree being deleted, as `deleteVM` does each.
    /// Returns why one was left in place, if any was.
    @discardableResult
    func deleteVMs(forWorktree worktreeID: String) async -> String? {
        var reasons: [String] = []
        for guest in [VMGuestOS.macOS, .linux] {
            if let reason = await deleteVM(worktreeID: worktreeID, guest: guest) { reasons.append(reason) }
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    /// `worktreeID` is a registry record id.
    @discardableResult
    private func removeRecordAndBundle(_ worktreeID: String) -> String? {
        guard vmsExist else { return nil }
        let me = VMRunOwner.current(label: ownerLabel)
        let (worktree, guest) = VMIdentity.parse(recordID: worktreeID)
        do {
            // The bundle goes under the registry lock too, so a concurrent
            // create of the same worktree cannot clone into it in between.
            // The alias stub for older builds follows in the same write.
            try registry.update(syncingLinuxAliasFor: worktree) { records in
                let index = records.firstIndex { $0.id == worktreeID }
                if let index, let owner = records[index].runOwner, !(me.map(owner.isSameProcess(as:)) ?? false) {
                    throw VMError(message: "it is running in \(owner.label)")
                }
                let bundle = index.map { URL(fileURLWithPath: records[$0].bundlePath) }
                    ?? Self.bundleURL(forWorktree: worktree, guest: guest, root: root)
                if FileManager.default.fileExists(atPath: bundle.path) {
                    try FileManager.default.removeItem(at: bundle)
                }
                let transfer = transferDirectory(forWorktree: worktree, guest: guest, bundlePath: bundle.path)
                if !worktreeID.hasPrefix(Self.goldenIDPrefix), FileManager.default.fileExists(atPath: transfer.path) {
                    try FileManager.default.removeItem(at: transfer)
                }
                if let index { records.remove(at: index) }
            }
        } catch {
            logger.error("Deleting VM \(worktreeID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return error.localizedDescription
        }
        return nil
    }

    /// Stops every VM this process runs. Called on quit so registry owners clear. macOS VMs
    /// that can save their state pause instead, all at once, within `quitPauseBound`; one still
    /// saving then is stopped as the others are. No VM starts afterwards, a disk operation's
    /// restart included.
    func stopAll() async {
        isQuitting = true
        let ids = Array(runningVMs.keys)
        // A VM running its setup stops: restored, it would resume mid-script and never rerun it.
        let pausable = Set(ids.filter { canSaveState($0) && !isSetupRunning(recordID: $0) && !diskOperations.contains($0) })
        let pauses = pausable.map { id in Task { await self.pauseVM(recordID: id) } }
        await withTaskGroup(of: Void.self) { group in
            for id in ids where !pausable.contains(id) {
                group.addTask { await self.stopRecorded(id) }
            }
            group.addTask { await self.waitForQuitPauses(pauses, ids: pausable) }
        }
    }

    private func waitForQuitPauses(_ pauses: [Task<VMPauseOutcome, Never>], ids: Set<String>) async {
        guard !pauses.isEmpty else { return }
        let (done, signal) = AsyncStream<Void>.makeStream()
        let all = Task {
            for pause in pauses { _ = await pause.value }
            signal.yield()
        }
        let bound = quitPauseBound
        let timer = Task {
            try? await Task.sleep(for: bound)
            signal.yield()
        }
        for await _ in done { break }
        signal.finish()
        timer.cancel()
        all.cancel()
        let late = ids.filter { runningVMs[$0] != nil }
        guard !late.isEmpty else { return }
        logger.error("Saving the state of VMs \(late.sorted(), privacy: .public) took too long; stopping them")
        await withTaskGroup(of: Void.self) { group in
            for id in late {
                group.addTask {
                    do {
                        // Out of time: power it off rather than wait for the guest too.
                        try await self.stopNow(id, force: true)
                    } catch {
                        self.logger.error("Stopping VM \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
    }

    // MARK: - Pause

    /// Whether VM `id`, running here, pauses by saving its state: a worktree's macOS VM whose
    /// configuration supports it. A golden never does: sealing it needs a clean shutdown.
    private func canSaveState(_ id: String) -> Bool {
        VMIdentity.parse(recordID: id).guest == .macOS && !id.hasPrefix(Self.goldenIDPrefix)
            && supportsSaveRestore(recordID: id)
    }

    /// Pauses the worktree's VM to free its slot: saves its machine state and stops it, so the
    /// next start resumes where it was. A VM that can't save its state stops instead.
    func pauseVM(worktreeID: String, guest: VMGuestOS = .macOS) async -> VMPauseOutcome {
        await pauseVM(recordID: VMIdentity.recordID(worktree: worktreeID, guest: guest))
    }

    func pauseVM(recordID id: String) async -> VMPauseOutcome {
        if let pause = pauses[id] { return await pause.value }
        guard runningVMs[id] != nil, !starting.contains(id) else { return .notRunning }
        pausing.insert(id)
        // Cleans up inside the task, so whoever awaits it resumes with the pause already over.
        let pause = Task {
            let outcome = await self.pauseNow(id)
            self.pauses[id] = nil
            self.pausing.remove(id)
            // `didStop` left the owner to the pause; a saved pause cleared it after `state.json`.
            if outcome != .saved, self.runningVMs[id] == nil { self.clearOwner(id) }
            return outcome
        }
        pauses[id] = pause
        return await pause.value
    }

    private func pauseNow(_ id: String) async -> VMPauseOutcome {
        guard let vm = runningVMs[id] else { return .notRunning }
        guard canSaveState(id) else { return await stopInsteadOfPausing(id) }
        let bundle = bundle(forID: id)
        let state = Self.savedStateURL(of: bundle)
        do {
            try await vm.pause()
            try await vm.saveState(to: state)
        } catch {
            logger.error("Saving the state of VM \(id, privacy: .public) failed, stopping it: \(String(describing: error), privacy: .public)")
            Self.removeSavedState(of: bundle)
            // Running again, the guest can shut down cleanly.
            if vm.state == .paused { try? await vm.resume() }
            return await stopInsteadOfPausing(id)
        }
        do {
            try await vm.forceStop()
        } catch {
            logger.error("Stopping VM \(id, privacy: .public) after saving its state failed: \(String(describing: error), privacy: .public)")
            Self.removeSavedState(of: bundle)
            try? await vm.resume()
            return .notRunning
        }
        // `onStopped` normally untracks it already. The owner stays until `state.json` is
        // written, so no other Alas boots the VM cold, or discards the state, in between.
        didStop(id)
        guard let stamp = Self.diskStamp(of: bundle) else {
            logger.error("Couldn't read VM \(id, privacy: .public)'s disk; discarding its saved state")
            Self.removeSavedState(of: bundle)
            return .stopped
        }
        do {
            try Self.writeSavedStateInfo(VMSavedState.Info(diskStamp: stamp), of: bundle)
        } catch {
            logger.error("Recording VM \(id, privacy: .public) as paused failed: \(String(describing: error), privacy: .public)")
            Self.removeSavedState(of: bundle)
            return .stopped
        }
        clearOwner(id)
        logger.notice("Paused VM \(id, privacy: .public) with its state saved")
        return .saved
    }

    private func stopInsteadOfPausing(_ id: String) async -> VMPauseOutcome {
        do {
            try await stopNow(id, force: false)
        } catch {
            logger.error("Stopping VM \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .notRunning
        }
        return .stopped
    }

    /// `disk.img`'s modification time, read with `attributesOfItem`, which never answers from a
    /// cache, plus 1 ms so the registry's floating-point round trip can't make it look older.
    nonisolated private static func diskStamp(of bundle: VMBundle) -> Date? {
        diskModified(bundle).map { $0.addingTimeInterval(0.001) }
    }

    nonisolated private static func diskModified(_ bundle: VMBundle) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: bundle.diskImage.path))?[.modificationDate] as? Date
    }

    /// Removes the saved state and its `state.json`, the info first so a state left behind is
    /// never restored.
    nonisolated private static func removeSavedState(of bundle: VMBundle) {
        for file in [savedStateInfoURL(of: bundle), savedStateURL(of: bundle)]
            where FileManager.default.fileExists(atPath: file.path)
        {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                Logger(subsystem: "io.nlopez.alas", category: "worktree-vm-manager")
                    .error("Removing saved VM state \(file.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    nonisolated private static func writeSavedStateInfo(_ info: VMSavedState.Info, of bundle: VMBundle) throws {
        try JSONEncoder().encode(info).write(to: savedStateInfoURL(of: bundle), options: .atomic)
    }

    nonisolated private static func readSavedStateInfo(of bundle: VMBundle) -> VMSavedState.Info? {
        guard let data = try? Data(contentsOf: savedStateInfoURL(of: bundle)) else { return nil }
        return try? JSONDecoder().decode(VMSavedState.Info.self, from: data)
    }

    /// The state file a start restores from: only a macOS VM's, with a `state.json` saying it
    /// was saved with the disk as it is now. Any other is stale and removed. Called while no Alas
    /// runs the VM: under the registry lock that admits its start, or with its disk claimed.
    nonisolated private static func restorableState(_ id: String, bundle: VMBundle) -> URL? {
        let state = savedStateURL(of: bundle)
        let fm = FileManager.default
        guard fm.fileExists(atPath: state.path) || fm.fileExists(atPath: savedStateInfoURL(of: bundle).path) else {
            return nil
        }
        if VMIdentity.parse(recordID: id).guest == .macOS, fm.fileExists(atPath: state.path),
           let info = readSavedStateInfo(of: bundle), let disk = diskModified(bundle),
           VMSavedState.isValid(pausedDiskStamp: info.diskStamp, currentDiskModified: disk)
        {
            return state
        }
        Logger(subsystem: "io.nlopez.alas", category: "worktree-vm-manager")
            .notice("Discarding stale saved state of VM \(id, privacy: .public)")
        removeSavedState(of: bundle)
        return nil
    }

    // MARK: - Clean point

    /// `<bundle>/clean/`: the clean point's `disk.img`, its `state.vzvmsave` when the VM could
    /// save one, and `clean.json`.
    nonisolated static func cleanDirectory(of bundle: VMBundle) -> URL {
        bundle.url.appendingPathComponent("clean", isDirectory: true)
    }

    nonisolated private static func cleanPointFile(in directory: URL) -> URL {
        directory.appendingPathComponent("clean.json")
    }

    nonisolated private static func readCleanPoint(of bundle: VMBundle) -> VMCleanPoint? {
        guard let data = try? Data(contentsOf: cleanPointFile(in: cleanDirectory(of: bundle))) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VMCleanPoint.self, from: data)
    }

    /// The clean point of VM `recordID`; nil until one is taken.
    func cleanPoint(recordID: String) -> VMCleanPoint? {
        guard vmsExist, !recordID.hasPrefix(Self.goldenIDPrefix) else { return nil }
        return Self.readCleanPoint(of: bundle(forID: recordID))
    }

    /// Saves the VM's disk, and its machine state where it can save one, as its clean point,
    /// replacing any earlier one. A VM running here pauses (or, without save/restore, shuts down
    /// cleanly) for the copy and then starts again, from the saved state where there is one. A
    /// paused VM's point is its disk and saved state. Refused for a stopped VM, whose disk may not
    /// be the state the user means to keep.
    /// `setupScriptHash` is the project's guest setup script the point was taken after.
    /// With `publishTemplate`, a first boot's point also becomes its project's template for that
    /// script (see `templateToPublish`): the guest then shuts down instead of pausing.
    func takeCleanPoint(
        worktreeID: String, guest: VMGuestOS = .macOS, setupScriptHash: String? = nil, publishTemplate: Bool = false
    ) async throws {
        let id = VMIdentity.recordID(worktree: worktreeID, guest: guest)
        try await withDiskOperation(id) {
            let bundle = bundle(forID: id)
            var template = publishTemplate ? templateToPublish(id, bundle: bundle, setupScriptHash: setupScriptHash) : nil
            let wasRunning = try await shutDownForCleanPoint(id, template: &template)
            guard wasRunning || Self.isPaused(bundle) else {
                throw VMError(message: "Start the VM to save its clean point")
            }
            try withDiskClaimed(id) {
                try writeCleanPoint(id, bundle: bundle, setupScriptHash: setupScriptHash)
                if let template { self.publish(template, from: id, bundle: bundle) }
            }
            logger.notice("Saved the clean point of VM \(id, privacy: .public)")
            if wasRunning { try await startAgain(id, done: "The clean point was saved") }
        }
    }

    /// Powers the VM off, swaps its disk for the clean point's, and starts it, from the clean
    /// point's saved state when it has one. Refused while it has no clean point.
    func resetToClean(worktreeID: String, guest: VMGuestOS = .macOS) async throws {
        let id = VMIdentity.recordID(worktree: worktreeID, guest: guest)
        try await withDiskOperation(id) {
            let bundle = bundle(forID: id)
            guard Self.readCleanPoint(of: bundle) != nil else {
                throw VMError(message: "This VM has no clean point yet")
            }
            // Its disk is replaced anyway. A call in flight fails as for any stop.
            try await stop(id, force: true)
            try withDiskClaimed(id) { try restoreCleanPoint(id, bundle: bundle) }
            logger.notice("Reset VM \(id, privacy: .public) to its clean point")
            try await startAgain(id, done: "The VM was reset to its clean point")
        }
    }

    /// Deletes the VM and clones it again from the base image, as a new VM: its next boot is a
    /// first boot. Does not start it.
    func resetFromScratch(worktreeID: String, guest: VMGuestOS = .macOS) async throws {
        let id = VMIdentity.recordID(worktree: worktreeID, guest: guest)
        try await withDiskOperation(id) {
            if guest == .macOS {
                try await replaceMacOSVM(worktreeID)
                return
            }
            guard LinuxGoldenInstaller.availableGolden(root: root) != nil else {
                throw VMError(message: "The Ubuntu image isn't available to clone the VM from")
            }
            if let reason = await deleteVM(worktreeID: worktreeID, guest: guest) {
                throw VMError(message: "Couldn't delete the VM: \(reason)")
            }
            try createVM(worktreeID: worktreeID, guest: guest, fromTemplate: false)
            logger.notice("Reset VM \(id, privacy: .public) from scratch")
        }
    }

    private func replaceMacOSVM(_ id: String) async throws {
        guard !isRemoteWorktree(id) else { throw VMError(message: "This worktree is on a remote host") }
        guard try macOSSource(worktreeID: id) != .unavailable else {
            throw VMError(message: "There is no macOS base image to clone this VM from")
        }
        let old = try registry.read().records.first { $0.id == id }
        guard !diskClaims.contains(id) else { throw VMError(message: "The VM's disk is already open") }
        try await stop(id, force: true)
        let canonical = Self.bundleURL(forWorktree: id, root: root)
        let destination = canonical.deletingLastPathComponent()
            .appendingPathComponent(canonical.lastPathComponent + ".reset-" + UUID().uuidString, isDirectory: true)
        do {
            try registry.update(syncingLinuxAliasFor: id) { records in
                let index = records.firstIndex { $0.id == id }
                let current = index.map { records[$0] }
                guard current?.bundlePath == old?.bundlePath, current?.bootGeneration == old?.bootGeneration,
                      current?.runOwner == nil else {
                    throw VMError(message: "The VM changed or is running in another Alas. Try again.")
                }
                guard let build = try cloneMacOS(id, to: destination, records: records, fromTemplate: false) else {
                    throw VMError(message: "There is no macOS base image to clone this VM from")
                }
                let date = now()
                let replacement = WorktreeVMRecord(
                    id: id, goldenBuild: build, bundlePath: destination.path, createdAt: date, lastUsedAt: date,
                    bootGeneration: current?.bootGeneration)
                if let index { records[index] = replacement } else { records.append(replacement) }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        cleanlyShutDown.removeValue(forKey: id)
        onVMDeleted(id)
        if let old {
            try? registry.withSnapshotLocked { records in
                guard !records.contains(where: { $0.bundlePath == old.bundlePath }) else { return }
                try? FileManager.default.removeItem(atPath: old.bundlePath)
                try? FileManager.default.removeItem(at: transferDirectory(forWorktree: id, guest: .macOS, bundlePath: old.bundlePath))
            }
        }
        logger.notice("Reset VM \(id, privacy: .public) from scratch")
    }

    /// Runs `body` as the only clean point or reset of VM `id`; other starts wait for it.
    private func withDiskOperation<T>(_ id: String, _ body: @MainActor () async throws -> T) async throws -> T {
        guard !id.hasPrefix(Self.goldenIDPrefix) else { throw VMError(message: "A base image has no clean point") }
        guard !starting.contains(id) else { throw VMError(message: "The VM is starting. Try again once it runs.") }
        guard diskOperations.insert(id).inserted else {
            throw VMError(message: "The VM is already being reset or saved")
        }
        defer {
            diskOperations.remove(id)
            if stoppedForDiskOperation.remove(id) != nil, runningVMs[id] == nil { onVMStopped(id) }
            diskOperationWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
        }
        return try await body()
    }

    /// Stops VM `id` for a clean point: pauses it where it can save its state, else shuts its
    /// guest down cleanly. A forced power-off would leave a disk unfit for a clean point. Returns
    /// whether it was running here.
    /// With a `template`, it always shuts the guest down, from inside where the helper is connected,
    /// and generalizes a Linux guest on the way: a template's disk must be consistent without
    /// memory. A Linux guest the power button shut down wasn't generalized: `template` becomes nil.
    private func shutDownForCleanPoint(_ id: String, template: inout VMTemplate?) async throws -> Bool {
        if let pause = pauses[id] { _ = await pause.value }
        guard let vm = runningVMs[id] else { return false }
        if template != nil {
            // macOS through `shutdown`, which a logged-in guest obeys where the power button only asks.
            let linux = VMIdentity.parse(recordID: id).guest == .linux
            let command = linux ? VMGuestClient.generalizingPoweroffCommand : GoldenProvisioner.shutdownCommand(account: .alas)
            var sent = false
            let send: @MainActor () async -> Bool = { [self] in
                sent = await sendGuestShutdown(id, command)
                return sent
            }
            guard await vm.stopGracefully(requestingShutdown: send, timeout: GoldenProvisioner.shutdownTimeout)
            else {
                throw VMError(message: "The VM didn't shut down, so no clean point was saved. Try again.")
            }
            didStop(id)
            // Stopped is not enough: one that ended in an error or was forced off may leave an
            // inconsistent disk. Its boot cleared any earlier evidence, as for sealing a golden.
            guard cleanlyShutDown[id] != nil else {
                throw VMError(message: "The VM didn't shut down cleanly, so no clean point was saved. Try again.")
            }
            if linux, !sent { template = nil }
            return true
        }
        if canSaveState(id) {
            // A failed save still shut the guest down: the point is then the disk alone. Not when
            // that shutdown had to force it off.
            let outcome = await pauseVM(recordID: id)
            guard outcome != .notRunning else {
                throw VMError(message: "The VM couldn't be paused to save its clean point")
            }
            guard outcome == .saved || !vm.wasForcedOff else {
                throw VMError(message: "The VM didn't shut down, so no clean point was saved. Try again.")
            }
            return true
        }
        guard await vm.stopGracefully(requestingShutdown: guestPoweroff(id)) else {
            throw VMError(message: "The VM didn't shut down, so no clean point was saved. Try again.")
        }
        didStop(id)
        return true
    }

    /// Runs `body` with VM `id`'s disk claimed, so no Alas process boots it meanwhile. Refused
    /// while any Alas runs it.
    private func withDiskClaimed(_ id: String, _ body: () throws -> Void) throws {
        try claimDisk(id: id)
        defer { releaseDisk(id: id) }
        try body()
    }

    /// Writes `clean.partial/` and renames it into place, so a failure never leaves a partial
    /// `clean/`. Called with the disk claimed.
    private func writeCleanPoint(_ id: String, bundle: VMBundle, setupScriptHash: String?) throws {
        let fm = FileManager.default
        let partial = bundle.url.appendingPathComponent("clean.partial", isDirectory: true)
        try? fm.removeItem(at: partial)
        do {
            try fm.createDirectory(at: partial, withIntermediateDirectories: false)
            try VMBundle.cloneFile(bundle.diskImage, to: partial.appendingPathComponent("disk.img"))
            // Cloned, not moved: the live VM restores from it. Only a state still valid for this
            // disk: another Alas may have restored the VM since the pause.
            if let state = Self.restorableState(id, bundle: bundle) {
                try VMBundle.cloneFile(state, to: partial.appendingPathComponent(state.lastPathComponent))
            }
            try Self.writeCleanPointFile(VMCleanPoint(createdAt: Date(), setupScriptHash: setupScriptHash), in: partial)
            try Self.moveDirectory(partial, into: Self.cleanDirectory(of: bundle))
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        // The new VM's first boot is over with its clean point. Left behind, the marker only
        // makes the next start take the clean point again.
        let marker = Self.firstBootMarker(of: bundle)
        if fm.fileExists(atPath: marker.path) {
            do {
                try fm.removeItem(at: marker)
            } catch {
                logger.error("Removing VM \(id, privacy: .public)'s first boot marker failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    nonisolated private static func writeCleanPointFile(_ point: VMCleanPoint, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(point).write(to: cleanPointFile(in: directory))
    }

    // MARK: - Templates

    /// The template slot worktree `worktreeID`'s new VM of `guest` may clone: its project's, made
    /// from this golden, as sealed now, with the project's current setup script. Nil otherwise.
    private func matchingTemplate(
        worktreeID: String, guest: VMGuestOS, goldenBuild: String, goldenSealedMarker: URL
    ) -> (slot: URL, setupScriptHash: String)? {
        guard let owner = projectVMOwner(worktreeID), let hash = owner.setupScriptHash,
              let sealedAt = Self.sealedAt(goldenSealedMarker) else { return nil }
        let slot = Self.templateSlot(projectID: owner.projectID, guest: guest, root: root)
        guard let template = Self.readTemplate(at: slot), template.projectID == owner.projectID,
              template.matches(goldenBuild: goldenBuild, goldenSealedAt: sealedAt, setupScriptHash: hash)
        else { return nil }
        return (slot, template.setupScriptHash)
    }

    /// Clones VM `id` from `template` with `clone` and gives it the template as its clean point.
    /// Nil, with nothing left at `destination`, when that fails: the caller clones the golden.
    private func cloneFromTemplate(
        _ id: String, template: (slot: URL, setupScriptHash: String), to destination: URL,
        clone: () throws -> VMBundle
    ) -> VMBundle? {
        do {
            let bundle = try clone()
            let clean = Self.cleanDirectory(of: bundle)
            try FileManager.default.createDirectory(at: clean, withIntermediateDirectories: false)
            try VMBundle.cloneFile(bundle.diskImage, to: clean.appendingPathComponent("disk.img"))
            try Self.writeCleanPointFile(VMCleanPoint(createdAt: Date(), setupScriptHash: template.setupScriptHash), in: clean)
            logger.notice("Cloned VM \(id, privacy: .public) from its project's template")
            return bundle
        } catch {
            try? FileManager.default.removeItem(at: destination)
            logger.error("Cloning VM \(id, privacy: .public) from its project's template failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// `<root>/templates/`: one slot per project and guest.
    nonisolated static func templatesDirectory(root: URL) -> URL {
        root.appendingPathComponent("templates", isDirectory: true)
    }

    /// The project's template slot for `guest`: `disk.img`, `aux.img` (macOS) and `template.json`.
    nonisolated static func templateSlot(projectID: String, guest: VMGuestOS, root: URL) -> URL {
        templatesDirectory(root: root)
            .appendingPathComponent(VMTemplate.slotName(projectID: projectID, guest: guest), isDirectory: true)
    }

    nonisolated private static func templateFile(in slot: URL) -> URL {
        slot.appendingPathComponent("template.json")
    }

    nonisolated static func readTemplate(at slot: URL) -> VMTemplate? {
        guard let data = try? Data(contentsOf: templateFile(in: slot)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VMTemplate.self, from: data)
    }

    /// The newest sealed golden of `guest` under `root`: its build and when it was sealed. A
    /// re-customized golden keeps its build but is sealed again.
    nonisolated static func currentGolden(_ guest: VMGuestOS, root: URL) -> (build: String, sealedAt: Date)? {
        let golden: (url: URL, marker: URL)? = switch guest {
        case .macOS: GoldenImageInstaller.availableGolden(root: root).map { ($0.url, $0.sealedMarker) }
        case .linux: LinuxGoldenInstaller.availableGolden(root: root).map { ($0.url, $0.sealedMarker) }
        }
        guard let golden, let sealedAt = sealedAt(golden.marker) else { return nil }
        return (golden.url.lastPathComponent, sealedAt)
    }

    /// Runs `body` holding `<root>/templates.lock`, so no Alas process publishes, clones or prunes
    /// a template meanwhile: a clone never mixes one publish's `template.json` with another's disk.
    nonisolated static func withTemplatesLocked<T>(root: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent("templates.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try body()
    }

    /// Removes the templates nothing can clone again: those of projects not in `liveProjectIDs`,
    /// those made from another golden than the current one, and unreadable or partial slots.
    nonisolated static func pruneTemplates(liveProjectIDs: Set<String>, root: URL) {
        try? withTemplatesLocked(root: root) { pruneTemplatesLocked(liveProjectIDs: liveProjectIDs, root: root) }
    }

    nonisolated private static func pruneTemplatesLocked(liveProjectIDs: Set<String>, root: URL) {
        let fm = FileManager.default
        let slots = (try? fm.contentsOfDirectory(at: templatesDirectory(root: root), includingPropertiesForKeys: nil)) ?? []
        for slot in slots {
            if let template = readTemplate(at: slot), slot.pathExtension != "partial",
               !template.isStale(liveProjectIDs: liveProjectIDs, currentGolden: currentGolden(template.guest, root: root))
            {
                continue
            }
            try? fm.removeItem(at: slot)
        }
    }

    /// When a golden was sealed: its `.sealed` marker's modification date.
    nonisolated private static func sealedAt(_ marker: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date
    }

    /// `<bundle>/golden-sealed-at`: when the golden a VM was cloned from was sealed. A golden
    /// customized since keeps its build, so only this tells its clones apart.
    nonisolated private static func goldenStampFile(of bundle: VMBundle) -> URL {
        bundle.url.appendingPathComponent("golden-sealed-at")
    }

    nonisolated private static func writeGoldenStamp(of marker: URL, into bundle: VMBundle) {
        guard let sealedAt = sealedAt(marker) else { return }
        try? Data(String(sealedAt.timeIntervalSince1970).utf8).write(to: goldenStampFile(of: bundle))
    }

    /// The template VM `id`'s clean point becomes, or nil when it must not: only a first boot's
    /// point (a rerun's disk is a used one), of a running VM in a project with this script, cloned
    /// from the golden that is current now, as it is sealed now.
    private func templateToPublish(_ id: String, bundle: VMBundle, setupScriptHash: String?) -> VMTemplate? {
        let vm = VMIdentity.parse(recordID: id)
        let fm = FileManager.default
        guard let setupScriptHash, runningVMs[id] != nil, !Self.isPaused(bundle),
              fm.fileExists(atPath: Self.firstBootMarker(of: bundle).path),
              let owner = projectVMOwner(vm.worktree), owner.setupScriptHash != nil,
              let golden = Self.currentGolden(vm.guest, root: root),
              let record = (try? registry.snapshot())?.first(where: { $0.id == id }),
              let stamp = (try? String(contentsOf: Self.goldenStampFile(of: bundle), encoding: .utf8)).flatMap(Double.init)
        else { return nil }
        let recordGolden = vm.guest == .linux
            ? String(record.goldenBuild.dropFirst(VMIdentity.linuxGoldenPrefix.count)) : record.goldenBuild
        let template = VMTemplate(
            projectID: owner.projectID, guest: vm.guest, goldenBuild: golden.build, goldenSealedAt: golden.sealedAt,
            setupScriptHash: setupScriptHash, createdAt: Date())
        guard template.matches(
            goldenBuild: recordGolden, goldenSealedAt: Date(timeIntervalSince1970: stamp), setupScriptHash: setupScriptHash)
        else { return nil }
        return template
    }

    /// Publishes VM `id`'s clean point, just taken after a clean shutdown, as `template`,
    /// replacing the project's earlier one. Never throws: a VM without a template only loses a
    /// shortcut. Called with the disk claimed.
    private func publish(_ template: VMTemplate, from id: String, bundle: VMBundle) {
        do {
            try Self.withTemplatesLocked(root: root) { try Self.stage(template, from: bundle, root: root) }
            logger.notice("Published VM \(id, privacy: .public)'s clean point as its project's template")
        } catch {
            logger.error("Publishing VM \(id, privacy: .public)'s template failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Builds `template` in its slot's `.partial` and swaps it in. Called with the templates locked.
    nonisolated private static func stage(_ template: VMTemplate, from bundle: VMBundle, root: URL) throws {
        let fm = FileManager.default
        let slot = templateSlot(projectID: template.projectID, guest: template.guest, root: root)
        let partial = slot.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        do {
            try fm.createDirectory(at: partial, withIntermediateDirectories: true)
            try VMBundle.cloneFile(
                cleanDirectory(of: bundle).appendingPathComponent("disk.img"), to: partial.appendingPathComponent("disk.img"))
            if template.guest == .macOS {
                try VMBundle.cloneFile(bundle.auxiliaryStorage, to: partial.appendingPathComponent("aux.img"))
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(template).write(to: templateFile(in: partial))
            try moveDirectory(partial, into: slot)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    nonisolated private static func markFirstBootPending(_ bundle: VMBundle) throws {
        try Data().write(to: firstBootMarker(of: bundle))
    }

    /// Renames `source` to `destination` in one step, swapping out an existing one, which is then
    /// removed.
    nonisolated private static func moveDirectory(_ source: URL, into destination: URL) throws {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return try FileManager.default.moveItem(at: source, to: destination)
        }
        guard renamex_np(source.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // `source` now holds the old one.
        try? FileManager.default.removeItem(at: source)
    }

    /// Replaces the stopped VM's disk with a clone of the clean point's, and its saved state with
    /// the clean point's, recorded as paused so the next start restores it. Called with the disk
    /// claimed.
    private func restoreCleanPoint(_ id: String, bundle: VMBundle) throws {
        let clean = Self.cleanDirectory(of: bundle)
        let state = Self.savedStateURL(of: bundle)
        // The live state goes first, its `state.json` before the disk changes: an interruption
        // past this point must cold-boot, never restore the old memory onto the clean disk.
        let info = Self.savedStateInfoURL(of: bundle)
        if FileManager.default.fileExists(atPath: info.path) { try FileManager.default.removeItem(at: info) }
        Self.removeSavedState(of: bundle)
        let staged = bundle.url.appendingPathComponent("disk.img.resetting")
        try? FileManager.default.removeItem(at: staged)
        try cloneCleanFile(clean.appendingPathComponent("disk.img"), staged)
        guard rename(staged.path, bundle.diskImage.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        let cleanState = clean.appendingPathComponent(state.lastPathComponent)
        guard VMIdentity.parse(recordID: id).guest == .macOS, FileManager.default.fileExists(atPath: cleanState.path)
        else { return }
        try cloneCleanFile(cleanState, state)
        // Read after the swap: restore accepts the state only for the disk as it is now.
        guard let stamp = Self.diskStamp(of: bundle) else {
            Self.removeSavedState(of: bundle)
            return
        }
        try Self.writeSavedStateInfo(VMSavedState.Info(diskStamp: stamp), of: bundle)
    }

    /// Whether VM `recordID` awaits its first boot's setup and clean point.
    func isFirstBootPending(recordID: String) -> Bool {
        guard vmsExist, !recordID.hasPrefix(Self.goldenIDPrefix) else { return false }
        return FileManager.default.fileExists(atPath: Self.firstBootMarker(of: bundle(forID: recordID)).path)
    }

    /// Whether a VM that just started here runs the first-boot setup: a worktree VM (not a golden)
    /// created new and without its clean point yet, not already being set up, and without a
    /// failed script awaiting "Run again" or "Skip".
    nonisolated static func runsFirstBootSetup(
        recordID: String, firstBootPending: Bool, setupRunning: Bool, setupFailed: Bool
    ) -> Bool {
        !recordID.hasPrefix(goldenIDPrefix) && VMIdentity.projectDraftID(recordID: recordID) == nil
            && firstBootPending && !setupRunning && !setupFailed
    }

    /// Whether creating a worktree also creates its macOS VM: the project (or its repo) asks, the
    /// worktree is on this Mac, the Mac can run macOS guests, and a sealed golden image exists.
    /// Without one, the VM is skipped silently and created on demand later.
    nonisolated static func shouldCreateVM(
        requested: Bool, isAppleSilicon: Bool, goldenAvailable: Bool, isRemote: Bool
    ) -> Bool {
        requested && isAppleSilicon && goldenAvailable && !isRemote
    }

    /// Starts VM `id` again after a disk operation that stopped it. `done` says what succeeded,
    /// for when it can't start.
    private func startAgain(_ id: String, done: String) async throws {
        let outcome: VMStartOutcome
        do {
            outcome = try await startRecorded(id: id, ensureRecord: nil, insideDiskOperation: true)
        } catch let error as RestartFailed {
            throw error
        } catch {
            // What the disk operation did still holds: only the start failed.
            throw RestartFailed(message: "\(done), but the VM couldn't start again: \(error.localizedDescription)")
        }
        switch outcome {
        case .running:
            return
        case .runningElsewhere(let label):
            throw RestartFailed(message: "\(done), but the VM is now running in \(label).")
        case .needsUserChoice:
            throw RestartFailed(message: "\(done), but no VM slot is free to start it again.")
        }
    }

    // MARK: - Guest helper

    /// Records what the guest helper of a VM running here answered: missing
    /// or unresponsive, or of another protocol revision, offers an update.
    /// `linuxHelperDiffers` is nil from a check that didn't compare the
    /// installed Linux helper, which keeps the last comparison.
    func noteHelperCheck(
        _ id: String, _ result: Result<VMGuestHello, VMGuestClient.Failure>, linuxHelperDiffers: Bool? = nil
    ) {
        guard runningVMs[id] != nil else { return }
        if let linuxHelperDiffers {
            if linuxHelperDiffers { linuxHelpersDiffering.insert(id) } else { linuxHelpersDiffering.remove(id) }
        }
        let guest = VMIdentity.parse(recordID: id).guest
        let differs = linuxHelpersDiffering.contains(id)
        if Self.helperNeedsUpdate(result, guest: guest, linuxHelperDiffers: differs) {
            helpersNeedingUpdate.insert(id)
        } else {
            helpersNeedingUpdate.remove(id)
        }
    }

    /// Whether a helper check result calls for Update helper. A stopped VM
    /// or a cancelled check says nothing about the helper. A Linux helper is
    /// updated through itself, so only one that answers calls for it: when
    /// it isn't the helper this build shares (`linuxHelperDiffers`), or
    /// can't do computer use yet.
    nonisolated static func helperNeedsUpdate(
        _ result: Result<VMGuestHello, VMGuestClient.Failure>, guest: VMGuestOS = .macOS,
        linuxHelperDiffers: Bool = false
    ) -> Bool {
        if guest == .linux {
            guard case .success(let hello) = result, hello.protocolRevision == VMGuestProtocol.revision else { return false }
            return linuxHelperDiffers || VMComputerUseRoute.linuxComputerUse(capabilities: hello.capabilities) == .outdated
        }
        return switch result {
        case .success(let hello): hello.protocolRevision != VMGuestProtocol.revision
        case .failure(.helperMissing), .failure(.helperUnresponsive), .failure(.outdated): true
        case .failure: false
        }
    }

    /// Whether the Linux helper behind `client` isn't the one this build shares. Only a check that
    /// ran and found them different says so.
    func linuxHelperDiffers(_ client: VMGuestClient) async -> Bool {
        let result = try? await client.run(LinuxGuestSetup.helperDiffersCommand, timeoutSeconds: 10)
        return result?.exitCode == 1
    }

    func dismissHelperUpdateFailure(_ id: String) {
        helperUpdateFailures.removeValue(forKey: id)
    }

    /// Reinstalls the helper in VM `id` (a worktree's, or a golden's awaiting
    /// setup) through `VMHelperUpdater`: restarts the VM, which ends up
    /// running with the new helper, or stopped with `helperUpdateFailures` set.
    /// A Linux VM's helper is reinstalled in place instead.
    func updateHelper(_ id: String) async {
        let vm = VMIdentity.parse(recordID: id)
        if vm.guest == .linux { return await updateLinuxHelper(id, worktreeID: vm.worktree) }
        if id.hasPrefix(Self.goldenIDPrefix),
           !isGoldenCustomized(build: String(id.dropFirst(Self.goldenIDPrefix.count))) {
            // A golden awaiting its first setup has no helper to update yet.
            helperUpdateFailures[id] = "Couldn't update the helper: set up this macOS image first."
            return
        }
        guard updatingHelpers.insert(id).inserted else { return }
        defer { updatingHelpers.remove(id) }
        helperUpdateFailures.removeValue(forKey: id)
        switch await VMHelperUpdater.live(manager: self, id: id).run(id: id, bundle: bundle(forID: id)) {
        case .updated:
            helpersNeedingUpdate.remove(id)
        case .failed(let reason):
            helperUpdateFailures[id] = "Couldn't update the helper (\(reason)). Start the VM and try again, or install it from My Shared Files › helper › Install Alas VM Guest."
        }
    }

    /// Reinstalls the helper of Linux VM `id` through the helper itself; the
    /// VM keeps running.
    private func updateLinuxHelper(_ id: String, worktreeID: String) async {
        guard updatingHelpers.insert(id).inserted else { return }
        defer { updatingHelpers.remove(id) }
        helperUpdateFailures.removeValue(forKey: id)
        let outcome = if let client = guestClient(for: worktreeID, guest: .linux) {
            await LinuxVMHelperUpdater.live(client: client).run()
        } else {
            VMHelperUpdater.Outcome.failed(reason: LinuxVMHelperUpdater.Reason.notRunning)
        }
        switch outcome {
        case .updated:
            helpersNeedingUpdate.remove(id)
            linuxHelpersDiffering.remove(id)
        case .failed(let reason):
            helperUpdateFailures[id] = "Couldn't update the helper (\(reason)). Restart the VM and try again."
        }
    }

    /// The bundle of VM `id`, a worktree's or a golden's.
    private func bundle(forID id: String) -> VMBundle {
        if id.hasPrefix(Self.goldenIDPrefix) {
            return VMBundle(url: goldenBundleURL(build: String(id.dropFirst(Self.goldenIDPrefix.count))))
        }
        // A lockless read: a write here would drop the fields of records only newer builds know.
        let recorded = (try? registry.read())?.records.first { $0.id == id }?.bundlePath
        let (worktree, guest) = VMIdentity.parse(recordID: id)
        return VMBundle(url: recorded.map { URL(fileURLWithPath: $0) }
            ?? Self.bundleURL(forWorktree: worktree, guest: guest, root: root))
    }

    // MARK: - Leftover sshd

    /// Written into a bundle before a patch turns the guest's sshd on, and
    /// removed once the in-guest finishing step or an offline edit turned it
    /// off again. Left behind, the guest may run sshd with a known password.
    nonisolated static func sshdEnabledMarker(of bundle: VMBundle) -> URL {
        bundle.url.appendingPathComponent(".sshd-enabled")
    }

    /// Turns sshd off on stopped VM `id`'s disk when a setup or helper
    /// update that turned it on was interrupted (Alas quit, or the offline
    /// fix failed). The disk is claimed meanwhile, so no Alas process boots it.
    func turnOffLeftoverSSH(id: String) async throws {
        let bundle = bundle(forID: id)
        let marker = Self.sshdEnabledMarker(of: bundle)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try claimDisk(id: id)
        do {
            try await disableSSHOffline(bundle)
        } catch is VMDiskSession.DetachFailed {
            // Still attached on the host: the claim stays so nothing boots it.
            logger.error("VM \(id, privacy: .public)'s disk stayed attached after turning sshd off; keeping its claim")
            throw VMError(message: "The VM's disk couldn't be detached from this Mac. Restart Alas, then try again.")
        } catch {
            releaseDisk(id: id)
            logger.error("Turning leftover sshd off in VM \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw VMError(message: "SSH is still on in this VM and couldn't be turned off (\(error.localizedDescription)). Try again.")
        }
        releaseDisk(id: id)
        try? FileManager.default.removeItem(at: marker)
        logger.notice("Turned leftover sshd off in VM \(id, privacy: .public)")
    }

    // MARK: - Golden VM

    /// Boots the golden VM so the user can finish Setup Assistant. It takes a
    /// slot like any worktree VM.
    /// Refuses a sealed image: worktree VMs clone its disk, so it must not
    /// change after sealing. `keepingSSH` is only for the unattended setup's
    /// and `VMHelperUpdater`'s own boots, which log in over SSH.
    func startGolden(build: String, keepingSSH: Bool = false) async throws -> VMStartOutcome {
        let id = Self.goldenIDPrefix + build
        let bundleURL = goldenBundleURL(build: build)
        guard !VMBundle(url: bundleURL).isSealed else {
            throw VMError(message: "This macOS image is already set up")
        }
        if !keepingSSH { try await turnOffLeftoverSSHBeforeBoot(id: id) }
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

    /// Powers a VM off at once, running or still booting. Only for a boot
    /// whose disk need not be consistent: a worktree clone, or a golden that
    /// will not be sealed from this run.
    func forceStop(id: String) async {
        do {
            try await stop(id, force: true)
        } catch {
            logger.error("Forcing VM \(id, privacy: .public) off failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Powers the golden VM off at once, running or still booting. Only for
    /// boots whose disk will not be sealed from this run: the unattended
    /// setup's first boot, or giving up on it.
    func forceStopGolden(build: String) async {
        await forceStop(id: Self.goldenIDPrefix + build)
    }

    /// Reserves a stopped VM's record for this process while its disk is
    /// attached on the host: under the registry lock boot admission and
    /// sealing take, the record gets this process as owner, so no Alas
    /// process boots (or seals) it until `releaseDisk`.
    func claimDisk(id: String) throws {
        guard let me = VMRunOwner.current(label: ownerLabel) else {
            throw VMError(message: "Could not identify this Alas process, so the VM cannot be tracked")
        }
        guard !diskClaims.contains(id) else { throw VMError(message: "The VM's disk is already open") }
        guard runningVMs[id] == nil, !starting.contains(id) else { throw VMError(message: "The VM is running") }
        let isGolden = id.hasPrefix(Self.goldenIDPrefix)
        try registry.update { records in
            if isGolden, goldenRunsAnywhere(records) {
                throw VMError(message: "The golden VM is running")
            }
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw VMError(message: "The VM has no record")
            }
            if let owner = records[index].runOwner {
                throw VMError(message: "The VM is running in \(owner.label)")
            }
            records[index].runOwner = me
        }
        diskClaims.insert(id)
    }

    func releaseDisk(id: String) {
        guard diskClaims.remove(id) != nil else { return }
        clearOwner(id)
    }

    /// Whether this process runs or boots the golden VM.
    func isGoldenRunning(build: String) -> Bool {
        let id = Self.goldenIDPrefix + build
        return runningVMs[id] != nil || starting.contains(id)
    }

    /// The guest helper's current version and grants in a VM this process runs.
    func helperStatus(id: String) async throws -> VMGuestHello {
        guard let client = guestClient(for: id) else {
            throw VMError(message: "The VM is not running")
        }
        return try await client.status()
    }

    /// Runs `command` in a guest this process runs, through its helper, without waiting
    /// for the result: a command that shuts the guest down drops the
    /// connection before it can answer. The guest stopping by itself is
    /// recorded as a clean shutdown, as for one from the Apple menu.
    func requestGuestCommand(id: String, _ command: String) {
        guard let client = guestClient(for: id) else { return }
        let logger = logger
        Task {
            do {
                _ = try await client.run(command, timeoutSeconds: 60)
            } catch {
                logger.notice("Guest command ended without a reply: \(String(describing: error), privacy: .public)")
            }
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
            // Every clone would run sshd with the known password.
            guard !FileManager.default.fileExists(atPath: Self.sshdEnabledMarker(of: bundle).path) else {
                throw VMError(message: "SSH is still enabled on this image; click Set up automatically or try again")
            }
            try GoldenImageInstaller.writeSealedMarker(bundle)
            try? FileManager.default.removeItem(at: Self.customizingMarker(of: bundle))
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
            // Before unsealing: an unsealed golden without it may be set up
            // unattended, which would overwrite the user's changes.
            try Data().write(to: Self.customizingMarker(of: golden))
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

    /// A fresh machine identifier for a worktree clone of the golden image.
    private static func newMachineIdentifier() throws -> Data {
        #if arch(arm64)
        return VZMacMachineIdentifier().dataRepresentation
        #else
        throw VMError(message: unsupportedMessage)
        #endif
    }

    /// Marks a golden unsealed by Customize: only the manual flow finishes it.
    nonisolated static func customizingMarker(of bundle: VMBundle) -> URL {
        bundle.url.appendingPathComponent(".customizing")
    }

    /// Whether the unsealed golden `build` was reopened by Customize rather
    /// than freshly installed, after a relaunch too.
    func isGoldenCustomized(build: String) -> Bool {
        FileManager.default.fileExists(
            atPath: Self.customizingMarker(of: VMBundle(url: goldenBundleURL(build: build))).path)
    }

    func goldenBundleURL(build: String) -> URL {
        root.appendingPathComponent("golden", isDirectory: true).appendingPathComponent(build, isDirectory: true)
    }

    // MARK: - Disk use

    /// Base images and worktree VMs with the disk they use, and apart from them the orphaned VM
    /// bundles: those under `worktrees/` no live worktree owns, because no record names them or
    /// their record's worktree is neither on disk nor in a project. One any Alas runs, or one a
    /// record this build can't decode names, never is. One scan; sizes are read off the main
    /// actor. Throws when the registry can't be read, rather than taking every VM for an orphan.
    func diskUse(liveProjectIDs: Set<String>? = nil) async throws -> VMDiskUse {
        let scanned = try scanBundles() + scanProjectBundles(liveProjectIDs: liveProjectIDs)
        async let bundles = VMBundleSummary.measured(scanned.filter { !$0.isOrphan })
        async let orphans = VMBundleSummary.measured(scanned.filter(\.isOrphan))
        return await VMDiskUse(bundles: bundles, orphans: orphans)
    }

    private func scanProjectBundles(liveProjectIDs: Set<String>?) throws -> [VMBundleSummary] {
        let projects = try projectBases.list()
        guard !projects.isEmpty else { return [] }
        let (records, foreign) = try registry.read()
        let me = VMRunOwner.current(label: ownerLabel)
        var summaries: [VMBundleSummary] = []
        for entry in projects {
            let project = entry.state.projectID
            let orphan = liveProjectIDs.map { !$0.contains(project) } ?? false
            if let base = entry.state.base, let url = entry.baseURL {
                summaries.append(.init(id: Self.projectBasePrefix + base.id.uuidString, kind: .projectBase,
                    guest: .macOS, name: project, worktreeID: nil, url: url, runningHere: false, runningElsewhere: nil,
                    isOrphan: orphan, leftovers: [], projectID: project, projectGeneration: base.id))
            }
            if let draft = entry.state.draft, let url = entry.draftURL {
                let id = VMIdentity.projectDraftRecordID(draft.id)
                let owner = records.first { $0.id == id }?.runOwner
                let elsewhere = owner.flatMap { me.map($0.isSameProcess(as:)) == true ? nil : $0.label }
                summaries.append(.init(id: id, kind: .projectDraft, guest: .macOS, name: project, worktreeID: nil,
                    url: url, runningHere: isBusyHere(id), runningElsewhere: elsewhere, isOrphan: orphan,
                    fromOtherBuild: foreign.contains(url.path), leftovers: [], projectID: project, projectGeneration: draft.id))
            }
        }
        return summaries
    }

    /// Deletes the orphans among `ids` (`VMBundleSummary.id`s) that a fresh scan still finds
    /// orphaned, with their records, then the leftovers of interrupted resets and clean points in
    /// VMs no Alas runs. Returns why some were left, if any.
    @discardableResult
    func deleteOrphans(_ ids: [String]) -> String? {
        guard vmsExist else { return nil }
        // Listed a while ago: a VM started or a worktree came back since is kept, and what is
        // deleted is what the registry says now.
        let orphans: [VMBundleSummary]
        do {
            orphans = try scanBundles().filter { $0.isOrphan && ids.contains($0.id) }
        } catch {
            return "the VM registry couldn't be read (\(error.localizedDescription))"
        }
        var reasons: [String] = []
        for orphan in orphans {
            if let recordID = orphan.recordID {
                if let reason = removeRecordAndBundle(recordID) {
                    reasons.append("\(orphan.name): \(reason)")
                } else {
                    onVMDeleted(recordID)
                }
                continue
            }
            do {
                // Under the registry lock, so a create cloning into this folder can't race it.
                try registry.updateSeeingForeignBundles { records, foreign in
                    let folder = orphan.url.lastPathComponent
                    let named = records.map(\.bundlePath) + foreign
                    guard !named.contains(where: { URL(fileURLWithPath: $0).lastPathComponent == folder }),
                          FileManager.default.fileExists(atPath: orphan.url.path)
                    else { return }
                    try FileManager.default.removeItem(at: orphan.url)
                }
            } catch {
                reasons.append("\(orphan.name): \(error.localizedDescription)")
            }
        }
        do {
            try registry.update { records in
                for record in records where !record.id.hasPrefix(Self.goldenIDPrefix) && record.runOwner == nil
                    && !isBusyHere(record.id)
                {
                    for leftover in VMDiskUsage.leftovers(in: URL(fileURLWithPath: record.bundlePath)) {
                        do {
                            try FileManager.default.removeItem(at: leftover)
                        } catch {
                            logger.error("Removing \(leftover.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                            reasons.append("\(leftover.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            }
        } catch {
            reasons.append(error.localizedDescription)
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    /// Deletes base image `id` (a `VMBundleSummary.id`). Refused while VMs cloned from it exist,
    /// while it runs, and while an install or setup holds its guest's install lock.
    func deleteGolden(id: String) throws {
        let guest: VMGuestOS
        let name: String
        if id.hasPrefix(Self.goldenIDPrefix) {
            (guest, name) = (.macOS, String(id.dropFirst(Self.goldenIDPrefix.count)))
        } else if id.hasPrefix(VMIdentity.linuxGoldenPrefix) {
            (guest, name) = (.linux, String(id.dropFirst(VMIdentity.linuxGoldenPrefix.count)))
        } else {
            throw VMError(message: "Not a base image")
        }
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw VMError(message: "Not a base image")
        }
        let url = guest == .macOS
            ? goldenBundleURL(build: name)
            : root.appendingPathComponent("golden-linux", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        let lock = try installLock(guest, busy: "The base image is being set up. Try again once that finishes.")
        defer { lock.release() }
        // Clones record the macOS build as is, the Linux serial with its prefix.
        let cloneBuild = guest == .macOS ? name : id
        let goldenRecord = Self.goldenIDPrefix + name
        // Under the registry lock `createVM` re-checks the golden under, so no clone starts from
        // a half-deleted image.
        try registry.update { records in
            guard !records.contains(where: { !$0.id.hasPrefix(Self.goldenIDPrefix) && $0.goldenBuild == cloneBuild })
            else { throw VMError(message: "Delete its worktree VMs first") }
            if guest == .macOS {
                if isBusyHere(goldenRecord) || records.contains(where: { $0.id == goldenRecord && $0.runOwner != nil }) {
                    throw VMError(message: "The base image is running. Shut it down first.")
                }
                records.removeAll { $0.id == goldenRecord }
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// The allocated bytes of the downloaded installers under `ipsw/` and `linux-images/`.
    func installerBytes() async -> Int64 {
        let directories = installerDirectories
        return await Task.detached(priority: .utility) {
            directories.reduce(0) { $0 + VMDiskUsage.allocatedBytes(inTree: $1) }
        }.value
    }

    /// Deletes the downloaded installers. Refused while an install holds either install lock,
    /// which it does from its download through its setup.
    func removeInstallers() throws {
        guard vmsExist else { return }
        let busy = "An install is downloading or setting up. Try again once it finishes."
        let macOS = try installLock(.macOS, busy: busy)
        defer { macOS.release() }
        let linux = try installLock(.linux, busy: busy)
        defer { linux.release() }
        for directory in installerDirectories where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private var installerDirectories: [URL] {
        ["ipsw", "linux-images"].map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// Takes `guest`'s install lock without waiting, as the installers do; `busy` is the
    /// refusal while an install holds it, in this Alas or another.
    private func installLock(_ guest: VMGuestOS, busy: String) throws -> ComputerUseDriverLock {
        let file = guest == .macOS ? "install.lock" : "install-linux.lock"
        do {
            return try ComputerUseDriverLock.acquire(at: root.appendingPathComponent(file), label: ownerLabel)
        } catch {
            switch error {
            case .held: throw VMError(message: busy)
            case .unavailable(let reason): throw VMError(message: reason)
            }
        }
    }

    /// Whether this process runs VM `id`, boots it, pauses it, or works on its disk.
    private func isBusyHere(_ id: String) -> Bool {
        runningVMs[id] != nil || starting.contains(id) || pausing.contains(id)
            || diskClaims.contains(id) || diskOperations.contains(id)
    }

    /// Every base image and worktree VM bundle on disk, without sizes. Cheap enough for the main
    /// actor: directory listings and one registry read.
    private func scanBundles() throws -> [VMBundleSummary] {
        guard vmsExist else { return [] }
        // Read without writing, so fields only a newer build knows survive.
        let (records, foreignBundlePaths) = try registry.read()
        let foreignFolders = Set(foreignBundlePaths.map { URL(fileURLWithPath: $0).lastPathComponent })
        let me = VMRunOwner.current(label: ownerLabel)
        func elsewhere(_ owner: VMRunOwner?) -> String? {
            owner.flatMap { me.map($0.isSameProcess(as:)) == true ? nil : $0.label }
        }
        let vmRecords = records.filter { !$0.id.hasPrefix(Self.goldenIDPrefix) && VMIdentity.projectDraftID(recordID: $0.id) == nil }
        func clones(of goldenBuild: String) -> Int {
            vmRecords.filter { $0.goldenBuild == goldenBuild }.count
        }
        var bundles: [VMBundleSummary] = []
        for golden in GoldenImageInstaller.goldenBundles(root: root) {
            let build = golden.url.lastPathComponent
            let id = Self.goldenIDPrefix + build
            bundles.append(VMBundleSummary(
                id: id, kind: .golden, guest: .macOS, name: build,
                osVersion: GoldenImageInstaller.osVersion(of: golden.url), worktreeID: nil, url: golden.url,
                runningHere: isBusyHere(id), runningElsewhere: elsewhere(records.first { $0.id == id }?.runOwner),
                isOrphan: false, leftovers: [], clones: clones(of: build)))
        }
        for url in Self.subdirectories(of: root.appendingPathComponent("golden-linux", isDirectory: true))
            where !url.lastPathComponent.hasSuffix(".partial")
        {
            bundles.append(VMBundleSummary(
                id: VMIdentity.linuxGoldenPrefix + url.lastPathComponent, kind: .golden, guest: .linux,
                name: url.lastPathComponent, worktreeID: nil, url: url, runningHere: false, runningElsewhere: nil,
                isOrphan: false, leftovers: [], clones: clones(of: VMIdentity.linuxGoldenPrefix + url.lastPathComponent)))
        }
        let folderOf = Dictionary(
            vmRecords.map { ($0.id, URL(fileURLWithPath: $0.bundlePath).lastPathComponent) },
            uniquingKeysWith: { first, _ in first })
        let recordIn = Dictionary(folderOf.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let folders = Self.subdirectories(of: root.appendingPathComponent("worktrees", isDirectory: true))
        let orphaned = Set(VMOrphans.find(
            bundleNames: folders.map(\.lastPathComponent).filter { !foreignFolders.contains($0) }, records: vmRecords,
            worktreeExists: { FileManager.default.fileExists(atPath: $0) || worktreePath($0) != nil },
            bundleName: { worktree, guest in
                // A record's own bundle path wins over the name a create would give it.
                folderOf[VMIdentity.recordID(worktree: worktree, guest: guest)]
                    ?? Self.directoryName(forWorktree: worktree, guest: guest)
            }))
        for url in folders {
            let folder = url.lastPathComponent
            let record = recordIn[folder].flatMap { id in vmRecords.first { $0.id == id } }
            let parsed = record.map { VMIdentity.parse(recordID: $0.id) }
            let busyHere = record.map { isBusyHere($0.id) } ?? false
            // A record this build can't decode may belong to a VM a newer Alas runs.
            let fromOtherBuild = record == nil && foreignFolders.contains(folder)
            let live = busyHere || record?.runOwner != nil || fromOtherBuild
            bundles.append(VMBundleSummary(
                id: "worktrees/" + folder, kind: .worktree,
                guest: parsed?.guest ?? (folder.hasSuffix("-linux") ? .linux : .macOS), name: folder,
                worktreeID: parsed?.worktree, url: url, runningHere: busyHere,
                runningElsewhere: elsewhere(record?.runOwner),
                isOrphan: orphaned.contains(folder) && !live, fromOtherBuild: fromOtherBuild,
                leftovers: live || record == nil ? [] : VMDiskUsage.leftovers(in: url)))
        }
        return bundles
    }

    nonisolated private static func subdirectories(of directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            let url = directory.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { return nil }
            return url
        }
    }

    // MARK: - Internals

    /// `<root>/worktrees/<name>-<hash>[-linux]/`: a readable, filesystem-safe
    /// name from the worktree's last path component plus a digest of the full
    /// id, and a suffix for a Linux VM.
    static func bundleURL(forWorktree worktreeID: String, guest: VMGuestOS = .macOS, root: URL) -> URL {
        root.appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(directoryName(forWorktree: worktreeID, guest: guest), isDirectory: true)
    }

    private static func directoryName(forWorktree worktreeID: String, guest: VMGuestOS) -> String {
        switch guest {
        case .macOS: directoryName(forWorktree: worktreeID)
        case .linux: directoryName(forWorktree: worktreeID) + "-linux"
        }
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
        /// `restoringFrom` is a saved state still valid for the disk; `wasPaused` whether the
        /// bundle had one at all.
        case boot(VMBundle, generation: Int, restoringFrom: URL?, wasPaused: Bool)
        case outcome(VMStartOutcome)
    }

    /// Decides under the registry lock and reserves the slot by recording this
    /// process as owner before booting, so two processes cannot both take the
    /// last slot. The reservation is released if the boot fails.
    private func startRecorded(
        id: String, ensureRecord: ((inout [WorktreeVMRecord]) throws -> Void)?, insideDiskOperation: Bool = false
    ) async throws -> VMStartOutcome {
        // A clean point or reset in progress starts the VM itself when it is done, and a VM being
        // paused starts again once its state is saved, from that state. Both are checked again
        // after every wait: a disk operation may begin while a pause runs, and the other way round.
        while (!insideDiskOperation && diskOperations.contains(id)) || pauses[id] != nil {
            if let pause = pauses[id] {
                _ = await pause.value
            } else {
                await withCheckedContinuation { diskOperationWaiters[id, default: []].append($0) }
            }
        }
        if let vm = runningVMs[id] { return .running(vm) }
        // Checked after the waits: a disk operation that ends during quit doesn't start it again.
        guard !isQuitting else { throw VMError(message: "Alas is quitting") }
        guard !starting.contains(id) else {
            throw VMError(message: "This VM is already starting")
        }
        guard !diskClaims.contains(id) else {
            throw VMError(message: "This VM's disk is being updated. Wait for it to finish.")
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
                let bundle = VMBundle(url: URL(fileURLWithPath: records[index].bundlePath))
                let fm = FileManager.default
                let wasPaused = fm.fileExists(atPath: Self.savedStateURL(of: bundle).path)
                    || fm.fileExists(atPath: Self.savedStateInfoURL(of: bundle).path)
                return .boot(
                    bundle, generation: generation, restoringFrom: Self.restorableState(id, bundle: bundle),
                    wasPaused: wasPaused)
            case .alreadyRunningHere:
                throw VMError(message: "This VM is already starting")
            case .runningElsewhere(let label):
                return .outcome(.runningElsewhere(label: label))
            case .needsUserChoice(let candidates):
                return .outcome(.needsUserChoice(candidates: candidates.filter {
                    localIDs.contains($0) && !isSetupRunning(recordID: $0) && !diskOperations.contains($0)
                }))
            }
        }
        let bundle: VMBundle
        let generation: Int
        let restoringFrom: URL?
        let wasPaused: Bool
        switch admission {
        case .outcome(let outcome): return outcome
        case .boot(let booting, let bootGeneration, let state, let paused):
            (bundle, generation, restoringFrom, wasPaused) = (booting, bootGeneration, state, paused)
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
            booted = .success(try await bootOrRestore(id, bundle: bundle, restoringFrom: restoringFrom))
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
        // A started VM no longer has a saved state: a later crash must not restore it.
        if wasPaused { Self.removeSavedState(of: bundle) }
        onVMStarted(id)
        return .running(vm)
    }

    /// Restores the VM from its saved state when it has one; a restore that fails is logged,
    /// never surfaced, and the VM cold-boots instead.
    private func bootOrRestore(_ id: String, bundle: VMBundle, restoringFrom state: URL?) async throws -> RunningVM {
        let shares = try shares(forRecord: id, bundlePath: bundle.url.path)
        guard let state else { return try await start(id, bundle, shares, nil) }
        do {
            let vm = try await start(id, bundle, shares, state)
            logger.notice("Resumed VM \(id, privacy: .public) from its saved state")
            return vm
        } catch let failure as RestoreFailed {
            logger.error("Restoring VM \(id, privacy: .public) failed, cold-booting it: \(String(describing: failure.underlying), privacy: .public)")
            Self.removeSavedState(of: bundle)
            return try await start(id, bundle, shares, nil)
        }
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
        startedAt[id] = now()
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
        helpersNeedingUpdate.remove(id)
        linuxHelpersDiffering.remove(id)
        startedAt.removeValue(forKey: id)
        if let client = guestClients.removeValue(forKey: id) {
            Task { await client.close() }
        }
        guard runningVMs.removeValue(forKey: id) != nil else { return }
        // A pause clears the owner itself, once it recorded the saved state.
        if !pausing.contains(id), !publishingDrafts.contains(id) { clearOwner(id) }
        if let draft = VMIdentity.projectDraftID(recordID: id) {
            projectDraftRuns.removeValue(forKey: draft)?.task.cancel()
        }
        if diskOperations.contains(id) { stoppedForDiskOperation.insert(id) } else { onVMStopped(id) }
    }

    func waitForSetupHelper(recordID id: String) async -> Bool {
        await GuestSetupSteps.waitUntil(
            timeout: .seconds(600), interval: .seconds(5),
            sleep: { try? await Task.sleep(for: $0) }, now: { .now }
        ) { [weak self] in
            guard !Task.isCancelled, let self, let client = guestClient(recordID: id) else { return true }
            return (try? await client.hello()) != nil
        } && !Task.isCancelled && runningVMs[id] != nil
    }

    func isSetupRunning(recordID id: String) -> Bool {
        isRunningSetup(id) || VMIdentity.projectDraftID(recordID: id).map(isProjectDraftSettingUp) == true
    }

    func isProjectDraftSettingUp(_ draft: UUID) -> Bool { projectDraftRuns[draft] != nil }

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

// MARK: - Project macOS base

extension WorktreeVMManager {
    enum ProjectDraftMode {
        case customize
        case rebuild(expectedDraft: UUID?)
    }

    enum ProjectDraftPreparation {
        case draft(ProjectVMBaseStore.Draft)
        case needsSharedBase
    }

    func projectBaseStatus(projectID: String) throws -> ProjectVMBaseStore.State {
        try projectBases.status(projectID: projectID)
    }

    func projectDraftRecordStatus(draftID: UUID) -> RecordStatus {
        recordStatus(recordID: VMIdentity.projectDraftRecordID(draftID))
    }

    func projectIDForDraft(_ draftID: UUID) -> String? {
        (try? projectBases.list())?.first { $0.state.draft?.id == draftID }?.state.projectID
    }

    func projectDraftTransferDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("transfer/project-drafts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func prepareProjectDraft(projectID: String, script: String?, mode: ProjectDraftMode = .customize) async throws -> ProjectDraftPreparation {
        let selectedScript = VMCleanPoint.scriptHash(script) == nil ? nil : script
        switch mode {
        case .customize, .rebuild(expectedDraft: nil):
            return try selectProjectDraft(projectID: projectID, script: selectedScript, mode: mode)
        case .rebuild(expectedDraft: let draftID?):
            guard availableGolden() != nil else { return .needsSharedBase }
            let id = VMIdentity.projectDraftRecordID(draftID)
            return try await withDiskOperation(id) {
                guard !isProjectDraftSettingUp(draftID) else { throw VMError(message: "Wait for the setup script to finish") }
                if let pause = pauses[id] { _ = await pause.value }
                if let vm = runningVMs[id] {
                    guard await shutDownProjectDraft(id, vm: vm) else {
                        throw VMError(message: "The draft is still running. Shut it down before rebuilding.")
                    }
                }
                return try selectProjectDraft(projectID: projectID, script: selectedScript, mode: mode)
            }
        }
    }

    private func selectProjectDraft(projectID: String, script: String?, mode: ProjectDraftMode) throws -> ProjectDraftPreparation {
        let result: ProjectDraftPreparation = try registry.withSnapshotLocked { records in
            try projectBases.withProject(projectID) { transaction in
                let expected: UUID?
                let source: ProjectVMBaseStore.DraftSource
                switch mode {
                case .customize:
                    if let draft = transaction.state.draft { return .draft(draft) }
                    expected = nil
                case .rebuild(let draftID):
                    guard transaction.state.draft?.id == draftID else { throw ProjectVMBaseStore.Failure.changed }
                    if let draftID { try requireStoppedDraft(draftID, records: records) }
                    expected = draftID
                }
                if case .customize = mode, transaction.state.base != nil {
                    source = .saved
                } else {
                    guard let golden = availableGolden(), !goldenRunsAnywhere(records),
                          let sealedAt = Self.sealedAt(golden.sealedMarker) else { return .needsSharedBase }
                    source = .shared(bundle: golden, provenance: .init(
                        sharedBuild: golden.url.lastPathComponent, sharedSealedAt: sealedAt,
                        scriptHash: VMCleanPoint.scriptHash(script)), script: script)
                }
                let draft = try transaction.replaceDraft(expected: expected, source: source, identity: Self.newMacIdentity())
                return .draft(draft)
            }
        }
        if case .draft = result {
            collectRetiredProjectDrafts(projectID)
            projectBaseRevision &+= 1
        }
        return result
    }

    func startProjectDraft(projectID: String, draftID: UUID, pausing other: String? = nil) async throws -> VMStartOutcome {
        let id = VMIdentity.projectDraftRecordID(draftID)
        guard try projectBaseStatus(projectID: projectID).draft?.id == draftID else { throw ProjectVMBaseStore.Failure.changed }
        if let other { try await pauseForSlot(other) }
        let outcome = try await startRecorded(id: id) { records in
            try projectBases.withProject(projectID) { transaction in
                let bundle = try transaction.selectedDraftBundle(id: draftID)
                guard let draft = transaction.state.draft else { throw ProjectVMBaseStore.Failure.changed }
                if let record = records.first(where: { $0.id == id }) {
                    guard record.bundlePath == bundle.url.path else { throw ProjectVMBaseStore.Failure.changed }
                } else {
                    records.append(.init(id: id, goldenBuild: id, bundlePath: bundle.url.path,
                                         createdAt: draft.createdAt, lastUsedAt: now()))
                }
            }
        }
        if case .running = outcome { _ = try scheduleDraftSetup(projectID: projectID, draftID: draftID, retry: false) }
        return outcome
    }

    func retryProjectDraftSetup(projectID: String, draftID: UUID) async throws {
        let run = try scheduleDraftSetup(projectID: projectID, draftID: draftID, retry: true)
        await run?.value
    }

    private func scheduleDraftSetup(projectID: String, draftID: UUID, retry: Bool) throws -> Task<Void, Never>? {
        guard let draft = try projectBaseStatus(projectID: projectID).draft, draft.id == draftID else {
            throw ProjectVMBaseStore.Failure.changed
        }
        let id = VMIdentity.projectDraftRecordID(draftID)
        guard let script = draft.script, draft.setup != .ready, retry || draft.setup == .pending else { return nil }
        guard !diskOperations.contains(id), !pausing.contains(id), runningVMs[id] != nil,
              let generation = try registry.read().records.first(where: { $0.id == id })?.bootGeneration else {
            throw VMError(message: "Start the draft before running its setup script")
        }
        if let run = projectDraftRuns[draftID] { return run.task }
        projectDraftSetupErrors[draftID] = nil
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if projectDraftRuns[draftID]?.token == token { projectDraftRuns[draftID] = nil }
            }
            var setup = draftSetup()
            setup.isCurrent = { [weak self] in self?.projectDraftRuns[draftID]?.token == token }
            let result = await setup.executeScript(recordID: id, script: script)
            guard projectDraftRuns[draftID]?.token == token, runningVMs[id] != nil else { return }
            let next: ProjectVMBaseStore.Setup
            switch result {
            case .succeeded: next = .ready
            case .failed(let code): next = .failed(exitCode: code)
            case .helperUnavailable: next = .failed(exitCode: nil)
            case .interrupted: return
            }
            do {
                try registry.withSnapshotLocked { records in
                    try requireOwnedDraftBoot(id, generation: generation, records: records)
                    try projectBases.withProject(projectID) { try $0.setDraftSetup(id: draftID, setup: next) }
                }
                projectBaseRevision &+= 1
            } catch {
                projectDraftSetupErrors[draftID] = "Couldn't save the setup result: \(error.localizedDescription)"
            }
        }
        projectDraftRuns[draftID] = DraftSetupRun(token: token, task: task)
        return task
    }

    func saveProjectBase(projectID: String, draftID: UUID) async throws -> ProjectVMBaseStore.Base {
        let id = VMIdentity.projectDraftRecordID(draftID)
        let base = try await withDiskOperation(id) {
            guard let draft = try projectBaseStatus(projectID: projectID).draft, draft.id == draftID else {
                throw ProjectVMBaseStore.Failure.changed
            }
            guard draft.setup == .ready, !isProjectDraftSettingUp(draftID) else { throw ProjectVMBaseStore.Failure.notReady }
            if let pause = pauses[id] { _ = await pause.value }
            let running = runningVMs[id]
            var claimed = false
            if running != nil { publishingDrafts.insert(id) }
            defer {
                if claimed { releaseDisk(id: id) }
                if publishingDrafts.remove(id) != nil, runningVMs[id] == nil { clearOwner(id) }
            }
            if let vm = running {
                guard await shutDownProjectDraft(id, vm: vm) else {
                    throw VMError(message: "The draft did not shut down. Shut down macOS and try again.")
                }
            } else {
                guard cleanlyShutDown[id] != nil else { throw Self.projectDraftNeedsCleanStop }
                try claimDisk(id: id)
                claimed = true
            }
            guard let generation = cleanlyShutDown[id], runningVMs[id] == nil else { throw Self.projectDraftNeedsCleanStop }
            return try registry.withSnapshotLocked { records in
                try requireOwnedDraftBoot(id, generation: generation, records: records)
                return try projectBases.withProject(projectID) { transaction in
                    let bundle = try transaction.selectedDraftBundle(id: draftID)
                    guard !FileManager.default.fileExists(atPath: Self.savedStateURL(of: bundle).path) else {
                        throw Self.projectDraftNeedsCleanStop
                    }
                    return try transaction.publish(expectedDraft: draftID, savedAt: now())
                }
            }
        }
        collectRetiredProjectDrafts(projectID)
        projectBaseRevision &+= 1
        return base
    }

    func discardProjectDraft(
        projectID: String, draftID: UUID, stillOrphaned: (() throws -> Bool)? = nil
    ) async throws {
        let id = VMIdentity.projectDraftRecordID(draftID)
        try await withDiskOperation(id) {
            guard try projectBaseStatus(projectID: projectID).draft?.id == draftID else { throw ProjectVMBaseStore.Failure.changed }
            if let stillOrphaned, try !stillOrphaned() { throw ProjectVMBaseStore.Failure.changed }
            try await stop(id, force: true)
            try registry.withSnapshotLocked { records in
                if let stillOrphaned, try !stillOrphaned() { throw ProjectVMBaseStore.Failure.changed }
                try requireStoppedDraft(draftID, records: records)
                try projectBases.withProject(projectID) { try $0.discard(expectedDraft: draftID) }
            }
        }
        collectRetiredProjectDrafts(projectID)
        projectBaseRevision &+= 1
    }

    func removeProjectBase(projectID: String, baseID: UUID, stillOrphaned: (() throws -> Bool)? = nil) throws {
        try registry.withSnapshotLocked { _ in
            if let stillOrphaned, try !stillOrphaned() { throw ProjectVMBaseStore.Failure.changed }
            try projectBases.withProject(projectID) { try $0.removeBase(expectedBase: baseID) }
        }
        collectRetiredProjectDrafts(projectID)
        projectBaseRevision &+= 1
    }

    private static var projectDraftNeedsCleanStop: VMError {
        VMError(message: "Alas didn't observe a clean shutdown. Start the draft, then shut down macOS and try again.")
    }

    private func shutDownProjectDraft(_ id: String, vm: RunningVM) async -> Bool {
        let command = GoldenProvisioner.shutdownCommand(account: .alas)
        guard await vm.stopGracefully(requestingShutdown: { [self] in await sendGuestShutdown(id, command) },
                                      timeout: GoldenProvisioner.shutdownTimeout) else { return false }
        didStop(id)
        return true
    }

    private func requireOwnedDraftBoot(_ id: String, generation: Int, records: [WorktreeVMRecord]) throws {
        guard let record = records.first(where: { $0.id == id }), record.bootGeneration == generation,
              let owner = record.runOwner, let me = VMRunOwner.current(label: ownerLabel), owner.isSameProcess(as: me) else {
            throw Self.projectDraftNeedsCleanStop
        }
    }

    private func requireStoppedDraft(_ draftID: UUID, records: [WorktreeVMRecord]) throws {
        let id = VMIdentity.projectDraftRecordID(draftID)
        guard !diskClaims.contains(id), runningVMs[id] == nil, !starting.contains(id) else {
            throw VMError(message: "The project draft is busy")
        }
        if let owner = records.first(where: { $0.id == id })?.runOwner {
            throw VMError(message: "The project draft is in use in \(owner.label)")
        }
    }

    private func collectRetiredProjectDrafts(_ projectID: String) {
        do {
            try registry.updateSeeingForeignBundles { records, foreign in
                try projectBases.withProject(projectID) { transaction in
                    transaction.collectRetiredBases()
                    for retired in transaction.retiredDrafts() {
                        let id = VMIdentity.projectDraftRecordID(retired.id)
                        guard !foreign.contains(retired.url.path), !isBusyHere(id),
                              !records.contains(where: { $0.id == id && $0.runOwner != nil }) else { continue }
                        try? FileManager.default.removeItem(at: retired.url)
                        try? FileManager.default.removeItem(at: projectDraftTransferDirectory(retired.id))
                        records.removeAll { $0.id == id }
                        cleanlyShutDown.removeValue(forKey: id)
                        projectDraftSetupErrors[retired.id] = nil
                    }
                }
            }
        } catch {
            logger.error("Retiring project VM draft files failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
