import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

extension ACPComposerDraft {
    /// Flatten a restored composer draft into the plain text the web
    /// composer can hold. Mentions and references keep their visible spelling; pasted-text badges expand to their full content;
    /// image segments are dropped, since the web client cannot re-stage bytes
    /// it never had. The queued bubble hides Edit when `imageCount > 0`, so
    /// dropping an image here is a defensive fallback, not the expected path.
    public var remoteQueuePlainText: String {
        var out = ""
        for segment in segments {
            switch segment {
            case .text(let value):
                out += value
            case .upstreamReference(let reference):
                out += reference.spelling
            case .pastedText(_, let content):
                out += content
            case .mention(let displayName, _):
                out += "@\(displayName) "
            case .image:
                break
            }
        }
        return out
    }
}
