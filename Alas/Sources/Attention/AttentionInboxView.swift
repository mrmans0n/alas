import SwiftUI

struct AttentionInboxRowPresentation: Identifiable {
    let item: AttentionItem
    let now: Date
    var id: UUID { item.eventID }
    var title: String {
        item.presentation == .unverified ? "Last known: \(item.title)" : item.title
    }
    var attribution: String {
        [item.display.projectName, item.display.branch.isEmpty ? RemotePath.display(item.display.path) : item.display.branch,
         item.display.host].compactMap { $0 }.joined(separator: " · ")
    }
    var timestampText: String { Self.timestamp(item.occurredAt, now: now) }
    var absoluteTimestamp: String { item.occurredAt.formatted(date: .complete, time: .standard) }
    var acknowledgmentText: String? {
        item.acknowledgedAt.map { "Acknowledged \(Self.timestamp($0, now: now))" }
    }
    var acknowledgmentHelp: String? {
        item.acknowledgedAt.map { "Acknowledged \($0.formatted(date: .complete, time: .standard))" }
    }
    var emphasizesAction: Bool {
        item.presentation == .live && item.kind.requiresAction && item.acknowledgedAt == nil
    }
    var stateExplanation: String {
        switch item.presentation {
        case .live:
            item.kind.requiresAction
                ? "Still active. Acknowledging this event does not resolve it."
                : "Current activity. No action requested."
        case .unverified:
            "Current state is unavailable. This last-known condition is pending verification."
        case .historical:
            "Past activity. This event is no longer current; it may have cleared or been superseded."
        }
    }
    var actionTitle: String {
        switch item.jumpTarget {
        case .session: "Open session"
        case .runScriptFailure: "View failure"
        case .conflicts: "Open conflicts"
        case .gitOperation: "Open changes"
        case .reviewRequest: "Open review request"
        case .reviewComment: "Open review reply"
        case .remoteWorktree: "Open worktree"
        case .none: "Unavailable"
        }
    }
    var unavailableReason: String? {
        if item.worktree == nil { return "The worktree is no longer available." }
        if item.jumpTarget == .none { return "This event has no destination." }
        return nil
    }
    var dismissAccessibilityLabel: String? {
        guard item.acknowledgedAt == nil, item.kind.requiresAction, item.presentation != .historical else { return nil }
        return "Acknowledge, \(title), \(attribution)"
    }

    static func timestamp(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(
            date: calendar.isDate(date, inSameDayAs: now) ? .omitted : .abbreviated,
            time: .shortened, calendar: calendar, timeZone: calendar.timeZone
        ))
    }
}

struct AttentionInboxPresentation {
    struct PersistenceError: Identifiable {
        let title: String
        let message: String
        var id: String { title }
    }

    let activeRows: [AttentionInboxRowPresentation]
    let peerRows: [RemoteSessionSummary]
    let pluginUpdates: [PluginManager.CatalogUpdate]
    let appUpdate: ReleaseInfo?
    let appUpdateReadyToRelaunch: Bool
    let cleanupReminders: [WorktreeCleanupReminder]
    let historyRows: [AttentionInboxRowPresentation]
    let errors: [PersistenceError]
    var totalCount: Int {
        activeRows.count + peerRows.count + pluginUpdates.count + (appUpdate == nil ? 0 : 1) + cleanupReminders.count
    }
    var emptyTitle: String? { totalCount == 0 ? "Nothing needs attention" : nil }
    var acknowledgeLabel: String? {
        guard !activeRows.isEmpty else { return nil }
        return activeRows.count == totalCount ? "Acknowledge all" : "Acknowledge local"
    }

    /// Label for the collapsed-by-default history section, used for both the tooltip and VoiceOver.
    static func historyToggleLabel(count: Int, isExpanded: Bool) -> String {
        let events = count == 1 ? "1 activity event" : "\(count) activity events"
        return isExpanded ? "Hide \(events)" : "Show \(events)"
    }

