import AppKit
import SwiftUI

/// Small pill shown in the Commits section header trailing slot when the
/// worktree is behind a tracked ref. Purely informative. The `role` selects
/// a distinct theme color so the "behind base" and "behind upstream" chips
/// read as different things at a glance; the `label` names the target.
struct BehindChip: View {
    /// Which "behind" signal this chip represents. Drives the color.
    enum Role {
        case base       // behind the trunk you compare against (e.g. main)
        case upstream   // behind your branch's own remote tracking ref

        /// Theme color token for this role.
        var colorToken: String {
            switch self {
            case .base: return "accent"
            case .upstream: return "caution"
            }
        }
    }

    let count: Int
    let label: String
    let role: Role
    /// Spinner shown while a pull triggered by this chip is in flight.
    var inFlight: Bool = false
    /// When set, the chip becomes a button that runs this action (used by the
    /// upstream chip to trigger a pull). When nil, the chip is a plain pill.
    var onTap: (() -> Void)? = nil
    /// Remote tracking ref shown in the action tooltip (e.g. "origin/main").
    var ref: String? = nil

    @Environment(\.theme) private var theme
    @State private var hovering = false

    /// Pure text composition: `↓N label` (e.g. "↓3 main"). `↓` reads as
    /// "commits to pull in."
    static func displayText(count: Int, label: String) -> String {
        "↓\(count) \(label)"
    }

    @ViewBuilder
    var body: some View {
        if let onTap {
            // The actionable chip owns the tooltip ("Pull …"); the call site
            // does not add its own `.help`, which would otherwise shadow this.
            let refSuffix = ref.map { " from \($0)" } ?? ""
            Button(action: onTap) { pill(highlighted: hovering) }
                .buttonStyle(.plain)
                .disabled(inFlight)
                .onHover { hovering = $0 }
                .onChange(of: inFlight) { _, nowInFlight in if nowInFlight { hovering = false } }
                .pointingHandCursor()
                .help("Pull \(count) commit\(count == 1 ? "" : "s")\(refSuffix) (rebase)")
        } else {
            pill(highlighted: false)
        }
    }

