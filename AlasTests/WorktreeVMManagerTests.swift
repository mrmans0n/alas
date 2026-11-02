import AlasComputerUseKit
import AlasCore
import Foundation
import Testing
import Virtualization
@testable import Alas

// Main actor: WorktreeVMManager and RunningVM are main-actor-only.
@MainActor
@Suite("WorktreeVMManager")
final class WorktreeVMManagerTests {
    private struct StopRefused: Error {}
    private struct HypervisorFailure: Error {}

    @MainActor
    private final class FakeMachine: VMMachine {
        unowned let hypervisor: FakeHypervisor
        let stopFails: Bool
        let guestStopError: Error?
        var state: VZVirtualMachine.State = .stopped
        var virtualMachine: VZVirtualMachine? { nil }
        var onGuestStop: ((Error?) -> Void)?
        private(set) var stopRequests = 0
        init(hypervisor: FakeHypervisor, stopFails: Bool, guestStopError: Error?) {
            self.hypervisor = hypervisor
            self.stopFails = stopFails
            self.guestStopError = guestStopError
        }
        func start() async throws { state = .running }
        func pause() async throws { state = .paused }
        func resume() async throws { state = .running }
        /// Writes the state file; a failing save leaves a partial one behind.
        func saveMachineState(to url: URL) async throws {
            await hypervisor.saveGate.passIfArmed()
            try Data("partial".utf8).write(to: url)
            if hypervisor.saveFails { throw HypervisorFailure() }
            try Data("state".utf8).write(to: url)
        }
        func restoreMachineState(from url: URL) async throws {
            guard !hypervisor.restoreFails else {
                throw WorktreeVMManager.RestoreFailed(underlying: HypervisorFailure())
            }
            state = .paused
        }
        func requestStop() throws {
            stopRequests += 1
            if stopFails { throw StopRefused() }
            state = guestStopError == nil ? .stopped : .error
            onGuestStop?(guestStopError)
        }
        func stop() async throws {
            await hypervisor.holdStopIfGated()
            if stopFails { throw StopRefused() }
            state = .stopped
        }
        func openGuestConnection(port: UInt32) async throws -> VMGuestTransport { throw StopRefused() }
    }

    /// Holds one call until `release()`; streams instead of continuations
    /// keep the mock handlers free of nested closures.
    @MainActor
    private final class Gate {
        var armed = false
        private let entered: AsyncStream<Void>
        private let enteredContinuation: AsyncStream<Void>.Continuation
        private let released: AsyncStream<Void>
        private let releasedContinuation: AsyncStream<Void>.Continuation

        init() {
            (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
            (released, releasedContinuation) = AsyncStream<Void>.makeStream()
        }

        func passIfArmed() async {
            guard armed else { return }
            armed = false
            enteredContinuation.yield()
            for await _ in released { break }
        }

        func waitUntilHeld() async {
            for await _ in entered { break }
        }

        func release() { releasedContinuation.yield() }
    }

    /// Boots fake machines. `bootGate` holds the next boot and `stopGate` the
    /// next forced stop while armed. With `guestStopError` set, a stop request
    /// ends with that hypervisor error instead of a clean guest shutdown.
    /// Every machine reports `supportsSaveRestore`, Linux ones too, so the
    /// manager's own guest check is what keeps Linux from saving state.
    @MainActor
    private final class FakeHypervisor {
        var stopFails = false
        var guestStopError: Error?
        var supportsSaveRestore = true
        var saveFails = false
        var restoreFails = false
        let bootGate = Gate()
        let stopGate = Gate()
        let saveGate = Gate()
        private(set) var boots = 0
        /// The state file each boot restored from; nil for a cold boot.
        private(set) var restoredFrom: [URL?] = []

        func boot(_ worktreeID: String, restoringFrom state: URL? = nil) async throws -> RunningVM {
            boots += 1
            await bootGate.passIfArmed()
            let vm = RunningVM(
                worktreeID: worktreeID,
                machine: FakeMachine(hypervisor: self, stopFails: stopFails, guestStopError: guestStopError),
                supportsSaveRestore: supportsSaveRestore)
            if let state {
                try await vm.restoreState(from: state)
                try await vm.resume()
            } else {
                try await vm.start()
            }
            restoredFrom.append(state)
            return vm
        }

        func holdStopIfGated() async {
            await stopGate.passIfArmed()
        }
    }

    private let hypervisor = FakeHypervisor()

    private let root: URL
    private let registry: WorktreeVMRegistry
    private var helperDirectory: URL { root.appendingPathComponent("helper", isDirectory: true) }
    private let elsewhere = VMRunOwner(pid: 999_999, processStart: Date(timeIntervalSince1970: 1), label: "Alas Dev")

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorktreeVMManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Every recorded owner counts as alive, so the fake "other process" keeps its slot.
        registry = WorktreeVMRegistry(fileURL: root.appendingPathComponent("registry.json"), isAlive: { _ in true })
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var linuxHelperDirectory: URL { root.appendingPathComponent("linux-helper", isDirectory: true) }

    private func makeManager() -> WorktreeVMManager {
        let hypervisor = hypervisor
        return WorktreeVMManager(
            registry: registry, root: root, helperDirectory: helperDirectory,
            linuxHelperDirectory: linuxHelperDirectory
        ) { worktreeID, _, _, state in
            try await hypervisor.boot(worktreeID, restoringFrom: state)
        }
    }

    /// A VM record with a bundle holding a disk image. `id` is a registry id: a Linux one
    /// (`linux:…`) gets a Linux record.
    @discardableResult
    private func addRecord(_ id: String, owner: VMRunOwner? = nil, lastUsed: TimeInterval = 0) throws -> URL {
        let bundle = root.appendingPathComponent("worktrees/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: VMBundle(url: bundle).diskImage)
        try registry.update { records in
            records.append(WorktreeVMRecord(
                id: id, guestOS: VMIdentity.parse(recordID: id).guest, goldenBuild: "25A1", bundlePath: bundle.path,
                createdAt: Date(timeIntervalSince1970: 0), lastUsedAt: Date(timeIntervalSince1970: lastUsed),
                runOwner: owner))
        }
        return bundle
    }

    @Test("a VM another live process runs cannot start here")
    func secondProcessCannotStartSameVM() async throws {
        try addRecord("/repo/a", owner: elsewhere)
        let outcome = try await makeManager().startVM(worktreeID: "/repo/a")
        guard case .runningElsewhere(let label) = outcome else {
            Issue.record("expected runningElsewhere, got \(outcome)")
            return
        }
        #expect(label == "Alas Dev")
    }

    @Test("with both slots taken, only VMs running in this process are offered to pause")
    func thirdStartNeedsChoiceWithLocalCandidatesOnly() async throws {
        try addRecord("/repo/local", lastUsed: 10)
        try addRecord("/repo/remote-owned", owner: elsewhere, lastUsed: 1)
        try addRecord("/repo/third")
        let manager = makeManager()
        guard case .running = try await manager.startVM(worktreeID: "/repo/local") else {
            Issue.record("first VM did not start")
            return
        }
        let outcome = try await manager.startVM(worktreeID: "/repo/third")
        guard case .needsUserChoice(let candidates) = outcome else {
            Issue.record("expected needsUserChoice, got \(outcome)")
            return
        }
        #expect(candidates == ["/repo/local"])
    }

    @Test("deleting a running VM stops it and removes its record and bundle")
    func deleteRunningVMFreesSlotAndFiles() async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")
        #expect(try registry.snapshot().first?.runOwner != nil)

        #expect(await manager.deleteVM(worktreeID: "/repo/a") == nil)

        #expect(manager.running("/repo/a") == nil)
        #expect(try registry.snapshot().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
        #expect(!FileManager.default.fileExists(atPath: manager.transferDirectory(forWorktree: "/repo/a").path))
    }

    enum BootInterruption: CaseIterable { case stop, delete }

    @Test(
        "a VM stopped or deleted while booting stays starting until it is forced off",
        arguments: BootInterruption.allCases)
    func interruptedBootBlocksRestartUntilForcedOff(_ interruption: BootInterruption) async throws {
        let bundle = try addRecord("/repo/a")
        hypervisor.bootGate.armed = true
        hypervisor.stopGate.armed = true
        let manager = makeManager()
        let start = Task { try await manager.startVM(worktreeID: "/repo/a") }
        await hypervisor.bootGate.waitUntilHeld()

        switch interruption {
        case .stop: await manager.stopVM(worktreeID: "/repo/a")
        case .delete: await manager.deleteVM(worktreeID: "/repo/a")
        }
        hypervisor.bootGate.release()
        await hypervisor.stopGate.waitUntilHeld()

        // The booted VM is being forced off: a second start must not boot
        // another machine on the same disk.
        #expect(manager.isStarting("/repo/a"))
        await #expect(throws: WorktreeVMManager.VMError.self) {
            _ = try await manager.startVM(worktreeID: "/repo/a")
        }
        #expect(hypervisor.boots == 1)

