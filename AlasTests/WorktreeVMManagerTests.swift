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
        init(hypervisor: FakeHypervisor, stopFails: Bool, guestStopError: Error?) {
            self.hypervisor = hypervisor
            self.stopFails = stopFails
            self.guestStopError = guestStopError
        }
        func start() async throws { state = .running }
        func requestStop() throws {
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

    private func makeManager() -> WorktreeVMManager {
        let hypervisor = hypervisor
        return WorktreeVMManager(registry: registry, root: root) { worktreeID, _ in
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

        await manager.deleteVM(worktreeID: "/repo/a")

        #expect(manager.running("/repo/a") == nil)
        #expect(try registry.snapshot().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
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

        let sawCleanShutdown = [.guestShutdown, .bootedElsewhereAfterCleanShutdown].contains(lastStop)
        #expect(shutdown == (sawCleanShutdown ? .clean : .forcedOff))
        #expect(manager.running(id) == nil)
        #expect(sealed == (lastStop == .guestShutdown))
        #expect(golden.isSealed == (lastStop == .guestShutdown))
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

    private func makeGoldenBundle() throws -> VMBundle {
        let golden = VMBundle(url: root.appendingPathComponent("golden/25A1", isDirectory: true))
        try FileManager.default.createDirectory(at: golden.url, withIntermediateDirectories: true)
        return golden
    }
}
