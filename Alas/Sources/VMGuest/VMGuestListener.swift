import AlasComputerUseKit
import AlasCore
import Darwin
import Foundation
import os

/// Accepts the host's vsock connections on `VMGuestPort.computerUse` and hands their messages
/// to `VMGuestService`. Each connection reads on a thread of its own (the reads block), handles
/// every message in its own task, so a `cancel` is read while its command runs, and serializes
/// its writes.
final class VMGuestListener: Sendable {
    private let service: VMGuestService
    private static let log = Logger(subsystem: "io.nlopez.vmguest", category: "listener")

    init(service: VMGuestService) {
        self.service = service
    }

    /// Binds the port and accepts connections until the process exits.
    func start() throws {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_cid = VMADDR_CID_ANY
        address.svm_port = VMGuestPort.computerUse
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        Self.log.notice("listening on vsock port \(VMGuestPort.computerUse, privacy: .public)")
        let service = service
        Thread.detachNewThread {
            while true {
                let connection = accept(fd, nil, nil)
                if connection < 0 {
                    if errno != EINTR { Self.log.error("accept failed: errno \(errno, privacy: .public)") }
                    continue
                }
                Self.log.notice("host connected")
                Connection(fd: connection, service: service).start()
            }
        }
    }
}

private final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let service: VMGuestService
    private let writeLock = NSLock()
    /// Guarded by `writeLock`: set once the descriptor is closed, so no write reaches a reused one.
    private var closed = false
    /// Commands dispatched and not answered yet; cancelled when the host goes away.
    @MainActor private var pending: Set<UInt64> = []
    private static let log = Logger(subsystem: "io.nlopez.vmguest", category: "connection")

    init(fd: Int32, service: VMGuestService) {
        self.fd = fd
        self.service = service
    }

    func start() {
        Thread.detachNewThread { self.readLoop() }
    }

    private func readLoop() {
        var framer = VMGuestFramer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            let output = framer.append(Data(buffer[..<count]))
            if output.malformedFrames > 0 {
                Self.log.error("skipped \(output.malformedFrames, privacy: .public) malformed frame(s)")
            }
            for message in output.messages {
                Task { @MainActor in await self.dispatch(message) }
            }
        }
        Self.log.notice("host disconnected")
        Task { @MainActor in
            // Nobody is waiting for these answers any more.
            for id in self.pending { _ = await self.service.handle(.cancel(id: id)) }
            self.pending.removeAll()
            self.writeLock.withLock {
                self.closed = true
                close(self.fd)
            }
        }
    }

    @MainActor
    private func dispatch(_ message: VMGuestMessage) async {
        if case let .command(id, _, _) = message { pending.insert(id) }
        let reply = await service.handle(message)
        if case let .command(id, _, _) = message { pending.remove(id) }
        if let reply { send(reply) }
    }

    /// The lock keeps frames whole when replies finish together.
    @MainActor
    private func send(_ message: VMGuestMessage) {
        let frame: Data
        do {
            frame = try VMGuestFramer.frame(message)
        } catch {
            Self.log.error("couldn't encode a reply: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Off the main actor: a large frame may wait on the host to read.
        Thread.detachNewThread {
            self.writeLock.withLock {
                guard !self.closed else { return }
                let fd = self.fd
                frame.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if written < 0 {
                            if errno == EINTR { continue }
                            Self.log.error("write failed: errno \(errno, privacy: .public)")
                            return
                        }
                        offset += written
                    }
                }
            }
        }
    }
}
