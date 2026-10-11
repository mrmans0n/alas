import SwiftUI

/// One checkpoint, rendered with the same inset card treatment the Run and
/// Agents tabs use (`RightPaneCardChrome`). Collapsed it is a single chip
/// line; expanded it also owns its manifest and its actions, so everything
/// belonging to one checkpoint lives inside one card instead of trailing
/// below it as loose rows.
struct CheckpointCard: View {
    let checkpoint: WorktreeCheckpointSummary
    let expanded: Bool
    let manifest: WorktreeCheckpointManifest?
    let manifestLoading: Bool
    let manifestError: String?
    let mutationsDisabled: Bool
    let blockedReason: String?
    /// 0-based page of manifest groups this expanded card is currently
    /// showing. Only this page's groups render — navigating never
    /// accumulates previously shown groups — so the card renders at most
    /// `CheckpointPresentation.maxInlineFileGroups` file rows regardless of
    /// how many pages a huge checkpoint has.
    let fileListPageIndex: Int
    let onToggle: () -> Void
    let onPreviousFilePage: () -> Void
    let onNextFilePage: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void
    let onInspect: (CheckpointFileGroup) -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    private var unavailable: Bool { checkpoint.unavailableReason != nil }
    private var tone: Color { theme.color(CheckpointPresentation.toneToken(checkpoint)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chipLine
            if let reason = checkpoint.unavailableReason {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundColor(theme.color("del"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.leading, Self.bodyIndent)
            } else if expanded {
                expandedBody
            }
        }
        .padding(10)
        .rightPaneCardChrome(accent: tone, isHovering: hovering || expanded)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Restore…") { onRestore() }
                .disabled(unavailable || mutationsDisabled)
            Divider()
            Button("Delete…", role: .destructive) { onDelete() }
                .disabled(mutationsDisabled)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CheckpointPresentation.rowID(checkpointID: checkpoint.id))
    }

    /// Indent that aligns the body with the label, past the chevron.
    private static let bodyIndent: CGFloat = 18

    private var chipLine: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Icon(
                    name: expanded ? "chev-down" : "chev-right",
                    size: 10,
                    color: expanded ? theme.color("accent") : theme.color("fg-faint")
                )
                .frame(width: 12, height: 12)
                .opacity(unavailable ? 0.35 : 1)
                Circle()
                    .fill(tone)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(checkpoint.label)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.color(unavailable ? "fg-muted" : "fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if checkpoint.kind != .automatic {
                    Text(CheckpointPresentation.kind(checkpoint.kind).uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.3)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(theme.color("seg-pill-bg"), in: Capsule())
                        .foregroundColor(theme.color("fg-muted"))
                        .fixedSize()
                }
                Spacer(minLength: 8)
                Text(CheckpointPresentation.compactDate(checkpoint.createdAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .accessibilityLabel("\(checkpoint.label), \(CheckpointPresentation.kind(checkpoint.kind)) checkpoint")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CheckpointPresentation.detail(checkpoint))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.color("fg-faint"))
            manifestContent
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                CheckpointActionButton(
                    title: "Restore…",
                    icon: "arrow.counterclockwise",
                    role: .primary,
                    disabled: unavailable || mutationsDisabled,
                    action: onRestore
                )
                .accessibilityIdentifier(CheckpointPresentation.restoreButtonID(checkpointID: checkpoint.id))
                CheckpointActionButton(
                    title: "Delete…",
                    icon: "trash",
                    role: .destructive,
                    disabled: mutationsDisabled,
                    action: onDelete
                )
                .accessibilityIdentifier(CheckpointPresentation.deleteButtonID(checkpointID: checkpoint.id))
            }
            .padding(.top, 5)
            if mutationsDisabled, let blockedReason {
                Text(blockedReason)
                    .font(.system(size: 10))
                    .foregroundColor(theme.color("mod"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
        .padding(.leading, Self.bodyIndent)
    }

    @ViewBuilder
    private var manifestContent: some View {
        if manifestLoading {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Loading checkpoint files…")
            }
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-muted"))
            .padding(.vertical, 2)
        } else if let manifestError {
            Text(manifestError)
                .font(.system(size: 11))
                .foregroundColor(theme.color("del"))
                .fixedSize(horizontal: false, vertical: true)
        } else if let manifest {
            let pathIndex = Dictionary(uniqueKeysWithValues: manifest.paths.map { ($0.relativePath, $0) })
            let cap = CheckpointPresentation.maxInlineFileGroups
            let total = manifest.groups.count
            let pageStart = total == 0 ? 0 : min(fileListPageIndex * cap, total - 1)
            let pageEnd = min(pageStart + cap, total)
            let windowGroups = total == 0 ? [] : Array(manifest.groups[pageStart..<pageEnd])
            ForEach(windowGroups) { group in
                CheckpointFileGroupRow(
                    group: group,
                    badges: CheckpointPresentation.fileBadges(for: group, pathIndex: pathIndex)
                ) { onInspect(group) }
                .id(CheckpointPresentation.groupRowID(checkpointID: checkpoint.id, groupID: group.id))
            }
            if total > cap {
                HStack(spacing: 6) {
                    Text("\(pageStart + 1)–\(pageEnd) of \(total) files")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.color("fg-faint"))
                    Spacer(minLength: 6)
                    Button(action: onPreviousFilePage) {
                        Icon(name: "chevron.left", size: 9, color: theme.color(pageStart == 0 ? "fg-faint" : "fg-muted"))
                    }
                    .buttonStyle(.plain)
                    .disabled(pageStart == 0)
                    .accessibilityLabel("Previous files")
                    Button(action: onNextFilePage) {
                        Icon(name: "chevron.right", size: 9, color: theme.color(pageEnd >= total ? "fg-faint" : "fg-muted"))
                    }
                    .buttonStyle(.plain)
                    .disabled(pageEnd >= total)
                    .accessibilityLabel("Next files")
                }
                .padding(.vertical, 2)
            }
            if !manifest.exclusions.isEmpty {
                CheckpointExclusionsRow(exclusions: manifest.exclusions)
            }
        }
    }
}

