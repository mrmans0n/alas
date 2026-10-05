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

    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }
}

/// The status line of an installed plugin in Settings. Hosts still starting or stopping do not count as active.
enum PluginStatusText {
    static func make(approved: Bool, enabled: Bool, hostStates: [PluginHostState]) -> String {
        if !approved { return "Not approved" }
        if !enabled { return "Disabled" }
        guard !hostStates.isEmpty else { return "Enabled" }
        let active = hostStates.filter { $0 == .active }.count
        let projects = hostStates.count == 1 ? "project" : "projects"
        return "Enabled · active in \(active) of \(hostStates.count) \(projects)"
    }
}

struct PluginsPane: View {
    let state: AppState
    @Environment(\.theme) var theme
    @State private var approving: PluginManager.Plugin?
    @State private var configuring: PluginPanelTarget?
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
                SettingsRow(name: "Enable plugins", desc: "Runs approved plugins. Turning this off stops them all.") {
                    AlasToggle(on: Binding(
                        get: { state.config.pluginsEnabled },
                        set: { enabled in Task { @MainActor in await state.setPluginsEnabled(enabled) } }))
                }
                .padding(.bottom, 12)
                if let manager = state.pluginManager {
                    content(manager)
                } else {
                    Text("Plugins are off. Nothing is loaded or run, and the plugin catalog is not fetched.")
                        .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
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
        .sheet(item: $configuring) { target in
            PluginConfigureSheet(target: target) { configuring = nil }
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
            let hosts = manager.hosts(for: plugin)
            SettingsGroup(title: "\(plugin.manifest.name) \(plugin.manifest.version)", verticalPadding: 8) {
                SettingsRow(name: plugin.id, desc: PluginStatusText.make(
                    approved: manager.isApproved(plugin), enabled: manager.isEnabled(plugin),
                    hostStates: hosts.map(\.host.state))) {
                    if manager.isApproved(plugin) {
                        HStack(spacing: 12) {
                            AlasToggle(on: Binding(
                                get: { manager.isEnabled(plugin) },
                                set: { enabled in Task { await manager.setEnabled(plugin, enabled) } }))
                            if let panel = plugin.manifest.configurePanel {
                                let host = state.pluginConfigureHost(plugin)
                                AlasButton(title: "Configure…", style: .normal) {
                                    if let host { configuring = PluginPanelTarget(host: host, place: PluginPanelPlace(panel: panel.id), title: panel.title) }
                                }
                                .disabled(host == nil)
                                .help(host == nil ? "Open a project to configure this plugin" : "")
                            }
                            Spacer()
                            AlasButton(title: "Revoke Approval", style: .subtle) { Task { await manager.revoke(plugin) } }
                        }
                    } else {
                        AlasButton(title: "Approve…", style: .normal) { approving = plugin }
                    }
                }
                if manager.isApproved(plugin), !plugin.manifest.settings.isEmpty {
                    PluginSettingsForm(settings: manager.settings(for: plugin))
                }
                ForEach(hosts.filter(\.host.state.isFailed), id: \.key) { entry in
                    hostRow(manager, entry)
                }
                if !hosts.isEmpty {
                    PaneDisclosure(title: "All hosts (\(hosts.count))") {
                        ForEach(hosts, id: \.key) { entry in
                            hostRow(manager, entry)
                        }
                        .padding(.leading, 14)
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
    private func hostRow(_ manager: PluginManager, _ entry: (key: PluginManager.HostKey, host: PluginHost)) -> some View {
        SettingsRow(name: "\(entry.host.project.name) host", desc: entry.host.state.displayText) {
            AlasButton(title: "Restart", style: .subtle) { Task { await manager.restart(entry.key) } }
        }
        if !entry.host.log.isEmpty {
            HostLogDisclosure(log: entry.host.log)
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
            capabilitiesLine(row)
        } control: {
            if busy.contains(entry.id) {
                Spinner().frame(width: 14, height: 14).accessibilityLabel("Loading")
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

    /// The capability count with the full list in a tooltip; the approval sheet discloses them again before anything runs.
    @ViewBuilder
    private func capabilitiesLine(_ row: PluginCatalogRow) -> some View {
        switch row {
        case .install(let version), .update(let version):
            let summaries = version.capabilities.map { PluginCapability(rawValue: $0)?.summary ?? $0 }
            let fullAccess = version.capabilities.contains { PluginCapability(rawValue: $0)?.isFullAccess == true }
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Text(summaries.isEmpty ? "No capabilities"
                        : summaries.count == 1 ? "1 capability" : "\(summaries.count) capabilities")
                    if !summaries.isEmpty { Image(systemName: "info.circle") }
                }
                .font(.system(size: 11.5))
                .foregroundColor(theme.color("fg-dim"))
                .help(Self.capabilitiesHelp(summaries, fullAccess: fullAccess))
                if fullAccess {
                    Text("Full access")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(theme.color("warn").opacity(0.18))
                        .foregroundColor(theme.color("warn"))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help("It acts with your permissions, outside the sandbox.")
                }
            }
            .padding(.top, 2)
        case .installed, .installedLocally, .incompatible:
            EmptyView()
        }
    }

    private static func capabilitiesHelp(_ summaries: [String], fullAccess: Bool) -> String {
        guard !summaries.isEmpty else { return "" }
        var lines = ["Asks to:"] + summaries.map { "• \($0)" }
        if fullAccess { lines.append("Full access: it acts with your permissions, outside the sandbox.") }
        return lines.joined(separator: "\n")
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

    private static func catalogDescription(_ entry: PluginCatalogIndex.Entry, _ row: PluginCatalogRow, failure: String?) -> String? {
        var lines = [entry.summary].compactMap { $0 }
        switch row {
        case .install, .update: break
        case .installed: lines.append("Installed from the catalog.")
        case .installedLocally: lines.append("Installed locally; the catalog leaves it alone.")
        case .incompatible: lines.append("No version runs on this Alas.")
        }
        if let failure { lines.append(failure) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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

/// A plugin's configure panel (API 9), rendered by one of its running instances, which hears `panel/visible` while
/// the sheet is open.
private struct PluginConfigureSheet: View {
    let target: PluginPanelTarget
    let done: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        let host = target.host
        VStack(spacing: 0) {
            Text(target.title).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Divider()
            Group {
                if case .failed(let reason) = host.state {
                    Text("Plugin stopped: \(reason)").foregroundColor(theme.color("fg-dim")).multilineTextAlignment(.center)
                } else if host.state == .active, host.panelTree(for: target.place) != nil {
                    PluginViewTabView(host: host, panel: target.place.panel)
                } else {
                    Spinner().frame(width: 14, height: 14).accessibilityLabel("Loading")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                // Escape, not Return: Return belongs to the panel's text fields.
                Button("Done", action: done).keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 400, idealWidth: 560, maxWidth: .infinity, minHeight: 300, idealHeight: 480, maxHeight: .infinity)
        .pluginPanelsVisible([target])
    }
}

/// A disclosure whose whole label toggles it, chevron included, in one dim color so it stays secondary to the rows.
private struct PaneDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text(title).font(.system(size: 11.5))
                }
                .foregroundColor(theme.color("fg-dim"))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded { content() }
        }
    }
}

/// Host log collapsed by default: PluginHost retains up to 200 entries of up
/// to 2,000 characters each, so rendering it inline would flood the pane.
private struct HostLogDisclosure: View {
    let log: [PluginLogEntry]
    @Environment(\.theme) var theme

    var body: some View {
        PaneDisclosure(title: "Log (\(log.count))") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(log.enumerated()), id: \.offset) { _, entry in
                    Text("[\(entry.level)] \(entry.message)")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundColor(theme.color("fg-dim"))
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, 15)
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
            // A long disclosure scrolls, so the confirmation and the buttons below it stay on screen.
            ViewThatFits(in: .vertical) {
                disclosure(sandboxed: sandboxed, fullAccess: fullAccess)
                ScrollView { disclosure(sandboxed: sandboxed, fullAccess: fullAccess) }
            }
            .frame(maxHeight: 420)
            if !fullAccess.isEmpty {
                Toggle(Self.confirmation(fullAccess, remote: manifest.remote), isOn: $acceptsFullAccess)
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

    private func disclosure(sandboxed: [PluginCapability], fullAccess: [PluginCapability]) -> some View {
        let manifest = plugin.manifest
        return VStack(alignment: .leading, spacing: 12) {
            if manifest.capabilities.isEmpty {
                Text("It requests no capabilities.")
            }
            if !sandboxed.isEmpty || manifest.web != nil {
                Text("Sandboxed. It will be able to:").font(.subheadline.weight(.semibold))
                ForEach(sandboxed, id: \.self) { Text("• \($0.summary)") }
                if manifest.web != nil { Text("• Show its own web content, with no network access") }
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
                    Text(PluginArgv.display(process.command) + (process.appendArgs ? " …" : ""))
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .padding(.leading, 12)
                }
            }
            if let remote = Self.remoteSummary(manifest) {
                Text("On SSH hosts").font(.subheadline.weight(.semibold))
                Text(remote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Outside the full access group, so a read-only plugin is not labelled full access.
    private static func remoteSummary(_ manifest: PluginManifest) -> String? {
        guard manifest.remote else { return nil }
        let does = [
            manifest.capabilities.contains(.filesRead) ? "reads files" : nil,
            manifest.capabilities.contains(.filesWrite) ? "changes files" : nil,
            manifest.capabilities.contains(.processExec) ? "runs these commands" : nil,
        ].compactMap { $0 }
        let list = does.count > 1 ? does.dropLast().joined(separator: ", ") + " and " + (does.last ?? "") : does.joined()
        return "In a project on an SSH host, it \(list) on that host, as your user there."
    }

    private static func confirmation(_ fullAccess: [PluginCapability], remote: Bool) -> String {
        let does = [
            fullAccess.contains(.processExec) ? "run these commands" : nil,
            fullAccess.contains(.filesWrite) ? "change files" : nil,
        ].compactMap { $0 }.joined(separator: " and ")
        return "I understand this plugin can \(does) in my worktrees" + (remote ? ", on this Mac and on SSH hosts" : "")
    }
}
