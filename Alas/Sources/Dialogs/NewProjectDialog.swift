import SwiftUI
import AppKit

struct NewProjectDialog: View {
    @Bindable var state: AppState
    @Binding var presented: Bool

    @State private var path: String = ""
    @State private var name: String = ""
    @State private var color: String = "#5fb7c4"
    @State private var isValidating = false
    @State private var errorMessage: String?

    private let palette = ["#5fb7c4", "#c89d6f", "#9789c7", "#7fb978", "#d77b88"]

    var body: some View {
        DialogContainer(
            title: "Add project",
            subtitle: "Register a git repository as an Alas project.",
            content: {
                DialogField(label: "Repository path") {
                    HStack(spacing: 6) {
                        AlasField(text: $path, placeholder: "/path/to/repo", monospaced: true)
                        AlasButton(title: "Choose…", action: choose)
                    }
                }
                DialogField(label: "Display name") {
                    AlasField(text: $name, placeholder: "owner/repo")
                }
                DialogField(label: "Color") {
                    HStack(spacing: 8) {
                        ForEach(palette, id: \.self) { hex in
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
            confirmTitle: isValidating ? "Adding…" : "Add project",
            confirmStyle: .primary,
            onCancel: { presented = false },
            onConfirm: confirm,
            confirmEnabled: !path.isEmpty && !name.isEmpty && !isValidating
        )
        .onChange(of: path) { _, new in
            Task { await suggestName(for: new) }
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
    }
}
