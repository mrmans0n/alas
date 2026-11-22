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
    @Environment(\.designScale) private var scale
    @State private var approvals = PluginApprovalQueue()
    @State private var configuring: PluginPanelTarget?
    /// Install or update failures, by catalog entry id, until the next attempt.
    @State private var installFailures: [String: String] = [:]
    @State private var busy: Set<String> = []
    @State private var tab = PluginListTab.installed
    /// The installed plugin whose page replaces the list; a sheet would hide the approval and configure sheets.
    @State private var selected: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let manager = state.pluginManager, let id = selected, let plugin = manager.plugin(id: id) {
                    detail(manager, plugin)
                } else {
                    Text("Plugins").font(SettingsPaneStyle.titleFont)
                    Text("Plugins run sandboxed, with only the capabilities you approve.")
                        .font(scale.metaFont).foregroundColor(theme.color("fg-dim"))
                        .padding(.bottom, scale.space[3])
                    SettingsRow(name: "Enable plugins", desc: "Runs approved plugins. Turning this off stops them all.") {
                        AlasToggle(on: Binding(
                            get: { state.config.pluginsEnabled },
                            set: { enabled in Task { @MainActor in await state.setPluginsEnabled(enabled) } }))
                    }
                    .padding(.bottom, scale.space[3])
                    if let manager = state.pluginManager {
                        content(manager)
                    } else {
                        Text("Plugins are off. Nothing is loaded or run, and the plugin catalog is not fetched.")
                            .font(scale.metaFont).foregroundColor(theme.color("fg-dim"))
                    }
                }
            }
            .padding(.horizontal, scale.space[5]).padding(.vertical, scale.space[5])
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
        .padding(.bottom, scale.space[3])
        let updates = manager.catalogUpdates
        if !updates.isEmpty {
            updatesBanner(manager, updates)
        }
        let available = (manager.catalog.index?.plugins ?? []).filter { manager.plugin(id: $0.id) == nil }
        AlasSegmentedControl(selection: tab, options: [
            AlasSegmentedOption(id: .installed, label: "Installed \(manager.plugins.count)"),
            AlasSegmentedOption(id: .available, label: manager.catalog.index == nil ? "Available" : "Available \(available.count)"),
            AlasSegmentedOption(id: .updates, label: "Updates \(updates.count)"),
        ]) { tab = $0 }
        .fixedSize()
        .padding(.bottom, scale.space[2])
        Group {
            switch tab {
            case .installed:
                if manager.plugins.isEmpty {
                    emptyRow("No plugins installed.")
                }
                ForEach(manager.plugins) { installedRow(manager, $0, updates) }
                if !manager.invalid.isEmpty {
                    SettingsGroup(title: "Not loaded") {
                        ForEach(manager.invalid) { entry in
                            SettingsRow(name: entry.folder.lastPathComponent, desc: entry.reason, selectable: true) { }
                        }
                    }
                }
            case .available:
                availableList(manager, available)
            case .updates:
                if updates.isEmpty {
                    emptyRow("Everything is up to date.")
                }
                ForEach(updates.compactMap { manager.plugin(id: $0.entry.id) }) { installedRow(manager, $0, updates) }
            }
        }
        .task { await manager.catalog.refresh() }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(scale.metaFont).foregroundColor(theme.color("fg-dim")).padding(.vertical, scale.space[3])
    }

    private func catalogEntry(_ manager: PluginManager, _ id: String) -> PluginCatalogIndex.Entry? {
        manager.catalog.index?.plugins.first { $0.id == id }
    }

    // MARK: Installed

    private func installedRow(_ manager: PluginManager, _ plugin: PluginManager.Plugin, _ updates: [Update]) -> some View {
        let listing = PluginListing(installed: plugin, entry: catalogEntry(manager, plugin.id))
        let failed = manager.hosts(for: plugin).filter(\.host.state.isFailed).count
        let status: String? = !manager.isApproved(plugin) ? "Not approved"
            : !manager.isEnabled(plugin) ? "Disabled"
            : failed > 0 ? "Stopped in \(failed) \(failed == 1 ? "project" : "projects")" : nil
        return PluginListRow(listing: listing, status: status, statusIsWarning: failed > 0, open: { selected = plugin.id }) {
            if busy.contains(plugin.id) {
                Spinner().frame(width: 14, height: 14).accessibilityLabel("Updating")
            } else if let update = updates.first(where: { $0.entry.id == plugin.id }) {
                AlasButton(title: "Update", style: .primary) { Task { await install(manager, update.entry, update.version) } }
                    .fixedSize()
                    .help("Update to \(update.version.version)")
            } else if manager.isApproved(plugin) {
                AlasToggle(on: Binding(
                    get: { manager.isEnabled(plugin) },
                    set: { enabled in Task { await manager.setEnabled(plugin, enabled) } }))
            } else {
                approveButton(manager, plugin)
            }
        } detail: {
            failureLine(plugin.id)
        }
    }

    /// The last install, update or remove of this plugin that failed, shown where it was started.
    @ViewBuilder
    private func failureLine(_ id: String) -> some View {
        if let failure = installFailures[id] {
            Text("Failed: \(failure)")
                .font(scale.metaFont)
                .foregroundStyle(theme.color("warn"))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func detail(_ manager: PluginManager, _ plugin: PluginManager.Plugin) -> some View {
        let entry = catalogEntry(manager, plugin.id)
        let listing = PluginListing(installed: plugin, entry: entry)
        let hosts = manager.hosts(for: plugin)
        let updates = manager.catalogUpdates
        let row = entry.map(manager.catalogRow)
        AlasButton(title: "Plugins", icon: "chevron.left", style: .subtle) { selected = nil }
            .fixedSize()
            .keyboardShortcut(.cancelAction)
            .padding(.bottom, scale.space[3])
        HStack(alignment: .top, spacing: scale.space[3]) {
            PluginIconTile(listing: listing, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(listing.name).font(SettingsPaneStyle.titleFont)
                    if let version = listing.version {
                        Text(version).font(scale.meta.font(design: .monospaced)).foregroundColor(theme.color("fg-muted"))
                    }
                }
                PluginMetaLine(listing: listing)
                if let summary = listing.summary {
                    Text(summary).font(scale.bodyFont).fixedSize(horizontal: false, vertical: true).padding(.top, scale.space[1])
                }
                HStack(spacing: scale.space[3]) {
                    Text(plugin.id).font(scale.meta.font(design: .monospaced)).textSelection(.enabled)
                    if let homepage = entry?.homepage { Link("Homepage", destination: homepage).font(scale.metaFont) }
                }
                .foregroundColor(theme.color("fg-muted"))
                .padding(.top, scale.space[1])
            }
        }
        .padding(.bottom, scale.space[4])
        SettingsRow(name: "Status", desc: PluginStatusText.make(
            approved: manager.isApproved(plugin), enabled: manager.isEnabled(plugin), hostStates: hosts.map(\.host.state))) {
            pluginControls(manager, plugin, updates)
        }
        SettingsRow(name: "Permissions", desc: Self.permissions(plugin.manifest)) { }
        let fromCatalog = Self.isFromCatalog(row)
        SettingsRow(name: "Source", desc: fromCatalog ? "Installed from the catalog." : "Installed locally; the catalog leaves it alone.") {
            if fromCatalog { removeButton(manager, plugin.id) }
        }
        failureLine(plugin.id)
        if manager.isApproved(plugin), !plugin.manifest.settings.isEmpty {
            SettingsGroup(title: "Settings", verticalPadding: scale.space[2]) {
                PluginSettingsForm(settings: manager.settings(for: plugin))
            }
        }
        ForEach(hosts.filter(\.host.state.isFailed), id: \.key) { entry in
            hostRow(manager, entry)
        }
        if !hosts.isEmpty {
            PaneDisclosure(title: "All hosts (\(hosts.count))") {
                ForEach(hosts, id: \.key) { entry in
                    hostRow(manager, entry)
                }
                .padding(.leading, scale.space[4])
            }
        }
    }

    /// Only the catalog's own copy can be removed from here.
    private static func isFromCatalog(_ row: PluginCatalogRow?) -> Bool {
        switch row {
        case .installed, .update: true
        case .installedLocally, .install, .incompatible, nil: false
        }
    }

    private static func permissions(_ manifest: PluginManifest) -> String {
        let lines = manifest.capabilities.map(\.summary) + [manifest.webSummary].compactMap { $0 }
        return lines.isEmpty ? "None requested." : lines.joined(separator: "\n")
    }

    /// The row's buttons on one line when the column is wide enough, stacked otherwise, so no title is cut short.
    private func pluginControls(_ manager: PluginManager, _ plugin: PluginManager.Plugin, _ updates: [Update]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: scale.space[3]) {
                updateSlot(manager, plugin, updates)
                if manager.isApproved(plugin) {
                    HStack(spacing: scale.space[3]) {
                        approvedControls(manager, plugin)
                        Spacer()
                        revokeButton(manager, plugin)
                    }
                } else {
                    approveButton(manager, plugin)
                }
            }
            VStack(alignment: .leading, spacing: scale.space[2]) {
                updateSlot(manager, plugin, updates)
                if manager.isApproved(plugin) {
                    HStack(spacing: scale.space[3]) {
                        approvedControls(manager, plugin)
                        Spacer()
                        revokeButton(manager, plugin)
                    }
                } else {
                    approveButton(manager, plugin)
                }
            }
        }
    }

    @ViewBuilder
    private func updateSlot(_ manager: PluginManager, _ plugin: PluginManager.Plugin, _ updates: [Update]) -> some View {
        if let update = updates.first(where: { $0.entry.id == plugin.id }) {
            updateButton(manager, update)
        }
    }

    @ViewBuilder
    private func approvedControls(_ manager: PluginManager, _ plugin: PluginManager.Plugin) -> some View {
        AlasToggle(on: Binding(
            get: { manager.isEnabled(plugin) },
            set: { enabled in Task { await manager.setEnabled(plugin, enabled) } }))
        if let panel = plugin.manifest.configurePanel {
            let host = state.pluginConfigureHost(plugin)
            AlasButton(title: "Configure…", style: .normal) {
                if let host { configuring = PluginPanelTarget(host: host, place: PluginPanelPlace(panel: panel.id), title: panel.title) }
            }
            .fixedSize()
            .disabled(host == nil)
            .help(host == nil ? "Open a project to configure this plugin" : "")
        }
    }

    private func revokeButton(_ manager: PluginManager, _ plugin: PluginManager.Plugin) -> some View {
        AlasButton(title: "Revoke Approval", style: .subtle) { Task { await manager.revoke(plugin) } }
            .fixedSize()
    }

    private func approveButton(_ manager: PluginManager, _ plugin: PluginManager.Plugin) -> some View {
        AlasButton(title: "Approve…", style: .normal) {
            approvals.ask(PluginApprovalRequest(manifest: plugin.manifest) { approved in
                if approved { Task { await manager.approve(plugin) } }
            })
        }
        .fixedSize()
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

    // MARK: Available

    @ViewBuilder
    private func availableList(_ manager: PluginManager, _ available: [PluginCatalogIndex.Entry]) -> some View {
        let catalog = manager.catalog
        // The last index stays listed through a refresh and its failure.
        if catalog.index == nil {
            if case .failed(let reason) = catalog.state {
                SettingsRow(name: "Catalog unavailable", desc: reason, selectable: true) {
                    AlasButton(title: "Retry", style: .subtle) { Task { await catalog.refresh(force: true) } }
                }
            } else {
                emptyRow("Loading the plugin catalog…")
            }
        } else {
            if available.isEmpty {
                emptyRow("Everything in the catalog is installed.")
            }
            ForEach(available) { entry in
                availableRow(manager, entry, manager.catalogRow(entry))
            }
        }
    }

    private func availableRow(_ manager: PluginManager, _ entry: PluginCatalogIndex.Entry, _ row: PluginCatalogRow) -> some View {
        PluginListRow(listing: PluginListing(installed: nil, entry: entry), status: nil, statusIsWarning: false, open: nil) {
            if busy.contains(entry.id) {
                Spinner().frame(width: 14, height: 14).accessibilityLabel("Installing")
            } else {
                switch row {
                case .install(let version):
                    AlasButton(title: "Install", style: .normal) { Task { await install(manager, entry, version) } }
                        .fixedSize()
                case .incompatible:
                    Text("Needs a newer Alas").font(scale.metaFont).foregroundColor(theme.color("fg-muted"))
                case .installed, .update, .installedLocally:
                    // A copy elsewhere in the folder holds this id.
                    Text("Installed locally").font(scale.metaFont).foregroundColor(theme.color("fg-muted"))
                }
            }
        } detail: {
            failureLine(entry.id)
            capabilitiesLine(row)
        }
    }

    private typealias Update = PluginManager.CatalogUpdate

    private func updatesBanner(_ manager: PluginManager, _ updates: [Update]) -> some View {
        HStack {
            Text(updates.count == 1 ? "1 update available" : "\(updates.count) updates available")
                .font(scale.meta.font(weight: .medium))
            Spacer()
            AlasButton(title: "Update All", style: .normal) {
                Task { for update in updates { await install(manager, update.entry, update.version) } }
            }
            .disabled(updates.contains { busy.contains($0.entry.id) })
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        .background(theme.color("accent-soft"))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .padding(.bottom, scale.space[3])
    }

    @ViewBuilder
    private func updateButton(_ manager: PluginManager, _ update: Update) -> some View {
        if busy.contains(update.entry.id) {
            Spinner().frame(width: 14, height: 14).accessibilityLabel("Updating")
        } else {
            AlasButton(title: "Update to \(update.version.version)", style: .normal) {
                Task { await install(manager, update.entry, update.version) }
            }
            .fixedSize()
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
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-dim"))
                .help(Self.capabilitiesHelp(summaries, fullAccess: fullAccess))
                if fullAccess {
                    Text("Full access")
                        .font(scale.captionFont)
                        .padding(.horizontal, scale.space[1]).padding(.vertical, scale.space[0])
                        .background(theme.color("warn").opacity(0.18))
                        .foregroundColor(theme.color("warn"))
                        .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
                        .help("It acts with your permissions, outside the sandbox.")
                }
            }
            .padding(.top, scale.space[0])
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
}

private enum PluginListTab: Hashable { case installed, available, updates }

/// An app-store style row: icon, name and version, author and release day, summary, and one action on the right.
private struct PluginListRow<Trailing: View, Detail: View>: View {
    let listing: PluginListing
    /// Shown instead of the summary line when something needs the user: not approved, disabled, stopped.
    let status: String?
    let statusIsWarning: Bool
    /// Opens the plugin's page; nil for a row with no page.
    let open: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder var detail: () -> Detail
    @Environment(\.theme) var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(alignment: .center, spacing: scale.space[3]) {
            if let open {
                Button(action: open) { info.contentShape(Rectangle()) }.buttonStyle(.plain)
            } else {
                info
            }
            trailing()
            if let open {
                Button(action: open) { Icon(name: "chevron.right", size: 11) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Details")
            }
        }
        .padding(.vertical, scale.space[2])
        .overlay(Divider().opacity(0.5), alignment: .top)
    }

    private var info: some View {
        HStack(alignment: .center, spacing: scale.space[3]) {
            PluginIconTile(listing: listing, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(listing.name).font(scale.emphasisFont).foregroundColor(theme.color("fg"))
                    if let version = listing.version {
                        Text(version).font(scale.caption.font(design: .monospaced)).foregroundColor(theme.color("fg-muted"))
                    }
                }
                .lineLimit(1)
                PluginMetaLine(listing: listing)
                if let status {
                    HStack(spacing: 4) {
                        if statusIsWarning { Image(systemName: "exclamationmark.triangle.fill") }
                        Text(status)
                    }
                    .font(scale.metaFont)
                    .foregroundColor(theme.color(statusIsWarning ? "warn" : "fg-muted"))
                } else if let summary = listing.summary {
                    Text(summary).font(scale.metaFont).foregroundColor(theme.color("fg-muted")).lineLimit(1)
                        .help(summary)
                }
                detail()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension PluginListRow where Detail == EmptyView {
    init(listing: PluginListing, status: String?, statusIsWarning: Bool, open: (() -> Void)?, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(listing: listing, status: status, statusIsWarning: statusIsWarning, open: open, trailing: trailing, detail: { EmptyView() })
    }
}

private extension PluginListing {
    @MainActor static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// "author · Updated 3 days ago"; nil when neither is known.
    @MainActor func meta(now: Date = .now) -> String? {
        let updated = released.map { date in
            now.timeIntervalSince(date) < 86_400 ? "Updated today" : "Updated " + Self.relative.localizedString(for: date, relativeTo: now)
        }
        let parts = [author, updated].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// "author · Updated 3 days ago", after the author's avatar.
private struct PluginMetaLine: View {
    let listing: PluginListing
    @Environment(\.theme) var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        if let meta = listing.meta() {
            HStack(spacing: 5) {
                if let author = listing.author {
                    AuthorAvatar(name: author, image: listing.authorAvatar, size: 14)
                }
                Text(meta).font(scale.metaFont).foregroundColor(theme.color("fg-dim")).lineLimit(1)
            }
        }
    }
}

/// The plugin's SF Symbol, or its initial when it declares none or one this macOS lacks.
private struct PluginIconTile: View {
    let listing: PluginListing
    let size: CGFloat
    @Environment(\.theme) var theme

    var body: some View {
        let symbol = listing.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil }
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(theme.color("accent-soft"))
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium)) // design-literal: scales with the tile
            } else {
                Text(listing.name.prefix(1).uppercased()).font(.system(size: size * 0.44, weight: .semibold, design: .rounded)) // design-literal: scales with the tile
            }
        }
        .foregroundColor(theme.color("accent"))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
    @Environment(\.designScale) private var scale

    var body: some View {
        let host = target.host
        VStack(spacing: 0) {
            Text(target.title)
                .font(.system(size: 15, weight: .semibold)) // design-literal: the one dialog title
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(scale.space[4])
            Divider()
            Group {
                if case .failed(let reason) = host.state {
                    Text("Plugin stopped: \(reason)").font(scale.bodyFont).foregroundColor(theme.color("fg-dim")).multilineTextAlignment(.center)
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
            .padding(scale.space[3])
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
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(scale.glyphFont)
                        .frame(width: 10)
                    Text(title).font(scale.metaFont)
                }
                .foregroundColor(theme.color("fg-dim"))
                .padding(.vertical, scale.space[1])
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
    @Environment(\.designScale) private var scale

    var body: some View {
        PaneDisclosure(title: "Log (\(log.count))") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(log.enumerated()), id: \.offset) { _, entry in
                    Text("[\(entry.level)] \(entry.message)")
                        .font(scale.meta.font(design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundColor(theme.color("fg-dim"))
                }
            }
            .padding(.vertical, scale.space[2])
            .padding(.leading, scale.space[4])
        }
        .padding(.leading, scale.space[3])
        .padding(.bottom, scale.space[2])
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
    @Environment(\.designScale) private var scale

    var body: some View {
        let manifest = request.manifest
        let sandboxed = manifest.capabilities.filter { !$0.isFullAccess }
        let fullAccess = manifest.capabilities.filter(\.isFullAccess)
        VStack(alignment: .leading, spacing: scale.space[3]) {
            if let update = request.update {
                Text("Update \(manifest.name) to \(manifest.version)?")
                    .font(.system(size: 15, weight: .semibold)) // design-literal: the one dialog title
                Text("\(manifest.id) · \(update.from) → \(manifest.version)")
                    .font(scale.meta.font(design: .monospaced)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: scale.space[1]) {
                    Text("New in this version:").font(scale.meta.font(weight: .semibold))
                    ForEach(update.added, id: \.self) { Text("• \($0)").font(scale.bodyFont) }
                }
                .padding(scale.space[2])
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.color("warn").opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
            } else {
                Text("Approve \(manifest.name)?")
                    .font(.system(size: 15, weight: .semibold)) // design-literal: the one dialog title
                Text("\(manifest.id) · version \(manifest.version)")
                    .font(scale.meta.font(design: .monospaced)).foregroundStyle(.secondary)
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
                .font(scale.metaFont).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { finish(false) }.keyboardShortcut(.cancelAction)
                Button(request.update == nil ? "Approve" : "Update and Approve") { finish(true) }.keyboardShortcut(.defaultAction)
                    .disabled(!fullAccess.isEmpty && !acceptsFullAccess)
            }
        }
        .padding(scale.space[4])
        .frame(width: 460)
        // Closed some other way: an update waiting on the answer must still get one.
        .onDisappear { finish(false) }
    }

    private func disclosure(sandboxed: [PluginCapability], fullAccess: [PluginCapability]) -> some View {
        let manifest = request.manifest
        return VStack(alignment: .leading, spacing: scale.space[3]) {
            if manifest.capabilities.isEmpty {
                Text("It requests no capabilities.")
            }
            if !sandboxed.isEmpty || manifest.web != nil {
                Text("Sandboxed. It will be able to:").font(scale.meta.font(weight: .semibold))
                ForEach(sandboxed, id: \.self) { Text("• \($0.summary)") }
                if let summary = manifest.webSummary { Text("• \(summary)") }
            }
            if !manifest.network.isEmpty {
                Text("Web requests: " + manifest.network.joined(separator: ", "))
                    .font(scale.metaFont).textSelection(.enabled)
            }
            ForEach(manifest.settings.filter { $0.kind == .secret }, id: \.key) { secret in
                Text("• Can use \(secret.title) with \(secret.hosts.joined(separator: ", "))")
            }
            if !fullAccess.isEmpty {
                Text("Full access. With your permissions, outside any sandbox, it will be able to:")
                    .font(scale.meta.font(weight: .semibold))
                ForEach(fullAccess, id: \.self) { Text("• \($0.summary)") }
                ForEach(manifest.processes, id: \.id) { process in
                    Text(PluginArgv.display(process.command) + (process.appendArgs ? " …" : ""))
                        .font(scale.meta.font(design: .monospaced)).textSelection(.enabled)
                        .padding(.leading, scale.space[3])
                }
            }
            if let remote = Self.remoteSummary(manifest) {
                Text("On SSH hosts").font(scale.meta.font(weight: .semibold))
                Text(remote)
            }
        }
        .font(scale.bodyFont)
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
