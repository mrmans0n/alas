// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ACP2Qualification",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "acp2-qualify", targets: ["ACP2Qualification"])],
    dependencies: [.package(path: "../../Packages/AlasCore")],
    targets: [
        .executableTarget(name: "ACP2Qualification", dependencies: [.product(name: "AlasCore", package: "AlasCore")]),
        .testTarget(name: "ACP2QualificationTests", dependencies: ["ACP2Qualification"]),
    ]
)
