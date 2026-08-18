import SwiftUI

struct FileHistoryTabView: View {
    let worktreePath: URL
    let state: FileHistoryTabState
    let onSelectCommit: (CommitInfo) -> Void
    let onCopySHA: (CommitInfo) -> Void
    var onStartupRecoveryReady: () -> Void = {}

    @Environment(\.theme) private var theme
    @State private var commits: [CommitInfo] = []
    @State private var loaded = false
    @State private var error: String?
    private let git = GitService()

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .task(id: loadKey) {
            await load()
            onStartupRecoveryReady()
        }
    }

    private var loadKey: String {
        "\(worktreePath.path)\u{0}\(state.relativePath)"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text((state.relativePath as NSString).lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color("fg"))

            Text("History")
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.color("accent").opacity(0.14))
                .foregroundColor(theme.color("accent"))
                .clipShape(RoundedRectangle(cornerRadius: 3))

            if !directoryPath.isEmpty {
                Text("·")
                    .foregroundColor(theme.color("fg-faint"))
                Text(directoryPath)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
    }

    private var directoryPath: String {
        (state.relativePath as NSString).deletingLastPathComponent
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(spacing: 8) {
                Text("Could not load file history")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.color("del"))
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                AlasButton(title: "Retry", style: .subtle) {
                    Task { await load() }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !loaded {
            Spinner()
                .frame(width: 20, height: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if commits.isEmpty {
            Text("No committed history for \(state.relativePath)")
                .font(.system(size: 13))
                .foregroundColor(theme.color("fg-dim"))
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                        CommitRow(
                            commit: commit,
                            isLast: index == commits.count - 1,
                            onSelect: { onSelectCommit(commit) },
                            onCopySHA: { onCopySHA(commit) }
                        )
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private func load() async {
        loaded = false
        error = nil
        do {
            let history = try await git.fileHistory(
                worktreePath: worktreePath,
                relativePath: state.relativePath,
                limit: 200
            )
            guard !Task.isCancelled else { return }
            commits = history
            loaded = true
        } catch {
            guard !Task.isCancelled else { return }
            commits = []
            self.error = (error as NSError).localizedDescription
            loaded = true
        }
    }
}