    init(aggregation: AttentionAggregation, loadError: String?, writeError: String? = nil,
         peerRows: [RemoteSessionSummary] = [], pluginUpdates: [PluginManager.CatalogUpdate] = [],
         appUpdate: ReleaseInfo? = nil, appUpdateReadyToRelaunch: Bool = false,
         cleanupReminders: [WorktreeCleanupReminder] = [], now: Date = Date()) {
        activeRows = aggregation.items.map { AttentionInboxRowPresentation(item: $0, now: now) }
        self.peerRows = peerRows
        self.pluginUpdates = pluginUpdates
        self.appUpdate = appUpdate
        self.appUpdateReadyToRelaunch = appUpdateReadyToRelaunch
        self.cleanupReminders = cleanupReminders
        historyRows = aggregation.history.map { AttentionInboxRowPresentation(item: $0, now: now) }
        errors = [
            loadError.map { PersistenceError(title: "History could not be loaded", message: $0) },
            writeError.map { PersistenceError(title: "History could not be saved", message: $0) },
        ].compactMap { $0 }
    }
}

struct AttentionInboxView: View {
    let aggregation: AttentionAggregation
    let peerRows: [RemoteSessionSummary]
    var pluginUpdates: [PluginManager.CatalogUpdate] = []
    var appUpdate: ReleaseInfo? = nil
    var appUpdateReadyToRelaunch = false
    var cleanupReminders: [WorktreeCleanupReminder] = []
    let loadError: String?
    let writeError: String?
    let navigationErrors: [UUID: String]
    let onDismiss: (AttentionItem) -> Void
    let onOpen: (AttentionItem) async -> Void
    let onOpenPeer: (RemoteSessionSummary) -> Void
    var onOpenPluginSettings: () -> Void = {}
    var onOpenAppUpdate: () -> Void = {}
    var onOpenWorktreeCleanup: (String) -> Void = { _ in }
    var onDismissWorktreeCleanup: (String) -> Void = { _ in }
    /// Nil hides the roll-up entirely, leaving the ordinary inbox.
    var rollUpSummarizer: AttentionRollUpSummarizer? = nil
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var historyExpanded = false
    @State private var rollUpVisible = false
    @State private var rollUp: AttentionRollUp?
    @State private var rollUpTask: Task<Void, Never>?

