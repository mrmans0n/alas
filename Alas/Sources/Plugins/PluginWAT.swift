#if DEBUG
import WAT

/// Compiles WebAssembly text for test fixtures. Debug-only so Release code
/// never depends on the text format.
enum PluginWAT {
    static func compile(_ text: String) throws -> [UInt8] {
        try wat2wasm(text)
    }
}
#endif
