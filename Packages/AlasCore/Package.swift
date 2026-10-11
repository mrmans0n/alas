// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlasCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AlasCore", targets: ["AlasCore"]),
    ],
    dependencies: [
        // Keep in step with the app's pin in project.yml.
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
    ],
    targets: [
        .target(
            name: "AlasCore",
            dependencies: [.product(name: "SwiftTreeSitter", package: "swift-tree-sitter")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "AlasCoreTests", dependencies: ["AlasCore"]),
    ]
)
