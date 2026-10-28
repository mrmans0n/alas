import Foundation
import Virtualization

/// The hypervisor side of a running VM. `VirtualizationMachine` drives a real
/// `VZVirtualMachine`; tests substitute an in-memory machine.
@MainActor
protocol VMMachine: AnyObject {
    var state: VZVirtualMachine.State { get }
    /// The underlying machine, for display views. Nil only for test doubles.
    var virtualMachine: VZVirtualMachine? { get }
    /// Called when the guest stops on its own or the hypervisor reports an
    /// error. Not called for a forced `stop()`.
    var onGuestStop: ((Error?) -> Void)? { get set }
    func start() async throws
    /// Asks the guest to shut down (a power button press).
    func requestStop() throws
    /// Stops the VM immediately, like pulling the power cord.
    func stop() async throws
}

@MainActor
final class VirtualizationMachine: NSObject, VMMachine, VZVirtualMachineDelegate {
    let vm: VZVirtualMachine
    var onGuestStop: ((Error?) -> Void)?

    init(configuration: VZVirtualMachineConfiguration) {
        vm = VZVirtualMachine(configuration: configuration)
        super.init()
        vm.delegate = self
    }

    var state: VZVirtualMachine.State { vm.state }
    var virtualMachine: VZVirtualMachine? { vm }

    func start() async throws { try await vm.start() }

    func requestStop() throws { try vm.requestStop() }

    func stop() async throws { try await vm.stop() }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { onGuestStop?(nil) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated { onGuestStop?(error) }
    }
}

/// A booted VM owned by `WorktreeVMManager`.
@MainActor
final class RunningVM {
    /// How long a guest gets to shut down before it is forced off.
    static let gracefulStopTimeout: Duration = .seconds(20)

    let worktreeID: String
    private let machine: any VMMachine
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set by the manager; fires once the guest has stopped by any route.
    var onStopped: ((Error?) -> Void)?
    /// True once `forceStop()` powered the VM off rather than the guest
    /// shutting down.
    private(set) var wasForcedOff = false

    init(worktreeID: String, machine: any VMMachine) {
        self.worktreeID = worktreeID
        self.machine = machine
        machine.onGuestStop = { [weak self] error in self?.guestStopped(error) }
    }

    var vm: VZVirtualMachine? { machine.virtualMachine }
    var state: VZVirtualMachine.State { machine.state }

    func start() async throws { try await machine.start() }

    /// Requests a guest shutdown and forces the VM off when the guest has not
    /// stopped within `gracefulStopTimeout` (or refuses the request).
    func stop() async throws {
        guard await !stopGracefully() else { return }
        try await forceStop()
    }

    /// Requests a guest shutdown and waits up to `gracefulStopTimeout`. True
    /// when the VM is stopped afterwards; false leaves it running.
    func stopGracefully() async -> Bool {
        guard machine.state != .stopped, machine.state != .error else { return true }
        do {
            try machine.requestStop()
        } catch {
            // The guest cannot take a stop request right now.
            return false
        }
        await waitForGuestStop(timeout: Self.gracefulStopTimeout)
        return machine.state == .stopped || machine.state == .error
    }

    /// Stops the VM immediately, without asking the guest.
    func forceStop() async throws {
        guard machine.state != .stopped, machine.state != .error else { return }
        try await machine.stop()
        wasForcedOff = true
        guestStopped(nil)
    }

    private func waitForGuestStop(timeout: Duration) async {
        guard machine.state != .stopped, machine.state != .error else { return }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resumeStopWaiters()
        }
        await withCheckedContinuation { stopWaiters.append($0) }
        timeoutTask.cancel()
    }

    private func guestStopped(_ error: Error?) {
        resumeStopWaiters()
        let onStopped = onStopped
        self.onStopped = nil
        onStopped?(error)
    }

    private func resumeStopWaiters() {
        let waiters = stopWaiters
        stopWaiters = []
        waiters.forEach { $0.resume() }
    }
}
