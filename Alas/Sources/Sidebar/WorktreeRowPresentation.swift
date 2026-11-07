import Foundation

/// What a worktree row shows, decided apart from how it draws it.
///
/// A row is two lines: the name, then everything the row knows, always on
/// screen so a scan of the list reads it without a pointer.
enum WorktreeRowPresentation {

    /// Agent state and conflicts get a coloured dot and lead line 2. A plain
    /// file count gets neither.
    nonisolated static func isStatusLoud(
        harnessState: HarnessService.AggregatedState?,
        worktreeStatus: WorktreeDirtyState
    ) -> Bool {
        if harnessState != nil { return true }
        if case .dirty(_, let conflictCount) = worktreeStatus { return conflictCount > 0 }
        return false
    }

    /// Short enough to sit beside a name: "5m", "3h", "2d".
    nonisolated static func compactAge(since date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        case ..<604_800: return "\(seconds / 86_400)d"
        case ..<2_592_000: return "\(seconds / 604_800)w"
        case ..<31_536_000: return "\(seconds / 2_592_000)mo"
        default: return "\(seconds / 31_536_000)y"
        }
    }

    /// Being behind upstream has a pull action waiting; being ahead does not.
    nonisolated static func upstreamItemsAtRest(
        _ items: [WorktreeUpstreamStatus.SubtitleItem]
    ) -> [WorktreeUpstreamStatus.SubtitleItem] {
        items.filter { $0.text.hasPrefix("↓") }
    }

    /// Spoken for the whole row, so its parts read as one sentence.
    nonisolated static func accessibilityLabel(_ content: WorktreeRowAccessibilityContent) -> String {
        var parts = [content.name]
        if let statusNote = content.statusNote { parts.append(statusNote) }
        if content.added > 0 || content.deleted > 0 {
            parts.append("\(content.added) lines added, \(content.deleted) lines deleted")
        }
        if let workspaceCheckout = content.workspaceCheckout { parts.append(workspaceCheckout) }
        if let commits = content.commits { parts.append(commits) }
        parts += content.upstream
        if let stack = content.stack { parts.append(stack) }
        parts += content.agents
        if let explanation = content.explanation { parts.append(explanation) }
        parts.append(content.lastActivity)
        return parts.joined(separator: ", ")
    }
}

/// Everything a row can say, for its accessibility label. No defaults: a new
/// row fact has to be supplied here, and the test reads every field by
/// reflection, so one the label forgets fails.
struct WorktreeRowAccessibilityContent {
    let name: String
    let statusNote: String?
    let added: Int
    let deleted: Int
    let workspaceCheckout: String?
    let commits: String?
    let upstream: [String]
    let stack: String?
    let agents: [String]
    let explanation: String?
    let lastActivity: String
}
