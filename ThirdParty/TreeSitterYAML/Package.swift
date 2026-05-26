// swift-tools-version:5.9
// Vendored from https://github.com/tree-sitter-grammars/tree-sitter-yaml @ v0.7.2.
// The upstream Package.swift conditionally adds `src/scanner.c` based on a
// relative-path `FileManager` check that fails under SPM resolution, so we
// ship our own manifest that lists both sources unconditionally and only
// compiles the C the parser actually needs (`schema.core.c` is pulled in by
// scanner.c via `#include`, not built standalone).

import PackageDescription

let package = Package(
    name: "TreeSitterYAML",
    products: [
        .library(name: "TreeSitterYAML", targets: ["TreeSitterYAML"])
    ],
    targets: [
        .target(
            name: "TreeSitterYAML",
            path: ".",
            exclude: [
                "src/schema.core.c",
                "src/schema.json.c",
                "src/schema.legacy.c",
                "LICENSE"
            ],
            sources: [
                "src/parser.c",
                "src/scanner.c"
            ],
            resources: [
                .copy("queries")
            ],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        )
    ],
    cLanguageStandard: .c11
)
