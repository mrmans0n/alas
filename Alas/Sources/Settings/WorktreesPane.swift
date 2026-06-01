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
                SettingsGroup(title: "Sorting") {
                    SettingsRow(
                        name: "Default ordering",
                        desc: "How worktrees are listed in the sidebar. Main is always pinned first. Reordering a repo's worktrees manually overrides this for that repo."
                    ) {
                        Picker("", selection: Binding(
                            get: { state.config.worktrees.defaultOrdering },
                            set: { newValue in
                                state.config.worktrees.defaultOrdering = newValue
                                state.saveConfig()
                                state.projectsManager.reapplyOrderingForAllProjects()
                            }
                        )) {
                            Text("Last update time").tag(AppConfig.WorktreeSortMode.lastUpdateDesc)
                            Text("Creation time").tag(AppConfig.WorktreeSortMode.creationDesc)
                            Text("Branch name").tag(AppConfig.WorktreeSortMode.branchAsc)
                            Text("Manual").tag(AppConfig.WorktreeSortMode.manual)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 240)
                    }
                }
                SettingsGroup(title: "Branch defaults") {
                    SettingsRow(name: "Branch prefix",
                                desc: "Default prefix when creating a new worktree.") {
                        VStack(alignment: .leading, spacing: 2) {
                            AlasField(text: branchPrefixBinding, monospaced: true, inputFilter: .branchPrefix)
                            if let prefixError = branchPrefixError {
                                Text(prefixError)
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    SettingsRow(name: "Base branch",
                                desc: "Default base branch for new worktrees; repo branches can be selected in the create dialog.") {
                        AlasField(text: bind(\.worktrees.baseBranch), monospaced: true)
                    }
                    SettingsRow(name: "Fetch remote before creating worktree",
                                desc: "Runs git fetch for the selected remote base branch before creating the worktree.") {
                        AlasToggle(on: bind(\.worktrees.fetchRemoteBeforeCreate))
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

    private var branchPrefixBinding: Binding<String> {
        Binding(
            get: { state.config.worktrees.branchPrefix },
            set: {
                state.config.worktrees.branchPrefix = $0
                state.saveConfig()
            }
        )
    }

    private var branchPrefixError: String? {
        if state.config.worktrees.branchPrefix.isEmpty {
            return nil
        }
        switch GitNameValidator.validateBranchPrefix(state.config.worktrees.branchPrefix) {
        case .valid:
            return nil
        case .invalid(let message):
            return message
        }
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
