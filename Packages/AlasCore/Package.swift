// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlasCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AlasCore", targets: ["AlasCore"]),
        .executable(name: "alas-host", targets: ["alas-host"]),
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
        .executableTarget(name: "alas-host", dependencies: ["AlasCore"]),
        // Depends on alas-host so `swift test` builds the binary its end-to-end tests launch.
        .testTarget(name: "AlasCoreTests", dependencies: ["AlasCore", "alas-host"], exclude: ["Fixtures"]),
    ]
)
