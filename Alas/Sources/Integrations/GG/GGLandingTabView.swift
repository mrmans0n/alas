import SwiftUI

struct GGLandingTabState: Codable, Equatable, Identifiable {
    let projectId: String
    let stackName: String
    var id: TabID { "gg-land:\(projectId)" }
    var title: String { "Land · \(stackName)" }
}

enum GGLandingPresentation {
    static func duration(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    static func detail(for wait: GGLandWait) -> String {
        var facts: [String] = []
        switch wait.phase {
        case .readiness:
            if let ci = wait.ciStatus {
                switch ci {
                case "success": facts.append("CI passed")
                case "failure", "failed": facts.append("CI failed")
                default: facts.append("CI \(ci)")
                }
            }
            if let approved = wait.approved {
                facts.append(approved ? "Approved" : "Waiting for approval")
            }
            if facts.isEmpty { facts.append("Waiting for readiness") }
        case .mergeTrain:
            facts.append("Merge train")
            if let position = wait.mergeTrainPosition { facts.append("Position \(position)") }
            if wait.pipelineRunning == true { facts.append("Pipeline running") }
        }
        facts.append("Waiting \(duration(seconds: wait.elapsedSeconds))")
        return facts.joined(separator: " · ")
    }

    static func isActive(_ row: GGLandingRow, in session: GGLandingSession) -> Bool {
        guard session.phase == .running || session.phase == .cancelling,
              !session.isPreparing, row.outcome == nil else { return false }
        return row.position == (session.activeWait?.position ?? session.rows.first { $0.outcome == nil }?.position)
    }

    static func detail(for row: GGLandingRow, in session: GGLandingSession) -> String {
        if let outcome = row.outcome {
            if let error = outcome.error { return error }
            switch outcome.action {
            case "merged": return "Merged"
            case "queued", "already_queued": return "Queued"
            default: return outcome.action?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Completed"
            }
        }
        if session.phase == .cancelled { return "Cancelled" }
        if session.phase == .failed || session.phase == .succeeded { return "Not landed" }
        if isActive(row, in: session) {
            if session.phase == .cancelling { return "Cancelling…" }
            if let wait = row.wait { return detail(for: wait) }
            return "Landing…"
        }
        if session.phase == .running, session.isPreparing,
           row.position == session.rows.first(where: { $0.outcome == nil })?.position {
            return "Checking stack…"
        }
        return "Pending"
    }

    static func summary(for session: GGLandingSession) -> String {
        let counts = counts(for: session)
        var facts: [String] = []
        if session.phase == .cancelled { facts.append("Cancelled") }
        if session.phase == .failed { facts.append("Failed") }
        facts.append("\(counts.merged) merged")
        if counts.queued > 0 { facts.append("\(counts.queued) queued") }
        facts.append("\(counts.remaining) remaining")
        return facts.joined(separator: " · ")
    }

    struct SidebarStatus: Equatable {
        let title: String
        let colorToken: String
        let isSpinning: Bool
    }

    static func sidebarStatus(for session: GGLandingSession) -> SidebarStatus? {
        switch session.phase {
        case .succeeded: return nil
        case .cancelled: return .init(title: "Landing cancelled", colorToken: "fg-dim", isSpinning: false)
        case .failed: return .init(title: "Landing failed", colorToken: "del", isSpinning: false)
        case .cancelling: return .init(title: "Cancelling…", colorToken: "accent", isSpinning: true)
        case .running:
            let counts = counts(for: session)
            return .init(
                title: session.isPreparing ? "Checking stack…" : "Landing \(counts.completed)/\(counts.total)",
                colorToken: "accent", isSpinning: true
            )
        }
    }

    struct Counts: Equatable {
        var total = 0
        var completed = 0
        var merged = 0
        var queued = 0
        var remaining = 0
    }

    static func counts(for session: GGLandingSession) -> Counts {
        var counts = Counts(total: session.rows.count)
        for row in session.rows {
            guard let outcome = row.outcome, outcome.error == nil else { continue }
            counts.completed += 1
            if outcome.action == "merged" { counts.merged += 1 }
            if outcome.action == "queued" || outcome.action == "already_queued" { counts.queued += 1 }
        }
        counts.remaining = session.result?.remaining ?? max(0, counts.total - counts.completed)
        return counts
    }

    enum Status: Equatable {
        case checking, landing, readiness, mergeTrain, cancelling, cancelled, failed, merged, queued

        var title: String {
            switch self {
            case .checking: return "Checking stack…"
            case .landing: return "Landing stack…"
            case .readiness: return "Waiting for readiness"
            case .mergeTrain: return "Waiting in merge train"
            case .cancelling: return "Cancelling…"
            case .cancelled: return "Landing cancelled"
            case .failed: return "Landing failed"
            case .merged: return "Landing complete"
            case .queued: return "Submitted to merge queue"
            }
        }

        var isSpinning: Bool {
            switch self {
            case .checking, .landing, .readiness, .mergeTrain, .cancelling: return true
            case .cancelled, .failed, .merged, .queued: return false
            }
        }

        var colorToken: String {
            switch self {
            case .failed: return "del"
            case .cancelled: return "fg-dim"
            case .merged: return "add"
            case .queued: return "caution"
            default: return "accent"
            }
        }

        var icon: String {
            switch self {
            case .failed: return "xmark.circle"
            case .cancelled: return "stop.circle"
            case .merged: return "checkmark.circle"
            case .queued: return "clock"
            default: return "circle"
            }
        }
    }

    static func status(for session: GGLandingSession) -> Status {
        switch session.phase {
        case .cancelled: return .cancelled
        case .failed: return .failed
        case .cancelling: return .cancelling
        case .succeeded: return counts(for: session).queued > 0 ? .queued : .merged
        case .running:
            if session.isPreparing { return .checking }
            switch session.activeWait?.phase {
            case .readiness: return .readiness
            case .mergeTrain: return .mergeTrain
            case nil: return .landing
            }
        }
    }

    static func statusTitle(for session: GGLandingSession) -> String {
        let status = status(for: session)
        guard session.phase == .running, !session.isPreparing, let wait = session.activeWait else {
            return status.title
        }
        let title: String
        if wait.phase == .readiness {
            switch wait.ciStatus {
            case "pending", "running", "failure", "failed", "canceled", "cancelled":
                title = "Waiting for CI"
            default:
                title = wait.approved == false ? "Waiting for approval" : status.title
            }
        } else {
            title = status.title
        }
        return "\(title) · #\(wait.prNumber)"
    }

    enum RowStatus: Equatable {
        case pending, active, merged, queued, completed, failed, cancelled, notLanded

        var colorToken: String {
            switch self {
            case .active: return "accent"
            case .merged: return "add"
            case .queued: return "caution"
            case .failed: return "del"
            default: return "fg-dim"
            }
        }

        var icon: String {
            switch self {
            case .merged: return "checkmark.circle"
            case .queued: return "clock"
            case .completed: return "checkmark"
            case .failed: return "xmark.circle"
            case .cancelled: return "stop.circle"
            default: return "circle"
            }
        }
    }

    static func rowStatus(for row: GGLandingRow, in session: GGLandingSession) -> RowStatus {
        if let outcome = row.outcome {
            if outcome.error != nil { return .failed }
            switch outcome.action {
            case "merged": return .merged
            case "queued", "already_queued": return .queued
            default: return .completed
            }
        }
        if session.phase == .cancelled { return .cancelled }
        if session.phase == .failed || session.phase == .succeeded { return .notLanded }
        return isActive(row, in: session) ? .active : .pending
    }

    static func warnings(for session: GGLandingSession) -> [String] {
        var warnings = session.result?.warnings ?? []
        if let warning = session.warning, !warnings.contains(warning) {
            warnings.insert(warning, at: 0)
        }
        return warnings
    }

    static func errors(for session: GGLandingSession) -> [String] {
        var errors: [String] = []
        if let error = session.error { errors.append(error) }
        if let error = session.result?.error, !errors.contains(error) { errors.append(error) }
        return errors
    }
}

struct GGLandingTabView: View {
    let state: AppState
    let tabState: GGLandingTabState
    private let store = GGLandingStore.shared

