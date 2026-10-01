import Foundation
@testable import Alas

enum PluginFixtureStep: Sendable {
    case send(String)
    case sendRepeated(String, times: Int)
    /// Raw JavaScript statements.
    case script(String)
    /// Presents `length` zero bytes.
    case present(tab: Int, length: Int, width: Int)
    case `throw`
    case spin
}

/// Builds a plugin whose Nth `handle` call runs `script[N]`. Calls past the end of the script do nothing.
enum PluginJSFixture {
    static func source(_ script: [[PluginFixtureStep]]) -> Data {
        let calls = script.enumerated().map { index, steps in
            "if (n === \(index)) { \(steps.map(statement).joined(separator: " ")) }"
        }
        return Data("""
        let n = -1;
        globalThis.handle = () => {
          n += 1;
          \(calls.joined(separator: "\n  "))
        };
        """.utf8)
    }

    private static func statement(_ step: PluginFixtureStep) -> String {
        switch step {
        case .send(let text): "alas.send(\(literal(text)));"
        case let .sendRepeated(text, times): "for (let i = 0; i < \(times); i++) alas.send(\(literal(text)));"
        case .script(let statements): statements
        case let .present(tab, length, width): "alas.present(\(tab), new Uint8Array(\(length)), \(width));"
        case .throw: #"throw new Error("boom");"#
        case .spin: "for (;;) {}"
        }
    }

    private static func literal(_ text: String) -> String {
        // A JSON string is a valid JavaScript string literal.
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }
}