        hypervisor.stopGate.release()
        let error = await #expect(throws: (any Error).self) { _ = try await start.value }
        #expect(manager.running("/repo/a") == nil)
        switch interruption {
        case .stop:
            #expect(error is WorktreeVMManager.StoppedWhileStarting)
            #expect(try registry.snapshot().first?.runOwner == nil)
        case .delete:
            #expect(error is WorktreeVMManager.VMError)
            #expect(try registry.snapshot().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: bundle.path))
        }
    }

    @Test("a VM that refuses to stop keeps its slot and cannot be paused for another")
    func failedStopKeepsSlot() async throws {
        try addRecord("/repo/a")
        try addRecord("/repo/b")
        hypervisor.stopFails = true
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")

        await #expect(throws: (any Error).self) {
            _ = try await manager.startVM(worktreeID: "/repo/b", pausing: "/repo/a")
        }
        #expect(manager.running("/repo/a") != nil)
        #expect(manager.running("/repo/b") == nil)
        #expect(try registry.snapshot().first { $0.id == "/repo/a" }?.runOwner != nil)
    }

    /// A Linux guest's helper powers it off; the power button is the fallback when it can't.
    @Test("a guest that takes the shutdown request stops without a power button press or a forced stop",
          arguments: [true, false])
    func stopAsksTheGuestFirst(guestTakesIt: Bool) async throws {
        let machine = FakeMachine(hypervisor: hypervisor, stopFails: false, guestStopError: nil)
        let vm = RunningVM(worktreeID: "linux:/repo/a", machine: machine)
        try await vm.start()

        try await vm.stop(requestingShutdown: {
            guard guestTakesIt else { return false }
            machine.state = .stopped
            machine.onGuestStop?(nil)
            return true
        })

        #expect(machine.state == .stopped)
        #expect(machine.stopRequests == (guestTakesIt ? 0 : 1))
        #expect(!vm.wasForcedOff)
    }

    @Test("a sealed golden image is never booted again")
    func sealedGoldenRefusesToStart() async throws {
        try GoldenImageInstaller.writeSealedMarker(makeGoldenBundle())

        await #expect(throws: WorktreeVMManager.VMError.self) {
            _ = try await self.makeManager().startGolden(build: "25A1")
        }
        #expect(hypervisor.boots == 0)
        #expect(try registry.snapshot().isEmpty)
    }

    enum GoldenLastStop: CaseIterable {
        case guestShutdown, forcedOff, hypervisorError, beforeLaunch
        /// Clean shutdown here, then another process booted the golden and
        /// was reaped (crashed) without a clean shutdown of its own.
        case bootedElsewhereAfterCleanShutdown
        /// Clean shutdown, but a setup or helper update that turned sshd on
        /// never turned it off.
        case guestShutdownWithSSHDLeftOn
    }

    @Test(
        "the golden image seals only after this process saw the guest shut down cleanly",
        arguments: GoldenLastStop.allCases)
    func sealingNeedsAnObservedCleanShutdown(_ lastStop: GoldenLastStop) async throws {
        let id = WorktreeVMManager.goldenIDPrefix + "25A1"
        let manager = makeManager()
        switch lastStop {
        case .guestShutdown:
            _ = try await manager.startGolden(build: "25A1")
        case .guestShutdownWithSSHDLeftOn:
            _ = try await manager.startGolden(build: "25A1")
            try Data().write(to: WorktreeVMManager.sshdEnabledMarker(of: makeGoldenBundle()))
        case .forcedOff:
            _ = try await manager.startGolden(build: "25A1")
            try await #require(manager.running(id)).forceStop()
        case .hypervisorError:
            hypervisor.guestStopError = HypervisorFailure()
            _ = try await manager.startGolden(build: "25A1")
        case .beforeLaunch:
            try addRecord(id)
        case .bootedElsewhereAfterCleanShutdown:
            _ = try await manager.startGolden(build: "25A1")
            #expect(await manager.shutDownGoldenForSealing(build: "25A1") == .clean)
            try registry.update { records in
                let index = try #require(records.firstIndex { $0.id == id })
                records[index].bootGeneration = (records[index].bootGeneration ?? 0) + 1
            }
        }

        let shutdown = await manager.shutDownGoldenForSealing(build: "25A1")
        let golden = try makeGoldenBundle()
        let sealed = (try? manager.sealGolden(golden)) != nil

        let sawCleanShutdown = [.guestShutdown, .bootedElsewhereAfterCleanShutdown, .guestShutdownWithSSHDLeftOn]
            .contains(lastStop)
        #expect(shutdown == (sawCleanShutdown ? .clean : .forcedOff))
        #expect(manager.running(id) == nil)
        #expect(sealed == (lastStop == .guestShutdown))
        #expect(golden.isSealed == (lastStop == .guestShutdown))
    }

    enum LeftoverSSHDStart: CaseIterable {
        case worktree, golden
        /// The unattended setup's or helper update's own boot, which needs sshd.
        case goldenKeepingSSH
    }

    @Test(
        "a VM an interrupted setup left with sshd on gets it turned off offline before it boots, unless the boot needs it",
        arguments: LeftoverSSHDStart.allCases)
    func leftoverSSHDIsTurnedOffBeforeBoot(_ start: LeftoverSSHDStart) async throws {
        let bundle: VMBundle
        switch start {
        case .worktree:
            bundle = try VMBundle(url: addRecord("/repo/a"))
        case .golden, .goldenKeepingSSH:
            bundle = try makeGoldenBundle()
            try addRecord(WorktreeVMManager.goldenIDPrefix + "25A1")
        }
        let marker = WorktreeVMManager.sshdEnabledMarker(of: bundle)
        try Data().write(to: marker)
        let manager = makeManager()
        let disabled = DisabledDisks()
        manager.disableSSHOffline = { [hypervisor] bundle in disabled.record(bundle.url, bootsSoFar: hypervisor.boots) }

        let outcome = switch start {
        case .worktree: try await manager.startVM(worktreeID: "/repo/a")
        case .golden: try await manager.startGolden(build: "25A1")
        case .goldenKeepingSSH: try await manager.startGolden(build: "25A1", keepingSSH: true)
        }

        guard case .running = outcome else {
            Issue.record("the VM did not start")
            return
        }
        let turnedOff = start != .goldenKeepingSSH
        #expect(disabled.bundles == (turnedOff ? [bundle.url] : []))
        #expect(disabled.bootsBefore == (turnedOff ? [0] : []))
        #expect(FileManager.default.fileExists(atPath: marker.path) == !turnedOff)
    }

    enum DiskStep: CaseIterable { case close, failedOpen }

    @Test(
        "a VM whose disk stays attached on the host stays claimed",
        arguments: DiskStep.allCases, [true, false])
    func failedDetachKeepsTheClaim(_ step: DiskStep, _ detached: Bool) async throws {
        try addRecord("/repo/a")
        let manager = makeManager()

        switch step {
        case .close:
            try manager.claimDisk(id: "/repo/a")
            await GuestSetupSteps.closeClaimed(
                ClaimedDisk(disk: FakeDisk(detaches: detached), id: "/repo/a"), manager: manager)
        case .failedOpen:
            // Attached, then the mount failed, and its cleanup detached or not.
            let failure: any Error = detached
                ? VMDiskSession.Failure(message: "mount failed") : VMDiskSession.DetachFailed(underlying: "mount failed")
            await #expect(throws: (any Error).self) {
                _ = try await GuestSetupSteps.openClaimed(id: "/repo/a", manager: manager) { throw failure }
            }
        }

        #expect(try (registry.snapshot().first?.runOwner == nil) == detached)
        if detached {
            _ = try await manager.startVM(worktreeID: "/repo/a")
            #expect(manager.running("/repo/a") != nil)
        } else {
            await #expect(throws: WorktreeVMManager.VMError.self) {
                _ = try await manager.startVM(worktreeID: "/repo/a")
            }
        }
    }

    private struct FakeDisk: GoldenProvisioningDisk {
        let detaches: Bool
        var dataVolume: URL { URL(fileURLWithPath: "/nonexistent") }
        func systemVersion() throws -> (product: String, build: String) { ("27.2", "25A1") }
        func close() -> Bool { detaches }
    }

    @MainActor
    private final class DisabledDisks {
        private(set) var bundles: [URL] = []
        private(set) var bootsBefore: [Int] = []
        func record(_ bundle: URL, bootsSoFar: Int) {
            bundles.append(bundle)
            bootsBefore.append(bootsSoFar)
        }
    }

    @Test("a golden VM another process booted after a clean shutdown here is not sealed")
    func goldenBootedElsewhereBlocksSealing() async throws {
        let id = WorktreeVMManager.goldenIDPrefix + "25A1"
        let manager = makeManager()
        _ = try await manager.startGolden(build: "25A1")
        #expect(await manager.shutDownGoldenForSealing(build: "25A1") == .clean)
        try registry.update { records in
            records[try #require(records.firstIndex { $0.id == id })].runOwner = elsewhere
        }
        let golden = try makeGoldenBundle()

        #expect(throws: WorktreeVMManager.VMError.self) { try manager.sealGolden(golden) }
        #expect(!golden.isSealed)
    }

    enum UnsealBlocker: CaseIterable { case goldenRunsElsewhere, anotherGoldenAwaitsSetup }

    @Test(
        "customizing the base image is refused while a golden VM runs anywhere or another awaits setup",
        arguments: UnsealBlocker.allCases)
    func unsealRefusesWhileAGoldenRunsAnywhere(_ blocker: UnsealBlocker) throws {
        let golden = try makeGoldenBundle()
        try GoldenImageInstaller.writeSealedMarker(golden)
        switch blocker {
        case .goldenRunsElsewhere:
            try addRecord(WorktreeVMManager.goldenIDPrefix + "25A1", owner: elsewhere)
        case .anotherGoldenAwaitsSetup:
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("golden/25A0", isDirectory: true), withIntermediateDirectories: true)
        }
        let manager = makeManager()

        #expect(throws: WorktreeVMManager.VMError.self) { try manager.unsealGoldenForCustomizing(from: "/repo/a") }
        #expect(golden.isSealed)
        #expect(manager.customizingFrom == nil)
    }

    @Test("no VM is cloned from a base image another process is customizing")
    func createVMRefusesWhileTheGoldenIsCustomized() throws {
        // The golden still looked sealed when createVM checked; under the
        // registry lock another process already runs it.
        try GoldenImageInstaller.writeSealedMarker(makeGoldenBundle())
        try addRecord(WorktreeVMManager.goldenIDPrefix + "25A1", owner: elsewhere)

        #expect(throws: WorktreeVMManager.VMError.self) { try self.makeManager().createVM(worktreeID: "/repo/a") }
        #expect(try !registry.snapshot().contains { $0.id == "/repo/a" })
    }

    @Test("a customized base image seals again only after a fresh clean shutdown")
    func unsealThenSealNeedsAFreshCleanShutdown() async throws {
        let manager = makeManager()
        _ = try await manager.startGolden(build: "25A1")
        #expect(await manager.shutDownGoldenForSealing(build: "25A1") == .clean)
        let golden = try makeGoldenBundle()
        try manager.sealGolden(golden)

        try manager.unsealGoldenForCustomizing(from: "/repo/a")

        #expect(!golden.isSealed)
        #expect(manager.customizingFrom == "/repo/a")
        #expect(await manager.shutDownGoldenForSealing(build: "25A1") == .forcedOff)
        #expect(throws: WorktreeVMManager.VMError.self) { try manager.sealGolden(golden) }
        #expect(!golden.isSealed)

        _ = try await manager.startGolden(build: "25A1")
        #expect(await manager.shutDownGoldenForSealing(build: "25A1") == .clean)
        try manager.sealGolden(golden)
        #expect(golden.isSealed)
        #expect(manager.customizingFrom == nil)
    }

    @Test("worktree VMs share the helper, the worktree and a transfer folder; the golden only the helper")
    func worktreeSharesPointAtTheRightDirectories() throws {
        let worktree = root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        let manager = makeManager()
        manager.worktreePath = { $0 == "/repo/a" ? worktree : nil }

        let transfer = manager.transferDirectory(forWorktree: "/repo/a")
        #expect(try manager.shares(forWorktree: "/repo/a") == [
            VMShare(name: "helper", hostURL: helperDirectory, readOnly: true),
            VMShare(name: "worktree", hostURL: worktree, readOnly: true),
            VMShare(name: "transfer", hostURL: transfer, readOnly: false),
        ])
        #expect(transfer.deletingLastPathComponent().lastPathComponent == "transfer")
        #expect(transfer.lastPathComponent
            == WorktreeVMManager.bundleURL(forWorktree: "/repo/a", root: root).lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: transfer.path))
        #expect(try manager.shares(forWorktree: WorktreeVMManager.goldenIDPrefix + "25A1") == [
            VMShare(name: "helper", hostURL: helperDirectory, readOnly: true),
        ])

        // A Linux VM gets the Linux helper and a transfer folder of its own.
        try FileManager.default.createDirectory(at: linuxHelperDirectory, withIntermediateDirectories: true)
        let linuxTransfer = manager.transferDirectory(forWorktree: "/repo/a", guest: .linux)
        #expect(try manager.shares(forWorktree: "/repo/a", guest: .linux) == [
            VMShare(name: "helper", hostURL: linuxHelperDirectory, readOnly: true),
            VMShare(name: "worktree", hostURL: worktree, readOnly: true),
            VMShare(name: "transfer", hostURL: linuxTransfer, readOnly: false),
        ])
        #expect(linuxTransfer.lastPathComponent == transfer.lastPathComponent + "-linux")
        #expect(linuxTransfer.lastPathComponent
            == WorktreeVMManager.bundleURL(forWorktree: "/repo/a", guest: .linux, root: root).lastPathComponent)
    }

    @Test("a worktree's Linux VM lives beside its macOS VM and starts outside the macOS slots")
    func linuxAndMacOSVMsCoexist() async throws {
        try makeSealedGoldens()
        let manager = makeManager()
        try manager.createVM(worktreeID: "/repo/a", guest: .linux)
        try manager.createVM(worktreeID: "/repo/a")

        let records = try registry.snapshot()
        #expect(Set(records.map(\.id)) == ["/repo/a", "linux:/repo/a"])
        #expect(records.first { $0.id == "linux:/repo/a" }?.guestOS == .linux)
        let bundles = [VMGuestOS.macOS, .linux].map { WorktreeVMManager.bundleURL(forWorktree: "/repo/a", guest: $0, root: root) }
        #expect(Set(bundles).count == 2)
        #expect(bundles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(manager.vmKinds(forWorktree: "/repo/a") == [.macOS, .linux])

        try addRecord("/repo/b", owner: elsewhere)
        try addRecord("/repo/c", owner: elsewhere)
        guard case .running = try await manager.startVM(worktreeID: "/repo/a", guest: .linux) else {
            Issue.record("the Linux VM did not start")
            return
        }
        #expect(manager.running("/repo/a", guest: .linux) != nil)
        #expect(manager.running("/repo/a") == nil)
        let transfers = [VMGuestOS.macOS, .linux].map { manager.transferDirectory(forWorktree: "/repo/a", guest: $0) }
        #expect(Set(transfers).count == 2)
        #expect(FileManager.default.fileExists(atPath: transfers[1].path))
    }

    @Test("the stub older builds read exists exactly while the worktree has a Linux VM and no macOS VM")
    func aliasStubFollowsTheWorktreesVMs() async throws {
        try makeSealedGoldens()
        let manager = makeManager()
        func stubPresent() throws -> Bool {
            let file = root.appendingPathComponent("registry.json")
            let elements = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] ?? []
            return elements.contains { $0["id"] as? String == "/repo/a" && $0["guestOS"] as? String == VMIdentity.aliasGuestRaw }
        }

        try manager.createVM(worktreeID: "/repo/a", guest: .linux)
        #expect(try stubPresent())
        #expect(manager.vmKinds(forWorktree: "/repo/a") == [.linux])

        try manager.createVM(worktreeID: "/repo/a")
        #expect(try !stubPresent())

        #expect(await manager.deleteVM(worktreeID: "/repo/a") == nil)
        #expect(try stubPresent())
        #expect(manager.vmKinds(forWorktree: "/repo/a") == [.linux])

        #expect(await manager.deleteVM(worktreeID: "/repo/a", guest: .linux) == nil)
        #expect(try !stubPresent())
        #expect(manager.vmKinds(forWorktree: "/repo/a") == [])
    }

    @Test("deleting a worktree removes both of its VMs")
    func deletingTheWorktreeRemovesBothVMs() async throws {
        try makeSealedGoldens()
        let manager = makeManager()
        try manager.createVM(worktreeID: "/repo/a", guest: .linux)
        try manager.createVM(worktreeID: "/repo/a")
        _ = try await manager.startVM(worktreeID: "/repo/a", guest: .linux)

        #expect(await manager.deleteVMs(forWorktree: "/repo/a") == nil)

        #expect(try registry.recordIDs().isEmpty)
        #expect(manager.running("/repo/a", guest: .linux) == nil)
        for guest in [VMGuestOS.macOS, .linux] {
            #expect(!FileManager.default.fileExists(
                atPath: WorktreeVMManager.bundleURL(forWorktree: "/repo/a", guest: guest, root: root).path))
            #expect(!FileManager.default.fileExists(
                atPath: manager.transferDirectory(forWorktree: "/repo/a", guest: guest).path))
        }
    }

    @Test("stopping a worktree's VMs, as archiving does, stops both guests and keeps their bundles")
    func stoppingTheWorktreeStopsBothVMs() async throws {
        try makeSealedGoldens()
        let manager = makeManager()
        try manager.createVM(worktreeID: "/repo/a", guest: .linux)
        try manager.createVM(worktreeID: "/repo/a")
        for guest in [VMGuestOS.macOS, .linux] {
            _ = try await manager.startVM(worktreeID: "/repo/a", guest: guest)
        }

        await manager.stopVMs(forWorktree: "/repo/a")

        #expect(manager.running("/repo/a") == nil)
        #expect(manager.running("/repo/a", guest: .linux) == nil)
        #expect(manager.vmKinds(forWorktree: "/repo/a") == [.macOS, .linux])
    }

    @Test("a corrupt registry is quarantined and read again, and a VM bundle on disk still counts as a VM")
    func corruptRegistryNeitherHidesAVMNorBlocksTheAnswer() throws {
        let manager = makeManager()
        let file = root.appendingPathComponent("registry.json")
        try Data("not json {".utf8).write(to: file)
        #expect(manager.vmKinds(forWorktree: "/repo/a") == [])

        try Data("not json {".utf8).write(to: file)
        let bundle = WorktreeVMManager.bundleURL(forWorktree: "/repo/a", root: root)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(manager.vmKinds(forWorktree: "/repo/a") == [.macOS])

        // Still unreadable after quarantine: the bundle on disk answers alone.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(manager.vmKinds(forWorktree: "/repo/a") == [.macOS])
        #expect(manager.vmKinds(forWorktree: "/repo/b") == nil)
    }

    // MARK: - Pause and restore

    private func record(_ id: String) throws -> WorktreeVMRecord {
        try #require(try registry.snapshot().first { $0.id == id })
    }

    private func stateFile(_ bundle: URL) -> URL {
        WorktreeVMManager.savedStateURL(of: VMBundle(url: bundle))
    }

    private func isPaused(_ bundle: URL) -> Bool {
        WorktreeVMManager.isPaused(VMBundle(url: bundle))
    }

    private func bundle(_ id: String) throws -> URL {
        URL(fileURLWithPath: try record(id).bundlePath)
    }

    @Test func pausingSavesStateAndFreesTheSlot() async throws {
        let bundle = try addRecord("/repo/a", lastUsed: 1)
        try addRecord("/repo/b", lastUsed: 2)
        try addRecord("/repo/c")
        let manager = makeManager()
        for id in ["/repo/a", "/repo/b"] {
            _ = try await manager.startVM(worktreeID: id)
        }

        #expect(await manager.pauseVM(worktreeID: "/repo/a", guest: .macOS) == .saved)

        #expect(isPaused(bundle))
        #expect(try record("/repo/a").runOwner == nil)
        #expect(manager.running("/repo/a") == nil)
        #expect(FileManager.default.fileExists(atPath: stateFile(bundle).path))
        guard case .running = try await manager.startVM(worktreeID: "/repo/c") else {
            Issue.record("the paused VM still holds its slot")
            return
        }
    }

    @Test func startingAPausedVMRestoresAndConsumesTheState() async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")
        #expect(await manager.pauseVM(worktreeID: "/repo/a", guest: .macOS) == .saved)

        _ = try await manager.startVM(worktreeID: "/repo/a")

        #expect(hypervisor.restoredFrom == [nil, stateFile(bundle)])
        #expect(manager.running("/repo/a") != nil)
        #expect(!isPaused(bundle))
        #expect(!FileManager.default.fileExists(atPath: stateFile(bundle).path))
    }

    @Test func aFailedSaveLeavesNoStateFile() async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")
        hypervisor.saveFails = true

        #expect(await manager.pauseVM(worktreeID: "/repo/a", guest: .macOS) == .stopped)

        #expect(manager.running("/repo/a") == nil)
        #expect(!isPaused(bundle))
        #expect(!FileManager.default.fileExists(atPath: stateFile(bundle).path))
        _ = try await manager.startVM(worktreeID: "/repo/a")
        #expect(hypervisor.restoredFrom == [nil, nil])
    }

    @Test func aRestoreFailureColdBoots() async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")
        #expect(await manager.pauseVM(worktreeID: "/repo/a", guest: .macOS) == .saved)
        hypervisor.restoreFails = true

        guard case .running = try await manager.startVM(worktreeID: "/repo/a") else {
            Issue.record("the VM did not cold boot")
            return
        }

        // The failed restore never returned a machine; the cold boot did.
        #expect(hypervisor.boots == 3)
        #expect(hypervisor.restoredFrom == [nil, nil])
        #expect(!isPaused(bundle))
        #expect(!FileManager.default.fileExists(atPath: stateFile(bundle).path))
    }

    enum StaleState: CaseIterable {
        /// An older build cold-booted the VM since, which wrote its disk.
        case diskChanged
        /// The state has no `state.json` saying which disk it belongs to.
        case noInfo
    }

    @Test(arguments: StaleState.allCases)
    func aStaleStateFileIsDiscarded(_ stale: StaleState) async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")
        #expect(await manager.pauseVM(worktreeID: "/repo/a", guest: .macOS) == .saved)
        let info = WorktreeVMManager.savedStateInfoURL(of: VMBundle(url: bundle))
        switch stale {
        case .diskChanged:
            let stamp = try JSONDecoder().decode(VMSavedState.Info.self, from: Data(contentsOf: info)).diskStamp
            try FileManager.default.setAttributes(
                [.modificationDate: stamp.addingTimeInterval(60)], ofItemAtPath: VMBundle(url: bundle).diskImage.path)
        case .noInfo:
            try FileManager.default.removeItem(at: info)
        }

        _ = try await manager.startVM(worktreeID: "/repo/a")

        #expect(hypervisor.boots == 2)
        #expect(hypervisor.restoredFrom == [nil, nil])
        #expect(!FileManager.default.fileExists(atPath: stateFile(bundle).path))
        #expect(!FileManager.default.fileExists(atPath: info.path))
    }

    @Test func aStartDuringAPauseWaitsAndRestores() async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")
        hypervisor.saveGate.armed = true
        let pause = Task { await manager.pauseVM(worktreeID: "/repo/a", guest: .macOS) }
        await hypervisor.saveGate.waitUntilHeld()

        let start = Task { try await manager.startVM(worktreeID: "/repo/a") }
        await Task.yield()
        hypervisor.saveGate.release()

        #expect(await pause.value == .saved)
        guard case .running(let vm) = try await start.value else {
            Issue.record("the start did not run the VM")
            return
        }
        #expect(manager.running("/repo/a") === vm)
        #expect(hypervisor.restoredFrom == [nil, stateFile(bundle)])
        #expect(!isPaused(bundle))
    }

    /// A start that waits on a pause, with a reset behind it on the same pause, waits for the
    /// reset too, and then runs the VM the reset started on the clean disk.
    @Test func aStartWaitingOnAPauseWaitsForAResetBehindIt() async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")
        try await manager.takeCleanPoint(worktreeID: "/repo/a", guest: .macOS)
        try Data("dirty".utf8).write(to: VMBundle(url: bundle).diskImage)
        hypervisor.saveGate.armed = true
        let pause = Task { await manager.pauseVM(worktreeID: "/repo/a", guest: .macOS) }
        await hypervisor.saveGate.waitUntilHeld()

        let start = Task { try await manager.startVM(worktreeID: "/repo/a") }
        await Task.yield()
        let reset = Task { try await manager.resetToClean(worktreeID: "/repo/a", guest: .macOS) }
        await Task.yield()
        // The reset's restart is held mid-boot, so the start wakes while the VM is down.
        hypervisor.bootGate.armed = true
        hypervisor.saveGate.release()
        await hypervisor.bootGate.waitUntilHeld()
        hypervisor.bootGate.release()

        #expect(await pause.value == .saved)
        try await reset.value
        guard case .running(let vm) = try await start.value else {
            Issue.record("the start did not run the VM")
            return
        }
        #expect(manager.running("/repo/a") === vm)
        // The first boot, the clean point's restart, the reset's restart: nothing else booted.
        #expect(hypervisor.boots == 3)
        #expect(try contents(VMBundle(url: bundle).diskImage) == "disk")
    }

    @Test func aStartDuringACleanPointWaitsForItsRestart() async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")
        hypervisor.saveGate.armed = true
        let cleanPoint = Task { try await manager.takeCleanPoint(worktreeID: "/repo/a", guest: .macOS) }
        await hypervisor.saveGate.waitUntilHeld()

        let start = Task { try await manager.startVM(worktreeID: "/repo/a") }
        await Task.yield()
        hypervisor.saveGate.release()

        try await cleanPoint.value
        guard case .running(let vm) = try await start.value else {
            Issue.record("the start did not run the VM")
            return
        }
        #expect(manager.running("/repo/a") === vm)
        #expect(hypervisor.boots == 2)
        #expect(hypervisor.restoredFrom == [nil, stateFile(bundle)])
    }

    /// A macOS VM whose configuration can't save state, and any Linux VM, stop instead.
    @Test(arguments: [VMGuestOS.macOS, .linux])
    func withoutSaveRestorePauseStops(guest: VMGuestOS) async throws {
        let id = VMIdentity.recordID(worktree: "/repo/a", guest: guest)
        let bundle = try addRecord(id)
        if guest == .macOS { hypervisor.supportsSaveRestore = false }
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a", guest: guest)

        #expect(await manager.pauseVM(worktreeID: "/repo/a", guest: guest) == .stopped)

        #expect(manager.running("/repo/a", guest: guest) == nil)
        #expect(!isPaused(bundle))
        #expect(!FileManager.default.fileExists(atPath: stateFile(bundle).path))
        #expect(await manager.pauseVM(worktreeID: "/repo/a", guest: guest) == .notRunning)
    }

    @Test func quitPausesMacOSVMsAndStopsLinuxOnes() async throws {
        let macOS = try addRecord("/repo/a")
        let linux = try addRecord("linux:/repo/b")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")
        _ = try await manager.startVM(worktreeID: "/repo/b", guest: .linux)

        await manager.stopAll()

        #expect(manager.runningVMs.isEmpty)
        #expect(try registry.snapshot().allSatisfy { $0.runOwner == nil })
        #expect(isPaused(macOS))
        #expect(!isPaused(linux))
        #expect(!FileManager.default.fileExists(atPath: stateFile(linux).path))
    }

    @MainActor
    private final class SweepClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    @Test func idleSweepPausesOnlyIdleMacOSVMs() async throws {
        for id in ["/repo/idle", "/repo/typing", "linux:/repo/linux"] {
            try addRecord(id)
        }
        let clock = SweepClock()
        let manager = makeManager()
        manager.now = { clock.now }
        _ = try await manager.startVM(worktreeID: "/repo/idle")
        _ = try await manager.startVM(worktreeID: "/repo/typing")
        _ = try await manager.startVM(worktreeID: "/repo/linux", guest: .linux)
        let sweeper = VMIdleSweeper(
            manager: manager,
            activity: { id in
                VMIdleSweeper.Activity(lastUserInput: id == "/repo/typing" ? clock.now : nil)
            },
            now: { clock.now }
        )

        clock.now += 14 * 60
        await sweeper.runIdleSweep()
        #expect(manager.runningVMs.count == 3)

        clock.now += 2 * 60
        await sweeper.runIdleSweep()
        #expect(manager.running("/repo/idle") == nil)
        #expect(try isPaused(bundle("/repo/idle")))
        #expect(manager.running("/repo/typing") != nil)
        #expect(manager.running("/repo/linux", guest: .linux) != nil)
    }

    // MARK: - Clean point and resets

    private func cleanDirectory(_ bundle: URL) -> URL {
        WorktreeVMManager.cleanDirectory(of: VMBundle(url: bundle))
    }

    private func contents(_ file: URL) throws -> String {
        try String(decoding: Data(contentsOf: file), as: UTF8.self)
    }

    @Test func cleanPointCopiesTheDiskAndStateWhenSupported() async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")

        try await manager.takeCleanPoint(worktreeID: "/repo/a", guest: .macOS, setupScriptHash: "abc")

        let clean = cleanDirectory(bundle)
        #expect(try contents(clean.appendingPathComponent("disk.img")) == "disk")
        #expect(try contents(clean.appendingPathComponent("state.vzvmsave")) == "state")
        #expect(manager.cleanPoint(recordID: "/repo/a")?.setupScriptHash == "abc")
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("clean.partial").path))
        // The live VM resumed from the pause's own state, which the start consumed.
        #expect(hypervisor.restoredFrom == [nil, stateFile(bundle)])
        #expect(manager.running("/repo/a") != nil)
        #expect(!FileManager.default.fileExists(atPath: stateFile(bundle).path))
    }

    /// A macOS VM whose configuration can't save state, and any Linux VM, shut down and cold-boot.
    @Test(arguments: [VMGuestOS.macOS, .linux])
    func cleanPointWithoutSaveRestoreShutsDownCopiesAndBoots(guest: VMGuestOS) async throws {
        let id = VMIdentity.recordID(worktree: "/repo/a", guest: guest)
        let bundle = try addRecord(id)
        if guest == .macOS { hypervisor.supportsSaveRestore = false }
        let manager = makeManager()
        var stops: [String] = []
        manager.onVMStopped = { stops.append($0) }
        _ = try await manager.startVM(worktreeID: "/repo/a", guest: guest)

        try await manager.takeCleanPoint(worktreeID: "/repo/a", guest: guest)

        let clean = cleanDirectory(bundle)
        #expect(try contents(clean.appendingPathComponent("disk.img")) == "disk")
        #expect(!FileManager.default.fileExists(atPath: clean.appendingPathComponent("state.vzvmsave").path))
        #expect(manager.cleanPoint(recordID: id) != nil)
        // Its own stop and restart end nothing, a take over included.
        #expect(stops.isEmpty)
        #expect(hypervisor.restoredFrom == [nil, nil])
        #expect(manager.running("/repo/a", guest: guest) != nil)
    }

    @Test func resetToCleanStopsTheVMAndSwapsTheDisk() async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")
        try await manager.takeCleanPoint(worktreeID: "/repo/a", guest: .macOS)
        let disk = VMBundle(url: bundle).diskImage
        try Data("dirty".utf8).write(to: disk)
        let clean = cleanDirectory(bundle)
        let cleanFiles = try FileManager.default.contentsOfDirectory(atPath: clean.path).sorted()
        // An agent call in flight fails as for any stop, but a take over survives the restart.
        var stops: [String] = []
        manager.onVMStopped = { stops.append($0) }

        try await manager.resetToClean(worktreeID: "/repo/a", guest: .macOS)

        #expect(stops.isEmpty)
        #expect(try contents(disk) == "disk")
        // It resumed from the clean point's state, not a cold boot.
        #expect(hypervisor.restoredFrom == [nil, stateFile(bundle), stateFile(bundle)])
        #expect(manager.running("/repo/a") != nil)
        #expect(!isPaused(bundle))
        #expect(try FileManager.default.contentsOfDirectory(atPath: clean.path).sorted() == cleanFiles)
        #expect(try contents(clean.appendingPathComponent("disk.img")) == "disk")
    }

    /// A reset whose restart fails leaves the VM stopped, which ends a take over like any stop.
    @Test func aResetLeftStoppedReportsTheStop() async throws {
        try addRecord("/repo/a")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")
        try await manager.takeCleanPoint(worktreeID: "/repo/a", guest: .macOS)
        var stops: [String] = []
        manager.onVMStopped = { stops.append($0) }
        let (registry, elsewhere) = (registry, elsewhere)
        // Another Alas takes the VM while its disk is swapped, so the restart can't happen.
        manager.cloneCleanFile = { source, destination in
            try VMBundle.cloneFile(source, to: destination)
            try registry.update { $0[0].runOwner = elsewhere }
        }

        await #expect(throws: WorktreeVMManager.RestartFailed.self) {
            try await manager.resetToClean(worktreeID: "/repo/a", guest: .macOS)
        }

        #expect(stops == ["/repo/a"])
    }

    /// The live state and its `state.json` go before the disk changes: an interrupted
    /// reset never restores the old memory onto the clean disk.
    @Test func anInterruptedResetToCleanColdBoots() async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        _ = try await manager.startVM(worktreeID: "/repo/a")
        try await manager.takeCleanPoint(worktreeID: "/repo/a", guest: .macOS)
        #expect(await manager.pauseVM(worktreeID: "/repo/a", guest: .macOS) == .saved)
        manager.cloneCleanFile = { source, destination in
            guard source.lastPathComponent != "state.vzvmsave" else { throw HypervisorFailure() }
            try VMBundle.cloneFile(source, to: destination)
        }

        await #expect(throws: HypervisorFailure.self) {
            try await manager.resetToClean(worktreeID: "/repo/a", guest: .macOS)
        }

        #expect(!isPaused(bundle))
        #expect(!FileManager.default.fileExists(atPath: stateFile(bundle).path))
        _ = try await manager.startVM(worktreeID: "/repo/a")
        #expect(hypervisor.restoredFrom.last == .some(nil))
    }

    enum ResetRefusal: CaseIterable { case noCleanPoint, runningElsewhere }

    @Test(arguments: ResetRefusal.allCases)
    func resetToCleanWithoutACleanPointIsRefused(_ refusal: ResetRefusal) async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        if refusal == .runningElsewhere {
            try await manager.takeCleanPoint(worktreeID: "/repo/a", guest: .macOS)
            try registry.update { $0[0].runOwner = elsewhere }
        }
        try Data("dirty".utf8).write(to: VMBundle(url: bundle).diskImage)

        await #expect(throws: WorktreeVMManager.VMError.self) {
            try await manager.resetToClean(worktreeID: "/repo/a", guest: .macOS)
        }

        #expect(try contents(VMBundle(url: bundle).diskImage) == "dirty")
        #expect(hypervisor.boots == 0)
    }

    @Test(arguments: [VMGuestOS.macOS, .linux])
    func resetFromScratchReclonesAndKeepsTheRecordGuest(guest: VMGuestOS) async throws {
        try makeSealedGoldens()
        let id = VMIdentity.recordID(worktree: "/repo/a", guest: guest)
        let manager = makeManager()
        try manager.createVM(worktreeID: "/repo/a", guest: guest)
        _ = try await manager.startVM(worktreeID: "/repo/a", guest: guest)
        try await manager.takeCleanPoint(worktreeID: "/repo/a", guest: guest)
        let disk = VMBundle(url: URL(fileURLWithPath: try record(id).bundlePath)).diskImage
        try Data("dirty".utf8).write(to: disk)

        try await manager.resetFromScratch(worktreeID: "/repo/a", guest: guest)

        #expect(try record(id).guestOS == guest)
        #expect(try contents(VMBundle(url: URL(fileURLWithPath: record(id).bundlePath)).diskImage) == "x")
        #expect(manager.cleanPoint(recordID: id) == nil)
        #expect(manager.isFirstBootPending(recordID: id))
        #expect(manager.running("/repo/a", guest: guest) == nil)
    }

    /// The setup steps over a manager, whose script run answers `exitCode`.
    @MainActor
    private final class SetupScriptRuns {
        var exitCode: Int32? = 0
        /// The VM stops mid-script, which cuts the run short.
        var stopsVM = false
        var runs: [(script: String, timeout: Int, hadCleanPoint: Bool)] = []
    }

    private func makeFirstBootSetup(_ manager: WorktreeVMManager, runs: SetupScriptRuns) -> VMFirstBootSetup {
        VMFirstBootSetup(
            manager: manager,
            waitForHelper: { _ in true },
            runScript: { recordID, script, timeout in
                runs.runs.append((script, timeout, manager.cleanPoint(recordID: recordID) != nil))
                if runs.stopsVM {
                    await manager.stopVM(worktreeID: recordID)
                    throw VMGuestClient.Failure.stopped
                }
                return VMGuestRunResult(
                    exitCode: runs.exitCode, stdout: "", stderr: "", truncated: false, timedOut: runs.exitCode == nil)
            }
        )
    }

    /// A script that already succeeded, before a clean point that failed, isn't run again.
    @Test(arguments: [false, true])
    func firstBootRunsTheSetupScriptThenTakesTheCleanPoint(scriptSucceeded: Bool) async throws {
        let bundle = try addRecord("/repo/a")
        try Data().write(to: WorktreeVMManager.firstBootMarker(of: VMBundle(url: bundle)))
        let manager = makeManager()
        let runs = SetupScriptRuns()
        _ = try await manager.startVM(worktreeID: "/repo/a")

        let outcome = await makeFirstBootSetup(manager, runs: runs)
            .run(recordID: "/repo/a", script: "brew install jq", scriptSucceeded: scriptSucceeded)

        #expect(outcome == .cleanPointTaken)
        #expect(runs.runs.map(\.script) == (scriptSucceeded ? [] : ["brew install jq"]))
        #expect(runs.runs.allSatisfy { $0.timeout == 600 && !$0.hadCleanPoint })
        #expect(manager.cleanPoint(recordID: "/repo/a")?.setupScriptHash == VMCleanPoint.scriptHash("brew install jq"))
        #expect(!manager.isFirstBootPending(recordID: "/repo/a"))
        #expect(manager.running("/repo/a") != nil)
    }

    @Test func aStopMidScriptIsNotAFailure() async throws {
        try addRecord("/repo/a")
        let manager = makeManager()
        let runs = SetupScriptRuns()
        runs.stopsVM = true
        _ = try await manager.startVM(worktreeID: "/repo/a")

        let outcome = await makeFirstBootSetup(manager, runs: runs).run(recordID: "/repo/a", script: "sleep 60")

        #expect(outcome == .interrupted)
        #expect(manager.cleanPoint(recordID: "/repo/a") == nil)
    }

    struct FirstBootCase: CustomTestStringConvertible, Sendable {
        let name: String
        var recordID = "/repo/a"
        var pending = true
        var running = false
        var failed = false
        let runs: Bool
        var testDescription: String { name }
    }

    @Test(arguments: [
        FirstBootCase(name: "a new VM", runs: true),
        FirstBootCase(name: "a VM created before first boots were tracked", pending: false, runs: false),
        FirstBootCase(name: "a golden", recordID: WorktreeVMManager.goldenIDPrefix + "25A1", runs: false),
        FirstBootCase(name: "setup already under way", running: true, runs: false),
        FirstBootCase(name: "a failed script awaits Run again or Skip", failed: true, runs: false),
    ])
    func firstBootSetupRunsOnlyForNewVMs(_ c: FirstBootCase) {
        #expect(WorktreeVMManager.runsFirstBootSetup(
            recordID: c.recordID, firstBootPending: c.pending, setupRunning: c.running, setupFailed: c.failed
        ) == c.runs)
    }

    struct AutoVMCase: CustomTestStringConvertible, Sendable {
        let name: String
        var setting: Bool? = true
        var appleSilicon = true
        var golden = true
        var remote = false
        let creates: Bool
        var testDescription: String { name }
    }

    @Test(arguments: [
        AutoVMCase(name: "setting on", creates: true),
        AutoVMCase(name: "setting off", setting: false, creates: false),
        AutoVMCase(name: "setting never chosen", setting: nil, creates: false),
        AutoVMCase(name: "Intel host", appleSilicon: false, creates: false),
        AutoVMCase(name: "no golden image", golden: false, creates: false),
        AutoVMCase(name: "remote project", remote: true, creates: false),
    ])
    func newWorktreesGetAVMOnlyWhenTheProjectAsksAndOneCanBeCloned(_ c: AutoVMCase) {
        var project = ProjectConfig(id: "p", name: "R", path: "/tmp/r", color: "#fff", addedAt: .distantPast)
        project.vmForNewWorktrees = c.setting
        #expect(WorktreeVMManager.shouldCreateVM(
            project: project, isAppleSilicon: c.appleSilicon, goldenAvailable: c.golden, isRemote: c.remote
        ) == c.creates)
    }

    @Test(arguments: [Int32(3), nil])
    func aFailingSetupScriptLeavesNoCleanPoint(exitCode: Int32?) async throws {
        let bundle = try addRecord("/repo/a")
        let manager = makeManager()
        let runs = SetupScriptRuns()
        runs.exitCode = exitCode
        _ = try await manager.startVM(worktreeID: "/repo/a")

        let outcome = await makeFirstBootSetup(manager, runs: runs).run(recordID: "/repo/a", script: "exit 3")

        #expect(outcome == .scriptFailed(exitCode: exitCode))
        #expect(manager.cleanPoint(recordID: "/repo/a") == nil)
        #expect(!FileManager.default.fileExists(atPath: cleanDirectory(bundle).path))
        // Left running, untouched, for "Run again" or "Skip and save clean point".
        #expect(manager.running("/repo/a") != nil)
        #expect(hypervisor.boots == 1)
    }

    // MARK: - Auto-start

    /// The auto-start's clock: frozen, a sleep only yields, so no deadline passes until `run()`.
    @MainActor
    private final class ManualClock {
        private(set) var instant = ContinuousClock.now
        private var running = false

        func run() { running = true }
        func now() -> ContinuousClock.Instant { instant }
        func sleep(_ duration: Duration) async {
            if running { instant += duration }
            await Task.yield()
        }
    }

    private let clock = ManualClock()

    /// Whether the guest helper of a started VM answers its hello.
    @MainActor
    private final class Helper {
        var answers = true
    }

    private let helper = Helper()

    /// An auto-starter over `manager`, whose guest helper answers while `helper.answers`.
    /// `start` replaces the manager's start.
    private func makeStarter(
        _ manager: WorktreeVMManager, start: ((String, VMGuestOS) async throws -> VMStartOutcome)? = nil
    ) -> VMAutoStarter {
        let clock = clock
        let helper = helper
        return VMAutoStarter(
            start: { worktreeID, guest in
                if let start { return try await start(worktreeID, guest) }
                return try await manager.startVM(worktreeID: worktreeID, guest: guest)
            },
            startPausing: { _ = try await manager.startVM(worktreeID: $0, pausing: $1) },
            isStarting: { manager.isStarting($0) },
            isRunning: { manager.running($0, guest: $1) != nil },
            helperAnswers: { _, _ in helper.answers },
            candidateName: { "name of \($0)" },
            sleep: { await clock.sleep($0) },
            now: { clock.now() }
        )
    }

    /// Polls `condition` on the real clock; the caller asserts it afterwards.
    private func eventually(_ condition: @MainActor () -> Bool) async {
        _ = await GuestSetupSteps.waitUntil(
            timeout: .seconds(5), interval: .milliseconds(5),
            sleep: { try? await Task.sleep(for: $0) }, now: { .now }, condition
        )
    }

    /// Both macOS slots run here, so starting "/repo/c" needs the user to pause one.
    private func fillBothSlots(_ manager: WorktreeVMManager) async throws {
        try addRecord("/repo/a", lastUsed: 1)
        try addRecord("/repo/b", lastUsed: 2)
        try addRecord("/repo/c")
        for id in ["/repo/a", "/repo/b"] {
            _ = try await manager.startVM(worktreeID: id)
        }
    }

    @Test func aStoppedVMStartsAndTheCallProceeds() async throws {
        try addRecord("/repo/a")
        let manager = makeManager()
        let starter = makeStarter(manager)

        let result = await starter.autoStart(worktreeID: "/repo/a", guest: .macOS, sessionID: "s1", call: .computer)

        #expect(result == .ready)
        #expect(manager.running("/repo/a") != nil)
        #expect(starter.starting.isEmpty)
    }

    @Test func concurrentCallsShareOneStart() async throws {
        try addRecord("/repo/a")
        let manager = makeManager()
        let starter = makeStarter(manager)
        hypervisor.bootGate.armed = true

        let first = Task { await starter.autoStart(worktreeID: "/repo/a", guest: .macOS, sessionID: "s1", call: .computer) }
        await hypervisor.bootGate.waitUntilHeld()
        let second = Task { await starter.autoStart(worktreeID: "/repo/a", guest: .macOS, sessionID: "s2", call: .computer) }
        await eventually { starter.isWaitingOnBoot(sessionID: "s2") }
        #expect(starter.isWaitingOnBoot(sessionID: "s1"))
        hypervisor.bootGate.release()

        #expect(await first.value == .ready)
        #expect(await second.value == .ready)
        #expect(hypervisor.boots == 1)
    }

    @Test func aSecondCallReusesTheSlotCard() async throws {
        let manager = makeManager()
        try await fillBothSlots(manager)
        let starter = makeStarter(manager)

        let first = Task { await starter.autoStart(worktreeID: "/repo/c", guest: .macOS, sessionID: "s1", call: .computer) }
        await eventually { starter.slotRequests.count == 1 }
        let second = Task { await starter.autoStart(worktreeID: "/repo/c", guest: .macOS, sessionID: "s1", call: .computer) }
        let other = Task { await starter.autoStart(worktreeID: "/repo/c", guest: .macOS, sessionID: "s2", call: .computer) }
        await eventually { starter.waiters.count == 3 }
        #expect(starter.slotRequests.map(\.sessionID).sorted() == ["s1", "s2"])
        let request = try #require(starter.slotRequests.first { $0.sessionID == "s1" })
        #expect(request.candidates.map(\.name) == ["name of /repo/a", "name of /repo/b"])

        // The first answer wins and takes the other session's card with it.
        starter.answer(requestID: request.id, choice: .decline)

        for call in [first, second, other] {
            #expect(await call.value == .declined)
        }
        #expect(starter.slotRequests.isEmpty)
        #expect(hypervisor.boots == 2)
    }

    @Test func pausingAnotherVMStartsThisOne() async throws {
        let manager = makeManager()
        try await fillBothSlots(manager)
        let starter = makeStarter(manager)

        let call = Task { await starter.autoStart(worktreeID: "/repo/c", guest: .macOS, sessionID: "s1", call: .computer) }
        await eventually { !starter.slotRequests.isEmpty }
        let request = try #require(starter.slotRequests.first)
        starter.answer(requestID: request.id, choice: .pause(recordID: "/repo/a"))

        #expect(await call.value == .ready)
        #expect(manager.running("/repo/a") == nil)
        #expect(try isPaused(bundle("/repo/a")))
        #expect(manager.running("/repo/c") != nil)
    }

    /// The VM chosen to pause stopped before the answer: the freed slot takes a plain start.
    @Test func pausingAVMThatAlreadyStoppedStartsThisOne() async throws {
        let manager = makeManager()
        try await fillBothSlots(manager)
        let starter = makeStarter(manager)

        let call = Task { await starter.autoStart(worktreeID: "/repo/c", guest: .macOS, sessionID: "s1", call: .computer) }
        await eventually { !starter.slotRequests.isEmpty }
        await manager.stopVM(worktreeID: "/repo/a")
        starter.answer(requestID: try #require(starter.slotRequests.first).id, choice: .pause(recordID: "/repo/a"))

        #expect(await call.value == .ready)
        #expect(manager.running("/repo/c") != nil)
        #expect(manager.running("/repo/b") != nil)
    }

    @Test func aVMStartedFromItsTabWhileTheCardWaitsEndsTheWait() async throws {
        let manager = makeManager()
        try await fillBothSlots(manager)
        let starter = makeStarter(manager)

        let call = Task { await starter.autoStart(worktreeID: "/repo/c", guest: .macOS, sessionID: "s1", call: .computer) }
        await eventually { !starter.slotRequests.isEmpty }
        _ = try await manager.startVM(worktreeID: "/repo/c", pausing: "/repo/a")

        #expect(await call.value == .ready)
        #expect(starter.slotRequests.isEmpty)
    }

    @Test func decliningReturnsTheDeclinedMessage() async throws {
        let manager = makeManager()
        try await fillBothSlots(manager)
        let starter = makeStarter(manager)

        let call = Task { await starter.autoStart(worktreeID: "/repo/c", guest: .macOS, sessionID: "s1", call: .computer) }
        await eventually { !starter.slotRequests.isEmpty }
        starter.answer(requestID: try #require(starter.slotRequests.first).id, choice: .decline)

        let result = await call.value
        #expect(result.refusal == "computer_vm_stopped: The user chose not to start this worktree's VM.")
        #expect(manager.running("/repo/c") == nil)
    }

    @Test func aSlowSlotAnswerLeavesThePendingCard() async throws {
        let manager = makeManager()
        try await fillBothSlots(manager)
        let starter = makeStarter(manager)

        let call = Task { await starter.autoStart(worktreeID: "/repo/c", guest: .macOS, sessionID: "s1", call: .computer) }
        await eventually { !starter.slotRequests.isEmpty }
        clock.run()

        let result = await call.value
        #expect(result == .slotPending)
        #expect(result.refusal == VMAutoStartMessages.slotPending)
        let request = try #require(starter.slotRequests.first)
        // Answered after the call gave up: the VM starts for the agent's next call.
        starter.answer(requestID: request.id, choice: .pause(recordID: "/repo/b"))
        await eventually { manager.running("/repo/c") != nil }
        #expect(manager.running("/repo/c") != nil)
        #expect(manager.running("/repo/b") == nil)
    }

    /// A call answers `starting` instead of running once too little of its client's budget is
    /// left: a computer call 35 s, a `vm_run` its own command timeout.
    @Test(arguments: [
        (VMAutoStartCall.computer, 85, true, 100),
        (.computer, 86, false, 100),
        (.vmRun(timeoutSeconds: 30), 25, true, 25),
        (.vmRun(timeoutSeconds: 30), 26, false, 25),
        (.vmRun(timeoutSeconds: 600), 26, false, 25),
    ])
    func aLateReadyCallReturnsStarting(call: VMAutoStartCall, elapsedSeconds: Int, proceeds: Bool, budgetSeconds: Int) {
        #expect(VMAutoStartCall.proceeds(call, elapsed: .seconds(elapsedSeconds)) == proceeds)
        #expect(call.waitBudget == .seconds(budgetSeconds))
    }

    enum StartFailure: Sendable { case throwing, noLocalCandidates }

    /// A start that can't run says why: it threw, or every slot belongs to another Alas.
    @Test(arguments: [
        (StartFailure.throwing, "computer_vm_stopped: Couldn't start this worktree's VM: boom"),
        (.noLocalCandidates,
         "computer_vm_stopped: Couldn't start this worktree's VM: both VM slots are in use by another Alas."),
    ])
    func aStartThatCannotRunSaysWhy(stub: StartFailure, expected: String) async throws {
        try addRecord("/repo/a")
        let starter = makeStarter(makeManager()) { _, _ in
            switch stub {
            case .throwing: throw WorktreeVMManager.VMError(message: "boom")
            case .noLocalCandidates: return .needsUserChoice(candidates: [])
            }
        }

        let result = await starter.autoStart(worktreeID: "/repo/a", guest: .macOS, sessionID: "s1", call: .computer)

        #expect(result.refusal == expected)
        #expect(starter.slotRequests.isEmpty)
    }

    @Test func aVMAlreadyBootingIsWaitedForNotStartedAgain() async throws {
        try addRecord("/repo/a")
        let manager = makeManager()
        let starter = makeStarter(manager)
        hypervisor.bootGate.armed = true
        let fromTab = Task { try await manager.startVM(worktreeID: "/repo/a") }
        await hypervisor.bootGate.waitUntilHeld()

        let call = Task { await starter.autoStart(worktreeID: "/repo/a", guest: .macOS, sessionID: "s1", call: .computer) }
        await eventually { starter.isWaitingOnBoot(sessionID: "s1") }
        hypervisor.bootGate.release()

        #expect(await call.value == .ready)
        _ = try await fromTab.value
        #expect(hypervisor.boots == 1)
    }

    /// The agent's retry after `starting` finds the VM running before its helper answers: it joins
    /// the start's helper wait, never a helper error, and ends with it.
    @Test(arguments: [true, false])
    func aCallReachingAVMWhoseHelperIsStillStartingJoinsTheStart(helloArrives: Bool) async throws {
        try addRecord("/repo/a")
        let manager = makeManager()
        let starter = makeStarter(manager)
        helper.answers = false

        let first = Task { await starter.autoStart(worktreeID: "/repo/a", guest: .macOS, sessionID: "s1", call: .computer) }
        await eventually { manager.running("/repo/a") != nil }
        // What the guest route checks before it talks to the helper.
        #expect(starter.starting == ["/repo/a"])
        let retry = Task { await starter.autoStart(worktreeID: "/repo/a", guest: .macOS, sessionID: "s1", call: .computer) }
        await eventually { starter.waiters.count == 2 }
        if helloArrives { helper.answers = true } else { clock.run() }

        let expected: AutoStartResult = helloArrives ? .ready : .starting
        #expect(await first.value == expected)
        #expect(await retry.value == expected)
        #expect(hypervisor.boots == 1)
    }

    @Test func aSlowBootReturnsStarting() async throws {
        try addRecord("/repo/a")
        let manager = makeManager()
        let starter = makeStarter(manager)
        hypervisor.bootGate.armed = true

        let call = Task { await starter.autoStart(worktreeID: "/repo/a", guest: .macOS, sessionID: "s1", call: .computer) }
        await hypervisor.bootGate.waitUntilHeld()
        clock.run()

        let result = await call.value
        #expect(result == .starting)
        #expect(result.refusal == VMAutoStartMessages.starting)
        #expect(starter.starting == ["/repo/a"])
        hypervisor.bootGate.release()
        await eventually { starter.starting.isEmpty }
        #expect(manager.running("/repo/a") != nil)
    }

    @Test func stoppingTheSessionDismissesItsCards() async throws {
        let manager = makeManager()
        try await fillBothSlots(manager)
        let starter = makeStarter(manager)

        let call = Task { await starter.autoStart(worktreeID: "/repo/c", guest: .macOS, sessionID: "s1", call: .computer) }
        await eventually { !starter.slotRequests.isEmpty }
        starter.dismiss(sessionID: "s1")

        let result = await call.value
        #expect(result.refusal == ComputerUseCoordinator.stoppedMessage)
        #expect(starter.slotRequests.isEmpty)
        // Nothing is left waiting on the dismissed card: the next call asks again.
        let next = Task { await starter.autoStart(worktreeID: "/repo/c", guest: .macOS, sessionID: "s1", call: .computer) }
        await eventually { !starter.slotRequests.isEmpty }
        starter.answer(requestID: try #require(starter.slotRequests.first).id, choice: .decline)
        #expect(await next.value == .declined)
    }

    // MARK: - Disk use

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test(arguments: [VMGuestOS.macOS, .linux])
    func deletingAGoldenWithClonesIsRefused(_ guest: VMGuestOS) async throws {
        try makeSealedGoldens()
        let manager = makeManager()
        try manager.createVM(worktreeID: "/repo/a", guest: guest)
        let golden = try #require(await manager.diskUse().bundles.first { $0.kind == .golden && $0.guest == guest })

        let refusal = #expect(throws: WorktreeVMManager.VMError.self) { try manager.deleteGolden(id: golden.id) }
        #expect(refusal?.message == "Delete its worktree VMs first")
        #expect(exists(golden.url))

        #expect(await manager.deleteVM(worktreeID: "/repo/a", guest: guest) == nil)
        try manager.deleteGolden(id: golden.id)
        #expect(!exists(golden.url))
        #expect(try await !manager.diskUse().bundles.contains { $0.id == golden.id })
    }

    @Test func orphanCleanupDeletesOnlyOrphans() async throws {
        // Live: the worktree is on disk, or belongs to a project.
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let onDisk = try addRecord(checkout.path)
        let inProject = try addRecord("linux:/repo/known")
        // The worktree is gone, but another Alas runs the VM.
        let runningElsewhere = try addRecord("/repo/gone-elsewhere", owner: elsewhere)
        // Orphans: the worktree is gone, or no record names the bundle.
        let gone = try addRecord("/repo/gone")
        let stray = root.appendingPathComponent("worktrees/stray", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        // Only a record this build can't decode names it: a newer Alas's VM, maybe running.
        let newer = root.appendingPathComponent("worktrees/newer", isDirectory: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("registry.json")
        var elements = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [Any] ?? []
        elements.append(["id": "/repo/newer", "guestOS": "plan9", "goldenBuild": "x", "bundlePath": newer.path,
                         "createdAt": 0, "lastUsedAt": 0])
        try JSONSerialization.data(withJSONObject: elements).write(to: file)
        // Leftovers of an interrupted reset and clean point.
        for bundle in [onDisk, runningElsewhere] {
            try Data("x".utf8).write(to: bundle.appendingPathComponent("disk.img.resetting"))
            try FileManager.default.createDirectory(
                at: bundle.appendingPathComponent("clean.partial"), withIntermediateDirectories: true)
        }
        let manager = makeManager()
        manager.worktreePath = { $0 == "/repo/known" ? URL(fileURLWithPath: "/repo/known") : nil }

        let orphans = try await manager.diskUse().orphans
        #expect(Set(orphans.map(\.url.lastPathComponent)) == [gone.lastPathComponent, stray.lastPathComponent])

        #expect(manager.deleteOrphans(orphans.map(\.id) + ["worktrees/newer"]) == nil)

        #expect([onDisk, inProject, runningElsewhere, newer].allSatisfy(exists))
        #expect(![gone, stray].contains(where: exists))
        #expect(try Set(registry.snapshot().map(\.id)) == [checkout.path, "linux:/repo/known", "/repo/gone-elsewhere"])
        #expect(!exists(onDisk.appendingPathComponent("disk.img.resetting")))
        #expect(!exists(onDisk.appendingPathComponent("clean.partial")))
        #expect(exists(runningElsewhere.appendingPathComponent("disk.img.resetting")))
        #expect(exists(runningElsewhere.appendingPathComponent("clean.partial")))
        #expect(try await manager.diskUse().orphans.isEmpty)
    }

    @Test func removeInstallersKeepsBundles() async throws {
        try makeSealedGoldens()
        let manager = makeManager()
        manager.worktreePath = { _ in URL(fileURLWithPath: "/repo/a") }
        try manager.createVM(worktreeID: "/repo/a")
        let installers = [root.appendingPathComponent("ipsw/UniversalMac.ipsw"),
                          root.appendingPathComponent("linux-images/20261016.img")]
        for file in installers {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("installer".utf8).write(to: file)
        }
        #expect(await manager.installerBytes() > 0)

        // Refused while an install holds its lock, as a download does.
        let install = try ComputerUseDriverLock.acquire(at: root.appendingPathComponent("install.lock"), label: "test")
        #expect(throws: WorktreeVMManager.VMError.self) { try manager.removeInstallers() }
        #expect(installers.allSatisfy(exists))
        install.release()

        try manager.removeInstallers()
        #expect(!installers.contains(where: exists))
        #expect(await manager.installerBytes() == 0)
        let bundles = try await manager.diskUse().bundles
        #expect(bundles.count == 3)
        #expect(bundles.allSatisfy { exists($0.url) && $0.allocatedBytes > 0 })
    }

    /// A sealed macOS and Linux golden image, enough for `createVM` to clone.
    private func makeSealedGoldens() throws {
        let macOS = try makeGoldenBundle()
        for file in [macOS.diskImage, macOS.auxiliaryStorage, macOS.hardwareModel] {
            try Data("x".utf8).write(to: file)
        }
        try GoldenImageInstaller.writeSealedMarker(macOS)
        let linux = LinuxVMBundle(url: root.appendingPathComponent(
            "golden-linux/\(LinuxGoldenImage.serial)", isDirectory: true))
        try FileManager.default.createDirectory(at: linux.url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: linux.diskImage)
        try LinuxGoldenInstaller.writeSealedMarker(linux)
    }

    private func makeGoldenBundle() throws -> VMBundle {
        let golden = VMBundle(url: root.appendingPathComponent("golden/25A1", isDirectory: true))
        try FileManager.default.createDirectory(at: golden.url, withIntermediateDirectories: true)
        return golden
    }
}
