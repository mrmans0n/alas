// swift-tools-version:5.9
// Vendored from https://github.com/tree-sitter/tree-sitter-javascript @ v0.25.0.
// Upstream's Package.swift conditionally adds src/scanner.c via a
// relative-path FileManager check that returns false during SPM resolution,
// dropping the external scanner at link time. Our manifest lists both
// sources unconditionally.
//
// The grammar parses JSX out of the box, so this same target serves both
// `.js`/`.mjs`/`.cjs` and `.jsx`. `queries/highlights-jsx.scm` is bundled
// alongside `highlights.scm` for callers that want the JSX-specific overlay.

import PackageDescription

let package = Package(
    name: "TreeSitterJavaScript",
    products: [
        .library(name: "TreeSitterJavaScript", targets: ["TreeSitterJavaScript"])
    ],
    targets: [
        .target(
            name: "TreeSitterJavaScript",
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
