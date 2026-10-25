import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum ACPProtocolVersion: Int, Codable, Sendable {
    case v1 = 1
    case v2 = 2

    public static let current: Int = v1.rawValue
}

/// Captured once when a connection is created, never read live from settings.
public struct ACPProtocolSelection: Equatable, Sendable {
    public let experimentalV2Enabled: Bool

    public init(experimentalV2Enabled: Bool = false) {
        self.experimentalV2Enabled = experimentalV2Enabled
    }

    // No adapter is eligible for live v2 sessions until the lifecycle and
    // transcript handlers are implemented. Bootstrap decoding is not eligibility.
    public var supportedVersions: Set<ACPProtocolVersion> { [.v1] }
    public var requestedVersion: ACPProtocolVersion { .v1 }
}
