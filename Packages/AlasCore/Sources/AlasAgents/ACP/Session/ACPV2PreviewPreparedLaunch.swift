import Foundation
import AlasACP
import AlasModel

public struct ACPV2PreviewPreparedLaunch: Sendable {
    public let spec: ACPLaunchSpec
    public let environment: [String: String]
    public let helperURL: URL
    public let identity: ACPV2PreviewLaunchIdentity
    public init(spec: ACPLaunchSpec, environment: [String: String], helperURL: URL, identity: ACPV2PreviewLaunchIdentity) {
        self.spec = spec
        self.environment = environment
        self.helperURL = helperURL
        self.identity = identity
    }
}

public enum ACPV2PreviewManagerError: Error, LocalizedError {
    case unavailable, viewOnly, changedLaunch, invalidated, cleanupUnavailable
    public var errorDescription: String? {
        switch self {
        case .unavailable: "No qualified adapter is available for a fresh local preview. Check the Debug experiment and launch configuration."
        case .viewOnly: "This session is view-only. Create a new session to send messages."
        case .changedLaunch: "The adapter, helper or provider configuration changed during preview startup."
        case .invalidated: "Preview startup lost its current owner."
        case .cleanupUnavailable: "The remaining preview process could not be confirmed as this session's unchanged source."
        }
    }
}
