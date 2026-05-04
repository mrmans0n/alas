import SwiftUI

struct WorktreesPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Worktrees").font(.system(size: 18, weight: .semibold))
                Text("How Alas creates and manages git worktrees on disk.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Location") {
                    SettingsRow(name: "Worktree root",
                                desc: "All worktrees are created under this directory by default.") {
                        AlasField(text: bind(\.worktrees.rootPath), monospaced: true)
                    }
                    SettingsRow(name: "Path template",
                                desc: "Variables: {repo}, {branch}, {user}, {ts}.") {
                        AlasField(text: bind(\.worktrees.pathTemplate), monospaced: true)
                    }
                }
                SettingsGroup(title: "Branch defaults") {
                    SettingsRow(name: "Branch prefix",
                                desc: "Default prefix when creating a new worktree.") {
                        AlasField(text: bind(\.worktrees.branchPrefix), monospaced: true)
                    }
                    SettingsRow(name: "Base branch",
                                desc: "Branch to fork new worktrees from.") {
                        Seg(value: bind(\.worktrees.baseBranch), options: [
                            ("main", "main"), ("develop", "develop"), ("origin/HEAD", "origin/HEAD")
                        ])
                    }
                    SettingsRow(name: "Track upstream",
                                desc: "Set upstream to origin on first push.") {
                        AlasToggle(on: bind(\.worktrees.trackUpstream))
                    }
                }
                SettingsGroup(title: "Cleanup") {
                    SettingsRow(name: "Delete branch on remove",
                                desc: "When removing a worktree, also delete its local branch if merged.") {
                        AlasToggle(on: bind(\.worktrees.deleteBranchOnRemove))
                    }
                    SettingsRow(name: "Auto fetch",
                                desc: "Periodically fetch from remote in the background.") {
                        AlasToggle(on: bind(\.worktrees.autoFetch))
                    }
                    SettingsRow(name: "Fetch interval (minutes)") {
                        AlasField(text: Binding(
                            get: { String(state.config.worktrees.fetchIntervalMinutes) },
                            set: { state.config.worktrees.fetchIntervalMinutes = Int($0) ?? 5; state.saveConfig() }
                        ), monospaced: true)
                        .frame(width: 80)
                    }
                    SettingsRow(name: "Prune stale worktrees",
                                desc: "Show a warning when a worktree's branch no longer exists upstream.") {
                        AlasToggle(on: bind(\.worktrees.pruneStale))
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }

    private func bind<T>(_ kp: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { state.config[keyPath: kp] },
            set: { state.config[keyPath: kp] = $0; state.saveConfig() }
        )
    }
}
