import Foundation
import AlasFoundation

public enum ACPSetupCheck: Equatable, Sendable {
    case binaryOnPath(name: String)
    case npxPackage(name: String)            // looks for global npm package
    case binaryOnPathOrNpmPackage(binary: String, npmPackage: String)
}

public enum ACPSetupResult: Equatable, Sendable {
    case ready
    case missing(reason: String)
    case error(message: String)
}
