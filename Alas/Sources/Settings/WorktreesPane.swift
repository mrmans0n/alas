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
                }
                // trackUpstream / autoFetch / fetchIntervalMinutes / pruneStale
                // are persisted in AppConfig but no creation or background-sync
                // path consumes them yet. They'll come back here when the
                // worktree automation lands; rendering them now would mislead
                // users into thinking the toggles do anything.
                SettingsGroup(title: "Cleanup") {
                    SettingsRow(name: "Delete branch on remove",
                                desc: "When removing a worktree, also delete its local branch if merged.") {
                        AlasToggle(on: bind(\.worktrees.deleteBranchOnRemove))
                    }
                }

                if hasAnyArchived {
                    SettingsGroup(title: "Archived worktrees") {
                        ForEach(state.projects) { project in
                            let archived = state.projectsManager.archivedWorktrees(projectId: project.id)
                            if !archived.isEmpty {
                                ArchivedProjectSection(project: project, archived: archived) { wt in
                                    state.unarchiveWorktree(projectId: project.id, path: wt.path)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }

    private var hasAnyArchived: Bool {
        state.projects.contains { !state.projectsManager.archivedWorktrees(projectId: $0.id).isEmpty }
    }

    private func bind<T>(_ kp: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { state.config[keyPath: kp] },
            set: { state.config[keyPath: kp] = $0
            state.saveConfig() }
        )
    }
}

private struct ArchivedProjectSection: View {
    let project: ProjectConfig
    let archived: [Worktree]
    let onUnarchive: (Worktree) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
                .padding(.top, 4)
            ForEach(archived) { wt in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wt.branch)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.color("fg"))
                        Text(wt.path.path)
                            .font(.system(size: 11))
                            .foregroundColor(theme.color("fg-dim"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    AlasButton(title: "Unarchive", style: .normal) { onUnarchive(wt) }
                }
                .padding(.vertical, 6)
            }
        }
    }
}
