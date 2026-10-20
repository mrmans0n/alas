import Foundation
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

package let sessionSummaryLogger = Logger(subsystem: "io.nlopez.alas", category: "session-summary")

/// Who asked for a summary: the popover (`manual`) or the automatic recap card,
/// which fails silently.
/// How a background recap precompute ended.
public enum SessionRecapPrecomputeOutcome: Sendable, Equatable {
    /// A valid summary is now stored.
    case stored
    /// Ended without a summary; not worth retrying soon.
    case skipped
    /// A foreground inference took the engine; retry after a back-off.
    case preempted
}

public enum SessionSummaryRequestMode: Sendable {
    case manual
    case recap
}
