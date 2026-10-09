import SwiftUI

/// Pure display decisions for the background task tray.
enum ACPBackgroundTaskPresentation {
    /// A task name split for display: the program (plus plain subcommands) in
    /// full weight, the arguments dimmed.
    struct CommandParts: Equatable {
        let head: String
        let arguments: String
    }

    /// Splits a shell-like task name into program and arguments, hiding leading
    /// `VAR=value` assignments. Returns nil for names that read as prose
    /// (e.g. "Explore auth module") so they render as plain text.
    static func commandParts(_ name: String) -> CommandParts? {
        var rest = Substring(name.trimmingCharacters(in: .whitespacesAndNewlines))
        func nextToken() -> Substring? {
            rest = rest.drop(while: \.isWhitespace)
            guard !rest.isEmpty else { return nil }
            let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
            let token = rest[..<end]
            rest = rest[end...]
            return token
        }
        func isAssignment(_ token: Substring) -> Bool {
            guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
            let key = token[..<eq]
            return key.first.map { $0.isLetter || $0 == "_" } == true
                && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }

        var program = nextToken()
        while let token = program, isAssignment(token) { program = nextToken() }
        guard let program, program.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || "._/~-".contains($0)) })
        else { return nil }

        var head = String(program.split(separator: "/").last ?? program)
        for _ in 0..<2 {
            let saved = rest
            guard let word = nextToken(),
                  word.first?.isLowercase == true,
                  word.allSatisfy({ $0.isASCII && ($0.isLowercase || $0 == "-") })
            else {
                rest = saved
                break
            }
            head += " " + word
        }
        return CommandParts(head: head, arguments: rest.trimmingCharacters(in: .whitespaces))
    }

    /// A lone task needs no header: its row already names it and its stop
    /// button covers "Stop all", so the tray is just that row.
    static func showsHeader(taskCount: Int) -> Bool { taskCount > 1 }

    /// Whether the rows are visible. Without a header there is nothing to
    /// collapse into, so a lone task is always shown.
    static func isExpanded(taskCount: Int, override: Bool?) -> Bool {
        guard showsHeader(taskCount: taskCount) else { return true }
        return override ?? (taskCount <= 3)
    }

    /// What the header's leading slot shows. Expanded rows carry their own
    /// activity glyphs, so the header only animates while it stands in for them.
    enum HeaderIcon: Equatable {
        case spinner, paused, list
    }

    static func headerIcon(expanded: Bool, allPaused: Bool) -> HeaderIcon {
        if expanded { return .list }
        return allPaused ? .paused : .spinner
    }

    /// Top plus bottom padding around the tray content.
    static let verticalPadding: CGFloat = 10
    static let headerHeight: CGFloat = 22
    static let rowHeight: CGFloat = 26
    /// A failed stop shows up to two lines of error under its row.
    static let rowErrorHeight: CGFloat = 32
    /// Expanded rows scroll beyond this height so a long list can't push the
    /// header off the top of a short chat.
    static let maxRowsHeight: CGFloat = 6 * rowHeight

    static func rowsHeight(_ tasks: [ACPBackgroundTask]) -> CGFloat {
        tasks.reduce(0) { $0 + rowHeight + ($1.stopError == nil ? 0 : rowErrorHeight) }
    }

    /// Height the tray occupies above the composer, so the transcript's tail
    /// spacer can keep the last line clear of it. Zero when there is no work.
    static func trayHeight(tasks: [ACPBackgroundTask], expandedOverride: Bool?) -> CGFloat {
        guard !tasks.isEmpty else { return 0 }
        let header = showsHeader(taskCount: tasks.count) ? headerHeight : 0
        let rows = isExpanded(taskCount: tasks.count, override: expandedOverride)
            ? min(rowsHeight(tasks), maxRowsHeight) : 0
        return verticalPadding + header + rows
    }

    static func elapsedText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, seconds) }
        return "\(seconds)s"
    }

    static func headerTitle(total: Int, paused: Int) -> String {
        let base = "\(total) background tasks"
        return paused > 0 ? "\(base) · \(paused) paused" : base
    }

    /// Text shown under the command when a transcript row is expanded: the
    /// summary, else the description. Either is skipped when it only repeats
    /// the task name, which adapters commonly send for shell commands.
    static func transcriptDetail(_ task: ACPBackgroundTask) -> String? {
        let name = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return [task.summary, task.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != name }
    }
}

extension ACPSession {
    var backgroundTrayHeight: CGFloat {
        ACPBackgroundTaskPresentation.trayHeight(
            tasks: activeBackgroundTasks, expandedOverride: backgroundTrayExpanded)
    }
}

/// Tray docked to the top of the composer listing active background work.
struct ACPBackgroundTaskTray: View {
    let tasks: [ACPBackgroundTask]
    let canStop: Bool
    /// The user's explicit collapse choice; nil follows the default.
    @Binding var expandedOverride: Bool?
    let stop: (String) -> Void
    let stopAll: () -> Void

    @Environment(\.theme) private var theme
    @State private var hoveredId: String?

    private var isExpanded: Bool {
        ACPBackgroundTaskPresentation.isExpanded(taskCount: tasks.count, override: expandedOverride)
    }

