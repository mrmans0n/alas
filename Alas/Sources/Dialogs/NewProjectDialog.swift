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

private struct SSHConnectionIssue {
    enum Kind: Equatable {
        case needsInteraction
        case nonInteractiveUnavailable
    }

    let kind: Kind
    let detail: String

    var title: String {
        switch kind {
        case .needsInteraction:
            "SSH connection needs attention"
        case .nonInteractiveUnavailable:
            "Non-interactive SSH is unavailable"
        }
    }

    var message: String {
        switch kind {
        case .needsInteraction:
            "Connect in an Alas terminal to accept host keys or complete authentication."
        case .nonInteractiveUnavailable:
            "Alas connected interactively, but the server still rejected the non-interactive channel required for remote projects. The account may require a terminal for every command."
        }
    }
}

private enum SSHSetupStatus: Equatable {
    case connecting
    case verifying
    case failed(String)
    case incompatible(String)
}

private struct ProjectDialog: View {
    @Bindable var state: AppState
    @Binding var presented: Bool
    let mode: ProjectDialogMode
    @Environment(\.theme) var theme

    @State private var path: String = ""
    private enum ProjectLocation: String, CaseIterable {
        case local = "Local"
        case github = "GitHub"
        case gitlab = "GitLab"
        case gitURL = "Git URL"
        case remoteSSH = "SSH"

        var repositoryHost: RepositoryHost? {
            switch self {
            case .github: .github
            case .gitlab: .gitlab
            default: nil
            }
        }