    var body: some View {
        if let session = store.sessions[tabState.projectId] {
            GGLandingContentView(
                session: session,
                onCancel: { state.cancelGGLanding(projectId: tabState.projectId) },
                onRestart: { state.restartGGLanding(projectId: tabState.projectId) }
            )
        } else {
            ContentUnavailableView("Landing session unavailable", systemImage: "arrow.down.to.line")
                .accessibilityIdentifier("gg-landing-tab")
        }
    }
}

struct GGLandingContentView: View {
    let session: GGLandingSession
    let onCancel: () -> Void
    let onRestart: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.color("line"))
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        GGLandingStatusCard(session: session)
                        HStack {
                            Text("STACK ORDER")
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.5)
                            Spacer()
                            Text("\(session.rows.count) entries")
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                        }
                        .foregroundStyle(theme.color("fg-muted"))
                        LazyVStack(spacing: 7) {
                            ForEach(session.rows) { row in
                                GGLandingEntryView(row: row, session: session)
                            }
                        }
                        if session.phase == .running {
                            Text("You can switch tabs or worktrees while landing continues.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(theme.color("fg-faint"))
                        } else if session.phase == .cancelling || session.phase == .cancelled {
                            Text("Completed merges and queued entries are not undone by cancellation.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(theme.color("fg-muted"))
                        }
                    }
                    .frame(
                        maxWidth: ACPChatLayout.contentMaxWidth(forPaneWidth: proxy.size.width),
                        alignment: .leading
                    )
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .background(theme.color("bg-1"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Landing \(session.stack)")
        .accessibilityIdentifier("gg-landing-tab")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Icon(name: "branch", size: 12, color: theme.color("fg-muted"))
            Text("Land · \(session.stack)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            GGLandingRuntimeView(startedAt: session.startedAt, endedAt: session.endedAt)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(theme.color("fg-faint"))
                .fixedSize()
            if session.phase == .running || session.phase == .cancelling {
                Button(session.phase == .cancelling ? "Cancelling…" : "Cancel", action: onCancel)
                    .disabled(session.phase == .cancelling)
                    .accessibilityLabel(session.phase == .cancelling ? "Cancelling landing" : "Cancel landing")
                    .accessibilityIdentifier("gg-landing-cancel")
            } else if session.phase == .failed || session.phase == .cancelled {
                Button("Restart", action: onRestart)
                    .accessibilityLabel("Restart landing")
                    .accessibilityIdentifier("gg-landing-restart")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(theme.color("accent"))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct GGLandingRuntimeView: View {
    let startedAt: Date
    let endedAt: Date?

    var body: some View {
        if let endedAt {
            Text(GGLandingPresentation.duration(seconds: Int(endedAt.timeIntervalSince(startedAt))))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(GGLandingPresentation.duration(seconds: Int(context.date.timeIntervalSince(startedAt))))
            }
        }
    }
}

private struct GGLandingStatusCard: View {
    let session: GGLandingSession
    @Environment(\.theme) private var theme

    var body: some View {
        let status = GGLandingPresentation.status(for: session)
        let warnings = GGLandingPresentation.warnings(for: session)
        let errors = GGLandingPresentation.errors(for: session)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if status.isSpinning {
                        Spinner(lineWidth: 1.5, color: theme.color(status.colorToken))
                    } else {
                        Image(systemName: status.icon)
                            .foregroundStyle(theme.color(status.colorToken))
                    }
                }
                .frame(width: 13, height: 13)
                .accessibilityHidden(true)
                Text(GGLandingPresentation.statusTitle(for: session))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(status == .checking ? "gg-landing-preparing" : "gg-landing-status")
            }
            if session.phase == .running, !session.isPreparing, let wait = session.activeWait {
                Text("Entry \(wait.position) · \(GGLandingPresentation.detail(for: wait))")
                    .foregroundStyle(theme.color("fg-muted"))
            }
            Text(GGLandingPresentation.summary(for: session))
                .foregroundStyle(theme.color("fg-dim"))
                .monospacedDigit()
            if status == .queued {
                Text("Queued entries have not merged yet.")
                    .foregroundStyle(theme.color("caution"))
            }
            if !errors.isEmpty {
                Text(errors.joined(separator: "\n"))
                    .foregroundStyle(theme.color("del"))
            }
            if !warnings.isEmpty {
                Label {
                    Text(warnings.joined(separator: "\n"))
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(theme.color("caution"))
                .accessibilityIdentifier("gg-landing-warning")
            }
        }
        .font(.system(size: 10.5))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.color(status.colorToken).opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        }
    }
}

private struct GGLandingEntryView: View {
    let row: GGLandingRow
    let session: GGLandingSession
    @Environment(\.theme) private var theme

    var body: some View {
        let status = GGLandingPresentation.rowStatus(for: row, in: session)
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(row.position)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.color("fg-faint"))
                .frame(minWidth: 12)
            Group {
                if status == .active {
                    Spinner(lineWidth: 1.4, color: theme.color(status.colorToken))
                } else {
                    Image(systemName: status.icon)
                        .foregroundStyle(theme.color(status.colorToken))
                }
            }
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color("fg"))
                Text(GGLandingPresentation.detail(for: row, in: session))
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.color(status == .pending ? "fg-dim" : status.colorToken))
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let number = row.prNumber {
                Text(verbatim: "#\(number)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.color("fg-muted"))
                    .fixedSize()
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(theme.color("line")).frame(width: 0.5)
                    }
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            status == .active ? theme.color("accent-soft") : theme.color(status.colorToken).opacity(status == .pending ? 0 : 0.04),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(theme.color(status == .active ? "accent" : "line"), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Entry \(row.position), \(row.title)")
        .accessibilityIdentifier("gg-landing-row-\(row.position)")
    }
}