    private var canSummarize: Bool {
        aggregation.items.count >= AttentionRollUpPolicy.minimumItems && rollUpSummarizer?.isAvailable == true
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = AttentionInboxPresentation(
                aggregation: aggregation, loadError: loadError, writeError: writeError,
                peerRows: peerRows, pluginUpdates: pluginUpdates, appUpdate: appUpdate,
                appUpdateReadyToRelaunch: appUpdateReadyToRelaunch, cleanupReminders: cleanupReminders, now: context.date
            )
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "tray")
                        .font(scale.meta.font)
                        .foregroundStyle(theme.color(presentation.totalCount > 0 ? "warn" : "fg-muted"))
                        .accessibilityHidden(true)
                    Text("Inbox")
                        .font(scale.title.font)
                    Text("\(presentation.totalCount)")
                        .font(scale.meta.font(weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(theme.color("fg-muted"))
                        .accessibilityLabel("\(presentation.totalCount) items needing attention")
                    Spacer()
                    if canSummarize, !rollUpVisible {
                        Button("Summarize", action: summarize)
                            .controlSize(.small)
                            .help("Group the items needing attention on-device")
                    }
                    if let acknowledgeLabel = presentation.acknowledgeLabel {
                        Button(acknowledgeLabel) {
                            for item in presentation.activeRows { onDismiss(item.item) }
                        }
                        .controlSize(.small)
                        .accessibilityLabel("\(acknowledgeLabel) \(presentation.activeRows.count) items needing attention")
                    }
                }
                .foregroundStyle(theme.color("fg"))
                .padding(.horizontal, scale.space[4])
                .padding(.vertical, scale.space[3])
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if rollUpVisible {
                            AttentionRollUpCard(
                                phase: .resolve(isSummarizing: rollUpTask != nil, rollUp: rollUp,
                                                currentItems: aggregation.items),
                                now: context.date,
                                canSummarize: canSummarize,
                                onSummarize: summarize,
                                onCancel: dismissRollUp,
                                onDismiss: dismissRollUp
                            )
                        }
                        AttentionInboxList(presentation: presentation, historyExpanded: $historyExpanded,
                                           navigationErrors: navigationErrors, onDismiss: onDismiss,
                                           onOpen: onOpen, onOpenPeer: onOpenPeer,
                                           onOpenPluginSettings: onOpenPluginSettings,
                                           onOpenAppUpdate: onOpenAppUpdate,
                                           onOpenWorktreeCleanup: onOpenWorktreeCleanup,
                                           onDismissWorktreeCleanup: onDismissWorktreeCleanup)
                    }
                    .padding(scale.space[4])
                }
            }
            .frame(width: 440) // design-literal: fixed popover width; fits roll-up item lines at meta size
            .frame(maxHeight: 520) // design-literal: fixed popover height cap
            .background(theme.color("bg-1"))
            .foregroundStyle(theme.color("fg"))
        }
        .onDisappear(perform: dismissRollUp)
        #if DEBUG
        .task {
            if DesignCaptureAttention.shared.autoSummarize { summarize() }
        }
        #endif
    }

    private func summarize() {
        guard rollUpTask == nil, let rollUpSummarizer, canSummarize else { return }
        rollUpVisible = true
        rollUp = nil
        let items = aggregation.items
        rollUpTask = Task { @MainActor in
            let result = await rollUpSummarizer.rollUp(items)
            guard !Task.isCancelled else { return }
            rollUp = result
            rollUpTask = nil
        }
    }

    private func dismissRollUp() {
        rollUpTask?.cancel()
        rollUpTask = nil
        rollUp = nil
        rollUpVisible = false
    }
}

