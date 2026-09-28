import Foundation
@_spi(Fuzzing) import WasmKit

struct PluginLimits: Sendable, Equatable {
    /// WasmKit cannot interrupt a running call from another thread, so fuel is
    /// the only stop for a runaway plugin. About 50 ms optimized; unoptimized
    /// (Debug) WasmKit burns fuel roughly 400x slower.
    var fuelPerCall: UInt64 = 25_000_000
    var maxMemoryBytes = 64 << 20
    var maxMessageBytes = 1 << 20
    var maxSendsPerCall = 64
}

enum PluginRuntimeError: Error, Equatable, CustomStringConvertible {
    case instantiation(String)
    case missingExport(String)
    case badGuestRange(ptr: UInt32, len: UInt32)
    case messageTooLarge(Int)
    case tooManySends(Int)
    case trap(String)

    var description: String {
        switch self {
        case .instantiation(let reason): "could not load plugin: \(reason)"
        case .missingExport(let name): "plugin does not export \(name)"
        case let .badGuestRange(ptr, len): "plugin passed an invalid memory range (ptr \(ptr), len \(len))"
        case .messageTooLarge(let size): "message of \(size) bytes exceeds the size limit"
        case .tooManySends(let limit): "plugin sent more than \(limit) messages in one call"
        case .trap(let reason): reason
        }
    }
}

private final class MemoryCap: ResourceLimiter {
    let maxBytes: Int
    init(maxBytes: Int) { self.maxBytes = maxBytes }
    func limitMemoryGrowth(to desired: Int) throws -> Bool { desired <= maxBytes }
}

/// One plugin instance. Every WasmKit call runs on `queue`, which is what makes
/// the `@unchecked Sendable` hold. This type moves bytes only; it knows nothing
/// about JSON-RPC or Alas.
final class PluginRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.nlopez.alas.plugin-runtime")
    private let limits: PluginLimits
    private let store: Store
    private var instance: Instance!
    private var outbox: [Data] = []
    private var sendFailure: PluginRuntimeError?

    private init(limits: PluginLimits) {
        self.limits = limits
        store = Store(engine: Engine(configuration: EngineConfiguration(fuelMetering: true)))
        store.resourceLimiter = MemoryCap(maxBytes: limits.maxMemoryBytes)
    }

    static func load(wasm: [UInt8], limits: PluginLimits) async throws -> PluginRuntime {
        let runtime = PluginRuntime(limits: limits)
        try await runtime.run { try runtime.instantiate(wasm) }
        return runtime
    }

    /// Delivers one message through `alas_handle`. Returns what the plugin sent
    /// with `alas.send` during the call, in order. The caller processes them
    /// after this returns, so the plugin is never re-entered.
    func handle(_ message: Data) async throws -> [Data] {
        try await run { try self.deliver(message) }
    }

    private func instantiate(_ wasm: [UInt8]) throws {
        let module: Module
        do {
            module = try parseWasm(bytes: wasm)
        } catch {
            throw PluginRuntimeError.instantiation(String(describing: error))
        }
        var imports = Imports()
        imports.define(module: "alas", name: "send", Function(store: store, parameters: [.i32, .i32]) { [unowned self] caller, args in
            try self.receive(caller, ptr: args[0].i32, len: args[1].i32)
            return []
        })
        store.fuel = Fuel(remaining: limits.fuelPerCall)
        do {
            instance = try module.instantiate(store: store, imports: imports)
        } catch {
            throw PluginRuntimeError.instantiation(Self.firstLine(error))
        }
        if instance.exports[memory: "memory"] == nil { throw PluginRuntimeError.missingExport("memory") }
        for name in ["alas_alloc", "alas_handle"] where instance.exports[function: name] == nil {
            throw PluginRuntimeError.missingExport(name)
        }
    }

    private func deliver(_ message: Data) throws -> [Data] {
        guard message.count <= limits.maxMessageBytes else {
            throw PluginRuntimeError.messageTooLarge(message.count)
        }
        outbox = []
        sendFailure = nil
        // Refill before alloc: a previous out-of-fuel trap leaves the budget empty.
        store.fuel = Fuel(remaining: limits.fuelPerCall)
        do {
            let ptr = try instance.exports[function: "alas_alloc"]!([.i32(UInt32(message.count))])[0].i32
            let memory = instance.exports[memory: "memory"]!
            // WasmKit preconditions on out-of-bounds host access, so every guest range is checked here.
            guard Int(ptr) + message.count <= memory.byteCount else {
                throw PluginRuntimeError.badGuestRange(ptr: ptr, len: UInt32(message.count))
            }
            memory.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: message.count) { buffer in
                _ = message.copyBytes(to: buffer)
            }
            _ = try instance.exports[function: "alas_handle"]!([.i32(ptr), .i32(UInt32(message.count))])
        } catch {
            throw sendFailure ?? (error as? PluginRuntimeError) ?? .trap(Self.firstLine(error))
        }
        return outbox
    }

    private func receive(_ caller: borrowing Caller, ptr: UInt32, len: UInt32) throws {
        guard outbox.count < limits.maxSendsPerCall else {
            throw record(.tooManySends(limits.maxSendsPerCall))
        }
        guard Int(len) <= limits.maxMessageBytes else {
            throw record(.messageTooLarge(Int(len)))
        }
        guard let memory = caller.instance?.exports[memory: "memory"],
              Int(ptr) + Int(len) <= memory.byteCount
        else { throw record(.badGuestRange(ptr: ptr, len: len)) }
        outbox.append(memory.withUnsafeBufferPointer(offset: UInt(ptr), count: Int(len)) { Data($0) })
    }

    /// Remembers why a host call failed, in case WasmKit wraps the thrown error.
    private func record(_ error: PluginRuntimeError) -> PluginRuntimeError {
        sendFailure = error
        return error
    }

    private static func firstLine(_ error: Error) -> String {
        String(describing: error).split(separator: "\n").first.map(String.init) ?? "trap"
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
}
