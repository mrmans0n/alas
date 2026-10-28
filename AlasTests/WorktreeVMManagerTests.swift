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

    @MainActor
    private final class FakeMachine: VMMachine {
        let stopFails: Bool
        var state: VZVirtualMachine.State = .stopped
        var virtualMachine: VZVirtualMachine? { nil }
        var onGuestStop: ((Error?) -> Void)?
        init(stopFails: Bool) { self.stopFails = stopFails }
        func start() async throws { state = .running }
        func requestStop() throws {
            if stopFails { throw StopRefused() }
            state = .stopped
            onGuestStop?(nil)
        }
        func stop() async throws {
            if stopFails { throw StopRefused() }
            state = .stopped
        }
    }

    /// Boots fake machines. `gateNextBoot` holds the next boot until
    /// `releaseBoot()`; streams instead of continuations keep the handler
    /// free of nested closures.
    @MainActor
    private final class FakeHypervisor {
        var stopFails = false
        var gateNextBoot = false
        private let entered: AsyncStream<Void>
        private let enteredContinuation: AsyncStream<Void>.Continuation
        private let release: AsyncStream<Void>
        private let releaseContinuation: AsyncStream<Void>.Continuation

        init() {
            (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
            (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        }

        func boot(_ worktreeID: String) async throws -> RunningVM {
            if gateNextBoot {
                gateNextBoot = false
                enteredContinuation.yield()
                for await _ in release { break }
            }
            let vm = RunningVM(worktreeID: worktreeID, machine: FakeMachine(stopFails: stopFails))
            try await vm.start()
            return vm
        }

        func waitUntilBootIsHeld() async {
            for await _ in entered { break }
        }

        func releaseBoot() { releaseContinuation.yield() }
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

    @Test("deleting a VM while it boots stops it once booted and removes its record and bundle")
    func deleteDuringBootLeavesNothingBehind() async throws {
        let bundle = try addRecord("/repo/a")
        hypervisor.gateNextBoot = true
        let manager = makeManager()
        let start = Task { try await manager.startVM(worktreeID: "/repo/a") }
        await hypervisor.waitUntilBootIsHeld()

        await manager.deleteVM(worktreeID: "/repo/a")
        hypervisor.releaseBoot()

        await #expect(throws: WorktreeVMManager.VMError.self) { _ = try await start.value }
        #expect(manager.running("/repo/a") == nil)
        #expect(try registry.snapshot().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
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

    @Test("a golden VM running in another process blocks sealing")
    func goldenRunningElsewhereCounts() throws {
        try addRecord("golden:25A1", owner: elsewhere)
        #expect(makeManager().goldenRunsAnywhere())
    }
}
