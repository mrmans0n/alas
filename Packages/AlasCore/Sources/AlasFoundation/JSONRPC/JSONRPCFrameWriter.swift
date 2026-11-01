import Foundation

public enum JSONRPCFrameWriteResult: Equatable, Sendable {
    case notWritten
    case written
    case writeUncertain(String)
}

/// Opt-in factual writes. Ordinary send return/onWritten conventions are not a
/// substitute for this contract. Authorization runs after write serialization.
public protocol JSONRPCFrameWriting: AnyObject, Sendable {
    func writeFrame(_ data: Data, authorize: @escaping @Sendable () -> Bool) async -> JSONRPCFrameWriteResult
}

/// Serializes framed bytes without putting close behind a blocked write. The
/// injected closure is the actual I/O boundary, shared by sync and async sends.
final class JSONRPCFrameWriter: @unchecked Sendable {
    private let worker = DispatchQueue(label: "alas.jsonrpc.frame-writer")
    private let writerLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false
    private var poisoned = false
    private let write: @Sendable (Data) throws -> Void

    init(write: @escaping @Sendable (Data) throws -> Void) { self.write = write }

    func close() { stateLock.withLock { closed = true } }
    private var writable: Bool { stateLock.withLock { !closed && !poisoned } }

    func send(_ frame: Data) throws {
        writerLock.lock()
        defer { writerLock.unlock() }
        guard writable else { throw WriterError.notWritable }
        do { try write(frame) }
        catch { stateLock.withLock { poisoned = true }
        throw error }
    }

    func writeFrame(_ frame: Data, authorize: @escaping @Sendable () -> Bool) async -> JSONRPCFrameWriteResult {
        await withCheckedContinuation { continuation in
            worker.async {
                self.writerLock.lock()
                let result: JSONRPCFrameWriteResult
                if self.writable, authorize(), self.writable {
                    do { try self.write(frame)
                    result = .written }
                    catch {
                        self.stateLock.withLock { self.poisoned = true }
                        result = .writeUncertain(error.localizedDescription)
                    }
                } else { result = .notWritten }
                self.writerLock.unlock()
                continuation.resume(returning: result)
            }
        }
    }

    private enum WriterError: Error { case notWritable }
}
