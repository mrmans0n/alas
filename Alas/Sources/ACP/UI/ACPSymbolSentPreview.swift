import SwiftUI

/// What the transcript popover of a sent symbol badge shows, decided from the
/// snapshot stored with the message and the file as it is now.
struct ACPSymbolSentPreview: Equatable {
    enum Source: Hashable { case sent, current }

    enum Note: Equatable {
        case changedSinceSent
        case noLongerFound
        case notFoundWhenSent

        var text: String {
            switch self {
            case .changedSinceSent: "Changed since sent"
            case .noLongerFound: "No longer found"
            case .notFoundWhenSent: "Not found when sent"
            }
        }
    }

    /// The code shown first. `.current` shows live code, a skeleton until read.
    let source: Source
    /// Whether the popover can switch to the current code: code was sent and
    /// the symbol exists now.
    let canShowCurrent: Bool
    let note: Note?

    /// `live` is nil until the file has been read.
    static func make(snapshot: ACPSymbolSnapshot?, live: ACPSymbolHoverPreview.Loaded?) -> ACPSymbolSentPreview {
        guard let snapshot else { return ACPSymbolSentPreview(source: .current, canShowCurrent: false, note: nil) }
        var liveHash: String?
        var liveMissing = false
        switch live {
        case .found(_, _, let hash)?: liveHash = hash
        case .missing?: liveMissing = true
        case nil: break
        }
        let sentCode = snapshot.excerpt != nil
        let note: Note? = if !snapshot.found {
            .notFoundWhenSent
        } else if liveMissing {
            .noLongerFound
        } else if let liveHash, liveHash != snapshot.contentHash {
            .changedSinceSent
        } else {
            nil
        }
        return ACPSymbolSentPreview(source: sentCode ? .sent : .current,
                                    canShowCurrent: sentCode && liveHash != nil, note: note)
    }
}
