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
    @State private var approvals = PluginApprovalQueue()
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
        .onAppear { approvals.isShown = true }
        .onDisappear { approvals.close() }
        // Requests leave the queue only through `finish`, which the sheet calls however it closes.
        .sheet(item: Binding(get: { approvals.requests.first }, set: { _ in })) { request in
            PluginApprovalSheet(request: request) { approvals.finish(request.id, $0) }
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
        let updates = Self.updates(manager)
        if !updates.isEmpty {
            updatesBanner(manager, updates)
        }
        if manager.plugins.isEmpty {
            SettingsRow(name: "No plugins installed.", desc: nil) { }
        }
        ForEach(manager.plugins) { plugin in
            let hosts = manager.hosts(for: plugin)
            SettingsGroup(title: "\(plugin.manifest.name) \(plugin.manifest.version)", verticalPadding: 8) {
                SettingsRow(name: plugin.id, desc: PluginStatusText.make(
                    approved: manager.isApproved(plugin), enabled: manager.isEnabled(plugin),
                    hostStates: hosts.map(\.host.state))) {
                    HStack(spacing: 12) {
                        if let update = updates.first(where: { $0.entry.id == plugin.id }) {
                            updateButton(manager, update)
                        }
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
                            AlasButton(title: "Approve…", style: .normal) {
                                approvals.ask(PluginApprovalRequest(manifest: plugin.manifest) { approved in
                                    if approved { Task { await manager.approve(plugin) } }
                                })
                            }
                        }
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
                    catalogRow(manager, entry, Self.row(manager, entry))
                }
            }
        }
        .task { await catalog.refresh() }
    }

    private static func row(_ manager: PluginManager, _ entry: PluginCatalogIndex.Entry) -> PluginCatalogRow {
        PluginCatalogRow(
            entry: entry, installed: manager.plugin(id: entry.id),
            // Duplicates of this plugin, or anything else at the path install would use.
            quarantined: manager.invalid.contains { $0.pluginID == entry.id } || manager.catalogPathIsTaken(id: entry.id))
    }

    private typealias Update = (entry: PluginCatalogIndex.Entry, version: PluginCatalogIndex.Version)

    private static func updates(_ manager: PluginManager) -> [Update] {
        (manager.catalog.index?.plugins ?? []).compactMap { entry in
            if case .update(let version) = row(manager, entry) { (entry, version) } else { nil }
        }
    }

    private func updatesBanner(_ manager: PluginManager, _ updates: [Update]) -> some View {
        HStack {
            Text(updates.count == 1 ? "1 update available" : "\(updates.count) updates available")
                .font(.system(size: 12.5, weight: .medium))
            Spacer()
            AlasButton(title: "Update All", style: .normal) {
                Task { for update in updates { await install(manager, update.entry, update.version) } }
            }
            .disabled(updates.contains { busy.contains($0.entry.id) })
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(theme.color("accent-soft"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func updateButton(_ manager: PluginManager, _ update: Update) -> some View {
        if busy.contains(update.entry.id) {
            Spinner().frame(width: 14, height: 14).accessibilityLabel("Updating")
        } else {
            AlasButton(title: "Update to \(update.version.version)", style: .normal) {
                Task { await install(manager, update.entry, update.version) }
            }
        }
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
                    AlasButton(title: "Install \(version.version)", style: .normal) { Task { await install(manager, entry, version) } }
                case .update(let version):
                    AlasButton(title: "Update to \(version.version)", style: .normal) { Task { await install(manager, entry, version) } }
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

    private func install(_ manager: PluginManager, _ entry: PluginCatalogIndex.Entry, _ version: PluginCatalogIndex.Version) async {
        guard !busy.contains(entry.id) else { return }
        let from = manager.plugin(id: entry.id)?.manifest.version ?? ""
        busy.insert(entry.id)
        // The instance itself, not the @State read later: the download may finish after the pane has gone.
        let approvals = self.approvals
        installFailures[entry.id] = await manager.install(entry, version) { manifest, added in
            await withCheckedContinuation { continuation in
                approvals.ask(PluginApprovalRequest(manifest: manifest, update: .init(from: from, added: added)) {
                    continuation.resume(returning: $0)
                })
            }
        }
        busy.remove(entry.id)
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

/// A plugin to approve: an installed one, or an update that asks for more than the approved version it replaces.
private struct PluginApprovalRequest: Identifiable {
    struct Update {
        let from: String
        let added: [String]
    }

    let id = UUID()
    let manifest: PluginManifest
    var update: Update?
    let finish: (Bool) -> Void
}

/// Approval requests shown one at a time: Update All, or two downloads finishing together, can ask more than once.
/// Install tasks keep it past the pane, so every request is answered: one made after the pane closed is declined.
@MainActor
@Observable
private final class PluginApprovalQueue {
    private(set) var requests: [PluginApprovalRequest] = []
    var isShown = false

    func ask(_ request: PluginApprovalRequest) {
        guard isShown else { return request.finish(false) }
        requests.append(request)
    }

    /// Answers a request once; later calls for it do nothing.
    func finish(_ id: UUID, _ approved: Bool) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests.remove(at: index).finish(approved)
    }

    func close() {
        isShown = false
        let pending = requests
        requests = []
        for request in pending { request.finish(false) }
    }
}

private struct PluginApprovalSheet: View {
    let request: PluginApprovalRequest
    let finish: (Bool) -> Void
    @State private var acceptsFullAccess = false
    @Environment(\.theme) var theme

    var body: some View {
        let manifest = request.manifest
        let sandboxed = manifest.capabilities.filter { !$0.isFullAccess }
        let fullAccess = manifest.capabilities.filter(\.isFullAccess)
        VStack(alignment: .leading, spacing: 12) {
            if let update = request.update {
                Text("Update \(manifest.name) to \(manifest.version)?").font(.headline)
                Text("\(manifest.id) · \(update.from) → \(manifest.version)").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("New in this version:").font(.subheadline.weight(.semibold))
                    ForEach(update.added, id: \.self) { Text("• \($0)") }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.color("warn").opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Text("Approve \(manifest.name)?").font(.headline)
                Text("\(manifest.id) · version \(manifest.version)").font(.caption).foregroundStyle(.secondary)
            }
            // A long disclosure scrolls, so the confirmation and the buttons below it stay on screen.
            ViewThatFits(in: .vertical) {
                disclosure(sandboxed: sandboxed, fullAccess: fullAccess)
                ScrollView { disclosure(sandboxed: sandboxed, fullAccess: fullAccess) }
            }
            .frame(maxHeight: 420)
            if !fullAccess.isEmpty {
                Toggle(Self.confirmation(fullAccess, remote: manifest.remote), isOn: $acceptsFullAccess)
            }
            Text(request.update.map { "If you cancel, \($0.from) keeps running." }
                ?? "Changing the plugin's files requires approving it again.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { finish(false) }.keyboardShortcut(.cancelAction)
                Button(request.update == nil ? "Approve" : "Update and Approve") { finish(true) }.keyboardShortcut(.defaultAction)
                    .disabled(!fullAccess.isEmpty && !acceptsFullAccess)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Closed some other way: an update waiting on the answer must still get one.
        .onDisappear { finish(false) }
    }

    private func disclosure(sandboxed: [PluginCapability], fullAccess: [PluginCapability]) -> some View {
        let manifest = request.manifest
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
