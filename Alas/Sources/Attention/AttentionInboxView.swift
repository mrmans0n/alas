import SwiftUI

struct AttentionInboxRowPresentation: Identifiable {
    let item: AttentionItem
    let now: Date
    var id: UUID { item.eventID }
    var title: String { item.title }
    var attribution: String {
        [item.display.projectName, item.display.branch.isEmpty ? item.display.path : item.display.branch,
         item.display.host].compactMap { $0 }.joined(separator: " · ")
    }
    var timestampText: String { Self.timestamp(item.occurredAt, now: now) }
    var absoluteTimestamp: String { item.occurredAt.formatted(date: .complete, time: .standard) }
    var acknowledgmentText: String? {
        item.acknowledgedAt.map { "Addressed \(Self.timestamp($0, now: now))" }
    }
    var acknowledgmentHelp: String? {
        item.acknowledgedAt.map { "Addressed \($0.formatted(date: .complete, time: .standard))" }
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
        guard item.acknowledgedAt == nil else { return nil }
        return "Dismiss, \(title), \(attribution)"
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
    let historyRows: [AttentionInboxRowPresentation]
    let errors: [PersistenceError]
    var emptyTitle: String? { activeRows.isEmpty ? "Nothing needs attention" : nil }

    init(aggregation: AttentionAggregation, loadError: String?, writeError: String? = nil, now: Date = Date()) {
        activeRows = aggregation.items.map { AttentionInboxRowPresentation(item: $0, now: now) }
        historyRows = aggregation.history.map { AttentionInboxRowPresentation(item: $0, now: now) }
        errors = [
            loadError.map { PersistenceError(title: "History could not be loaded", message: $0) },
            writeError.map { PersistenceError(title: "History could not be saved", message: $0) },
        ].compactMap { $0 }
    }
}

struct AttentionInboxView: View {
    let aggregation: AttentionAggregation
    let loadError: String?
    let writeError: String?
    let navigationErrors: [UUID: String]
    let onDismiss: (AttentionItem) -> Void
    let onOpen: (AttentionItem) async -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = AttentionInboxPresentation(
                aggregation: aggregation, loadError: loadError, writeError: writeError, now: context.date
            )
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.color("warn"))
                        .accessibilityHidden(true)
                    Text("Needs attention")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(aggregation.unresolvedCount)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(theme.color("fg-muted"))
                        .accessibilityLabel("\(aggregation.unresolvedCount) unresolved items")
                    Spacer()
                    if !presentation.activeRows.isEmpty {
                        Button("Dismiss all") {
                            for item in presentation.activeRows { onDismiss(item.item) }
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Dismiss all \(aggregation.unresolvedCount) unresolved items")
                    }
                }
                .foregroundStyle(theme.color("fg"))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(presentation.errors) { error in
                            AttentionInboxErrorRow(title: error.title, message: error.message)
                        }
                        if let emptyTitle = presentation.emptyTitle {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(emptyTitle).font(.system(size: 13, weight: .medium))
                                Text("New requests will appear here. Earlier events stay below.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.color("fg-muted"))
                            }
                            .padding(.vertical, 16)
                        }
                        ForEach(presentation.activeRows) { row in
                            AttentionInboxRow(presentation: row, isHistory: false,
                                              navigationError: navigationErrors[row.id], onDismiss: onDismiss, onOpen: onOpen)
                        }
                        if !presentation.historyRows.isEmpty {
                            Text("Earlier")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.color("fg-muted"))
                                .padding(.top, 10)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(presentation.historyRows) { row in
                                AttentionInboxRow(presentation: row, isHistory: true,
                                                  navigationError: navigationErrors[row.id], onDismiss: onDismiss, onOpen: onOpen)
                            }
                        }
                    }
                    .padding(14)
                }
            }
            .frame(width: 400)
            .frame(maxHeight: 520)
            .background(theme.color("bg-1"))
            .foregroundStyle(theme.color("fg"))
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
    @State private var opening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isHistory ? "clock" : "exclamationmark.circle")
                    .foregroundStyle(theme.color(isHistory ? "fg-dim" : "warn"))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(presentation.title)
                        .font(.system(size: 13, weight: isHistory ? .regular : .medium))
                    Text(presentation.attribution)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("fg-muted"))
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Text(presentation.timestampText)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-muted"))
                    .fixedSize()
                    .help(presentation.absoluteTimestamp)
                    .accessibilityLabel(presentation.absoluteTimestamp)
            }
            if let body = presentation.item.body, !body.isEmpty {
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color("fg-muted"))
                    .textSelection(.enabled)
            }
            if let error = navigationError ?? (isHistory && presentation.item.jumpTarget == .none ? nil : presentation.unavailableReason) {
                Text(error).font(.system(size: 11)).foregroundStyle(theme.color("warn"))
            }
            HStack {
                if let acknowledgment = presentation.acknowledgmentText {
                    Text(acknowledgment)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("fg-muted"))
                        .help(presentation.acknowledgmentHelp ?? acknowledgment)
                        .accessibilityLabel(presentation.acknowledgmentHelp ?? acknowledgment)
                }
                Spacer(minLength: 0)
                if !isHistory {
                    Button("Dismiss") { onDismiss(presentation.item) }
                        .controlSize(.small)
                        .accessibilityLabel(presentation.dismissAccessibilityLabel ?? "Dismiss")
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
        .padding(14)
        .background(theme.color(isHistory ? "bg-1" : "bg-2"), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color("line"), lineWidth: 1) }
        .foregroundStyle(theme.color(isHistory ? "fg-muted" : "fg"))
        .accessibilityElement(children: .contain)
    }
}

private struct AttentionInboxErrorRow: View {
    let title: String
    let message: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
            Text(message).font(.system(size: 11)).textSelection(.enabled)
        }
        .foregroundStyle(theme.color("warn"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
