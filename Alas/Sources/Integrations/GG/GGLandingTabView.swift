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
        guard session.phase == .running || session.phase == .cancelling, row.outcome == nil else { return false }
        return row.position == (session.activeWait?.position ?? session.rows.first { $0.outcome == nil }?.position)
    }

    static func detail(for row: GGLandingRow, in session: GGLandingSession) -> String {
        if let outcome = row.outcome {
            if let error = outcome.error { return error }
            switch outcome.action {
            case "merged": return "Merged"
            case "queued": return "Queued"
            default: return outcome.action?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Completed"
            }
        }
        if session.phase == .cancelled { return "Cancelled" }
        if session.phase == .failed { return "Not landed" }
        if isActive(row, in: session) {
            if let wait = row.wait { return detail(for: wait) }
            return session.phase == .cancelling ? "Cancelling…" : "Landing…"
        }
        return "Pending"
    }

    static func progress(for session: GGLandingSession) -> String {
        "\(session.rows.filter { $0.outcome != nil && $0.outcome?.error == nil }.count) / \(session.rows.count)"
    }

    static func summary(for session: GGLandingSession) -> String {
        let outcomes = session.rows.compactMap(\.outcome).filter { $0.error == nil }
        let merged = outcomes.filter { $0.action == "merged" }.count
        let queued = outcomes.filter { $0.action == "queued" }.count
        var facts: [String] = []
        if session.phase == .cancelled { facts.append("Cancelled") }
        if session.phase == .failed { facts.append("Failed") }
        facts.append("\(merged) merged")
        if queued > 0 { facts.append("\(queued) queued") }
        let remaining = session.result?.remaining ?? max(0, session.rows.count - outcomes.count)
        facts.append("\(remaining) remaining")
        return facts.joined(separator: " · ")
    }
}

struct GGLandingTabView: View {
    let state: AppState
    let tabState: GGLandingTabState
    private let store = GGLandingStore.shared

    var body: some View {
        Group {
            if let session = store.sessions[tabState.projectId] {
                VStack(alignment: .leading, spacing: 16) {
                    header(session)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(session.rows) { row in
                                landingRow(row, session: session)
                            }
                            if session.phase != .running && session.phase != .cancelling {
                                terminalSummary(session)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            } else {
                ContentUnavailableView("Landing session unavailable", systemImage: "arrow.down.to.line")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Landing \(tabState.stackName)")
        .accessibilityIdentifier("gg-landing-tab")
    }

    private func header(_ session: GGLandingSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Land · \(session.stack)").font(.title2)
                HStack {
                    Text(GGLandingPresentation.progress(for: session))
                    runtime(session).monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if session.phase == .running || session.phase == .cancelling {
                Button(session.phase == .cancelling ? "Cancelling…" : "Cancel") {
                    state.cancelGGLanding(projectId: tabState.projectId)
                }
                .disabled(session.phase == .cancelling)
                .accessibilityLabel(session.phase == .cancelling ? "Cancelling landing" : "Cancel landing")
                .accessibilityIdentifier("gg-landing-cancel")
            }
        }
    }

    @ViewBuilder
    private func runtime(_ session: GGLandingSession) -> some View {
        if let endedAt = session.endedAt {
            Text(GGLandingPresentation.duration(seconds: Int(endedAt.timeIntervalSince(session.startedAt))))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(GGLandingPresentation.duration(seconds: Int(context.date.timeIntervalSince(session.startedAt))))
            }
        }
    }

    private func landingRow(_ row: GGLandingRow, session: GGLandingSession) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if row.outcome?.error != nil {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                } else if row.outcome?.action == "queued" {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                } else if row.outcome != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if GGLandingPresentation.isActive(row, in: session) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(row.position). \(row.title)").font(.headline)
                if let number = row.prNumber { Text("#\(number)").foregroundStyle(.secondary) }
                Text(GGLandingPresentation.detail(for: row, in: session)).foregroundStyle(.secondary)
                if GGLandingPresentation.isActive(row, in: session), let warning = session.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Temporary warning: \(warning)")
                        .accessibilityIdentifier("gg-landing-warning")
                }
            }
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Entry \(row.position), \(row.title)")
        .accessibilityIdentifier("gg-landing-row-\(row.position)")
    }

    private func terminalSummary(_ session: GGLandingSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(GGLandingPresentation.summary(for: session)).font(.headline)
            if let error = session.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if let warnings = session.result?.warnings, !warnings.isEmpty {
                Text(warnings.joined(separator: "\n")).foregroundStyle(.orange).textSelection(.enabled)
            }
            if session.phase == .cancelled || session.phase == .failed {
                Button("Restart") { state.restartGGLanding(projectId: tabState.projectId) }
                    .accessibilityLabel("Restart landing")
                    .accessibilityIdentifier("gg-landing-restart")
            }
        }
    }
}
