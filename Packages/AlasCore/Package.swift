// swift-tools-version: 6.0
import PackageDescription

/// The modules below the agent ones, which each agent module depends on.
let base: [Target.Dependency] = [
    "AlasFoundation", "AlasModel", "AlasPlatform", "AlasFeatures", "AlasIntegrations", "AlasCode",
]

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
        // The modules AlasCore is split into, bottom to top; see
        // docs/plans/2026-10-20-alascore-modules.md. AlasCore re-exports them.
        .target(
            name: "AlasFoundation",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "AlasModel", dependencies: ["AlasFoundation"]),
        .target(name: "AlasPlatform", dependencies: ["AlasFoundation", "AlasModel"]),
        .target(name: "AlasFeatures", dependencies: ["AlasFoundation", "AlasModel", "AlasPlatform"]),
        .target(
            name: "AlasIntegrations",
            dependencies: ["AlasFoundation", "AlasModel", "AlasPlatform", "AlasFeatures"]
        ),
        .target(
            name: "AlasCode",
            dependencies: [
                "AlasFoundation", "AlasModel", "AlasPlatform", "AlasFeatures", "AlasIntegrations",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
            ]
        ),
        .target(name: "AlasACP", dependencies: base),
        .target(name: "AlasSessions", dependencies: base + ["AlasACP"]),
        .target(name: "AlasAgentKit", dependencies: base + ["AlasACP", "AlasSessions"]),
        .target(name: "AlasAgents", dependencies: base + ["AlasACP", "AlasSessions", "AlasAgentKit"]),
        .target(name: "AlasHostCore", dependencies: base + ["AlasACP", "AlasSessions", "AlasAgentKit", "AlasAgents"]),
        // The umbrella: re-exports every module, so the app imports one.
        .target(
            name: "AlasCore",
            dependencies: base + ["AlasACP", "AlasSessions", "AlasAgentKit", "AlasAgents", "AlasHostCore"]
        ),
        .executableTarget(name: "alas-host", dependencies: ["AlasCore"]),
        // Sets a scratch profile before the tests start; see profile.c.
        .target(name: "AlasCoreTestProfile", path: "Tests/AlasCoreTestProfile"),
        // Depends on alas-host so `swift test` builds the binary its end-to-end tests launch.
        .testTarget(
            name: "AlasCoreTests",
            dependencies: ["AlasCore", "alas-host", "AlasCoreTestProfile"],
            exclude: ["Fixtures"]
        ),
    ]
)