/// Card action button. Shares the ACP composer's capsule metrics so the
/// primary reads like Send and the destructive reads like Stop.
struct CheckpointActionButton: View {
    enum Role {
        case primary
        case destructive
    }

    let title: String
    let icon: String
    let role: Role
    let disabled: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Icon(name: icon, size: 10, color: foreground)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .frame(height: ACPComposerActionButtonMetrics.capsuleHeight)
            .background(
                RoundedRectangle(cornerRadius: ACPComposerActionButtonMetrics.cornerRadius)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ACPComposerActionButtonMetrics.cornerRadius)
                    .strokeBorder(stroke, lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: ACPComposerActionButtonMetrics.cornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        if disabled { return theme.color("fg-faint") }
        switch role {
        case .primary: return theme.color("bg-0")
        case .destructive: return theme.color("del")
        }
    }

    private var fill: Color {
        if disabled { return theme.color("bg-3").opacity(0.5) }
        switch role {
        case .primary: return theme.color("accent")
        case .destructive: return theme.color("del").opacity(0.15)
        }
    }

    private var stroke: Color {
        if disabled { return theme.color("line").opacity(0.6) }
        switch role {
        case .primary: return .clear
        case .destructive: return theme.color("del").opacity(0.45)
        }
    }
}

struct CheckpointFooterRow: View {
    let storageUsage: Int64

    @Environment(\.theme) private var theme

    var body: some View {
        Text(CheckpointPresentation.footer(storageUsage: storageUsage))
            .font(.system(size: 10))
            .foregroundColor(theme.color("fg-faint"))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .help(CheckpointPresentation.retentionHelp)
    }
}

struct CheckpointFileGroupRow: View {
    let group: CheckpointFileGroup
    let badges: String
    let onInspect: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            onInspect()
        } label: {
            HStack(spacing: 5) {
                Icon(name: "file", size: 10, color: theme.color("fg-faint"))
                    .frame(width: 11, height: 11)
                Text(group.renameSource.map { "\($0) → \(group.primaryPath)" } ?? group.primaryPath)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(badges)
                    .font(.system(size: 9))
                    .foregroundColor(theme.color("fg-faint"))
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityLabel("Inspect checkpoint file \(group.primaryPath)")
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
        .padding(.vertical, 2)
    }
}