/// The scrollable body of the inbox: errors, empty state, active rows, and the collapsible
/// history section. Split out from `AttentionInboxView` so it can be measured directly in
/// tests without the ScrollView's greedy-fill sizing masking its intrinsic height.
struct AttentionInboxList: View {
    let presentation: AttentionInboxPresentation
    @Binding var historyExpanded: Bool
    let navigationErrors: [UUID: String]
    let onDismiss: (AttentionItem) -> Void
    let onOpen: (AttentionItem) async -> Void
    var onOpenPeer: (RemoteSessionSummary) -> Void = { _ in }
    var onOpenPluginSettings: () -> Void = {}
    var onOpenAppUpdate: () -> Void = {}
    var onOpenWorktreeCleanup: (String) -> Void = { _ in }
    var onDismissWorktreeCleanup: (String) -> Void = { _ in }
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(presentation.errors) { error in
                AttentionInboxErrorRow(title: error.title, message: error.message)
            }
            if let emptyTitle = presentation.emptyTitle {
                VStack(alignment: .leading, spacing: 6) {
                    Text(emptyTitle).font(scale.emphasis.font)
                    Text("New requests will appear here. Acknowledged events and other activity remain below.")
                        .font(scale.meta.font)
                        .foregroundStyle(theme.color("fg-muted"))
                }
                .padding(.vertical, scale.space[4])
            }
            ForEach(presentation.activeRows) { row in
                AttentionInboxRow(presentation: row, isHistory: false,
                                  navigationError: navigationErrors[row.id], onDismiss: onDismiss, onOpen: onOpen)
            }
            if !presentation.peerRows.isEmpty {
                Text("Peer sessions")
                    .font(scale.caption.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg-muted"))
                    .padding(.top, scale.space[3])
                ForEach(presentation.peerRows, id: \.id) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(theme.color("warn"))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title).font(scale.emphasis.font)
                            Text(row.serverName ?? "Peer")
                                .font(scale.meta.font)
                                .foregroundStyle(theme.color("fg-muted"))
                        }
                        Spacer()
                        Button("Open") { onOpenPeer(row) }
                            .controlSize(.small)
                    }
                    .padding(scale.space[3])
                    .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: scale.radius.medium))
                }
            }
            if let update = presentation.appUpdate {
                Text("App update")
                    .font(scale.caption.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg-muted"))
                    .padding(.top, scale.space[3])
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.down.app")
                        .foregroundStyle(theme.color("accent"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Alas").font(scale.emphasis.font)
                        let status = presentation.appUpdateReadyToRelaunch ? "installed" : "available"
                        switch update {
                        case .stable(let release):
                            Text("Version \(release.version.description) \(status)")
                                .font(scale.meta.font)
                                .foregroundStyle(theme.color("fg-muted"))
                        case .nightly(let release):
                            Text("Nightly \(release.shortSHA) \(status)")
                                .font(scale.meta.font)
                                .foregroundStyle(theme.color("fg-muted"))
                        }
                    }
                    Spacer()
                    Button(presentation.appUpdateReadyToRelaunch ? "Relaunch" : "View update",
                           action: onOpenAppUpdate)
                        .controlSize(.small)
                }
                .padding(scale.space[3])
                .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: scale.radius.medium))
            }
            if !presentation.cleanupReminders.isEmpty {
                Text("Worktree cleanup")
                    .font(scale.caption.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg-muted"))
                    .padding(.top, scale.space[3])
                ForEach(presentation.cleanupReminders) { reminder in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "archivebox")
                            .foregroundStyle(theme.color("accent"))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reminder.projectName).font(scale.emphasis.font)
                            Text("\(reminder.readyCount) worktrees look ready to clean up")
                                .font(scale.meta.font)
                                .foregroundStyle(theme.color("fg-muted"))
                        }
                        Spacer()
                        Button("Dismiss") { onDismissWorktreeCleanup(reminder.projectId) }
                            .controlSize(.small)
                            .help("Hide until more worktrees are ready to clean up")
                        Button("Clean Up…") { onOpenWorktreeCleanup(reminder.projectId) }
                            .controlSize(.small)
                    }
                    .padding(scale.space[3])
                    .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: scale.radius.medium))
                }
            }
            if !presentation.pluginUpdates.isEmpty {
                Text("Plugin updates")
                    .font(scale.caption.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg-muted"))
                    .padding(.top, scale.space[3])
                ForEach(presentation.pluginUpdates, id: \.entry.id) { update in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundStyle(theme.color("accent"))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(update.entry.name).font(scale.emphasis.font)
                            Text("Version \(update.version.version) available")
                                .font(scale.meta.font)
                                .foregroundStyle(theme.color("fg-muted"))
                        }
                        Spacer()
                        Button("Open Settings", action: onOpenPluginSettings)
                            .controlSize(.small)
                    }
                    .padding(scale.space[3])
                    .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: scale.radius.medium))
                }
            }
            if !presentation.historyRows.isEmpty {
                AttentionInboxHistoryToggle(count: presentation.historyRows.count, isExpanded: $historyExpanded)
                    .padding(.top, scale.space[3])
                if historyExpanded {
                    ForEach(presentation.historyRows) { row in
                        AttentionInboxRow(presentation: row, isHistory: true,
                                          navigationError: navigationErrors[row.id], onDismiss: onDismiss, onOpen: onOpen)
                    }
                }
            }
        }
    }
}

