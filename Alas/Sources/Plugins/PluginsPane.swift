import AppKit
import SwiftUI

extension PluginHostState {
    var displayText: String {
        switch self {
        case .loaded: "Loaded"
        case .activating: "Starting"
        case .active: "Active"
        case .deactivating: "Stopping"
        case .stopped: "Stopped"
        case .failed(let reason): "Stopped: \(reason)"
        }
    }
}

struct PluginsPane: View {
    let state: AppState
    @Environment(\.theme) var theme
    @State private var approving: PluginManager.Plugin?
    /// Install or update failures, by catalog entry id, until the next attempt.
    @State private var installFailures: [String: String] = [:]
    @State private var busy: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Plugins").font(.system(size: 18, weight: .semibold))
                Text("Plugins run sandboxed, with only the capabilities you approve.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)
                if let manager = state.pluginManager {
                    content(manager)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .sheet(item: $approving) { plugin in
            PluginApprovalSheet(plugin: plugin) { approved in
                approving = nil
                if approved, let manager = state.pluginManager {
                    Task { await manager.approve(plugin) }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ manager: PluginManager) -> some View {
        HStack {
            AlasButton(title: "Reveal Plugins Folder", icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([manager.directory])
            }
            AlasButton(title: "Rescan", icon: "arrow.clockwise") {
                Task {
                    await manager.reload()
                    await manager.catalog.refresh(force: true)
                }
            }
        }
        .padding(.bottom, 12)
        if manager.plugins.isEmpty {
            SettingsRow(name: "No plugins installed.", desc: nil) { }
        }
        ForEach(manager.plugins) { plugin in
            SettingsGroup(title: "\(plugin.manifest.name) \(plugin.manifest.version)") {
                SettingsRow(name: plugin.id, desc: Self.status(manager, plugin)) {
                    if manager.isApproved(plugin) {
                        AlasToggle(on: Binding(
                            get: { manager.isEnabled(plugin) },
                            set: { enabled in Task { await manager.setEnabled(plugin, enabled) } }))
                        AlasButton(title: "Revoke Approval", style: .normal) { Task { await manager.revoke(plugin) } }
                    } else {
                        AlasButton(title: "Approve…", style: .normal) { approving = plugin }
                    }
                }
                if manager.isApproved(plugin), !plugin.manifest.settings.isEmpty {
                    PluginSettingsForm(settings: manager.settings(for: plugin))
                }
                ForEach(manager.hosts(for: plugin), id: \.key) { entry in
                    SettingsRow(name: "\(entry.host.project.name) host", desc: entry.host.state.displayText) {
                        AlasButton(title: "Restart", style: .subtle) { Task { await manager.restart(entry.key) } }
                    }
                    if !entry.host.log.isEmpty {
                        HostLogDisclosure(log: entry.host.log)
                    }
                }
            }
        }
        catalogSection(manager)
        if !manager.invalid.isEmpty {
            SettingsGroup(title: "Not loaded") {
                ForEach(manager.invalid) { entry in
                    SettingsRow(name: entry.folder.lastPathComponent, desc: entry.reason, selectable: true) { }
                }
            }
        }
    }

    @ViewBuilder
    private func catalogSection(_ manager: PluginManager) -> some View {
        let catalog = manager.catalog
        SettingsGroup(title: "Available") {
            switch catalog.state {
            case .idle, .loading:
                SettingsRow(name: "Loading the plugin catalog…", desc: nil) { }
            case .failed(let reason):
                SettingsRow(name: "Catalog unavailable", desc: reason, selectable: true) {
                    AlasButton(title: "Retry", style: .subtle) { Task { await catalog.refresh(force: true) } }
                }
            case .loaded(let index):
                ForEach(index.plugins) { entry in
                    catalogRow(manager, entry, PluginCatalogRow(
                        entry: entry, installed: manager.plugin(id: entry.id),
                        // Duplicates of this plugin, or anything else at the path install would use.
                        quarantined: manager.invalid.contains { $0.pluginID == entry.id } || manager.catalogPathIsTaken(id: entry.id)))
                }
            }
        }
        .task { await catalog.refresh() }
    }

    private func catalogRow(_ manager: PluginManager, _ entry: PluginCatalogIndex.Entry, _ row: PluginCatalogRow) -> some View {
        SettingsRow(name: entry.name, desc: Self.catalogDescription(entry, row, failure: installFailures[entry.id]), selectable: true) {
            if busy.contains(entry.id) {
                ProgressView().controlSize(.small)
            } else {
                switch row {
                case .install(let version):
                    AlasButton(title: "Install \(version.version)", style: .normal) { install(manager, entry, version) }
                case .update(let version):
                    AlasButton(title: "Update to \(version.version)", style: .normal) { install(manager, entry, version) }
                    removeButton(manager, entry.id)
                case .installed:
                    removeButton(manager, entry.id)
                case .installedLocally, .incompatible:
                    EmptyView()
                }
            }
        }
    }

    private func removeButton(_ manager: PluginManager, _ id: String) -> some View {
        AlasButton(title: "Remove", style: .subtle) {
            guard let plugin = manager.plugin(id: id) else { return }
            Task {
                busy.insert(id)
                installFailures[id] = await manager.uninstall(plugin)
                busy.remove(id)
            }
        }
    }

    private func install(_ manager: PluginManager, _ entry: PluginCatalogIndex.Entry, _ version: PluginCatalogIndex.Version) {
        Task {
            busy.insert(entry.id)
            installFailures[entry.id] = await manager.install(entry, version)
            busy.remove(entry.id)
        }
    }

    private static func catalogDescription(_ entry: PluginCatalogIndex.Entry, _ row: PluginCatalogRow, failure: String?) -> String {
        var lines = [entry.summary].compactMap { $0 }
        switch row {
        case .install(let version), .update(let version):
            let asks = version.capabilities.map { PluginCapability(rawValue: $0)?.summary ?? $0 }
            lines.append(asks.isEmpty ? "Asks for no capabilities." : "Asks to: " + asks.joined(separator: "; ") + ".")
            if version.capabilities.contains(where: { PluginCapability(rawValue: $0)?.isFullAccess == true }) {
                lines.append("Asks for full access: it acts with your permissions, outside the sandbox.")
            }
        case .installed: lines.append("Installed from the catalog.")
        case .installedLocally: lines.append("Installed locally; the catalog leaves it alone.")
        case .incompatible: lines.append("No version runs on this Alas.")
        }
        if let failure { lines.append(failure) }
        return lines.joined(separator: "\n")
    }

    private static func status(_ manager: PluginManager, _ plugin: PluginManager.Plugin) -> String {
        if !manager.isApproved(plugin) { return "Not approved" }
        if !manager.isEnabled(plugin) { return "Disabled" }
        return "Enabled"
    }
}

/// The plugin's declared settings. Text is committed on Return or when the field loses focus;
/// a stored secret is never shown, only whether one is set.
private struct PluginSettingsForm: View {
    let settings: PluginSettings

    var body: some View {
        ForEach(settings.declared, id: \.key) { setting in
            switch setting.kind {
            case .string:
                SettingsRow(name: setting.title) { PluginTextSetting(settings: settings, key: setting.key) }
            case .bool:
                SettingsRow(name: setting.title) {
                    AlasToggle(on: Binding(
                        get: { settings.bool(setting.key) },
                        set: { settings.set(setting.key, .bool($0)) }))
                }
            case .secret:
                let isSet = settings.isSecretSet(setting.key)
                SettingsRow(
                    name: setting.title,
                    desc: (isSet ? "Set" : "Not set") + ". Sent only to " + setting.hosts.joined(separator: ", ") + ".") {
                    PluginSecretSetting(settings: settings, key: setting.key, isSet: isSet)
                }
            }
        }
    }
}

private struct PluginTextSetting: View {
    let settings: PluginSettings
    let key: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .focused($focused)
            .onAppear { draft = settings.string(key) }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onDisappear(perform: commit)
    }

    private func commit() {
        guard draft != settings.string(key) else { return }
        settings.set(key, .string(draft))
    }
}

private struct PluginSecretSetting: View {
    let settings: PluginSettings
    let key: String
    let isSet: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            // Saved on Return, when focus leaves, or when Settings closes, so a pasted value is never lost.
            SecureField(isSet ? "Replace" : "Paste a value", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onDisappear(perform: commit)
            if isSet {
                AlasButton(title: "Clear", style: .subtle) { settings.setSecret(key, nil) }
            }
        }
    }

    private func commit() {
        guard !draft.isEmpty, settings.setSecret(key, draft) else { return }
        draft = ""
    }
}

/// Host log collapsed by default: PluginHost retains up to 200 entries of up
/// to 2,000 characters each, so rendering it inline would flood the pane.
private struct HostLogDisclosure: View {
    let log: [PluginLogEntry]
    @State private var isExpanded = false
    @Environment(\.theme) var theme

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(log.enumerated()), id: \.offset) { _, entry in
                    Text("[\(entry.level)] \(entry.message)")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundColor(theme.color("fg-dim"))
                }
            }
            .padding(.vertical, 6)
        } label: {
            Text("Log (\(log.count))")
                .font(.system(size: 11.5))
                .foregroundColor(theme.color("fg-dim"))
        }
        .padding(.leading, 12)
        .padding(.bottom, 10)
    }
}

