import SwiftUI

struct ReviewScopePicker: View {
    enum Tab: String, CaseIterable, Identifiable {
        case commits = "Commits"
        case branches = "Branches"
        var id: String { rawValue }
    }

    let commits: [CommitInfo]
    let branches: [String]
    let onSelect: (ReviewScopeChoice) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var tab: Tab = .commits
    @State private var query: String = ""
    @State private var rangeAnchor: CommitInfo?

    private var filtered: [CommitInfo] {
        ReviewScopeSelection.filteredCommits(commits, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.color("line"))
            switch tab {
            case .commits: commitsList
            case .branches: branchesList
            }
        }
        .frame(width: 560, height: 480)
        .background(theme.color("bg-1"))
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Review scope")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                Spacer()
                Button("Working tree") { onSelect(.workingTree) }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.color("accent"))
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.color("fg-muted"))
            }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if tab == .commits {
                TextField("Filter commits…", text: $query)
                    .textFieldStyle(.roundedBorder)
                if let anchor = rangeAnchor {
                    HStack(spacing: 6) {
                        Image(systemName: "smallcircle.filled.circle")
                        Text("Range start: \(anchor.shortSha) — pick the end commit")
                            .font(.system(size: 11))
                        Spacer()
                        Button("Clear") { rangeAnchor = nil }
                            .buttonStyle(.plain)
                    }
                    .foregroundColor(theme.color("accent"))
                }
            }
        }
        .padding(12)
        .background(theme.color("bg-2"))
    }

    private var commitsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { commit in
                    commitRow(commit)
                    Divider().overlay(theme.color("line").opacity(0.5))
                }
            }
        }
    }

    private func commitRow(_ commit: CommitInfo) -> some View {
        let inRange = rangeAnchor.map { isBetween(commit, $0) } ?? false
        return HStack(spacing: 10) {
            Button {
                rangeAnchor = (rangeAnchor?.id == commit.id) ? nil : commit
            } label: {
                Image(systemName: rangeAnchor?.id == commit.id
                    ? "smallcircle.filled.circle.fill"
                    : "smallcircle.filled.circle")
                    .foregroundColor(rangeAnchor?.id == commit.id
                        ? theme.color("accent")
                        : theme.color("fg-muted"))
            }
            .buttonStyle(.plain)
            .help("Set as range start")

            Button {
                select(commit)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.subject)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                    Text("\(commit.shortSha) · \(commit.author)")
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("fg-dim"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(inRange ? theme.color("accent-soft") : Color.clear)
    }

    private func select(_ commit: CommitInfo) {
        if let anchor = rangeAnchor, anchor.id != commit.id {
            let (older, newer) = orderByPosition(anchor, commit)
            onSelect(.range(older: older, newer: newer))
        } else {
            onSelect(.commit(commit))
        }
    }

    // Commits arrive newest-first (git log order). "older" = larger index.
    private func orderByPosition(_ a: CommitInfo, _ b: CommitInfo) -> (older: CommitInfo, newer: CommitInfo) {
        let ia = commits.firstIndex(of: a) ?? 0
        let ib = commits.firstIndex(of: b) ?? 0
        return ia > ib ? (a, b) : (b, a)
    }

    private func isBetween(_ commit: CommitInfo, _ anchor: CommitInfo) -> Bool {
        guard let ic = commits.firstIndex(of: commit),
              let ia = commits.firstIndex(of: anchor)
        else { return false }
        return (min(ia, ic) ... max(ia, ic)).contains(ic)
    }

    private var branchesList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(branches, id: \.self) { name in
                    Button {
                        onSelect(.branch(name: name))
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.branch")
                                .foregroundColor(theme.color("fg-muted"))
                            Text(name)
                                .font(.system(size: 12))
                                .foregroundColor(theme.color("fg"))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(theme.color("line").opacity(0.5))
                }
            }
        }
    }
}
