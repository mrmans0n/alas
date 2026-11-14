import SwiftUI
import AppKit

/// Settings → Machines: the SSH machines offered as places to run worktrees.
struct MachinesPane: View {
    @Environment(\.designScale) private var scale
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    @ObservedObject private var hostStatus = RemoteHostStatusStore.shared
    @State private var editor: MachineEditorTarget?
    @State private var configHosts: [SSHConfigHost] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Machines")
                    .font(SettingsPaneStyle.titleFont)
                Text("SSH machines you can run worktrees on.")
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, scale.space[3])

                SettingsGroup(title: "Machines") {
                    if state.config.machines.isEmpty {
                        SettingsRow(name: "No machines yet.") { EmptyView() }
                        ForEach(unlistedConfigHosts) { host in
                            SettingsRow(name: host.alias, desc: host.hostName) {
                                AlasButton(title: "Add", icon: "plus", style: .normal) {
                                    editor = .add(destination: host.alias)
                                }
                            }
                        }
                    }
                    ForEach(state.config.machines) { machine in
                        machineRow(machine)
                    }
                    SettingsRow(name: "Add machine", desc: "Any host you can reach with ssh.") {
                        AlasButton(title: "Add Machine…", icon: "plus", style: .normal) {
                            editor = .add(destination: "")
                        }
                    }
                }

                HStack(spacing: scale.space[2]) {
                    Button("Open ~/.ssh/config") {
                        NSWorkspace.shared.open(
                            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
                        )
                    }
                    .buttonStyle(.link)
                    Text("User, port, identity, and jump host come from your SSH config.")
                        .foregroundColor(theme.color("fg-dim"))
                }
                .font(scale.metaFont)
                .padding(.top, scale.space[2])
            }
            .padding(.horizontal, scale.space[5])
            .padding(.vertical, scale.space[5])
        }
        .task { await loadConfigHosts() }
        .sheet(item: $editor) { target in
            MachineEditor(state: state, target: target) { editor = nil }
                .environment(\.theme, theme)
        }
    }

    private var unlistedConfigHosts: [SSHConfigHost] {
        let listed = Set(state.config.machines.map(\.destination))
        return configHosts.filter { !listed.contains($0.alias) }
    }

    private func machineRow(_ machine: Machine) -> some View {
        let projectCount = state.projects.filter { $0.host == machine.destination }.count
        return SettingsRow(
            name: machine.label,
            desc: "\(machine.destination) · \(machine.projectsFolder) · \(projectCount) project\(projectCount == 1 ? "" : "s")"
        ) {
            HStack(spacing: scale.space[2]) {
                Circle()
                    .fill(reachabilityColor(machine.destination))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(reachabilityLabel(machine.destination))
                AlasButton(title: "Edit…", style: .subtle) {
                    editor = .edit(machine)
                }
                AlasButton(title: "Remove", style: .subtle) {
                    state.config.machines.removeAll { $0.destination == machine.destination }
                    _ = state.saveConfig()
                }
            }
        }
    }

    private func reachabilityColor(_ host: String) -> Color {
        switch hostStatus.reachability(for: host) {
        case .online: .green
        case .offline: .red
        case .unknown: theme.color("fg-faint")
        }
    }

    private func reachabilityLabel(_ host: String) -> String {
        switch hostStatus.reachability(for: host) {
        case .online: "Online"
        case .offline: "Offline"
        case .unknown: "Not checked yet"
        }
    }

    private func loadConfigHosts() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configHosts = await Task.detached { SSHConfigParser.parse(home: home) }.value
    }
}

private enum MachineEditorTarget: Identifiable {
    case add(destination: String)
    case edit(Machine)

    var id: String {
        switch self {
        case .add(let destination): "add:\(destination)"
        case .edit(let machine): "edit:\(machine.destination)"
        }
    }
}

private struct MachineEditor: View {
    @Environment(\.designScale) private var scale
    @Bindable var state: AppState
    let target: MachineEditorTarget
    let onClose: () -> Void
    @Environment(\.theme) var theme

    @State private var destination: String
    @State private var label: String
    @State private var projectsFolder: String
    @State private var showHostPicker = false
    @State private var configHosts: [SSHConfigHost] = []
    @State private var configHostsLoading = true
    @State private var checkMessage: (text: String, isError: Bool)?
    @State private var isChecking = false
    @State private var sshSetup = SSHConnectionSetup()

