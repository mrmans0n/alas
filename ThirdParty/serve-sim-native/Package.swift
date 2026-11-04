// swift-tools-version:6.0
//
// serve-sim's simulator capture and input code (Apache-2.0), vendored from
// expo/expo-device-hub by sync.sh. README.md says what is here and why.
// Swift 5 mode, as upstream builds it.

import PackageDescription

let package = Package(
    name: "serve-sim-native",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ServeSimCore", targets: ["ServeSimCore"]),
    ],
    targets: [
        .target(name: "StreamingPolicy"),
        .target(
            name: "CoreDeviceShim",
            linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("IOKit")]
        ),
        .target(name: "ServeSimCore", dependencies: ["StreamingPolicy", "CoreDeviceShim"]),
    ],
    swiftLanguageModes: [.v5]
)
