import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    @State private var iconMode: ProjectIcon.Mode = .letter
    @State private var iconColor: String = ProjectIcon.defaultColor
    @State private var iconLabel: String = ""
    @State private var iconSymbolName: String = "folder"
    @State private var iconEmoji: String = "🚀"
    @State private var iconImagePath: String?
    @State private var pendingProjectId = UUID().uuidString
    @State private var avatarPreset: ProjectAvatarPreset?
    @State private var avatarPresetData: Data?
    @State private var avatarPresetLoading = false
    @State private var avatarPresetError = false
    @State private var avatarPresetRequestId = UUID()
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

    private var draftIcon: ProjectIcon {
        ProjectIcon(
            mode: iconMode,
            color: iconColor,
            label: iconMode == .letter ? iconLabel : nil,
            symbolName: iconMode == .symbol ? iconSymbolName : nil,
            emoji: iconMode == .emoji ? iconEmoji : nil,
            imagePath: iconMode == .image ? iconImagePath : nil
        )
    }

    var body: some View {
        DialogContainer(
            title: title,
            subtitle: subtitle,
            width: DialogContainerLayout.projectWidth,
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
                DialogField(label: "Icon") {
                    projectIconSection
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
        .onAppear {
            populateInitialValues()
            Task { await loadAvatarPresetIfAvailable() }
        }
        .onChange(of: path) { _, new in
            if case .add = mode {
                Task {
                    await suggestName(for: new)
                    await loadAvatarPresetIfAvailable()
                }
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
        palette.contains(iconColor) ? palette : [iconColor] + palette
    }

    private var projectIconSection: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                ProjectIconView(icon: draftIcon, fallbackName: name, size: .dialog)
                HStack(spacing: 8) {
                    ProjectIconView(icon: draftIcon, fallbackName: name, size: .sidebar)
                    ProjectIconView(icon: draftIcon, fallbackName: name, size: .picker)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Seg(value: $iconMode, options: ProjectIcon.Mode.allCases.map { ($0, modeTitle($0)) })
                iconModeControls
                colorControls
            }
        }
    }

    private func modeTitle(_ mode: ProjectIcon.Mode) -> String {
        switch mode {
        case .letter: "Letter"
        case .symbol: "Symbol"
        case .emoji: "Emoji"
        case .image: "Image"
        }
    }

    @ViewBuilder
    private var iconModeControls: some View {
        switch iconMode {
        case .letter:
            AlasField(text: $iconLabel, placeholder: ProjectIcon.fallbackLabel(projectName: name))
                .frame(width: 90)
        case .symbol:
            VStack(alignment: .leading, spacing: 6) {
                AlasField(text: $iconSymbolName, placeholder: "folder")
                symbolQuickChoices
            }
        case .emoji:
            EmojiPickerButton(selection: ProjectIcon.sanitizedEmoji(iconEmoji) ?? "🚀") { emoji in
                iconEmoji = emoji
            }
            .accessibilityLabel("Project icon emoji")
        case .image:
            imageControls
        }
    }

    private var symbolQuickChoices: some View {
        HStack(spacing: 6) {
            ForEach(["folder", "terminal", "sparkle", "github", "gitlab", "commit"], id: \.self) { symbol in
                Button {
                    iconSymbolName = symbol
                } label: {
                    Icon(name: symbol, size: 13, color: theme.color("fg"))
                        .frame(width: 24, height: 24)
                        .background(iconSymbolName == symbol ? theme.color("bg-4") : theme.color("bg-2"))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(symbol)
            }
        }
    }

    private var colorControls: some View {
        HStack(spacing: 8) {
            ForEach(availablePalette, id: \.self) { hex in
                Button { iconColor = hex } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white, lineWidth: iconColor == hex ? 2 : 0))
                }
                .buttonStyle(.plain)
            }
            AlasField(text: $iconColor, placeholder: ProjectIcon.defaultColor, monospaced: true)
                .frame(width: 96)
        }
    }

    private var imageControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlasButton(title: "Choose Image…", icon: "image", action: chooseProjectIconImage)
            if let avatarPreset {
                HStack(spacing: 8) {
                    Text(avatarPreset.label)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-muted"))
                    AlasButton(
                        title: avatarPresetLoading ? "Loading…" : "Use",
                        action: useAvatarPreset
                    )
                    .disabled(avatarPresetData == nil || avatarPresetLoading)
                }
            } else if avatarPresetError {
                Text("Avatar preset unavailable")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-faint"))
            }
        }
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
            iconMode = project.icon.mode
            iconColor = project.icon.color
            iconLabel = project.icon.label ?? ""
            iconSymbolName = project.icon.symbolName ?? "folder"
            iconEmoji = project.icon.emoji ?? "🚀"
            iconImagePath = project.icon.imagePath
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

    private func chooseProjectIconImage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try ProjectIconImageStaging.validateFileSize(at: url)
                let data = try Data(contentsOf: url)
                let staged = try ProjectIconImageStaging.stage(
                    data: data,
                    projectId: existingProjectIdForIconStorage()
                )
                iconImagePath = staged.imagePath
                iconMode = .image
                errorMessage = nil
            } catch let stagingError as ProjectIconImageStaging.StagingError {
                errorMessage = stagingError.userMessage
            } catch {
                errorMessage = "Couldn't load that image. Please try another file."
            }
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

    private func existingProjectIdForIconStorage() -> String {
        if case .edit(let project) = mode { return project.id }
        return pendingProjectId
    }

    private func loadAvatarPresetIfAvailable() async {
        let requestId = UUID()
        avatarPresetRequestId = requestId
        avatarPreset = nil
        avatarPresetData = nil
        avatarPresetError = false
        avatarPresetLoading = false

        guard let repoURL = currentAvatarPresetRepoURL() else { return }
        let requestedPath = repoURL.path

        avatarPresetLoading = true
        defer {
            if avatarPresetRequestId == requestId {
                avatarPresetLoading = false
            }
        }

        do {
            let remotes = try await GitService().remotes(worktreePath: repoURL)
            guard let preset = ProjectAvatarPresetProvider.candidate(from: remotes) else { return }
            let data = try await ProjectAvatarPresetProvider.fetch(preset)
            guard avatarPresetRequestId == requestId,
                  currentAvatarPresetRepoURL()?.path == requestedPath
            else {
                return
            }
            avatarPreset = preset
            avatarPresetData = data
        } catch {
            if avatarPresetRequestId == requestId {
                avatarPresetError = true
            }
        }
    }

    private func currentAvatarPresetRepoURL() -> URL? {
        switch mode {
        case .add:
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        case .edit(let project):
            return URL(fileURLWithPath: project.path)
        }
    }

    private func useAvatarPreset() {
        guard let data = avatarPresetData else { return }
        do {
            let staged = try ProjectIconImageStaging.stage(
                data: data,
                projectId: existingProjectIdForIconStorage()
            )
            iconImagePath = staged.imagePath
            iconMode = .image
            errorMessage = nil
        } catch let stagingError as ProjectIconImageStaging.StagingError {
            errorMessage = stagingError.userMessage
        } catch {
            errorMessage = "Couldn't save that avatar. Please try another image."
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
                    try await state.addProject(
                        path: url,
                        displayName: name,
                        icon: draftIcon,
                        id: pendingProjectId
                    )
                    presented = false
                } catch {
                    errorMessage = error.localizedDescription
                }
                isValidating = false
            }
        case .edit(let project):
            // Preserve fields the dialog doesn't yet edit (the worktree
            // agent override — that lands with the AgentsPane UI later).
            // Without this, hand-set JSON values would be silently wiped
            // every time the user edits an unrelated startup-script field.
            state.updateProject(
                id: project.id,
                name: name,
                icon: draftIcon,
                startupScripts: ProjectStartupScripts(
                    sessionOpenMode: sessionOpenMode,
                    sessionOpenScript: sessionOpenScript,
                    worktreeCreateMode: worktreeCreateMode,
                    worktreeCreateScript: worktreeCreateScript,
                    worktreeAgentMode: project.startupScripts.worktreeAgentMode,
                    worktreeAgentId: project.startupScripts.worktreeAgentId,
                    worktreeAgentUseBypassPermissions: project.startupScripts.worktreeAgentUseBypassPermissions
                )
            )
            presented = false
        }
    }
}
