import Foundation

enum ACPSetupCheck: Equatable {
    case binaryOnPath(name: String)
    case npxPackage(name: String)            // looks for global npm package
    case binaryOnPathOrNpmPackage(binary: String, npmPackage: String)
}

enum ACPSetupResult: Equatable {
    case ready
    case missing(reason: String)
    case error(message: String)
}
