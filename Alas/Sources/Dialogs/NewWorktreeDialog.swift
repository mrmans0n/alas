import SwiftUI

struct NewWorktreeDialog: View {
    @Bindable var state: AppState
    @Binding var presented: Bool

    @State private var projectId: String = ""
    // Defaults are seeded from the persisted Worktrees settings in .onAppear
    // (these literals are placeholders only — the real defaults come from
    // state.config.worktrees.{baseBranch,branchPrefix}).
    @State private var base: String = ""
    @State private var branch: String = ""
    @State private var pathOverride: String = ""
    @State private var runStartup: Bool = true
    @State private var openTerminal: Bool = true
    @State private var isCreating = false
    @State private var errorMessage: String?

    @Environment(\.theme) var theme

    var body: some View {
        DialogContainer(
            title: "New worktree",
            subtitle: subtitleText,
            content: {
                DialogField(label: "Repository") {
                    if state.projects.isEmpty {
                        Text("No projects yet — add one first.").font(.system(size: 12))
                            .foregroundColor(theme.color("fg-dim"))
                    } else {
                        Seg(value: $projectId,
                            options: state.projects.map { ($0.id, $0.name) })
                    }
                }
                DialogField(label: "Base branch") {
                    Seg(value: $base, options: [
                        ("main", "main"), ("develop", "develop"), ("origin/HEAD", "origin/HEAD")
                    ])
                }
                DialogField(label: "Branch name") {
                    AlasField(text: $branch, monospaced: true)
                }
                DialogField(label: "Path on disk") {
                    AlasField(text: Binding(
                        get: { pathOverride.isEmpty ? renderedPath : pathOverride },
                        set: { pathOverride = $0 }
                    ), monospaced: true)
                }
                HStack(spacing: 10) {
                    AlasToggle(on: $runStartup)
                    Text("Run startup script after create").font(.system(size: 12))
                        .foregroundColor(theme.color("fg"))
                }
                HStack(spacing: 10) {
                    AlasToggle(on: $openTerminal)
                    Text("Open in new terminal pane").font(.system(size: 12))
                        .foregroundColor(theme.color("fg"))
                }
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 11)).foregroundColor(.red)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: isCreating ? "Creating…" : "Create worktree",
            confirmStyle: .primary,
            onCancel: { presented = false },
            onConfirm: create,
            confirmEnabled: !state.projects.isEmpty && !branch.isEmpty && !isCreating
        )
        .onAppear {
            if projectId.isEmpty {
                projectId = state.projects.first?.id ?? ""
            }
            if base.isEmpty {
                base = state.config.worktrees.baseBranch
            }
            if branch.isEmpty {
                branch = state.config.worktrees.branchPrefix
            }
        }
    }

    private var subtitleText: String {
        guard let project = state.projects.first(where: { $0.id == projectId }) else {
            return "Create a worktree."
        }
        return "Create a worktree in \(project.name) branched from \(base)."
    }

    private var renderedPath: String {
        guard let project = state.projects.first(where: { $0.id == projectId }) else { return "" }
        let template = state.config.worktrees.pathTemplate
            .replacingOccurrences(of: "{worktreeRoot}", with: state.config.worktrees.rootPath)
            .replacingOccurrences(of: "{repo}", with: project.name.split(separator: "/").last.map(String.init) ?? "repo")
            .replacingOccurrences(of: "{branch}", with: branch.replacingOccurrences(of: "/", with: "-"))
            .replacingOccurrences(of: "{user}", with: NSUserName())
            .replacingOccurrences(of: "{ts}", with: ISO8601DateFormatter().string(from: Date()))
        return (template as NSString).expandingTildeInPath
    }

    private func create() {
        guard let project = state.projects.first(where: { $0.id == projectId }) else { return }
        isCreating = true
        errorMessage = nil
        let runStartupAfter = runStartup
        let openTerminalAfter = openTerminal
        Task {
            do {
                let svc = WorktreeService()
                let dest = URL(fileURLWithPath: pathOverride.isEmpty ? renderedPath : pathOverride)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let newWorktree = try await svc.add(
                    repoPath: URL(fileURLWithPath: project.path),
                    base: base, branch: branch, destination: dest, projectId: project.id
                )
                try await state.projectsManager.refreshWorktrees(projectId: project.id)

                // Run worktree-create script if requested. Best-effort: errors
                // in the user-supplied script don't roll back the worktree.
                if runStartupAfter {
                    let script = state.config.terminal.worktreeCreateScript
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !script.isEmpty {
                        _ = try? await Process.run(
                            "/bin/zsh",
                            args: ["-c", script],
                            cwd: newWorktree.path
                        )
                    }
                }

                // Auto-select the new worktree + open a terminal tab if asked.
                state.selectedWorktreeId = newWorktree.id
                if openTerminalAfter {
                    _ = try? state.openTerminalTab(for: newWorktree)
                }
                presented = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isCreating = false
        }
    }
}
