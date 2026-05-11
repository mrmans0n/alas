import SwiftUI

struct CommitsSectionView: View {
    let commits: [CommitInfo]
    let comparisonRef: String?
    @Binding var expanded: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "Commits",
                count: commits.isEmpty ? nil : commits.count,
                expanded: expanded,
                onToggle: { expanded.toggle() }
            ) {
                if let comparisonRef {
                    HStack(spacing: 4) {
                        Icon(name: "branch", size: 10, color: theme.color("fg-faint"))
                        Text(comparisonRef)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(theme.color("fg-faint"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if expanded {
                if commits.isEmpty {
                    emptyPlaceholder
                } else {
                    ForEach(Array(commits.enumerated()), id: \.element.id) { idx, commit in
                        CommitRow(commit: commit, isLast: idx == commits.count - 1)
                    }
                }
            }
        }
    }

    private var emptyPlaceholder: some View {
        Text(comparisonRef.map { "up to date with \($0)" } ?? "no upstream branch")
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-faint"))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
