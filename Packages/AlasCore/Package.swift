// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlasCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AlasCore", targets: ["AlasCore"]),
    ],
    targets: [
        .target(name: "AlasCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "AlasCoreTests", dependencies: ["AlasCore"]),
    ]
)