    private var pausedCount: Int { tasks.filter { $0.state == "paused" }.count }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 0,
                               bottomTrailingRadius: 0, topTrailingRadius: 10, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if ACPBackgroundTaskPresentation.showsHeader(taskCount: tasks.count) {
                header
            }
            if isExpanded {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tasks) { task in row(task) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(ACPBackgroundTaskPresentation.rowsHeight(tasks),
                                   ACPBackgroundTaskPresentation.maxRowsHeight))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, ACPBackgroundTaskPresentation.verticalPadding / 2)
        .background(shape.fill(theme.color("bg-1")))
        .overlay(shape.strokeBorder(theme.color("line"), lineWidth: 0.75))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background work")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                expandedOverride = !isExpanded
            } label: {
                HStack(spacing: 8) {
                    headerIcon
                    Text(ACPBackgroundTaskPresentation.headerTitle(total: tasks.count, paused: pausedCount))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.color("fg-muted"))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.color("fg-faint"))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse background tasks" : "Expand background tasks")
            if canStop, tasks.contains(where: \.canStop) {
                Button(action: stopAll) {
                    Text("Stop all")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.color("fg-dim"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop all background tasks")
            }
        }
        .frame(height: ACPBackgroundTaskPresentation.headerHeight)
    }

    @ViewBuilder
    private var headerIcon: some View {
        Group {
            switch ACPBackgroundTaskPresentation.headerIcon(
                expanded: isExpanded, allPaused: pausedCount == tasks.count) {
            case .spinner:
                Spinner(lineWidth: 1.2, duration: 0.7)
            case .paused:
                Image(systemName: "pause.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.color("warn"))
            case .list:
                Image(systemName: "list.bullet")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.color("fg-faint"))
            }
        }
        .frame(width: 11, height: 11)
    }

    private func row(_ task: ACPBackgroundTask) -> some View {
        let hovered = hoveredId == task.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                leadingIcon(task)
                commandText(task)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ACPBackgroundTaskPresentation.elapsedText(context.date.timeIntervalSince(task.startedAt)))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.color("fg-faint"))
                }
                stopButton(task)
            }
            .frame(height: ACPBackgroundTaskPresentation.rowHeight)
            if let error = task.stopError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.color("del"))
                    .lineLimit(2)
                    .padding(.leading, 21)
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? theme.color("bg-2") : .clear))
        .padding(.horizontal, -6)
        .acpTrackingHover { inside in
            if inside { hoveredId = task.id } else if hoveredId == task.id { hoveredId = nil }
        }
        .help([task.name, task.summary ?? task.description].compactMap { $0 }.joined(separator: "\n"))
    }

    @ViewBuilder
    private func leadingIcon(_ task: ACPBackgroundTask) -> some View {
        Group {
            if task.state == "paused" {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.color("warn"))
            } else {
                Spinner(lineWidth: 1.2, duration: 0.7)
            }
        }
        .frame(width: 11, height: 11)
    }

    private func commandText(_ task: ACPBackgroundTask) -> some View {
        ACPBackgroundTaskName(name: task.name)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func stopButton(_ task: ACPBackgroundTask) -> some View {
        if canStop && task.canStop {
            StopTaskButton(taskName: task.name) { stop(task.id) }
        } else {
            Color.clear.frame(width: 18, height: 18)
        }
    }
}

/// A task name in one truncated line: shell commands in monospace with the
/// arguments dimmed, prose names in the regular font.
private struct ACPBackgroundTaskName: View {
    let name: String
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let parts = ACPBackgroundTaskPresentation.commandParts(name) {
                (Text(parts.head).foregroundColor(theme.color("fg"))
                    + Text(parts.arguments.isEmpty ? "" : " " + parts.arguments).foregroundColor(theme.color("fg-dim")))
                    .font(.system(size: 11.5, design: .monospaced))
            } else {
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color("fg"))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

/// Transcript row for a background task, styled like a collapsed tool call:
/// label, command chip, duration and status glyph. Expanding reveals the full
/// command, the task's summary and any stop error.
struct ACPBackgroundTaskTranscriptRow: View {
    let task: ACPBackgroundTask

    @State private var expanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .frame(width: 16)
                        .foregroundStyle(theme.color("fg-faint"))
                        .accessibilityHidden(true)
                    Text("Background")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.color("fg-faint"))
                    ACPBackgroundTaskName(name: task.name)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: 4))
                    Spacer(minLength: 6)
                    if let finishedAt = task.finishedAt {
                        Text(ACPToolCallDurationFormatter.string(for: finishedAt.timeIntervalSince(task.startedAt)))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.color("fg-faint"))
                            .lineLimit(1)
                    }
                    status
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.color("fg-faint"))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, expanded ? 10 : 0)
                .padding(.vertical, expanded ? 7 : 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Background task \(task.name), \(task.state)")

            if expanded {
                Divider().background(theme.color("line-soft"))
                details
            }
        }
        .background(expanded ? theme.color("bg-1").opacity(0.5) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("bg-4"), lineWidth: 0.5)
                .opacity(expanded ? 1 : 0)
        )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: task.name)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(theme.color("fg-dim"))
            if let detail = ACPBackgroundTaskPresentation.transcriptDetail(task) {
                Text(verbatim: detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.color("fg-muted"))
            }
            if let error = task.stopError {
                Text(verbatim: error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.color("del"))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.color("bg-0").opacity(0.55))
    }

    @ViewBuilder
    private var status: some View {
        switch task.state {
        case "completed":
            EmptyView()
        case "failed":
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.color("del"))
        case "stopped", "lost":
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.color("fg-faint"))
        case "paused":
            Image(systemName: "pause.fill")
                .font(.system(size: 9))
                .foregroundStyle(theme.color("warn"))
        default:
            Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 11, height: 11)
        }
    }
}

/// Always-visible stop control; the fill appears on hover like the toolbar buttons.
private struct StopTaskButton: View {
    let taskName: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.color(hovering ? "fg" : "fg-muted"))
                .toolbarControlSurface(
                    isLit: hovering,
                    metrics: ToolbarControlMetrics(width: 18, height: 18, cornerRadius: 4))
        }
        .buttonStyle(.toolbarControl)
        .acpTrackingHover { hovering = $0 }
        .help("Stop")
        .accessibilityLabel("Stop background task \(taskName)")
    }
}
