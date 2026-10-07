import Foundation
import Testing
@testable import Alas

@Suite("SymbolExtractor")
struct SymbolExtractorTests {
    struct Expected: Sendable, CustomTestStringConvertible {
        let path: String
        let source: String
        /// (name, kind, container, first line, last line), 0-based lines.
        let symbols: [(String, SymbolKind, String?, Int, Int)]
        var testDescription: String { path }
    }

    static let cases: [Expected] = [
        Expected(path: "Sources/Session.swift", source: """
        // 🚀 émoji before declarations shifts UTF-16 offsets
        struct Session {
            let id: String
            func restore() {
                print(id)
            }
        }
        extension Session {
            func close() {}
        }
        protocol Restorable { func restore() }
        """, symbols: [
            ("Session", .struct, nil, 1, 6),
            ("id", .property, "Session", 2, 2),
            ("restore", .method, "Session", 3, 5),
            ("close", .method, "Session", 8, 8),
            ("Restorable", .interface, nil, 10, 10),
            ("restore", .method, "Restorable", 10, 10),
        ]),
        Expected(path: "src/app.ts", source: """
        export interface Store { load(): void }
        export class TabStore {
          restore(from: string) {
            return from
          }
        }
        export function generatePrompt() {}
        """, symbols: [
            ("Store", .interface, nil, 0, 0),
            ("load", .method, "Store", 0, 0),
            ("TabStore", .class, nil, 1, 5),
            ("restore", .method, "TabStore", 2, 4),
            ("generatePrompt", .function, nil, 6, 6),
        ]),
        Expected(path: "src/app.js", source: """
        class Greeter {
          greet() { return 1 }
        }
        function main() {}
        """, symbols: [
            ("Greeter", .class, nil, 0, 2),
            ("greet", .method, "Greeter", 1, 1),
            ("main", .function, nil, 3, 3),
        ]),
        Expected(path: "pkg/tool.py", source: """
        class Converter:
            def storage_to_text(self, value):
                return value

            @staticmethod
            def build():
                pass

        def main():
            pass
        """, symbols: [
            ("Converter", .class, nil, 0, 6),
            ("storage_to_text", .method, "Converter", 1, 2),
            ("build", .method, "Converter", 4, 6),
            ("main", .function, nil, 8, 9),
        ]),
        Expected(path: "server.go", source: """
        package main

        type Server struct{}

        func (s *Server) Start() {}

        func (c Client) Start() {}

        func main() {}
        """, symbols: [
            ("Server", .type, nil, 2, 2),
            ("Start", .method, "Server", 4, 4),
            ("Start", .method, "Client", 6, 6),
            ("main", .function, nil, 8, 8),
        ]),
        Expected(path: "src/lib.rs", source: """
        pub struct Index;
        impl Index {
            pub fn refresh(&self) {}
        }
        pub fn build() {}
        """, symbols: [
            ("Index", .class, nil, 0, 0),
            ("refresh", .method, "Index", 2, 2),
            ("build", .function, nil, 4, 4),
        ]),
        Expected(path: "src/Main.java", source: """
        public class Main {
            void run() {}
        }
        interface Runner { void run(); }
        """, symbols: [
            ("Main", .class, nil, 0, 2),
            ("run", .method, "Main", 1, 1),
            ("Runner", .interface, nil, 3, 3),
            ("run", .method, "Runner", 3, 3),
        ]),
        Expected(path: "rules/Check.kt", source: """
        class ModifierReusedCheck {
            val id = "x"
            fun visit() {
                val local = 1
            }
        }
        """, symbols: [
            ("ModifierReusedCheck", .class, nil, 0, 5),
            ("id", .property, "ModifierReusedCheck", 1, 1),
            ("visit", .method, "ModifierReusedCheck", 2, 4),
        ]),
        Expected(path: "Sources/Locals.swift", source: """
        struct Cache {
            var count: Int {
                let doubled = 2
                return doubled
            }
            var value = 0 {
                didSet { let old = value }
            }
            init() {
                let seed = 1
            }
            func load() {
                let temporary = 1
                func helper() {}
                let handler = { (input: Int) -> Int in
                    let inner = input
                    return inner
                }
            }
        }
        func run() {
            let temporary = 1
            struct Local {}
        }
        let shared = 1
        """, symbols: [
            ("Cache", .struct, nil, 0, 19),
            ("count", .property, "Cache", 1, 4),
            ("value", .property, "Cache", 5, 7),
            ("init", .method, "Cache", 8, 10),
            ("load", .method, "Cache", 11, 18),
            ("run", .function, nil, 20, 23),
            ("shared", .property, nil, 24, 24),
        ]),
        Expected(path: "src/locals.ts", source: """
        export class Loader {
          static {
            function boot() {}
          }
          load() {
            function parse() {}
            class Row {}
            const format = () => 1
          }
        }
        export const handler = () => {
          function inner() {}
        }
        export namespace Tools {
          export function util() {}
        }
        """, symbols: [
            ("Loader", .class, nil, 0, 9),
            ("load", .method, "Loader", 4, 8),
            ("handler", .function, nil, 10, 12),
            ("util", .method, "Tools", 14, 14),
        ]),
        Expected(path: "src/locals.js", source: """
        function main() {
          function helper() {}
          class Local {
            go() {}
          }
        }
        """, symbols: [
            ("main", .function, nil, 0, 5),
        ]),
        Expected(path: "pkg/locals.py", source: """
        class Service:
            def handle(self):
                def local_helper():
                    pass
                class LocalModel:
                    pass
                return local_helper

        def main():
            def nested():
                pass
        """, symbols: [
            ("Service", .class, nil, 0, 6),
            ("handle", .method, "Service", 1, 6),
            ("main", .function, nil, 8, 10),
        ]),
        Expected(path: "locals.go", source: """
        package main

        func (s *Server) Start() {
        \ttype request struct{}
        \thandler := func() {}
        \t_ = handler
        }
        """, symbols: [
            ("Start", .method, "Server", 2, 6),
        ]),
        Expected(path: "src/locals.rs", source: """
        impl Index {
            pub fn refresh(&self) {
                fn helper() {}
                struct Scratch;
                let run = || {
                    fn inner() {}
                };
            }
        }
        """, symbols: [
            ("refresh", .method, "Index", 1, 7),
        ]),
        Expected(path: "src/Worker.java", source: """
        class Worker {
            Worker() {
                class Temp {}
            }
            void run() {
                Runnable task = new Runnable() {
                    public void run() {}
                };
                class LocalTask {}
            }
        }
        """, symbols: [
            ("Worker", .class, nil, 0, 10),
            ("run", .method, "Worker", 4, 9),
        ]),
        Expected(path: "rules/Repository.kt", source: """
        class Repository {
            val size: Int
                get() {
                    fun compute() = 1
                    return compute()
                }
            init {
                fun setup() {}
            }
            fun load() {
                fun parse() {}
                class Row
                val callback = { fun inner() {} }
            }
        }
        fun main() {
            fun helper() {}
        }
        """, symbols: [
            ("Repository", .class, nil, 0, 14),
            ("size", .property, "Repository", 1, 5),
            ("load", .method, "Repository", 9, 13),
            ("main", .function, nil, 15, 17),
        ]),
    ]

    @Test("extracts exactly the non-local declarations with kind, container, and line range", arguments: cases)
    func extracts(_ expected: Expected) {
        let symbols = SymbolExtractor.symbols(in: expected.source, relativePath: expected.path)
        let actual = symbols.map { "\($0.name)|\($0.kind)|\($0.container ?? "-")|\($0.lineRange.lowerBound)-\($0.lineRange.upperBound)" }
        let lines = expected.symbols.map { name, kind, container, start, end in
            "\(name)|\(kind)|\(container ?? "-")|\(start)-\(end)"
        }
        #expect(actual == lines)
        for symbol in symbols {
            #expect((expected.source as NSString).substring(with: symbol.nameRange) == symbol.name)
            #expect(symbol.relativePath == expected.path)
        }
    }

    @Test("unknown languages and unparsable input yield no symbols")
    func unsupported() {
        #expect(SymbolExtractor.symbols(in: "{ \"a\": 1 }", relativePath: "a.json").isEmpty)
        #expect(SymbolExtractor.symbols(in: "", relativePath: "a.swift").isEmpty)
    }
}
