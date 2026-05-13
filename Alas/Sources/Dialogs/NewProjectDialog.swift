import SwiftUI
import AppKit

struct NewProjectDialog: View {
    @Bindable var state: AppState
    @Binding var presented: Bool

    var body: some View {
        ProjectDialog(state: state, presented: $presented, mode: .add)
    }
}

struct EditProjectDialog: View {
    @Bindable var state: AppState
    @Binding var presented: Bool
    let project: ProjectConfig

    var body: some View {
        ProjectDialog(state: state, presented: $presented, mode: .edit(project))
    }
}

private enum ProjectDialogMode {
    case add
    case edit(ProjectConfig)
}

private struct ProjectDialog: View {
    @Bindable var state: AppState
    @Binding var presented: Bool
    let mode: ProjectDialogMode
    @Environment(\.theme) var theme

    @State private var path: String = ""
    @State private var name: String = ""
    @State private var color: String = "#5fb7c4"
    @State private var sessionOpenMode: ProjectStartupScriptMode = .useGlobal
    @State private var sessionOpenScript: String = ""
    @State private var worktreeCreateMode: ProjectStartupScriptMode = .useGlobal
    @State private var worktreeCreateScript: String = ""
    @State private var isValidating = false
    @State private var errorMessage: String?

    private let palette = [
        "#5fb7c4", "#c89d6f", "#9789c7", "#7fb978", "#d77b88",
        "#6f9bd1", "#e0b86f", "#b87fc4", "#7fc4b0", "#c4b87f",
        "#d49960", "#8fb4d4",
    ]

    private let startupOptions: [(ProjectStartupScriptMode, String)] = [
        (.useGlobal, "Use global"),
        (.appendToGlobal, "Append to global"),
        (.overrideGlobal, "Override global"),
        (.disabled, "Disabled"),
    ]

    var body: some View {
        DialogContainer(
            title: title,
            subtitle: subtitle,
            content: {
                DialogField(label: "Repository path") {
                    switch mode {
                    case .add:
                        HStack(spacing: 6) {
                            AlasField(text: $path, placeholder: "/path/to/repo", monospaced: true)
                            AlasButton(title: "Choose…", action: choose)
                        }
                    case .edit:
                        readOnlyPath
                    }
                }
                DialogField(label: "Display name") {
                    AlasField(text: $name, placeholder: "repo-folder")
                }
                DialogField(label: "Color") {
                    HStack(spacing: 8) {
                        ForEach(availablePalette, id: \.self) { hex in
                            Button { color = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle().strokeBorder(.white, lineWidth: color == hex ? 2 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if case .edit = mode {
                    Divider().padding(.vertical, 4)
                    startupScriptsSection
                }
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 11)).foregroundColor(.red)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: confirmTitle,
            confirmStyle: .primary,
            onCancel: { presented = false },
            onConfirm: confirm,
            confirmEnabled: confirmEnabled
        )
        .onAppear(perform: populateInitialValues)
        .onChange(of: path) { _, new in
            if case .add = mode {
                Task { await suggestName(for: new) }
            }
        }
    }

    private var title: String {
        switch mode {
        case .add: "Add project"
        case .edit: "Edit project"
        }
    }

    private var subtitle: String {
        switch mode {
        case .add: "Register a git repository as an Alas project."
        case .edit: "Update this project's settings."
        }
    }

    private var confirmTitle: String {
        switch mode {
        case .add: isValidating ? "Adding…" : "Add project"
        case .edit: "Save changes"
        }
    }

    private var confirmEnabled: Bool {
        switch mode {
        case .add:
            !path.isEmpty && !name.isEmpty && !isValidating
        case .edit:
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var availablePalette: [String] {
        palette.contains(color) ? palette : [color] + palette
    }

    private var readOnlyPath: some View {
        Text(path)
            .foregroundColor(theme.color("fg"))
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(theme.color("bg-1"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var startupScriptsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Startup scripts")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            VStack(alignment: .leading, spacing: 8) {
                Text("Session open script")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.color("fg"))
                Seg(value: $sessionOpenMode, options: startupOptions)
                if sessionOpenMode == .appendToGlobal || sessionOpenMode == .overrideGlobal {
                    TextEditor(text: $sessionOpenScript)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.color("fg"))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60)
                        .padding(8)
                        .background(theme.color("bg-0"))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Worktree create script")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.color("fg"))
                Seg(value: $worktreeCreateMode, options: startupOptions)
                if worktreeCreateMode == .appendToGlobal || worktreeCreateMode == .overrideGlobal {
                    TextEditor(text: $worktreeCreateScript)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.color("fg"))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60)
                        .padding(8)
                        .background(theme.color("bg-0"))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
                }
            }
        }
    }

    private func populateInitialValues() {
        switch mode {
        case .add:
            break
        case .edit(let project):
            path = project.path
            name = project.name
            color = project.color
            sessionOpenMode = project.startupScripts.sessionOpenMode
            sessionOpenScript = project.startupScripts.sessionOpenScript
            worktreeCreateMode = project.startupScripts.worktreeCreateMode
            worktreeCreateScript = project.startupScripts.worktreeCreateScript
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func suggestName(for newPath: String) async {
        guard !newPath.isEmpty else { return }
        let url = URL(fileURLWithPath: newPath)
        let svc = GitService()
        if (try? await svc.isGitRepository(url)) == true {
            if let suggested = try? await svc.suggestProjectName(url), name.isEmpty {
                name = suggested
            }
        }
    }

    private func confirm() {
        switch mode {
        case .add:
            isValidating = true
            errorMessage = nil
            Task {
                do {
                    let url = URL(fileURLWithPath: path)
                    try await state.addProject(path: url, displayName: name, color: color)
                    presented = false
                } catch {
                    errorMessage = error.localizedDescription
                }
                isValidating = false
            }
        case .edit(let project):
            state.updateProject(
                id: project.id,
                name: name,
                color: color,
                startupScripts: ProjectStartupScripts(
                    sessionOpenMode: sessionOpenMode,
                    sessionOpenScript: sessionOpenScript,
                    worktreeCreateMode: worktreeCreateMode,
                    worktreeCreateScript: worktreeCreateScript
                )
            )
            presented = false
        }
    }
}