private struct PluginApprovalSheet: View {
    let plugin: PluginManager.Plugin
    let finish: (Bool) -> Void
    @State private var acceptsFullAccess = false

    var body: some View {
        let manifest = plugin.manifest
        let sandboxed = manifest.capabilities.filter { !$0.isFullAccess }
        let fullAccess = manifest.capabilities.filter(\.isFullAccess)
        VStack(alignment: .leading, spacing: 12) {
            Text("Approve \(manifest.name)?").font(.headline)
            Text("\(plugin.id) · version \(manifest.version)").font(.caption).foregroundStyle(.secondary)
            if manifest.capabilities.isEmpty {
                Text("It requests no capabilities.")
            }
            if !sandboxed.isEmpty {
                Text("Sandboxed. It will be able to:").font(.subheadline.weight(.semibold))
                ForEach(sandboxed, id: \.self) { Text("• \($0.summary)") }
            }
            if !manifest.network.isEmpty {
                Text("Web requests: " + manifest.network.joined(separator: ", "))
                    .font(.callout).textSelection(.enabled)
            }
            ForEach(manifest.settings.filter { $0.kind == .secret }, id: \.key) { secret in
                Text("• Can use \(secret.title) with \(secret.hosts.joined(separator: ", "))")
            }
            if !fullAccess.isEmpty {
                Text("Full access. With your permissions, outside any sandbox, it will be able to:")
                    .font(.subheadline.weight(.semibold))
                ForEach(fullAccess, id: \.self) { Text("• \($0.summary)") }
                ForEach(manifest.processes, id: \.id) { process in
                    Text(process.command.joined(separator: " ") + (process.appendArgs ? " …" : ""))
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .padding(.leading, 12)
                }
                Toggle(Self.confirmation(fullAccess), isOn: $acceptsFullAccess)
            }
            Text("Changing the plugin's files requires approving it again.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { finish(false) }.keyboardShortcut(.cancelAction)
                Button("Approve") { finish(true) }.keyboardShortcut(.defaultAction)
                    .disabled(!fullAccess.isEmpty && !acceptsFullAccess)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private static func confirmation(_ fullAccess: [PluginCapability]) -> String {
        let does = [
            fullAccess.contains(.processExec) ? "run these commands" : nil,
            fullAccess.contains(.filesWrite) ? "change files" : nil,
        ].compactMap { $0 }.joined(separator: " and ")
        return "I understand this plugin can \(does) in my worktrees"
    }
}
