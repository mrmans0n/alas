#if DEBUG
import Foundation
@_spi(Fuzzing) import WasmKit
import WAT

// Throwaway prototype for #1560 phase 1: load a Wasm plugin, render its panel
// natively, forward clicks, and contain runaway or misbehaving plugins.
// Not a commitment to any plugin API.

/// Panel description a plugin emits as JSON. Alas renders it with native controls.
struct PluginPanel: Decodable, Equatable, Sendable {
    struct Button: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let label: String
    }

    let title: String
    let text: String
    let buttons: [Button]
}

enum PluginPrototypeError: Error, CustomStringConvertible {
    case badGuestRange(ptr: UInt32, len: UInt32)
    case noPanel
    case invalidPanel(String)

    var description: String {
        switch self {
        case let .badGuestRange(ptr, len): "Plugin passed an invalid memory range (ptr \(ptr), len \(len))"
        case .noPanel: "Plugin returned without emitting a panel"
        case let .invalidPanel(detail): "Plugin emitted an invalid panel: \(detail)"
        }
    }
}

private final class MemoryCap: ResourceLimiter {
    let maxBytes: Int
    init(maxBytes: Int) { self.maxBytes = maxBytes }
    func limitMemoryGrowth(to desired: Int) throws -> Bool { desired <= maxBytes }
}

/// Owns one plugin instance. Every WasmKit call runs on `queue`, which is what
/// makes the `@unchecked Sendable` hold; the main thread only awaits results.
final class PluginPrototypeRuntime: @unchecked Sendable {
    /// Per-call execution budget. WasmKit cannot interrupt a running call from
    /// another thread, so fuel is the only stop for a runaway plugin.
    /// Unoptimized WasmKit burns fuel ~400x slower, so this is ~1s in a Debug
    /// build and ~10ms optimized.
    /// ponytail: fixed budget, derive it from a wall-clock calibration if budgets become user-facing.
    static let fuelPerCall: UInt64 = 10_000_000
    static let maxMemoryBytes = 16 * 65536
    static let maxMessageBytes = 64 * 1024

    private let queue = DispatchQueue(label: "io.nlopez.alas.plugin-prototype")
    private let engine = Engine(configuration: EngineConfiguration(fuelMetering: true))
    private let module: Module
    private var store: Store?
    private var instance: Instance?
    private var emitted: [UInt8]?

    init(wasm: [UInt8]) throws {
        module = try parseWasm(bytes: wasm)
    }

    /// Fresh store and instance, discarding all plugin state.
    func reload() async throws -> PluginPanel {
        try await run {
            let store = Store(engine: self.engine)
            store.resourceLimiter = MemoryCap(maxBytes: Self.maxMemoryBytes)
            var imports = Imports()
            imports.define(module: "host", name: "emit", Function(store: store, parameters: [.i32, .i32]) { caller, args in
                self.emitted = try Self.read(caller, ptr: args[0].i32, len: args[1].i32)
                return []
            })
            self.store = store
            self.instance = try self.module.instantiate(store: store, imports: imports)
            return try self.call("render")
        }
    }

    func send(event id: String) async throws -> PluginPanel {
        try await run {
            guard let instance = self.instance, let store = self.store else { throw PluginPrototypeError.noPanel }
            // A previous out-of-fuel trap leaves the budget empty; refill before calling alloc.
            store.fuel = Fuel(remaining: Self.fuelPerCall)
            let bytes = Array(id.utf8)
            let ptr = try instance.exports[function: "alloc"]!([.i32(UInt32(bytes.count))])[0].i32
            let memory = instance.exports[memory: "memory"]!
            guard Int(ptr) + bytes.count <= memory.byteCount else {
                throw PluginPrototypeError.badGuestRange(ptr: ptr, len: UInt32(bytes.count))
            }
            memory.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: bytes.count) { $0.copyBytes(from: bytes) }
            return try self.call("on_event", [.i32(ptr), .i32(UInt32(bytes.count))])
        }
    }

    var memoryBytes: Int {
        get async { await withCheckedContinuation { cont in queue.async { cont.resume(returning: self.instance?.exports[memory: "memory"]?.byteCount ?? 0) } } }
    }

    private func call(_ export: String, _ args: [Value] = []) throws -> PluginPanel {
        guard let store, let function = instance?.exports[function: export] else { throw PluginPrototypeError.noPanel }
        emitted = nil
        store.fuel = Fuel(remaining: Self.fuelPerCall)
        _ = try function(args)
        guard let emitted else { throw PluginPrototypeError.noPanel }
        do {
            return try JSONDecoder().decode(PluginPanel.self, from: Data(emitted))
        } catch {
            throw PluginPrototypeError.invalidPanel(String(decoding: emitted.prefix(80), as: UTF8.self))
        }
    }

    /// WasmKit preconditions on out-of-bounds host access, so guest ranges must be validated here.
    private static func read(_ caller: borrowing Caller, ptr: UInt32, len: UInt32) throws -> [UInt8] {
        guard let memory = caller.instance?.exports[memory: "memory"],
              len <= maxMessageBytes, Int(ptr) + Int(len) <= memory.byteCount
        else { throw PluginPrototypeError.badGuestRange(ptr: ptr, len: len) }
        return memory.withUnsafeBufferPointer(offset: UInt(ptr), count: Int(len)) { Array($0) }
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result(catching: body)) }
        }
    }
}

