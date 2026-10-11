import Foundation

public enum ACPFirstRunConnectingPhase: CaseIterable, Equatable, Sendable {
    case checkingSetup
    case launchingAdapter
    case initializing
    case creatingSession

    public var label: String {
        switch self {
        case .checkingSetup: return "Checking setup"
        case .launchingAdapter: return "Launching adapter"
        case .initializing: return "Initializing"
        case .creatingSession: return "Creating session"
        }
    }
}
