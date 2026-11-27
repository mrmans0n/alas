import AlasCore
import Darwin
import Foundation
import os

/// One serialized read-only adb subprocess per device. Pipe state lives only on `queue`.
final class AndroidSnapshotReader: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case unsupported, busy, unavailable, disconnected, timedOut, invalidReply
    }

    private let executable: URL
    private let arguments: [String]
    private let preparation: [[String]]
    private let queue = DispatchQueue(label: "io.nlopez.alas.android-snapshot", qos: .userInitiated)
    private let closed = OSAllocatedUnfairLock(initialState: false)
    private var prepared = false
    private var unsupported = false
    private var session: Session?

    init(executable: URL, arguments: [String], preparation: [[String]] = []) {
        self.executable = executable
        self.arguments = arguments
        self.preparation = preparation
    }

    func read() async throws -> Data {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(with: Result { try exchange(cancelled: cancelled) })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    func close() {
        closed.withLock { $0 = true }
        queue.async { [self] in session = nil }
    }

    private func exchange(cancelled: OSAllocatedUnfairLock<Bool>) throws -> Data {
        func checkCancellation() throws {
            if cancelled.withLock({ $0 }) || closed.withLock({ $0 }) { throw CancellationError() }
        }
        try checkCancellation()
        if unsupported { throw Failure.unsupported }
        // Drain a retired session before a new helper tries to take its slot.
        // Retire before the device's five-second deadline, not at the same instant.
        if let session, session.inputClosed || !session.process.isRunning || DispatchTime.now() >= session.reuseUntil {
            try session.finish(checkCancellation: checkCancellation)
            if session.process.terminationStatus != 0 { prepared = false }
            self.session = nil
        }
        if !prepared {
            for args in preparation {
                let process = Process()
                process.executableURL = executable
                process.arguments = args
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
                do {
                    while process.isRunning {
                        try checkCancellation()
                        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.timedOut }
                        usleep(20_000)
                    }
                } catch {
                    if process.isRunning { process.terminate() }
                    throw error
                }
                guard process.terminationStatus == 0 else { throw Failure.unavailable }
            }
            prepared = true
        }
        try checkCancellation()
        if session == nil { session = try Session(executable: executable, arguments: arguments) }
        guard let session else { throw Failure.disconnected }
        do {
            let reply = try session.read(checkCancellation: checkCancellation)
            try checkCancellation()
            switch reply.first {
            case UInt8(ascii: "!"):
                switch String(decoding: reply, as: UTF8.self) {
                case "!unsupported":
                    try session.finish(checkCancellation: checkCancellation)
                    unsupported = true
                    throw Failure.unsupported
                case "!busy":
                    try session.finish(checkCancellation: checkCancellation)
                    throw Failure.busy
                case "!unavailable": throw Failure.unavailable
                default: throw Failure.invalidReply
                }
            default:
                guard reply.starts(with: "<hierarchy ".utf8), reply.suffix(12).elementsEqual("</hierarchy>".utf8) else {
                    throw Failure.invalidReply
                }
                return reply
            }
        } catch {
            if error as? Failure == .disconnected { prepared = false }
            if error as? Failure != .unavailable {
                session.endInput()
                if !session.process.isRunning { self.session = nil }
            }
            throw error
        }
    }

    private final class Session {
        let process = Process()
        private let input = Pipe.closingOnExec()
        private let output = Pipe.closingOnExec()
        private(set) var inputClosed = false
        private(set) var reuseUntil = DispatchTime.distantFuture

        init(executable: URL, arguments: [String]) throws {
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw Failure.unavailable
            }
            try process.run()
        }

        deinit {
            endInput()
            if process.isRunning { process.terminate() }
        }

        func endInput() {
            guard !inputClosed else { return }
            inputClosed = true
            try? input.fileHandleForWriting.close()
        }

        func finish(checkCancellation: () throws -> Void) throws {
            endInput()
            // Allow the device's three-second disconnect watchdog to fire first.
            let deadline = DispatchTime.now() + .seconds(4)
            while process.isRunning {
                try checkCancellation()
                if DispatchTime.now() >= deadline {
                    process.terminate()
                    throw Failure.timedOut
                }
                usleep(10_000)
            }
        }

        func read(checkCancellation: () throws -> Void) throws -> Data {
            let started = DispatchTime.now()
            // The helper's idle period starts when it finishes the reply, so this is conservative.
            reuseUntil = started + .seconds(4)
            do {
                try input.fileHandleForWriting.write(contentsOf: Data([UInt8(ascii: "r"), 10]))
            } catch {
                throw Failure.disconnected
            }
            let fd = output.fileHandleForReading.fileDescriptor
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let deadline = started + .seconds(7)
            var reply = Data()
            return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16_384) { buffer in
                while DispatchTime.now() < deadline {
                    try checkCancellation()
                    let ready = poll(&descriptor, 1, 50)
                    if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                    guard ready > 0, let base = buffer.baseAddress else { throw Failure.disconnected }
                    let count = Darwin.read(fd, base, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw Failure.disconnected }
                    let chunk = UnsafeBufferPointer(start: base, count: count)
                    guard reply.count + count <= 1_048_576 else { throw Failure.invalidReply }
                    if let end = chunk.firstIndex(of: 10) {
                        guard end == count - 1 else { throw Failure.invalidReply }
                        reply.append(base, count: end)
                        return reply
                    }
                    reply.append(base, count: count)
                }
                throw Failure.timedOut
            }
        }
    }
}
