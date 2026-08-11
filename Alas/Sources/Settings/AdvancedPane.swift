import SwiftUI

struct AdvancedPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    @State private var pendingAction: CleanupAction?
    @State private var cleanupMessage: String?
    @State private var isCleaningStaleProjects = false
    /// Mirrors `AppKitDiffScrollerFlag.isEnabled` in observable state.
    /// Reading the flag straight from a `Binding` getter renders the toggle
    /// correctly once but never invalidates this view, so the switch could
    /// keep drawing its old position after the override had already changed.
    @State private var appKitDiffScrollerEnabled = AppKitDiffScrollerFlag.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Advanced").font(.system(size: 18, weight: .semibold))
                Text("Experimental features and destructive maintenance actions.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Experiments") {
                    SettingsRow(
                        name: "Missions",
                        desc: "Shows the experimental Missions interface and resumes its background coordination."
                    ) {
                        AlasToggle(on: Binding(
                            get: { state.missionsEnabled },
                            set: { state.setMissionsEnabled($0) }
                        ))
                    }
                    SettingsRow(
                        name: "AppKit diff scrollers",
                        desc: "Replaces vertical scrolling in diff and review panes with an AppKit-backed scroller. Toggling this re-creates open diff views, so their scroll positions are lost."
                    ) {
                        AlasToggle(on: Binding(
                            get: { appKitDiffScrollerEnabled },
                            set: {
                                appKitDiffScrollerEnabled = $0
                                AppKitDiffScrollerFlag.setOverride($0)
                            }
                        ))
                    }
                }

                SettingsGroup(title: "Cleanup") {
                    SettingsRow(
                        name: "Clear all projects",
                        desc: "Stops tracking every project and closes associated tabs. Files on disk are not deleted."
                    ) {
                        AlasButton(title: "Clear All Projects...", icon: "trash", style: .normal) {
                            pendingAction = .clearAll
                        }
                    }
                    SettingsRow(
                        name: "Clear projects without worktrees",
                        desc: "Refreshes project worktrees, then removes only projects with no worktree entries."
                    ) {
                        AlasButton(title: staleProjectsButtonTitle, icon: "trash", style: .normal) {
                            pendingAction = .clearWithoutWorktrees
                        }
                        .disabled(isCleaningStaleProjects)
                    }
                }

                if let cleanupMessage {
                    Text(cleanupMessage)
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.color("fg-dim"))
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .alert(
            pendingAction?.title ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button(action.destructiveButtonTitle, role: .destructive) {
                run(action)
            }
            Button("Cancel", role: .cancel) {
                pendingAction = nil
            }
        } message: { action in
            Text(action.message(projectCount: state.projects.count))
        }
        .onReceive(
            NotificationCenter.default.publisher(for: AppKitDiffScrollerFlag.overrideDidChangeNotification)
        ) { _ in
            // Keeps the switch honest when the override changes from outside
            // this pane — a `defaults write`, or another window's copy of it.
            appKitDiffScrollerEnabled = AppKitDiffScrollerFlag.isEnabled
        }
    }

    private var staleProjectsButtonTitle: String {
        isCleaningStaleProjects ? "Clearing..." : "Clear Projects Without Worktrees..."
    }

    private func run(_ action: CleanupAction) {
        pendingAction = nil
        switch action {
        case .clearAll:
            let removed = state.clearAllProjects()
            cleanupMessage = removed == 1
                ? "Removed 1 project from Alas."
                : "Removed \(removed) projects from Alas."
        case .clearWithoutWorktrees:
            isCleaningStaleProjects = true
            cleanupMessage = "Refreshing projects..."
            Task { @MainActor in
                let removed = await state.clearProjectsWithoutWorktrees()
                isCleaningStaleProjects = false
                cleanupMessage = removed == 1
                    ? "Removed 1 project without worktrees from Alas."
                    : "Removed \(removed) projects without worktrees from Alas."
            }
        }
    }

    private enum CleanupAction: Identifiable {
        case clearAll
        case clearWithoutWorktrees

        var id: String {
            switch self {
            case .clearAll: return "clearAll"
            case .clearWithoutWorktrees: return "clearWithoutWorktrees"
            }
        }

        var title: String {
            switch self {
            case .clearAll:
                return "Clear all projects?"
            case .clearWithoutWorktrees:
                return "Clear projects without worktrees?"
            }
        }

        var destructiveButtonTitle: String {
            switch self {
            case .clearAll:
                return "Clear All Projects"
            case .clearWithoutWorktrees:
                return "Clear Projects Without Worktrees"
            }
        }

        func message(projectCount: Int) -> String {
            switch self {
            case .clearAll:
                return "Alas will stop tracking all \(projectCount) projects and close associated tabs. No repository or worktree files will be deleted from disk. If editor tabs have unsaved changes, you will be asked to save or discard them."
            case .clearWithoutWorktrees:
                return "Alas will refresh every project, then stop tracking only projects whose Git worktree list is empty. No repository or worktree files will be deleted from disk. If editor tabs have unsaved changes, you will be asked to save or discard them."
            }
        }
    }
}
