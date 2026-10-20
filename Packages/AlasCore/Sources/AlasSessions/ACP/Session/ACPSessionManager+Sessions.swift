import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasIntegrations
import AlasACP

private extension ACPSetupResult {
    package var reasonText: String {
        switch self {
        case .ready: return ""
        case .missing(let r): return r
        case .error(let m): return m
        }
    }

    /// Only a missing adapter is installable; a failed probe (unreachable
    /// host, broken Node) must stay a plain, retryable failure.
    package var discoveryError: ACPSessionDiscoveryError {
        switch self {
        case .missing(let reason): .setupRequired(reason)
        case .ready, .error: .setupFailed(reasonText)
        }
    }

    package var sessionSetupState: ACPSession.SetupState {
        switch self {
        case .ready: return .ready
        case .missing(let reason): return .needsSetup(reason: reason)
        case .error(let message): return .setupError(reason: message)
        }
    }
}
