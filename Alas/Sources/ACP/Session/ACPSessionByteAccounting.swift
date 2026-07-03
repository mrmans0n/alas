#if DEBUG
import Foundation

@MainActor
extension ACPSession {
    /// Sum of approximate UTF-8 byte sizes across every message in the transcript.
    /// Tool-call `content` and `preview` are counted in full; locations are
    /// counted by their joined path length.
    func transcriptByteEstimate() -> UInt64 {
        var total: UInt64 = 0
        for m in transcript.messages {
            switch m {
            case .user(_, _, let text, let atts):
                total &+= UInt64(text.utf8.count)
                for a in atts {
                    total &+= UInt64(a.uri.utf8.count)
                    total &+= UInt64(a.name?.utf8.count ?? 0)
                }
            case .agent(_, _, let buf), .thought(_, _, let buf):
                total &+= UInt64(buf.value.utf8.count)
            case .toolCall(let tc):
                total &+= UInt64(tc.content.utf8.count)
                total &+= UInt64(tc.preview?.utf8.count ?? 0)
                total &+= UInt64(tc.rawInput?.utf8.count ?? 0)
                total &+= UInt64(tc.title.utf8.count)
                for path in tc.locations { total &+= UInt64(path.utf8.count) }
            case .fileEdit(_, let edit):
                total &+= UInt64(edit.path.utf8.count)
            case .plan(_, let items):
                for item in items { total &+= UInt64(item.content.utf8.count) }
            case .systemNotice(_, let text):
                total &+= UInt64(text.utf8.count)
            }
        }
        return total
    }

    /// Forwards to `ACPTranscript.markdownCacheByteEstimate`.
    func markdownCacheByteEstimate() -> UInt64 {
        transcript.markdownCacheByteEstimate
    }
}
#endif
