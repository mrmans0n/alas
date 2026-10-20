import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Per-transcript state a renderer keeps alongside the transcript.
@MainActor
public protocol ACPTranscriptRenderState: AnyObject {
    #if DEBUG
    /// Approximate retained bytes, for `MemoryDiagnostics`.
    var byteEstimate: UInt64 { get }
    #endif
}