struct AttentionInboxRow: View {
    let presentation: AttentionInboxRowPresentation
    let isHistory: Bool
    let navigationError: String?
    let onDismiss: (AttentionItem) -> Void
    let onOpen: (AttentionItem) async -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var opening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: presentation.emphasizesAction ? "exclamationmark.circle" : "clock")
                    .foregroundStyle(theme.color(presentation.emphasizesAction ? "warn" : "fg-dim"))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(presentation.title)
                        .font(isHistory ? scale.body.font : scale.emphasis.font)
                    Text(presentation.attribution)
                        .font(scale.meta.font)
                        .foregroundStyle(theme.color("fg-muted"))
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Text(presentation.timestampText)
                    .font(scale.meta.font)
                    .foregroundStyle(theme.color("fg-muted"))
                    .fixedSize()
                    .help(presentation.absoluteTimestamp)
                    .accessibilityLabel(presentation.absoluteTimestamp)
            }
            Text(presentation.stateExplanation)
                .font(scale.meta.font)
                .foregroundStyle(theme.color("fg-muted"))
            if let body = presentation.item.body, !body.isEmpty {
                Text(body)
                    .font(scale.meta.font)
                    .foregroundStyle(theme.color("fg-muted"))
                    .textSelection(.enabled)
            }
            if let error = navigationError ?? (isHistory && presentation.item.jumpTarget == .none ? nil : presentation.unavailableReason) {
                Text(error).font(scale.meta.font).foregroundStyle(theme.color("warn"))
            }
            HStack {
                if let acknowledgment = presentation.acknowledgmentText {
                    Text(acknowledgment)
                        .font(scale.meta.font)
                        .foregroundStyle(theme.color("fg-muted"))
                        .help(presentation.acknowledgmentHelp ?? acknowledgment)
                        .accessibilityLabel(presentation.acknowledgmentHelp ?? acknowledgment)
                }
                Spacer(minLength: 0)
                if !isHistory, let acknowledgmentLabel = presentation.dismissAccessibilityLabel {
                    Button("Acknowledge") { onDismiss(presentation.item) }
                        .controlSize(.small)
                        .accessibilityLabel(acknowledgmentLabel)
                }
                if !isHistory || presentation.item.jumpTarget != .none {
                    Button(presentation.actionTitle) {
                        opening = true
                        Task { @MainActor in
                            await onOpen(presentation.item)
                            opening = false
                        }
                    }
                    .controlSize(.small)
                    .disabled(opening || presentation.unavailableReason != nil)
                    .accessibilityLabel("\(presentation.actionTitle), \(presentation.title), \(presentation.attribution)")
                }
            }
        }
        .padding(scale.space[4])
        .background(theme.color(isHistory ? "bg-1" : "bg-2"), in: RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay { RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 1) }
        .foregroundStyle(theme.color(isHistory ? "fg-muted" : "fg"))
        .accessibilityElement(children: .contain)
    }
}

/// Header for acknowledged events and other activity. Starts collapsed so the panel
/// opens on what needs attention without hiding access to current or past activity.
private struct AttentionInboxHistoryToggle: View {
    let count: Int
    @Binding var isExpanded: Bool
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var hovering = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(scale.glyph.font)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
                Text("Activity")
                    .font(scale.meta.font(weight: .semibold))
                Text("\(count)")
                    .font(scale.meta.font)
                    .monospacedDigit()
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.color(hovering ? "fg" : "fg-muted"))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(AttentionInboxPresentation.historyToggleLabel(count: count, isExpanded: isExpanded))
        .accessibilityLabel(AttentionInboxPresentation.historyToggleLabel(count: count, isExpanded: isExpanded))
        .accessibilityAddTraits(.isHeader)
    }
}

private struct AttentionInboxErrorRow: View {
    let title: String
    let message: String
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(scale.meta.font(weight: .medium))
            Text(message).font(scale.meta.font).textSelection(.enabled)
        }
        .foregroundStyle(theme.color("warn"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(scale.space[3])
        .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: scale.radius.medium))
        .accessibilityElement(children: .combine)
    }
}
