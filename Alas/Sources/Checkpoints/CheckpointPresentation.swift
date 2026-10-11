import Foundation

enum CheckpointPresentation {
    static let remoteReason = "Checkpoints are not available for remote worktrees yet."
    /// Cap on file rows built inline inside an expanded card. A checkpoint
    /// can capture hundreds or thousands of paths; unlike the old per-group
    /// `AppKitDiffRowSpec` rows, an expanded card's file list is one
    /// `NSHostingView` subtree, so an unbounded `ForEach` here would eagerly
    /// construct and measure every row instead of only the visible ones.
    static let maxInlineFileGroups = 24

    static func compactDate(_ date: Date, now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        if Calendar.current.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "d/M HH:mm"
        }
        return formatter.string(from: date)
    }

    static func bytes(_ count: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB"]
        var value = Double(max(0, count))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let number = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return "\(number) \(units[unit])"
    }

    static func summary(_ checkpoint: WorktreeCheckpointSummary) -> String {
        let parts = [
            checkpoint.stagedFileCount > 0 ? "\(checkpoint.stagedFileCount) staged" : nil,
            checkpoint.unstagedFileCount > 0 ? "\(checkpoint.unstagedFileCount) unstaged" : nil,
            checkpoint.untrackedFileCount > 0 ? "\(checkpoint.untrackedFileCount) untracked" : nil
        ].compactMap { $0 }
        return parts.isEmpty ? "Clean" : parts.joined(separator: " · ")
    }

    /// Content line shown inside an expanded card. The creation time lives on
    /// the card's chip line, so it is deliberately absent here.
    static func detail(_ checkpoint: WorktreeCheckpointSummary) -> String {
        "\(summary(checkpoint)) · \(bytes(checkpoint.byteCount))"
    }

    static func capturedFileCount(_ checkpoint: WorktreeCheckpointSummary) -> Int {
        checkpoint.stagedFileCount + checkpoint.unstagedFileCount + checkpoint.untrackedFileCount
    }

    /// Theme token for the card's tone dot and its accent-tinted chrome.
    /// Precedence is deliberate: a broken checkpoint outranks everything, and
    /// "carries uncommitted work" outranks "was made by hand", because the
    /// former is what makes a row worth restoring.
    static func toneToken(_ checkpoint: WorktreeCheckpointSummary) -> String {
        if checkpoint.unavailableReason != nil { return "del" }
        if capturedFileCount(checkpoint) > 0 { return "mod" }
        switch checkpoint.kind {
        case .manual, .recovery: return "accent"
        case .automatic: return "fg-faint"
        }
    }

    /// Why Restore/Delete are disabled. `RightPaneState.checkpointMutationsDisabled`
    /// is the union of these three conditions; the card prints the reason instead
    /// of greying the buttons out silently.
    static func mutationsBlockedReason(
        operationInFlight: CheckpointOperationKind?,
        hasInterruptedRestore: Bool
    ) -> String? {
        if let operationInFlight {
            switch operationInFlight {
            case .capture: return "A checkpoint is being created."
            case .preview: return "A restore is being prepared."
            case .restore: return "A restore is already in progress."
            case .delete: return "A checkpoint is being deleted."
            case .recovery: return "An interrupted restore is being recovered."
            }
        }
        if hasInterruptedRestore { return "Recover the interrupted restore first." }
        return "Checkpoint state is still loading."
    }

    static func kind(_ kind: CheckpointKind) -> String {
        switch kind {
        case .manual: "Manual"
        case .automatic: "Automatic"
        case .recovery: "Recovery"
        }
    }

    static func footer(storageUsage: Int64) -> String {
        "\(bytes(storageUsage)) used"
    }

    static let retentionHelp = "Keeps up to 50 automatic, 20 manual, and 5 recovery checkpoints within 2 GiB per worktree."

    static func rowID(checkpointID: CheckpointID) -> String { "checkpoint-\(checkpointID.uuidString)" }
    static func groupRowID(checkpointID: CheckpointID, groupID: UUID) -> String {
        "checkpoint-\(checkpointID.uuidString)-group-\(groupID.uuidString)"
    }

    /// `index`/`working tree` badge for one file group. Takes a
    /// path-to-state lookup built once per manifest so this stays O(member
    /// paths) instead of re-filtering the whole manifest per group.
    static func fileBadges(for group: CheckpointFileGroup, pathIndex: [String: CheckpointPathState]) -> String {
        let hasIndexChange = group.memberPaths.contains { pathIndex[$0].map { $0.index != $0.head } ?? false }
        let hasWorktreeChange = group.memberPaths.contains { pathIndex[$0].map { $0.worktree != $0.head } ?? false }
        return [hasIndexChange ? "index" : nil, hasWorktreeChange ? "working tree" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
    static func restoreButtonID(checkpointID: CheckpointID) -> String {
        "checkpoint-restore-\(checkpointID.uuidString)"
    }
    static func deleteButtonID(checkpointID: CheckpointID) -> String {
        "checkpoint-delete-\(checkpointID.uuidString)"
    }
}

enum CheckpointOperationKind: Equatable {
    case capture
    case preview
    case restore
    case delete
    case recovery
}
