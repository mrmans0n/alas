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
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: Self.railX, y: -Self.stackSpacing))
                path.addLine(to: CGPoint(
                    x: Self.railX,
                    y: continuesBelow ? proxy.size.height + Self.stackSpacing : Self.elbowY
                ))
                path.move(to: CGPoint(x: Self.railX, y: Self.elbowY))
                path.addLine(to: CGPoint(x: Self.gutter - 3, y: Self.elbowY))
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
    @State private var isEditing = false
    @State private var isHovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { actions.onFocus(row.id) } label: {
                HStack(alignment: .top, spacing: 10) {
                    logo
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.color("fg"))
                            .lineLimit(2)
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
            .help("Focus \(row.title)")

            if let plan = row.plan {
                planProgress(plan)
            }

            if row.contextUsage != nil || canControl {
                controls
            }

            if let sessionID = row.sessionID,
               isEditing || !draft.isEmpty || delivery == .failed {
                followUpComposer(sessionID: sessionID)
            }
        }
        .padding(10)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(cardBorderColor, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(isHovering ? 0.18 : 0.10), radius: isHovering ? 5 : 3, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 11))
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
            // The logo tile already identifies the harness, so the name would
            // just repeat it; only the SF-symbol fallback needs the caption.
            if agent == nil {
                Text(agentName)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: true, vertical: false)
                Text("·")
                    .fixedSize(horizontal: true, vertical: false)
            }
            if let model = row.model {
                Text(model)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if row.activityAt != .distantPast {
                Text("·")
                    .fixedSize(horizontal: true, vertical: false)
                TimelineView(.periodic(from: row.activityAt, by: 60)) { context in
                    Text(AgentSidebarRelativeTime.compact(from: row.activityAt, to: context.date))
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            if let host = row.host {
                Text("·")
                    .fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 3) {
                    Image(systemName: "network")
                        .accessibilityHidden(true)
                    Text(AgentSidebarHostDisplay.shortName(for: host))
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(theme.color("fg-muted"))
        .lineLimit(1)
    }

    /// A nested child needs no caption — its connector already says who owns
    /// it — so only parents and orphaned children annotate themselves.
    @ViewBuilder
    private var delegationNote: some View {
        switch row.delegation {
        case .parent(let childCount):
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
                Text(childCount == 1 ? "1 delegated" : "\(childCount) delegated")
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(theme.color("fg-muted"))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.color("seg-pill-bg"), in: Capsule())
            .padding(.top, 1)
        case .child(_, let parentTitle, false):
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
        case .child, .none:
            EmptyView()
        }
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
            ACPContextUsageButton(usage: row.contextUsage, modelName: row.model)
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

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                stateColor.opacity(isHovering ? 0.12 : 0.07),
                theme.color("bg-1").opacity(isHovering ? 0.82 : 0.66)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardBorderColor: Color {
        isHovering ? stateColor.opacity(0.38) : theme.color("line").opacity(0.78)
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
        case .detached: "History"
        case .unknown: "Unknown"
        }
    }
}
