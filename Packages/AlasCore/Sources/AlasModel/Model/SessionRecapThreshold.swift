import Foundation

/// How long a user must be away from a session before an automatic recap is offered.
public enum SessionRecapThreshold: String, Codable, CaseIterable, Sendable {
    case off, thirtyMinutes, twoHours, eightHours

    public var duration: Duration? {
        let base: Int
        switch self {
        case .off: return nil
        case .thirtyMinutes: base = 1800
        case .twoHours: base = 7200
        case .eightHours: base = 28800
        }
        #if DEBUG
        // Manual-verification override; never applies to `.off`.
        if let raw = ProcessInfo.processInfo.environment["ALAS_RECAP_THRESHOLD_SECONDS"],
           let seconds = Int(raw) {
            return .seconds(seconds)
        }
        #endif
        return .seconds(base)
    }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .thirtyMinutes: return "30 min"
        case .twoHours: return "2 h"
        case .eightHours: return "8 h"
        }
    }
}
