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
    @State private var isValidating = false
    @State private var errorMessage: String?

    private let palette = ["#5fb7c4", "#c89d6f", "#9789c7", "#7fb978", "#d77b88"]

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
                    AlasField(text: $name, placeholder: "owner/repo")
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
        case .edit: "Update this project's name and color."
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

    private func populateInitialValues() {
        guard case .edit(let project) = mode else { return }
        path = project.path
        name = project.name
        color = project.color
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
            state.updateProject(id: project.id, name: name, color: color)
            presented = false
        }
    }
}
