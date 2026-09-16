import Foundation

struct WorktreeUpstreamStatus: Equatable, Sendable {
    struct SubtitleItem: Equatable, Sendable {
        let text: String
        let accessibilityLabel: String
    }

    let ahead: Int
    let behind: Int
    let upstreamRef: String

    var subtitleItems: [SubtitleItem] {
        var items: [SubtitleItem] = []
        if ahead > 0 {
            items.append(.init(
                text: "↑\(ahead)",
                accessibilityLabel: "\(ahead) commit\(ahead == 1 ? "" : "s") ahead of \(upstreamRef)"
            ))
        }
        if behind > 0 {
            items.append(.init(
                text: "↓\(behind)",
                accessibilityLabel: "\(behind) commit\(behind == 1 ? "" : "s") behind \(upstreamRef)"
            ))
        }
        return items
    }
}