    init(state: AppState, target: MachineEditorTarget, onClose: @escaping () -> Void) {
        self.state = state
        self.target = target
        self.onClose = onClose
        switch target {
        case .add(let destination):
            _destination = State(initialValue: destination)
            _label = State(initialValue: "")
            _projectsFolder = State(initialValue: Machine.defaultProjectsFolder(
                cloneRoot: state.config.repositoryCloneRootPath
            ))
        case .edit(let machine):
            _destination = State(initialValue: machine.destination)
            _label = State(initialValue: machine.label)
            _projectsFolder = State(initialValue: machine.projectsFolder)
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var trimmedDestination: String { destination.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedFolder: String { projectsFolder.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        RemotePath.isValidHost(trimmedDestination)
            && !trimmedFolder.isEmpty
            && (isEditing || !state.config.machines.contains { $0.destination == trimmedDestination })
    }

    var body: some View {
        DialogContainer(
            title: isEditing ? "Edit Machine" : "Add Machine",
            subtitle: "Alas connects with your ssh configuration.",
            content: {
                VStack(alignment: .leading, spacing: scale.space[3]) {
                    field("Destination") { destinationField }
                    field("Label") { AlasField(text: $label, placeholder: trimmedDestination) }
                    field("Projects folder") {
                        AlasField(text: $projectsFolder, placeholder: "~/code", monospaced: true)
                    }
                    HStack(spacing: scale.space[2]) {
                        AlasButton(title: isChecking ? "Testing…" : "Test", icon: "bolt.horizontal", style: .normal) {
                            Task { await test() }
                        }
                        .disabled(isChecking || !RemotePath.isValidHost(trimmedDestination) || trimmedFolder.isEmpty)
                        if let checkMessage {
                            Text(checkMessage.text)
                                .font(scale.metaFont)
                                .foregroundColor(checkMessage.isError ? .red : theme.color("fg-muted"))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: "Save",
            confirmStyle: .primary,
            onCancel: onClose,
            onConfirm: save,
            confirmEnabled: canSave
        )
        .task { await loadConfigHosts() }
        .sheet(isPresented: $sshSetup.isPresented, onDismiss: sshSetup.dismiss) {
            SSHConnectionAssistant(
                host: trimmedDestination,
                surface: sshSetup.surface,
                status: sshSetup.status,
                onCancel: { sshSetup.isPresented = false },
                onRetry: startSSHSetup
            )
            .environment(\.theme, theme)
        }
    }

    @ViewBuilder
    private var destinationField: some View {
        if isEditing {
            Text(trimmedDestination)
                .font(scale.bodyFont.monospaced())
                .foregroundColor(theme.color("fg-muted"))
        } else {
            HStack(spacing: 6) {
                AlasField(text: $destination, placeholder: "devbox or user@host")
                Button(action: { showHostPicker.toggle() }) {
                    Image(systemName: "list.bullet")
                        .font(scale.meta.font(weight: .semibold))
                        .foregroundColor(theme.color("fg-dim"))
                        .frame(width: 30, height: 28)
                        .background(theme.color("bg-2"))
                        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium)
                            .strokeBorder(theme.color("line"), lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
                }
                .buttonStyle(.plain)
                .help("Choose a host from ~/.ssh/config")
                .accessibilityLabel("Choose SSH host")
                .popover(isPresented: $showHostPicker, arrowEdge: .bottom) {
                    SSHHostPicker(
                        host: $destination,
                        hosts: configHosts,
                        isLoading: configHostsLoading,
                        isPresented: $showHostPicker
                    )
                }
            }
        }
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(scale.meta.font(weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
            content()
        }
    }

    private func test() async {
        isChecking = true
        defer { isChecking = false }
        checkMessage = nil
        switch await MachineCheck.run(host: trimmedDestination, projectsFolder: trimmedFolder) {
        case .ok:
            checkMessage = ("Connected. Projects folder is ready.", false)
        case .folderUnusable(let message):
            checkMessage = (message, true)
        case .connectionFailed:
            startSSHSetup()
        }
    }

    /// First contact may need a host key or a password: let the user answer
    /// in a terminal, then check again over the non-interactive channel.
    private func startSSHSetup() {
        let host = trimmedDestination
        let folder = trimmedFolder
        if let failure = sshSetup.start(host: host, state: state, theme: theme, onConnected: {
            switch await MachineCheck.run(host: host, projectsFolder: folder) {
            case .ok:
                sshSetup.isPresented = false
                checkMessage = ("Connected. Projects folder is ready.", false)
            case .folderUnusable(let message):
                sshSetup.isPresented = false
                checkMessage = (message, true)
            case .connectionFailed(let detail):
                sshSetup.markIncompatible(
                    SSHConnectionIssue(kind: .nonInteractiveUnavailable, detail: detail).message
                )
            }
        }) {
            checkMessage = (failure, true)
        }
    }

    private func save() {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let machine = Machine(
            destination: trimmedDestination,
            label: label.isEmpty ? nil : label,
            projectsFolder: trimmedFolder
        )
        if let index = state.config.machines.firstIndex(where: { $0.destination == machine.destination }) {
            state.config.machines[index] = machine
        } else {
            state.config.machines.append(machine)
        }
        _ = state.saveConfig()
        onClose()
    }

    private func loadConfigHosts() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configHosts = await Task.detached { SSHConfigParser.parse(home: home) }.value
        configHostsLoading = false
    }
}