/// Sample plugin: a click counter plus buttons that misbehave on purpose.
enum PluginPrototypeSample {
    static func wasm() throws -> [UInt8] { try wat2wasm(wat) }

    private static let prefix = #"{"title":"Counter plugin","text":"Clicked "#
    private static let suffix = #" times","buttons":[{"id":"click","label":"Click"},{"id":"spin","label":"Spin forever"},{"id":"hog","label":"Hog memory"},{"id":"trap","label":"Trap"},{"id":"garbage","label":"Emit invalid JSON"},{"id":"wild","label":"Wild pointer"}]}"#
    private static let garbage = "{not json"

    private static func watString(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "\\\"") }

    // Layout: prefix at 0, suffix at 256, garbage at 1024, digit scratch below 1930,
    // output buffer at 2048, bump heap from 8192.
    private static let wat = """
    (module
      (import "host" "emit" (func $emit (param i32 i32)))
      (memory (export "memory") 1)
      (global $heap (mut i32) (i32.const 8192))
      (global $clicks (mut i32) (i32.const 0))
      (data (i32.const 0) "\(watString(prefix))")
      (data (i32.const 256) "\(watString(suffix))")
      (data (i32.const 1024) "\(watString(garbage))")

      (func (export "alloc") (param $n i32) (result i32)
        (local $p i32)
        (local.set $p (global.get $heap))
        (global.set $heap (i32.add (global.get $heap) (local.get $n)))
        (local.get $p))

      ;; Writes the decimal digits of $n at $dst and returns their count.
      (func $itoa (param $n i32) (param $dst i32) (result i32)
        (local $start i32)
        (local.set $start (i32.const 1930))
        (loop $digit
          (local.set $start (i32.sub (local.get $start) (i32.const 1)))
          (i32.store8 (local.get $start) (i32.add (i32.const 48) (i32.rem_u (local.get $n) (i32.const 10))))
          (local.set $n (i32.div_u (local.get $n) (i32.const 10)))
          (br_if $digit (local.get $n)))
        (memory.copy (local.get $dst) (local.get $start) (i32.sub (i32.const 1930) (local.get $start)))
        (i32.sub (i32.const 1930) (local.get $start)))

      (func $render (export "render")
        (local $at i32)
        (memory.copy (i32.const 2048) (i32.const 0) (i32.const \(prefix.utf8.count)))
        (local.set $at (i32.add (i32.const 2048) (i32.const \(prefix.utf8.count))))
        (local.set $at (i32.add (local.get $at) (call $itoa (global.get $clicks) (local.get $at))))
        (memory.copy (local.get $at) (i32.const 256) (i32.const \(suffix.utf8.count)))
        (local.set $at (i32.add (local.get $at) (i32.const \(suffix.utf8.count))))
        (call $emit (i32.const 2048) (i32.sub (local.get $at) (i32.const 2048))))

      ;; Dispatches on the event id's first byte: c(lick) s(pin) h(og) t(rap) g(arbage) w(ild).
      (func (export "on_event") (param $ptr i32) (param $len i32)
        (local $c i32)
        (local.set $c (i32.load8_u (local.get $ptr)))
        (if (i32.eq (local.get $c) (i32.const 99))
          (then (global.set $clicks (i32.add (global.get $clicks) (i32.const 1)))))
        (if (i32.eq (local.get $c) (i32.const 115))
          (then (loop $forever (br $forever))))
        (if (i32.eq (local.get $c) (i32.const 104))
          (then (block $full (loop $grow
            (br_if $full (i32.eq (memory.grow (i32.const 1)) (i32.const -1)))
            (br $grow)))))
        (if (i32.eq (local.get $c) (i32.const 116))
          (then unreachable))
        (if (i32.eq (local.get $c) (i32.const 103))
          (then (call $emit (i32.const 1024) (i32.const \(garbage.utf8.count))) (return)))
        (if (i32.eq (local.get $c) (i32.const 119))
          (then (call $emit (i32.const -65536) (i32.const 16)) (return)))
        (call $render))
    )
    """
}
#endif