        var clonesRepository: Bool {
            self == .github || self == .gitlab || self == .gitURL
        }
    }
    @State private var location: ProjectLocation = .local
    @State private var sshHost: String = ""
    @State private var showHostPicker = false
    @State private var sshHosts: [SSHConfigHost] = []
    @State private var sshHostsLoading = false
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
    @State private var mcpServers: [ProjectMCPServer] = []
    @State private var mcpManagerPresented = false
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var sshConnectionIssue: SSHConnectionIssue?
    @State private var sshSetupPresented = false
    @State private var sshSetupSurface: AlasGhostty.SurfaceView?
    @State private var sshSetupStatus: SSHSetupStatus = .connecting
    @State private var sshSetupAttemptID = UUID()
    @State private var gitRemote = ""
    @State private var cloneRootPath = ""
    @State private var repositoryCatalogs: [RepositoryHost: [RemoteRepository]] = [:]
    @State private var displayedRepositories: [RemoteRepository] = []
    @State private var selectedRepository: RemoteRepository?
    @State private var repositorySearch = ""
    @State private var repositoryCatalogLoading = false
    @State private var catalogErrorMessage: String?
    @State private var catalogTask: Task<Void, Never>?
    @State private var cloneTask: Task<Void, Never>?

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
                if case .add = mode {
                    DialogField(label: "Location") {
                        Seg(value: $location, options: ProjectLocation.allCases.map { ($0, $0.rawValue) })
                    }
                }
                DialogField(label: locationFieldLabel) {
                    switch mode {
                    case .add:
                        addLocationFields
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
                    Divider().padding(.vertical, 4)
                    integrationsSection
                }
                if let sshConnectionIssue {
                    sshConnectionIssueField(sshConnectionIssue)
                } else if let errorMessage {
                    errorField(errorMessage)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: confirmTitle,
            confirmStyle: .primary,
            onCancel: cancel,
            onConfirm: confirm,
            confirmEnabled: confirmEnabled
        )
        .onAppear {
            populateInitialValues()
            Task { await loadAvatarPresetIfAvailable() }
        }
        .onChange(of: path) { _, new in
            if case .add = mode, location == .local {
                Task {
                    await suggestName(for: new)
                    await loadAvatarPresetIfAvailable()
                }
            }
        }
        .onChange(of: showHostPicker) { _, isOpen in
            if isOpen && sshHosts.isEmpty && !sshHostsLoading {
                loadSSHHosts()
            }
        }
        .onChange(of: sshHost) { _, _ in
            sshConnectionIssue = nil
            errorMessage = nil
        }
        .onChange(of: location) { _, _ in
            sshConnectionIssue = nil
            errorMessage = nil
            catalogErrorMessage = nil
            selectedRepository = nil
            repositorySearch = ""
            displayedRepositories = []
            loadRepositoryCatalogIfNeeded()
        }
        .onChange(of: repositorySearch) { _, _ in
            refreshDisplayedRepositories()
        }
        .onChange(of: gitRemote) { _, remote in
            if let suggested = RepositoryImportService.repositoryName(from: remote), name.isEmpty {
                name = suggested
            }
        }
        .sheet(isPresented: $mcpManagerPresented) {
            ProjectMCPServerManager(servers: $mcpServers)
        }
        .sheet(isPresented: $sshSetupPresented, onDismiss: dismissSSHSetup) {
            SSHConnectionAssistant(
                host: sshHost.trimmingCharacters(in: .whitespacesAndNewlines),
                surface: sshSetupSurface,
                status: sshSetupStatus,
                onCancel: { sshSetupPresented = false },
                onRetry: startSSHSetup
            )
            .environment(\.theme, theme)
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

    private var locationFieldLabel: String {
        switch mode {
        case .edit: "Repository path"
        case .add:
            switch location {
            case .local: "Repository path"
            case .github, .gitlab: "Repository"
            case .gitURL: "Git remote"
            case .remoteSSH: "Remote repository path"
            }
        }
    }

    @ViewBuilder
    private var addLocationFields: some View {
        switch location {
        case .local:
            HStack(spacing: 6) {
                AlasField(text: $path, placeholder: "/path/to/repo", monospaced: true)
                AlasButton(title: "Choose…", action: choose)
            }
        case .github, .gitlab:
            VStack(alignment: .leading, spacing: 8) {
                AlasField(text: $repositorySearch, placeholder: "Search repositories")
                repositoryCatalog
                cloneFolderField
            }
        case .gitURL:
            VStack(alignment: .leading, spacing: 8) {
                AlasField(text: $gitRemote, placeholder: "https://host/team/repo.git or git@host:team/repo.git", monospaced: true)
                cloneFolderField
            }
        case .remoteSSH:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    AlasField(text: $sshHost, placeholder: "devbox or user@host", monospaced: true)
                    Button(action: { showHostPicker.toggle() }) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.color("fg-dim"))
                            .frame(width: 30, height: 28)
                            .background(theme.color("bg-2"))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(theme.color("line"), lineWidth: 0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Choose a host from ~/.ssh/config")
                    .accessibilityLabel("Choose SSH host")
                    .popover(isPresented: $showHostPicker, arrowEdge: .bottom) {
                        SSHHostPicker(
                            host: $sshHost,
                            hosts: sshHosts,
                            isLoading: sshHostsLoading,
                            isPresented: $showHostPicker
                        )
                    }
                }
                AlasField(text: $path, placeholder: "/home/me/repo", monospaced: true)
            }
        }
    }

