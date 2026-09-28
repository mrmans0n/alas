import Foundation
@testable import Alas

enum PluginFixtureStep: Sendable {
    case send(String)
    case sendRepeated(String, times: Int)
    case sendRange(ptr: Int, len: Int)
    case trap
    case spin
}

/// Builds a plugin whose Nth `alas_handle` call runs `script[N]`. Calls past the
/// end of the script do nothing. Message text is stored in data segments from
/// offset 1024; `alas_alloc` bumps from 32768 unless `allocReturns` pins it.
enum PluginWATFixture {
    static func wasm(
        _ script: [[PluginFixtureStep]],
        extraImports: String = "",
        allocReturns: Int? = nil
    ) throws -> [UInt8] {
        var data = ""
        var offset = 1024
        var calls = ""
        for (index, steps) in script.enumerated() {
            var body = ""
            for step in steps {
                switch step {
                case .send(let text), .sendRepeated(let text, _):
                    let length = text.utf8.count
                    data += "(data (i32.const \(offset)) \"\(escape(text))\")\n"
                    let call = "(call $send (i32.const \(offset)) (i32.const \(length)))"
                    if case .sendRepeated(_, let times) = step {
                        body += String(repeating: call, count: times)
                    } else {
                        body += call
                    }
                    offset += length
                case .sendRange(let ptr, let len):
                    body += "(call $send (i32.const \(ptr)) (i32.const \(len)))"
                case .trap:
                    body += "unreachable"
                case .spin:
                    body += "(loop $forever (br $forever))"
                }
            }
            calls += "(if (i32.eq (global.get $calls) (i32.const \(index))) (then \(body)))\n"
        }
        let alloc = allocReturns.map { "(i32.const \($0))" } ?? """
            (local.set $p (global.get $heap))
            (global.set $heap (i32.add (global.get $heap) (local.get $n)))
            (local.get $p)
            """
        return try PluginWAT.compile("""
        (module
          (import "alas" "send" (func $send (param i32 i32)))
          \(extraImports)
          (memory (export "memory") 1)
          (global $heap (mut i32) (i32.const 32768))
          (global $calls (mut i32) (i32.const 0))
          \(data)
          (func (export "alas_alloc") (param $n i32) (result i32)
            (local $p i32)
            \(alloc))
          (func (export "alas_handle") (param $ptr i32) (param $len i32)
            \(calls)
            (global.set $calls (i32.add (global.get $calls) (i32.const 1))))
        )
        """)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
