import SwiftUI

enum CheckpointPresentation {
    static let remoteReason = "Checkpoints are not available for remote worktrees yet."

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
        "\(checkpoint.stagedFileCount) staged, \(checkpoint.unstagedFileCount) unstaged, \(checkpoint.untrackedFileCount) untracked"
    }

    static func statusLine(_ checkpoint: WorktreeCheckpointSummary, now: Date = .now) -> String {
        if let reason = checkpoint.unavailableReason {
            return reason
        }
        return "\(compactDate(checkpoint.createdAt, now: now)) · \(summary(checkpoint)) · \(bytes(checkpoint.byteCount))"
    }

    static func kind(_ kind: CheckpointKind) -> String {
        kind == .manual ? "Manual" : "Recovery"
    }

    static func footer(storageUsage: Int64) -> String {
        "\(bytes(storageUsage)) used · 20 manual · 5 recovery · 2 GiB per worktree"
    }

    static func rowID(checkpointID: CheckpointID) -> String { "checkpoint-\(checkpointID.uuidString)" }
    static func groupRowID(checkpointID: CheckpointID, groupID: UUID) -> String {
        "checkpoint-\(checkpointID.uuidString)-group-\(groupID.uuidString)"
    }
}

struct CheckpointSummaryRow: View {
    let checkpoint: WorktreeCheckpointSummary
    let expanded: Bool
    let onToggle: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        let unavailable = checkpoint.unavailableReason != nil
        HStack(spacing: 8) {
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(checkpoint.label).font(.system(size: 12, weight: .medium))
                        Text(CheckpointPresentation.kind(checkpoint.kind))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.color("fg-muted"))
                    }
                    Text(CheckpointPresentation.statusLine(checkpoint))
                        .font(.system(size: 10))
                        .foregroundColor(unavailable ? theme.color("del") : theme.color("fg-muted"))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !unavailable {
                    Icon(name: expanded ? "chevron.down" : "chevron.right", size: 9, color: theme.color("fg-faint"))
                }
            }
            .buttonStyle(.plain)
            .disabled(unavailable)
            .accessibilityLabel("\(checkpoint.label), \(CheckpointPresentation.kind(checkpoint.kind)) checkpoint")

            Menu {
                Button("Restore...") { onRestore() }
                    .disabled(unavailable)
                Divider()
                Button("Delete...", role: .destructive) { onDelete() }
            } label: {
                Icon(name: "ellipsis", size: 12, color: theme.color("fg-muted"))
                    .frame(width: 20, height: 22)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct CheckpointManifestRows: View {
    let checkpointID: CheckpointID
    let manifest: WorktreeCheckpointManifest?
    let loading: Bool
    let error: String?

    @Environment(\.theme) private var theme

    var body: some View {
        if loading {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Loading checkpoint files…")
            }
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-muted"))
            .padding(.leading, 28).padding(.vertical, 6)
        } else if let error {
            Text(error)
                .font(.system(size: 11))
                .foregroundColor(theme.color("del"))
                .padding(.leading, 28).padding(.vertical, 6)
        } else if let manifest {
            ForEach(manifest.groups) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.renameSource.map { "\($0) → \(group.primaryPath)" } ?? group.primaryPath)
                        .font(.system(size: 11))
                    Text(groupBadgeText(group, manifest: manifest))
                        .font(.system(size: 9))
                        .foregroundColor(theme.color("fg-muted"))
                }
                .padding(.leading, 28).padding(.vertical, 5)
                .id(CheckpointPresentation.groupRowID(checkpointID: checkpointID, groupID: group.id))
            }
            if !manifest.exclusions.isEmpty {
                DisclosureGroup("Excluded files (\(manifest.exclusions.count))") {
                    ForEach(manifest.exclusions, id: \.relativePath) { exclusion in
                        Text("\(exclusion.relativePath) — \(CreateCheckpointSheetModel.exclusionReason(exclusion.reason))")
                    }
                }
                .font(.system(size: 10))
                .padding(.leading, 28).padding(.vertical, 4)
            }
        }
    }

    private func groupBadgeText(_ group: CheckpointFileGroup, manifest: WorktreeCheckpointManifest) -> String {
        let paths = manifest.paths.filter { group.memberPaths.contains($0.relativePath) }
        let index = paths.contains { $0.index != $0.head }
        let worktree = paths.contains { $0.worktree != $0.head }
        return [index ? "index" : nil, worktree ? "working tree" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

struct CheckpointFooterRow: View {
    let storageUsage: Int64

    @Environment(\.theme) private var theme

    var body: some View {
        Text(CheckpointPresentation.footer(storageUsage: storageUsage))
            .font(.system(size: 10))
            .foregroundColor(theme.color("fg-muted"))
            .padding(.horizontal, 12).padding(.vertical, 7)
    }
}

struct CheckpointFileGroupRow: View {
    let group: CheckpointFileGroup
    let manifest: WorktreeCheckpointManifest
    let onInspect: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            onInspect()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.renameSource.map { "\($0) → \(group.primaryPath)" } ?? group.primaryPath)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg"))
                Text(badges)
                    .font(.system(size: 9))
                    .foregroundColor(theme.color("fg-muted"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 28).padding(.vertical, 5)
        .accessibilityLabel("Inspect checkpoint file \(group.primaryPath)")
    }

    private var badges: String {
        let paths = manifest.paths.filter { group.memberPaths.contains($0.relativePath) }
        return [paths.contains { $0.index != $0.head } ? "index" : nil,
                paths.contains { $0.worktree != $0.head } ? "working tree" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct CheckpointExclusionsRow: View {
    let exclusions: [CheckpointExclusion]

    var body: some View {
        DisclosureGroup("Excluded files (\(exclusions.count))") {
            ForEach(exclusions, id: \.relativePath) { exclusion in
                Text("\(exclusion.relativePath) — \(CreateCheckpointSheetModel.exclusionReason(exclusion.reason))")
            }
        }
        .font(.system(size: 10))
        .padding(.leading, 28).padding(.vertical, 4)
    }
}