    /// Hover styling is passed in explicitly so the non-interactive (base)
    /// chip can never inherit it.
    private func pill(highlighted: Bool) -> some View {
        let tint = theme.color(role.colorToken)
        return HStack(spacing: 4) {
            if inFlight {
                Spinner(lineWidth: 1.2, duration: 0.7)
                    .frame(width: 9, height: 9)
            }
            Text(Self.displayText(count: count, label: label))
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(highlighted ? tint.opacity(0.8) : tint)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(tint.opacity(highlighted ? 0.2 : 0.12))
        .clipShape(Capsule())
    }
}

struct CommitsSectionView: View {
    let commits: [CommitInfo]
    let olderCommits: [CommitInfo]
    let comparisonRef: String?
    let hasMoreOlder: Bool
    let isLoadingOlder: Bool
    let behindBase: GitService.BehindStatus?
    let behindUpstream: GitService.BehindStatus?
    @Binding var expanded: Bool
    @Binding var baseBranch: String
    let branches: [String]
    let isLoadingBranches: Bool
    let hasLoadedBranches: Bool
    let onSelect: (CommitInfo) -> Void
    let onCopySHA: (CommitInfo) -> Void
    let onEdit: (CommitInfo) -> Void
    let onReview: (CommitInfo) -> Void
    let onLoadOlder: () -> Void
    let onSelectBaseBranch: (String) -> Void
    let onOpenBaseBranchSelector: () -> Void
    let rps: RightPaneState
    let ggStack: GGStack?
    let stackCodeHostKind: CodeHostKind?
    let onGGAction: (GGCommitAction, CommitInfo) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            if expanded {
                expandedBody
            }
        } header: {
            SectionHeader(
                title: Self.sectionTitle(ggStack: ggStack),
                count: totalCount,
                expanded: expanded,
                onToggle: { expanded.toggle() }
            ) {
                HStack(spacing: 6) {
                    if let s = behindBase {
                        BehindChip(count: s.count, label: baseBranch, role: .base)
                            .help("\(s.count) behind \(s.ref)")
                    }
                    if let s = behindUpstream {
                        BehindChip(
                            count: s.count,
                            label: "remote",
                            role: .upstream,
                            inFlight: rps.pullInFlight,
                            onTap: { rps.pull() },
                            ref: s.ref
                        )
                        .disabled(rps.pullInFlight || rps.mergeOp.current != nil)
                    }
                    BaseBranchSelector(
                        baseBranch: $baseBranch,
                        branches: branches,
                        isLoadingBranches: isLoadingBranches,
                        hasLoadedBranches: hasLoadedBranches,
                        currentRef: comparisonRef,
                        onSelect: onSelectBaseBranch,
                        onOpen: onOpenBaseBranchSelector
                    )
                    BranchOpsMenu(rps: rps)
                }
            }
        }
    }

    private var totalCount: Int? {
        let n = commits.count + olderCommits.count
        return n == 0 ? nil : n
    }

    /// A section's identity follows the active stack rather than the current
    /// comparison mode's visible rows. This keeps the header stable for synced
    /// or filtered-to-empty stacks.
    static func sectionTitle(ggStack: GGStack?) -> String {
        ggStack?.name ?? "Commits"
    }

    static func ggRowMutationsEnabled(
        inFlightAction: GGStackActionKind?,
        mergeOperation: MergeOperation?,
        pausedGGOperation: GGPausedOperation?
    ) -> Bool {
        inFlightAction == nil
            && pausedGGOperation == nil
            && !GGStackReadinessProjection.hasBlockingGitOperation(
                mergeOperation: mergeOperation,
                pausedGGOperation: pausedGGOperation
            )
    }

    static func ggSelectionIsStale(rps: RightPaneState) -> Bool {
        rps.ggCommitSelectionIsStale
    }

    @ViewBuilder
    private var expandedBody: some View {
        // 1. Worktree commits ("your work") OR today's empty placeholder.
        if !commits.isEmpty {
                ForEach(Array(commits.enumerated()), id: \.element.id) { idx, commit in
                CommitRow(
                    commit: commit,
                    isLast: idx == commits.count - 1 && olderCommits.isEmpty,
                    onSelect: { onSelect(commit) },
                    onCopySHA: { onCopySHA(commit) },
                    onCopyMessage: { Clipboard.copy(commit.fullMessage) },
                    onOpenRemote: rps.commitsNeedPush ? nil : openRemoteAction(for: commit, remote: rps.primaryCommitRemote),
                    onEdit: { onEdit(commit) },
                    onReview: { onReview(commit) },
                    onCherryPick: { rps.requestCherryPick(sha: commit.sha) },
                    onRevert: { rps.runRevert(sha: commit.sha) },
                    ggMenu: ggMenu(for: commit),
                    onGGAction: { action in onGGAction(action, commit) },
                    onGGOpenPR: ggOpenReviewRequestAction(for: commit).map { action in
                        { onGGAction(action, commit) }
                    },
                    stackEntry: ggStack?.entry(matchingCommitSHA: commit.sha),
                    codeHostKind: stackCodeHostKind
                )
            }
        } else if olderCommits.isEmpty {
            emptyPlaceholder
        }

        // 2. Divider — only when older commits are shown AND we have a
        // comparison ref to label the boundary against.
        if !olderCommits.isEmpty, let ref = comparisonRef {
            dividerRow(label: ref)
        }

        // 3. Older commits — dimmed when comparisonRef exists, plain when not.
        if !olderCommits.isEmpty {
                ForEach(Array(olderCommits.enumerated()), id: \.element.id) { idx, commit in
                CommitRow(
                    commit: commit,
                    isLast: idx == olderCommits.count - 1,
                    isHistorical: comparisonRef != nil,
                    onSelect: { onSelect(commit) },
                    onCopySHA: { onCopySHA(commit) },
                    onCopyMessage: { Clipboard.copy(commit.fullMessage) },
                    onOpenRemote: openRemoteAction(for: commit, remote: rps.commitRemote),
                    onReview: { onReview(commit) },
                    onCherryPick: { rps.requestCherryPick(sha: commit.sha) },
                    onRevert: { rps.runRevert(sha: commit.sha) }
                )
            }
        }

        // 4. Footer.
        footer
    }

    private var emptyPlaceholder: some View {
        Text(comparisonRef.map { "up to date with \($0)" } ?? "no comparison branch")
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-faint"))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dividerRow(label: String) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(theme.color("line"))
                .frame(height: 1)
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.color("fg-faint"))
                .textCase(.uppercase)
                .tracking(0.4)
            Rectangle()
                .fill(theme.color("line"))
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func ggMenu(for commit: CommitInfo) -> GGCommitMenuModel? {
        guard let stack = ggStack,
              let entry = stack.entry(matchingCommitSHA: commit.sha)
        else { return nil }
        let providerReviewURL = entry.prNumber.flatMap { rps.commitRemote?.reviewRequestURL(number: $0) }
        return GGCommitMenuModel.make(context: GGCommitMenuContext(
            entry: entry,
            stack: stack,
            provider: stackCodeHostKind,
            capabilities: GGAvailability.shared.capabilities,
            inFlightAction: rps.ggActionState.inFlightAction,
            pausedOperation: rps.ggActionState.pausedOperation,
            hasBlockingGitOperation: GGStackReadinessProjection.hasBlockingGitOperation(
                mergeOperation: rps.mergeOp.current,
                pausedGGOperation: rps.ggActionState.pausedOperation
            ),
            selectionIsStale: Self.ggSelectionIsStale(rps: rps),
            canOpenSplitCommit: rps.requestGGSplitCommit != nil && rps.mergeOp.current == nil,
            providerReviewURL: providerReviewURL
        ))
    }

    private func ggOpenReviewRequestAction(for commit: CommitInfo) -> GGCommitAction? {
        guard let entry = ggStack?.entry(matchingCommitSHA: commit.sha) else { return nil }
        return Self.ggStackChipClickAction(for: entry, remote: rps.commitRemote)
    }

    static func ggStackChipClickAction(for entry: GGStackEntry, remote: CodeHostRemote?) -> GGCommitAction? {
        guard let number = entry.prNumber, remote != nil else { return nil }
        return .openProviderRequest(number: number)
    }

    private func openRemoteAction(for commit: CommitInfo, remote: CodeHostRemote?) -> (() -> Void)? {
        guard let url = remote?.commitURL(sha: commit.sha) else { return nil }
        return {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if isLoadingOlder {
            HStack(spacing: 6) {
                Spinner(lineWidth: 1.5, duration: 0.7)
                    .frame(width: 10, height: 10)
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-faint"))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        } else if hasMoreOlder {
            Button(action: onLoadOlder) {
                Text("↓ Load older commits")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("accent"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if !olderCommits.isEmpty {
            Text("End of history")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        }
    }
}
