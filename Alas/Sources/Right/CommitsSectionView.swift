import SwiftUI

/// Small pill shown in the Commits section header trailing slot when the
/// worktree is behind a tracked ref (base trunk or its own upstream).
/// Purely informative.
struct BehindChip: View {
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(theme.color("accent"))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(theme.color("accent").opacity(0.12))
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
    let onSelect: (CommitInfo) -> Void
    let onCopySHA: (CommitInfo) -> Void
    let onLoadOlder: () -> Void
    let onSelectBaseBranch: (String) -> Void
    let onOpenBaseBranchSelector: () -> Void
    let rps: RightPaneState

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "Commits",
                count: totalCount,
                expanded: expanded,
                onToggle: { expanded.toggle() }
            ) {
                HStack(spacing: 6) {
                    if let s = behindBase {
                        BehindChip(text: "\(s.count) behind")
                            .help("\(s.count) behind \(s.ref)")
                    }
                    if let s = behindUpstream {
                        BehindChip(text: "\(s.count) behind")
                            .help("\(s.count) behind \(s.ref)")
                    }
                    BaseBranchSelector(
                        baseBranch: $baseBranch,
                        branches: branches,
                        currentRef: comparisonRef,
                        onSelect: onSelectBaseBranch,
                        onOpen: onOpenBaseBranchSelector
                    )
                    BranchOpsMenu(rps: rps)
                }
            }

            if expanded {
                expandedBody
            }
        }
    }

    private var totalCount: Int? {
        let n = commits.count + olderCommits.count
        return n == 0 ? nil : n
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
                    onCherryPick: { rps.runCherryPick(sha: commit.sha) }
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
                    onCherryPick: { rps.runCherryPick(sha: commit.sha) }
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

    @ViewBuilder
    private var footer: some View {
        if isLoadingOlder {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
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
