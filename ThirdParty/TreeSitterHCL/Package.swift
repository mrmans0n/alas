// swift-tools-version:5.9
// Vendored from https://github.com/tree-sitter-grammars/tree-sitter-hcl @ v1.2.0.
// Upstream's Package.swift does not include query resources, so Alas keeps
// a local manifest and highlight query with the generated parser sources.

import PackageDescription

let package = Package(
    name: "TreeSitterHCL",
    products: [
        .library(name: "TreeSitterHCL", targets: ["TreeSitterHCL"])
    ],
    targets: [
        .target(
            name: "TreeSitterHCL",
            path: ".",
            exclude: ["LICENSE"],
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
