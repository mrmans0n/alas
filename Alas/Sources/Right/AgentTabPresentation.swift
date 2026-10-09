import SwiftUI

struct AgentSidebarEmptyState: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(theme.color("accent"))
                .frame(width: 38, height: 38)
                .background(theme.color("accent").opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            Text("No agent activity")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.color("fg"))
            Text("Agent sessions and terminals for this worktree will appear here.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.color("fg-muted"))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .background(
            LinearGradient(
                colors: [
                    theme.color("accent").opacity(0.08),
                    theme.color("bg-1").opacity(0.55)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.color("line").opacity(0.7), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
    }
}

struct AgentSidebarSectionHeader: View {
    let title: String
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.color("seg-pill-bg"), in: Capsule())
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.color("fg-muted"))
        .padding(.horizontal, 2)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The elbow drawn in the gutter of a nested child card. It deliberately
/// overshoots the card by the stack spacing at both ends so the rail reads as
/// one continuous line across the gaps between sibling cards.
struct AgentSidebarDelegationConnector: View {
    static let gutter: CGFloat = 18
    private static let stackSpacing: CGFloat = 8
    private static let elbowY: CGFloat = 20
    private static let railX: CGFloat = 7

    let continuesBelow: Bool
    /// False draws only the rail, carrying an outer connector past cards
    /// nested one level deeper.
    var hasElbow = true
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: Self.railX, y: -Self.stackSpacing))
                path.addLine(to: CGPoint(
                    x: Self.railX,
                    y: continuesBelow ? proxy.size.height + Self.stackSpacing : Self.elbowY
                ))
                if hasElbow {
                    path.move(to: CGPoint(x: Self.railX, y: Self.elbowY))
                    path.addLine(to: CGPoint(x: Self.gutter - 3, y: Self.elbowY))
                }
            }
            .stroke(
                theme.color("line"),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: Self.gutter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AgentSidebarRowView: View {
    let row: AgentSidebarRow
    let agent: AgentDefinition?
    let actions: AgentSidebarActions
    let canControl: Bool
    let delivery: AgentSidebarFollowUpDelivery?
    @Binding var draft: String
    /// Set when the row can't be focused; shown as its tooltip.
    var disabledReason: String? = nil
    @State private var isEditing = false
    @State private var isHovering = false
    @Environment(\.theme) private var theme

    /// Whether `controls` has anything worth rendering beyond the
    /// interrupt/etc. buttons already gated by `canControl` — mirrors
    /// `ACPContextUsageButton.hasContent`'s quota half so a quota-only
    /// adapter's usage still surfaces on a non-controllable (history) row.
    private var hasQuotaData: Bool {
        (row.lastTurnQuota?.hasDisplayableContent == true)
            || (row.sessionQuotaTotal?.hasDisplayableContent == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { actions.onFocus(row.id) } label: {
                HStack(alignment: .top, spacing: 10) {
                    logo
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(row.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.color("fg"))
                                .lineLimit(2)
                            if case .child = row.delegation {
                                AgentSidebarKindTag(label: "DELEGATED", color: theme.color("fg-muted"))
                            }
                        }
                        metadata
                        delegationNote
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    statusPill
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Focus \(row.title), \(accessibilityMetadata), \(row.state.label)")
            .disabled(disabledReason != nil)
            .help(disabledReason ?? "Focus \(row.title)")

            if let plan = row.plan {
                planProgress(plan)
            }

            if row.contextUsage != nil || hasQuotaData || canControl {
                controls
            }

            if let sessionID = row.sessionID,
               isEditing || !draft.isEmpty || delivery == .failed {
                followUpComposer(sessionID: sessionID)
            }
        }
        .padding(10)
        .rightPaneCardChrome(accent: stateColor, isHovering: isHovering)
        .onHover { isHovering = $0 }
        .onChange(of: delivery) {
            if delivery == .sent {
                isEditing = false
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(stateColor.opacity(0.13))
            if let agent {
                AgentLogoView(agent: agent, size: 20)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: row.agentID == "terminal" ? "terminal" : "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(stateColor)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 32, height: 32)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(stateColor.opacity(0.24), lineWidth: 0.75)
        )
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            ForEach(Array(metadataSegments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Text("·")
                        .fixedSize(horizontal: true, vertical: false)
                }
                segment
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(theme.color("fg-muted"))
        .lineLimit(1)
    }

    /// Only present segments make it into the line, so separators (added by
    /// `metadata` between array entries) never appear before the first one —
    /// a registered agent without an advertised model, or a terminal row
    /// whose harness is recognized, would otherwise open with a stray "·".
    private var metadataSegments: [AnyView] {
        var segments: [AnyView] = []
        // A distinctive logo already identifies the harness, so the name
        // would just repeat it. A custom agent has no logo asset — its tile
        // renders the same generic sparkle as every other custom agent, so
        // its name still needs the caption to tell cards apart.
        var hasDistinctiveLogo = false
        if let agent, case .asset = AgentLogoPresentation.resolve(for: agent) {
            hasDistinctiveLogo = true
        }
        if !hasDistinctiveLogo {
            // A removed custom agent falls back to its raw (UUID) id here,
            // which is far longer than anything else on the line, so this
            // needs the same truncate-as-fallback treatment as the host.
            segments.append(AnyView(
                Text(agentName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            ))
        }
        if let model = row.model {
            segments.append(AnyView(
                Text(model)
                    .lineLimit(1)
                    .truncationMode(.tail)
            ))
        }
        if row.activityAt != .distantPast {
            segments.append(AnyView(
                TimelineView(.periodic(from: row.activityAt, by: 60)) { context in
                    Text(AgentSidebarRelativeTime.compact(from: row.activityAt, to: context.date))
                }
                .fixedSize(horizontal: true, vertical: false)
            ))
        }
        if let host = row.host {
            segments.append(AnyView(
                HStack(spacing: 3) {
                    Image(systemName: "network")
                        .accessibilityHidden(true)
                    Text(AgentSidebarHostDisplay.shortName(for: host))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Preferred over the model (which absorbs compression
                // first), but — unlike the fixed-size segments above — a
                // long FQDN can still truncate rather than overflow the card.
                .layoutPriority(1)
            ))
        }
        return segments
    }

    /// A nested child needs no caption — its connector already says who owns
    /// it — so only parents and orphaned children annotate themselves.
    @ViewBuilder
    private var delegationNote: some View {
        if let childSummary {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
                Text(childSummary)
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(theme.color("fg-muted"))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.color("seg-pill-bg"), in: Capsule())
            .padding(.top, 1)
        }
        if case .child(_, let parentTitle, false) = row.delegation {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
                Text(delegatedByLabel(parentTitle))
                    .font(.system(size: 9.5))
                    .lineLimit(1)
            }
            .foregroundStyle(theme.color("fg-faint"))
            .padding(.top, 1)
        }
    }

    /// "3 subagents · 1 delegated", omitting whichever kind is absent.
    private var childSummary: String? {
        var parts: [String] = []
        if !row.subagents.isEmpty {
            parts.append(row.subagents.count == 1 ? "1 subagent" : "\(row.subagents.count) subagents")
        }
        if case .parent(let childCount) = row.delegation {
            parts.append(childCount == 1 ? "1 delegated" : "\(childCount) delegated")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func delegatedByLabel(_ parentTitle: String?) -> String {
        guard let parentTitle else { return "Delegated by another session" }
        return "Delegated by \(parentTitle)"
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            Text(row.state.label)
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(stateColor)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(stateColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(stateColor.opacity(0.22), lineWidth: 0.5))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(row.state.label)")
    }

    private func planProgress(_ plan: AgentSidebarPlanProgress) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(stateColor)
                Text("Tasks \(plan.completed)/\(plan.total)")
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                if let step = plan.currentStep {
                    Text(step)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.color("fg-muted"))
                        .lineLimit(1)
                }
            }
            ProgressView(value: Double(plan.completed), total: Double(plan.total))
                .tint(stateColor)
        }
        .foregroundStyle(theme.color("fg"))
        .padding(8)
        .background(theme.color("bg-0").opacity(0.42), in: RoundedRectangle(cornerRadius: 7))
    }

    private var controls: some View {
        HStack(spacing: 7) {
            ACPContextUsageButton(
                usage: row.contextUsage, modelName: row.model,
                lastTurnQuota: row.lastTurnQuota, sessionQuotaTotal: row.sessionQuotaTotal)
            Spacer(minLength: 0)
            if let sessionID = row.sessionID, row.isLiveACP, canControl {
                if row.state == .running || row.state == .awaitingInput || row.state == .permissionRequest {
                    Button("Interrupt", systemImage: "stop.fill") {
                        actions.onInterrupt(sessionID)
                    }
                    .tint(theme.color("del"))
                }
                Button("Follow up", systemImage: "arrowshape.turn.up.left.fill") {
                    isEditing.toggle()
                }
                .tint(theme.color("accent"))
                if let onDelegate = actions.onDelegate {
                    Button("Delegate", systemImage: "person.badge.plus") {
                        onDelegate(sessionID)
                    }
                    .tint(theme.color("accent"))
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func followUpComposer(sessionID: ACPSession.ID) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("Follow-up message", text: $draft, axis: .vertical)
                .lineLimit(2 ... 5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(theme.color("bg-0").opacity(0.66), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(theme.color("line"), lineWidth: 0.75)
                )
                .disabled(delivery == .sending)
            HStack {
                if delivery == .failed {
                    Text("Could not send. Your message is kept here.")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.color("del"))
                }
                Spacer(minLength: 0)
                Button(delivery == .sending ? "Sending…" : "Send", systemImage: "arrow.up") {
                    actions.onFollowUp(sessionID, draft)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.color("accent"))
                .disabled(
                    !canControl
                        || delivery == .sending
                        || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(theme.color("bg-1").opacity(0.62), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(theme.color("accent").opacity(0.22), lineWidth: 0.75)
        )
    }

    private var agentName: String {
        agent?.displayName ?? row.agentID
    }

    private var accessibilityMetadata: String {
        var values = [agentName]
        if let model = row.model {
            values.append(model)
        }
        if row.activityAt != .distantPast {
            let verb = row.state == .detached ? "last active" : "created"
            values.append("\(verb) \(row.activityAt.formatted(.relative(presentation: .named)))")
        }
        if let host = row.host {
            values.append("host \(AgentSidebarHostDisplay.shortName(for: host))")
        }
        if !row.subagents.isEmpty {
            values.append(row.subagents.count == 1 ? "1 subagent" : "\(row.subagents.count) subagents")
        }
        switch row.delegation {
        case .parent(let childCount):
            values.append(childCount == 1 ? "1 delegated session" : "\(childCount) delegated sessions")
        case .child(_, let parentTitle, _):
            values.append(delegatedByLabel(parentTitle))
        case .none:
            break
        }
        return values.joined(separator: ", ")
    }

    private var stateColor: Color {
        switch row.state {
        case .running:
            theme.color("add")
        case .awaitingInput, .permissionRequest:
            theme.color("warn")
        case .idle:
            theme.color("accent")
        case .failed:
            theme.color("del")
        case .detached:
            theme.color("fg-faint")
        case .unknown:
            row.isLiveACP ? theme.color("del") : theme.color("fg-faint")
        }
    }
}

extension AgentSidebarRow {
    var sessionID: ACPSession.ID? {
        guard case .acp(let sessionID) = id else { return nil }
        return sessionID
    }
}

extension AgentSidebarState {
    var label: String {
        switch self {
        case .running: "Running"
        case .awaitingInput: "Awaiting input"
        case .permissionRequest: "Permission"
        case .idle: "Idle"
        case .failed: "Failed"
        case .detached: "History"
        case .unknown: "Unknown"
        }
    }
}

/// Tells a session's own subagents apart from Alas-delegated sessions, which
/// otherwise nest the same way.
struct AgentSidebarKindTag: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

/// A compact card for one of a session's own subagents. A subagent takes no
/// prompts, so the only actions are focusing its parent and cancelling it.
struct AgentSidebarSubagentRowView: View {
    let subagent: AgentSidebarSubagent
    let onFocus: () -> Void
    let onCancel: (() -> Void)?
    @State private var isHovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: onFocus) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "person.2")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(stateColor)
                        .frame(width: 24, height: 24)
                        .background(stateColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(subagent.name)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(theme.color("fg"))
                                .lineLimit(1)
                            AgentSidebarKindTag(label: "SUBAGENT", color: theme.color("info"))
                        }
                        if let task = ACPSubagentRowPolicy.summary(task: subagent.task, messageCount: 0) {
                            Text(task)
                                .font(.system(size: 10).italic())
                                .foregroundStyle(theme.color("fg-muted"))
                                .lineLimit(2)
                        }
                        timing
                            .font(.system(size: 10))
                            .foregroundStyle(theme.color("fg-faint"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    statusPill
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Subagent \(subagent.name), \(ACPSubagentRowPolicy.stateLabel(for: subagent.state))")
            .help("Focus the session that started this subagent")

            if let onCancel {
                HStack {
                    Spacer(minLength: 0)
                    Button("Cancel", systemImage: "xmark", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(theme.color("del"))
                        .accessibilityLabel("Cancel subagent \(subagent.name)")
                }
            }
        }
        .padding(8)
        .rightPaneCardChrome(accent: stateColor, isHovering: isHovering)
        .opacity(isDimmed ? 0.6 : 1)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var timing: some View {
        if subagent.state.isTerminal {
            // A row restored from before finish times were persisted has none.
            if let finishedAt = subagent.finishedAt {
                Text("finished in \(Self.duration(from: subagent.startedAt, to: finishedAt))")
            }
        } else {
            TimelineView(.periodic(from: subagent.startedAt, by: 1)) { context in
                Text("running \(Self.duration(from: subagent.startedAt, to: context.date))")
            }
        }
    }

    private var statusPill: some View {
        Text(ACPSubagentRowPolicy.stateLabel(for: subagent.state))
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(stateColor)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(stateColor.opacity(0.12), in: Capsule())
            .fixedSize()
    }

    /// A failure stays at full strength so it is not mistaken for a clean finish.
    private var isDimmed: Bool {
        subagent.state.isTerminal && subagent.state != .failed
    }

    private var stateColor: Color {
        switch subagent.state {
        case .running, .other: theme.color("add")
        case .failed: theme.color("del")
        case .completed, .cancelled, .disconnected: theme.color("fg-faint")
        }
    }

    private static func duration(from start: Date, to end: Date) -> String {
        Duration.seconds(max(0, end.timeIntervalSince(start).rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}