    private var repositoryCatalog: some View {
        Group {
            if repositoryCatalogLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading repositories…")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-muted"))
                }
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else if let catalogErrorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(catalogErrorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                    AlasButton(title: "Retry", action: { loadRepositoryCatalog(force: true) })
                }
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            } else if displayedRepositories.isEmpty {
                Text(repositorySearch.isEmpty ? "No repositories found." : "No matching repositories.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-muted"))
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(displayedRepositories) { repository in
                            repositoryRow(repository)
                        }
                    }
                }
                .frame(height: 150)
            }
        }
        .padding(6)
        .background(theme.color("bg-1"))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func repositoryRow(_ repository: RemoteRepository) -> some View {
        let selected = selectedRepository?.id == repository.id
        return Button {
            selectedRepository = repository
            name = repository.name
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repository.fullName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                    Text([repository.visibility, repository.isArchived ? "Archived" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.color("fg-muted"))
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundColor(theme.color("accent"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? theme.color("bg-3") : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(repository.fullName), \(repository.visibility)\(repository.isArchived ? ", archived" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var cloneFolderField: some View {
        HStack(spacing: 6) {
            Text("Clone into")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-muted"))
            AlasField(text: $cloneRootPath, placeholder: "Choose on first clone", monospaced: true)
            AlasButton(title: "Choose…", action: chooseCloneFolder)
        }
    }

    private var confirmTitle: String {
        switch mode {
        case .add:
            if location.clonesRepository {
                isValidating ? "Cloning…" : "Clone and add"
            } else {
                isValidating ? "Adding…" : "Add project"
            }
        case .edit: "Save changes"
        }
    }

    private var confirmEnabled: Bool {
        switch mode {
        case .add:
            let hasLocation: Bool
            switch location {
            case .local:
                hasLocation = !path.isEmpty
            case .github, .gitlab:
                hasLocation = selectedRepository != nil
            case .gitURL:
                hasLocation = RepositoryImportService.repositoryName(from: gitRemote) != nil
            case .remoteSSH:
                hasLocation = !sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && path.hasPrefix("/")
            }
            return hasLocation && !name.isEmpty && !isValidating
        case .edit:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private func sshConnectionIssueField(_ issue: SSHConnectionIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.kind == .needsInteraction ? "terminal" : "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(issue.kind == .needsInteraction ? theme.color("accent") : .red)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.color("fg"))
                    Text(issue.message)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-muted"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if issue.kind == .needsInteraction {
                    AlasButton(
                        title: "Connect",
                        icon: "terminal",
                        style: .primary,
                        action: startSSHSetup
                    )
                }
            }
            if !issue.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup("SSH details") {
                    copyableSSHDetail(issue.detail)
                        .padding(.top, 6)
                }
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            }
        }
        .padding(10)
        .background(theme.color("bg-0"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func copyableSSHDetail(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(detail.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(theme.color("fg-muted"))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: { copyToPasteboard(detail) }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .buttonStyle(.plain)
            .help("Copy SSH details")
            .accessibilityLabel("Copy SSH details")
        }
    }

    private func errorField(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: {
                copyToPasteboard(message)
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .buttonStyle(.plain)
            .help("Copy error")
            .accessibilityLabel("Copy error message")
        }
        .padding(8)
        .background(theme.color("bg-0"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
                    ProjectStartupScriptEditor(
                        text: $sessionOpenScript,
                        minHeight: 60
                    )
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Worktree create script")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.color("fg"))
                Seg(value: $worktreeCreateMode, options: startupOptions)
                if worktreeCreateMode == .appendToGlobal || worktreeCreateMode == .overrideGlobal {
                    ProjectStartupScriptEditor(
                        text: $worktreeCreateScript,
                        minHeight: 60
                    )
                }
            }
        }
    }

    private var integrationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Integrations")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            HStack(spacing: 8) {
                Text(mcpServers.isEmpty ? "No MCP servers configured" : "\(mcpServers.count) MCP server\(mcpServers.count == 1 ? "" : "s") configured")
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.color("fg-dim"))
                Spacer()
                AlasButton(title: "Manage MCP Servers…", icon: "slider", action: {
                    mcpManagerPresented = true
                })
            }
        }
    }

    private func populateInitialValues() {
        switch mode {
        case .add:
            cloneRootPath = state.config.repositoryCloneRootPath
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
            mcpServers = project.mcpServers
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

    private func chooseCloneFolder() {
        _ = pickCloneFolder()
    }

    private func pickCloneFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        cloneRootPath = url.path
        if state.config.repositoryCloneRootPath.isEmpty {
            state.config.repositoryCloneRootPath = url.path
            state.saveConfig()
        }
        return url
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

    private func loadSSHHosts() {
        sshHostsLoading = true
        Task {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let parsed = await Task.detached { SSHConfigParser.parse(home: home) }.value
            sshHosts = parsed
            sshHostsLoading = false
        }
    }

    private func loadRepositoryCatalogIfNeeded() {
        guard let host = location.repositoryHost else { return }
        if let repositories = repositoryCatalogs[host] {
            showCachedRepositoryCatalog(repositories)
        } else {
            loadRepositoryCatalog(force: false)
        }
    }

    private func loadRepositoryCatalog(force: Bool) {
        guard let host = location.repositoryHost else { return }
        if !force, let repositories = repositoryCatalogs[host] {
            showCachedRepositoryCatalog(repositories)
            return
        }
        catalogTask?.cancel()
        repositoryCatalogLoading = true
        catalogErrorMessage = nil
        catalogTask = Task {
            do {
                let repositories = try await RepositoryImportService().repositories(for: host)
                guard !Task.isCancelled, location.repositoryHost == host else { return }
                repositoryCatalogs[host] = repositories
                displayedRepositories = RepositoryImportService.filter(repositories, query: repositorySearch)
            } catch {
                guard !Task.isCancelled, location.repositoryHost == host else { return }
                catalogErrorMessage = error.localizedDescription
            }
            if location.repositoryHost == host {
                repositoryCatalogLoading = false
            }
        }
    }

    private func showCachedRepositoryCatalog(_ repositories: [RemoteRepository]) {
        catalogTask?.cancel()
        catalogTask = nil
        repositoryCatalogLoading = false
        catalogErrorMessage = nil
        displayedRepositories = RepositoryImportService.filter(repositories, query: repositorySearch)
    }

    private func refreshDisplayedRepositories() {
        guard let host = location.repositoryHost, let repositories = repositoryCatalogs[host] else { return }
        displayedRepositories = RepositoryImportService.filter(repositories, query: repositorySearch)
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
            if location.clonesRepository && cloneRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard pickCloneFolder() != nil else { return }
            }
            if location.clonesRepository && state.config.repositoryCloneRootPath.isEmpty {
                state.config.repositoryCloneRootPath = cloneRootPath
                state.saveConfig()
            }
            isValidating = true
            errorMessage = nil
            sshConnectionIssue = nil
            cloneTask = Task {
                if location.clonesRepository {
                    await cloneAndAddProject()
                } else {
                    await addProject(afterInteractiveSetup: false)
                }
                isValidating = false
                cloneTask = nil
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
                ),
                mcpServers: mcpServers
            )
            presented = false
        }
    }

    private func cloneAndAddProject() async {
        let source: RepositoryCloneSource
        let repositoryName: String
        switch location {
        case .github:
            guard let repository = selectedRepository else { return }
            source = .github(repository.fullName)
            repositoryName = repository.name
        case .gitlab:
            guard let repository = selectedRepository else { return }
            source = .gitlab(repository.fullName)
            repositoryName = repository.name
        case .gitURL:
            guard let derivedName = RepositoryImportService.repositoryName(from: gitRemote) else { return }
            source = .gitURL(gitRemote.trimmingCharacters(in: .whitespacesAndNewlines))
            repositoryName = derivedName
        case .local, .remoteSSH:
            return
        }

        let expandedRoot = NSString(string: cloneRootPath).expandingTildeInPath
        let destination = URL(fileURLWithPath: expandedRoot, isDirectory: true)
            .appendingPathComponent(repositoryName, isDirectory: true)
        do {
            try await RepositoryImportService().clone(source, to: destination)
            if Task.isCancelled { return }
            path = destination.path
            do {
                try await state.addProject(
                    path: destination,
                    displayName: name,
                    icon: draftIcon,
                    id: pendingProjectId
                )
                presented = false
            } catch {
                errorMessage = "Cloned to \(destination.path), but Alas couldn't add the project: \(error.localizedDescription)"
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancel() {
        catalogTask?.cancel()
        cloneTask?.cancel()
        presented = false
    }

    private func addProject(afterInteractiveSetup: Bool) async {
        do {
            let url = URL(fileURLWithPath: path)
            try await state.addProject(
                path: url,
                displayName: name,
                icon: draftIcon,
                host: location == .remoteSSH
                    ? sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil,
                id: pendingProjectId
            )
            sshSetupPresented = false
            presented = false
        } catch let validationError as RemoteRepoValidationError {
            switch validationError {
            case .connectionFailed(let detail):
                let issue = SSHConnectionIssue(
                    kind: afterInteractiveSetup ? .nonInteractiveUnavailable : .needsInteraction,
                    detail: detail
                )
                sshConnectionIssue = issue
                if afterInteractiveSetup {
                    sshSetupStatus = .incompatible(issue.message)
                }
            case .notARepository:
                sshConnectionIssue = nil
                errorMessage = validationError.localizedDescription
                sshSetupPresented = false
            }
        } catch {
            sshConnectionIssue = nil
            errorMessage = error.localizedDescription
            sshSetupPresented = false
        }
    }

    private func startSSHSetup() {
        let host = sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }

        let attemptID = UUID()
        sshSetupAttemptID = attemptID
        sshSetupStatus = .connecting
        errorMessage = nil
        let invocation = RemoteRepoValidator.interactiveSetupInvocation(host: host)
        do {
            sshSetupSurface = try state.terminal.makeTransientSurface(
                cfg: state.config.terminal,
                theme: theme,
                executable: invocation.executable,
                args: invocation.args,
                onExit: {
                    Task { @MainActor in
                        handleSSHSetupExit(attemptID: attemptID, host: host)
                    }
                }
            )
            sshSetupPresented = true
        } catch {
            sshConnectionIssue = nil
            errorMessage = "Could not open the SSH connection terminal: \(error.localizedDescription)"
        }
    }

    private func handleSSHSetupExit(attemptID: UUID, host: String) {
        guard sshSetupAttemptID == attemptID, sshSetupStatus == .connecting else { return }
        sshSetupStatus = .verifying
        Task {
            let connected = await RemoteRepoValidator.waitForActiveControlMaster(host: host)
            guard sshSetupAttemptID == attemptID else { return }
            guard connected else {
                sshSetupStatus = .failed(
                    "SSH did not establish a reusable connection. Review the terminal output and retry."
                )
                return
            }
            isValidating = true
            await addProject(afterInteractiveSetup: true)
            isValidating = false
        }
    }

    private func dismissSSHSetup() {
        sshSetupAttemptID = UUID()
        sshSetupSurface?.processExitHandler = nil
        sshSetupSurface = nil
        if sshSetupStatus == .verifying {
            sshSetupStatus = .connecting
        }
    }
}

struct ProjectStartupScriptEditor: View {
    @Binding var text: String
    let minHeight: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        PairedTextEditor(
            text: $text,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            textColor: NSColor(theme.color("fg"))
        )
        .frame(minHeight: minHeight)
        .padding(8)
        .background(theme.color("bg-0"))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }
}

private struct SSHConnectionAssistant: View {
    let host: String
    let surface: AlasGhostty.SurfaceView?
    let status: SSHSetupStatus
    let onCancel: () -> Void
    let onRetry: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        DialogContainer(
            title: "Connect to \(host)",
            subtitle: "Complete the SSH prompts below. Alas will continue when the connection is ready.",
            width: 760,
            content: {
                Group {
                    if let surface {
                        GhosttyHost(surface: surface)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 380)
                .background(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))

                statusView
            },
            cancelTitle: "Cancel",
            confirmTitle: confirmTitle,
            confirmStyle: confirmEnabled ? .primary : .normal,
            onCancel: onCancel,
            onConfirm: confirmAction,
            confirmEnabled: confirmEnabled
        )
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .connecting:
            Label("Waiting for SSH", systemImage: "terminal")
                .foregroundColor(theme.color("fg-muted"))
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying the non-interactive connection…")
            }
            .foregroundColor(theme.color("fg-muted"))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
        case .incompatible(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
        }
    }

    private var confirmTitle: String {
        switch status {
        case .failed: "Retry"
        case .incompatible: "Close"
        case .connecting, .verifying: "Waiting…"
        }
    }

    private var confirmEnabled: Bool {
        switch status {
        case .failed, .incompatible: true
        case .connecting, .verifying: false
        }
    }

    private func confirmAction() {
        switch status {
        case .failed: onRetry()
        case .incompatible: onCancel()
        case .connecting, .verifying: break
        }
    }
}
