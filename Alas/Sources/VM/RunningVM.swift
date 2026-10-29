import Foundation
import Virtualization
import os

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
    /// Connects to a vsock port a process in the guest listens on.
    func openGuestConnection(port: UInt32) async throws -> VMGuestTransport
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

    func openGuestConnection(port: UInt32) async throws -> VMGuestTransport {
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw POSIXError(.ENODEV)
        }
        // On the main queue, the VM's queue.
        return VsockGuestTransport(connection: try await device.connect(toPort: port))
    }

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

    func openGuestConnection(port: UInt32) async throws -> VMGuestTransport {
        try await machine.openGuestConnection(port: port)
    }

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

/// A vsock connection to the guest. Its reads block, so they run on a thread of their own; writes
/// go through a serial queue. The descriptor is closed only after the reader has stopped, so
/// neither side can touch a reused one.
final class VsockGuestTransport: VMGuestTransport, @unchecked Sendable {
    /// Owns the descriptor; kept until the reader stops.
    private let connection: VZVirtioSocketConnection
    private let fd: Int32
    private let writes = DispatchQueue(label: "io.nlopez.alas.vm-guest-transport.write")
    private let lock = NSLock()
    /// Guarded by `lock`: the socket was shut down, by `close()` or by the reader stopping.
    private var isShutDown = false
    /// Used only by the client's single reader task.
    private var chunks: AsyncStream<Data>.Iterator
    private static let log = Logger(subsystem: "io.nlopez.alas", category: "vm-guest-transport")

    init(connection: VZVirtioSocketConnection) {
        self.connection = connection
        fd = connection.fileDescriptor
        var on: Int32 = 1
        // Without it, a write after the guest went away raises SIGPIPE, which the app does not ignore.
        if setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            Self.log.error("SO_NOSIGPIPE failed on the guest socket: errno \(errno, privacy: .public)")
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        chunks = stream.makeAsyncIterator()
        Thread.detachNewThread { [self] in readLoop(into: continuation) }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writes.async { continuation.resume(with: Result { try self.write(data) }) }
        }
    }

    func receive() async throws -> Data? {
        await chunks.next()
    }

    func close() {
        lock.withLock {
            guard !isShutDown else { return }
            isShutDown = true
            // Wakes the reader, which then closes the descriptor.
            if shutdown(fd, SHUT_RDWR) != 0 {
                Self.log.error("shutting down the guest socket failed: errno \(errno, privacy: .public)")
            }
        }
    }

    private func readLoop(into chunks: AsyncStream<Data>.Continuation) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            chunks.yield(Data(buffer[..<count]))
        }
        chunks.finish()
        lock.withLock { isShutDown = true }
        // After any write already queued.
        writes.async { self.connection.close() }
    }

    private func write(_ data: Data) throws {
        guard !lock.withLock({ isShutDown }) else { throw POSIXError(.ENOTCONN) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }
}
