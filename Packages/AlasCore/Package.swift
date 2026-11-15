// swift-tools-version: 6.0
import PackageDescription

let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto")
/// Apple's SDKs ship an `SQLite3` module; Linux gets the system library through `CSQLite`.
let sqlite: Target.Dependency = .target(name: "CSQLite", condition: .when(platforms: [.linux]))

/// The modules below the agent ones, which each agent module depends on.
let base: [Target.Dependency] = [
    crypto, sqlite, "AlasFoundation", "AlasModel", "AlasPlatform", "AlasFeatures", "AlasIntegrations", "AlasCode",
]

let package = Package(
    name: "AlasCore",
    platforms: [.macOS(.v15), .iOS("26.0")],
    products: [
        .library(name: "AlasCore", targets: ["AlasCore"]),
        .library(name: "AlasRemoteKit", targets: ["AlasRemoteKit"]),
        .executable(name: "alas-host", targets: ["alas-host"]),
    ],
    dependencies: [
        // Keep in step with the app's pin in project.yml.
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        // CryptoKit on Apple platforms (it re-exports it), BoringSSL on Linux.
        // Keep in step with the app's resolved pin.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        // The modules AlasCore is split into, bottom to top; see
        // docs/plans/2026-10-20-alascore-modules.md. AlasCore re-exports them.
        // Foundation, CryptoKit and Observation only: the remote wire types
        // the iOS app shares with the Mac. Must build for iOS.
        .target(name: "AlasRemoteKit", dependencies: [crypto]),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "AlasFoundation",
            dependencies: ["AlasRemoteKit", crypto, sqlite],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "AlasModel", dependencies: [crypto, "AlasFoundation"]),
        .target(name: "AlasPlatform", dependencies: [crypto, "AlasFoundation", "AlasModel"]),
        .target(name: "AlasFeatures", dependencies: [crypto, sqlite, "AlasFoundation", "AlasModel", "AlasPlatform"]),
        .target(
            name: "AlasIntegrations",
            dependencies: [crypto, "AlasFoundation", "AlasModel", "AlasPlatform", "AlasFeatures"]
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
