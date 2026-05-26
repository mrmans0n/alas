// swift-tools-version:5.9
// Vendored from https://github.com/tree-sitter/tree-sitter-python @ v0.25.0.
// Upstream's Package.swift conditionally adds src/scanner.c via a
// relative-path FileManager check that returns false during SPM resolution,
// dropping the external scanner at link time. Our manifest lists both
// sources unconditionally.

import PackageDescription

let package = Package(
    name: "TreeSitterPython",
    products: [
        .library(name: "TreeSitterPython", targets: ["TreeSitterPython"])
    ],
    targets: [
        .target(
            name: "TreeSitterPython",
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
