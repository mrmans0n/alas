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
    @MainActor
    private final class FakeHypervisor {
        var stopFails = false
        var guestStopError: Error?
        let bootGate = Gate()
        let stopGate = Gate()
        private(set) var boots = 0

        func boot(_ worktreeID: String) async throws -> RunningVM {
            boots += 1
            await bootGate.passIfArmed()
            let vm = RunningVM(worktreeID: worktreeID, machine: FakeMachine(
                hypervisor: self, stopFails: stopFails, guestStopError: guestStopError))
            try await vm.start()
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
        ) { worktreeID, _, _ in
            try await hypervisor.boot(worktreeID)
        }
    }

    @discardableResult
    private func addRecord(_ id: String, owner: VMRunOwner? = nil, lastUsed: TimeInterval = 0) throws -> URL {
        let bundle = root.appendingPathComponent("worktrees/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try registry.update { records in
            records.append(WorktreeVMRecord(
                id: id, goldenBuild: "25A1", bundlePath: bundle.path,
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
