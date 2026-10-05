import Foundation
import SwiftUI

/// Toolbar pill for a session goal. Every goal surface uses the `goal` tint;
/// a running goal also carries the `/btw` prism sweep across its fill.
struct ACPGoalPill: View {
    let goal: ACPGoalState
    var isLit = false
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Phase: Equatable {
        case running
        case paused
        case settled
    }

    var body: some View {
        let running = Self.phase(of: goal) == .running
        let paused = Self.phase(of: goal) == .paused
        let tint = theme.color("goal")
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        HStack(spacing: 5) {
            Image(systemName: paused ? "pause.fill" : "target")
                .font(.system(size: paused ? 9 : 11, weight: .semibold))
                .foregroundStyle(running ? tint : theme.color("fg-muted"))
            Text(Self.pillTitle(goal))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.color(running ? "fg" : "fg-muted"))
                .lineLimit(1)
                .truncationMode(.tail)
            if let tokens = Self.tokenText(goal) {
                Text(tokens)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(running ? tint : theme.color("fg-dim"))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background {
            tint.opacity(running ? (isLit ? 0.26 : 0.14) : (isLit ? 0.18 : 0.08))
            if Self.showsSheen(for: goal, reduceMotion: reduceMotion) {
                ACPAlasPrismSweep().opacity(0.55)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                tint.opacity(running ? (isLit ? 0.7 : 0.5) : (isLit ? 0.5 : 0.3)),
                lineWidth: 0.5
            )
        }
        .help(Self.summary(goal))
        .transition(.opacity)
    }

    nonisolated static func phase(of goal: ACPGoalState) -> Phase {
        switch goal.status?.lowercased() {
        case "active", "in_progress": .running
        case "paused": .paused
        default: .settled
        }
    }

    /// Only a running goal animates; Reduce Motion keeps it static.
    nonisolated static func showsSheen(for goal: ACPGoalState, reduceMotion: Bool) -> Bool {
        !reduceMotion && phase(of: goal) == .running
    }

    /// Tooltip and accessibility text; the pill itself shows the state through
    /// color and motion instead of words.
    nonisolated static func summary(_ goal: ACPGoalState) -> String {
        var parts = ["Goal: \(goal.objective)"]
        if let status = normalizedStatus(goal.status) {
            parts.append(status)
        }
        if let tokens = tokenText(goal) {
            parts.append(tokens)
        }
        return parts.joined(separator: " · ")
    }

    nonisolated static func pillTitle(_ goal: ACPGoalState) -> String {
        guard goal.objective.count > 40 else { return goal.objective }
        return "\(goal.objective.prefix(40))…"
    }

    nonisolated static func tokenText(_ goal: ACPGoalState) -> String? {
        switch (goal.tokensUsed, goal.tokenBudget) {
        case let (used?, budget?): "\(formattedTokens(used)) / \(formattedTokens(budget))"
        case let (nil, budget?): "\(formattedTokens(budget)) budget"
        case let (used?, nil): "\(formattedTokens(used)) used"
        case (nil, nil): nil
        }
    }

    /// Fraction of the budget spent, when both sides are known.
    nonisolated static func tokenProgress(_ goal: ACPGoalState) -> Double? {
        guard let used = goal.tokensUsed, let budget = goal.tokenBudget, budget > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(budget)))
    }

    nonisolated static func normalizedStatus(_ status: String?) -> String? {
        guard let status = status?.replacingOccurrences(of: "_", with: " "),
              !status.isEmpty else { return nil }
        return status
    }

    nonisolated static func actions(for goal: ACPGoalState?, capability: ACPGoalCapability) -> [ACPGoalAction] {
        guard let goal else { return [ACPGoalAction.set].filter { capability.actions.contains($0) } }
        let allowed: [ACPGoalAction] = switch phase(of: goal) {
        case .running: [.set, .pause, .clear]
        case .paused: [.set, .resume, .clear]
        case .settled: [.set, .clear]
        }
        return allowed.filter { capability.actions.contains($0) }
    }

    private nonisolated static func formattedTokens(_ tokens: Int) -> String {
        guard tokens >= 1_000 else { return "\(tokens)" }
        let thousands = Double(tokens) / 1_000
        let rounded = (thousands * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))k"
        }
        return String(format: "%.1fk", rounded)
    }
}

struct ACPGoalControl: View {
    @ObservedObject var session: ACPSession
    let onAction: (ACPGoalAction, String?) async throws -> Void

    @Environment(\.theme) private var theme
    @State private var isPresented = false
    @State private var hovering = false

    /// Lit while the pointer is over the pill or its popover is up, so the
    /// trigger stays visibly tied to the surface it opened.
    private var isLit: Bool { hovering || isPresented }

    var body: some View {
        if let capability = session.goalCapability,
           session.currentGoal != nil || capability.actions.contains(.set) {
            Button {
                isPresented.toggle()
            } label: {
                if let goal = session.currentGoal {
                    ACPGoalPill(goal: goal, isLit: isLit)
                } else {
                    setGoalLabel
                }
            }
            .buttonStyle(.toolbarControl)
            .onHover { hovering = $0 }
            .accessibilityLabel(session.currentGoal == nil ? "Set goal" : "View and control goal")
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                ACPGoalPopover(session: session, capability: capability, onAction: onAction)
            }
        } else if let goal = session.currentGoal {
            ACPGoalPill(goal: goal)
        }
    }

    private var setGoalLabel: some View {
        let tint = theme.color("goal")
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return HStack(spacing: 5) {
            Image(systemName: "target")
                .font(.system(size: 11, weight: .medium))
            Text("Set goal")
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(tint.opacity(isLit ? 0.22 : 0.10))
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(tint.opacity(isLit ? 0.5 : 0.28), lineWidth: 0.5)
        }
        .help("Set a goal for this session")
    }

    nonisolated static func formattedDuration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        guard seconds > 0 else { return "0s" }
        if seconds >= Double(Int.max) { return String(format: "%.0fs", seconds) }
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }
}

/// The goal card: objective, budget, and stats, with the goal's actions in a
/// footer bar. Clearing confirms inside the footer.
private struct ACPGoalPopover: View {
    @ObservedObject var session: ACPSession
    let capability: ACPGoalCapability
    let onAction: (ACPGoalAction, String?) async throws -> Void

    @Environment(\.theme) private var theme
    @State private var objective = ""
    @State private var isEditing = false
    @State private var confirmsClear = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var editorFocused: Bool

    private struct Stat: Hashable {
        let label: String
        let value: String
    }

    private var canMutate: Bool {
        session.agentState == .ready && !isSubmitting
    }

    private var trimmedObjective: String {
        objective.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let goal = session.currentGoal
        let actions = ACPGoalPill.actions(for: goal, capability: capability)
        let showsEditor = (goal == nil || isEditing) && actions.contains(.set)
        VStack(alignment: .leading, spacing: 0) {
            header(goal: goal, showsEditor: showsEditor)
            VStack(alignment: .leading, spacing: 10) {
                if showsEditor {
                    editor
                } else if let goal {
                    details(goal)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("del"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            footer(goal: goal, actions: actions, showsEditor: showsEditor)
        }
        .frame(width: 320)
        .background(theme.color("bg-1"))
    }

    // MARK: Header

    private func header(goal: ACPGoalState?, showsEditor: Bool) -> some View {
        let running = goal.map { ACPGoalPill.phase(of: $0) == .running } ?? true
        return HStack(spacing: 7) {
            Image(systemName: "target")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(running ? theme.color("goal") : theme.color("fg-faint"))
            Text(showsEditor ? (goal == nil ? "Set a goal" : "Change goal") : "Goal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.color("fg"))
            Spacer(minLength: 0)
            if let goal {
                statusChip(goal)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusChip(_ goal: ACPGoalState) -> some View {
        if let status = ACPGoalPill.normalizedStatus(goal.status) {
            let phase = ACPGoalPill.phase(of: goal)
            let tint = theme.color("goal")
            HStack(spacing: 4) {
                switch phase {
                case .running:
                    Circle().fill(tint).frame(width: 5, height: 5)
                case .paused:
                    Image(systemName: "pause.fill").font(.system(size: 7, weight: .bold))
                case .settled:
                    EmptyView()
                }
                Text(status.prefix(1).uppercased() + status.dropFirst())
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(phase == .running ? tint : theme.color("fg-muted"))
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(
                phase == .running ? tint.opacity(0.16) : theme.color("bg-4").opacity(0.7),
                in: Capsule()
            )
        }
    }

    // MARK: Editor

    private var editor: some View {
        TextField("Describe what done looks like…", text: $objective, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(theme.color("fg"))
            .lineLimit(3...6)
            .focused($editorFocused)
            .disabled(isSubmitting)
            .onSubmit { perform(.set) }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(theme.color("field-bg"), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(theme.color("goal").opacity(editorFocused ? 0.6 : 0.3), lineWidth: 0.5)
            }
            .accessibilityLabel("Goal objective")
            .onAppear { editorFocused = true }
    }

    // MARK: Details

    @ViewBuilder
    private func details(_ goal: ACPGoalState) -> some View {
        let running = ACPGoalPill.phase(of: goal) == .running
        Text(goal.objective)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.color("fg"))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)

        if let tokens = ACPGoalPill.tokenText(goal) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Tokens")
                        .foregroundStyle(theme.color("fg-dim"))
                    Spacer(minLength: 0)
                    Text(tokens)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.color("fg-muted"))
                }
                .font(.system(size: 10.5))
                if let progress = ACPGoalPill.tokenProgress(goal) {
                    progressBar(progress, running: running)
                }
            }
        }

        let stats = stats(for: goal)
        if !stats.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                ForEach(stats, id: \.self) { stat in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stat.label)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.color("fg-dim"))
                        Text(stat.value)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.color("fg"))
                    }
                }
            }
        }

        if let reason = goal.lastReason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-muted"))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .padding(.leading, 10)
                .padding(.trailing, 9)
                .background(theme.color("field-bg"))
                .overlay(alignment: .leading) {
                    Rectangle().fill(theme.color("goal").opacity(0.6)).frame(width: 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func progressBar(_ progress: Double, running: Bool) -> some View {
        let tint = theme.color("goal")
        return Capsule()
            .fill(theme.color("bg-4"))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * progress)
                        .opacity(running ? 1 : 0.5)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Token budget used")
            .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }

    private func stats(for goal: ACPGoalState) -> [Stat] {
        var stats: [Stat] = []
        if let seconds = goal.timeUsedSeconds {
            stats.append(Stat(label: "Elapsed", value: ACPGoalControl.formattedDuration(seconds)))
        }
        if let iterations = goal.iterations {
            stats.append(Stat(label: "Iterations", value: "\(iterations)"))
        }
        if let updatedAt = goal.updatedAt {
            stats.append(Stat(label: "Updated", value: relativeTime(updatedAt)))
        }
        return stats
    }

    // MARK: Footer

    private func footer(goal: ACPGoalState?, actions: [ACPGoalAction], showsEditor: Bool) -> some View {
        HStack(spacing: 6) {
            if confirmsClear {
                Text("Clear this goal?")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.color("fg"))
                Spacer(minLength: 0)
                progressIndicator
                ACPGoalFooterButton(title: "Cancel", kind: .ghost) { confirmsClear = false }
                ACPGoalFooterButton(title: "Clear Goal", kind: .destructiveFilled) { perform(.clear) }
                    .disabled(!canMutate)
                    .accessibilityLabel("Confirm clear goal")
            } else if showsEditor {
                Spacer(minLength: 0)
                progressIndicator
                if goal != nil {
                    ACPGoalFooterButton(title: "Cancel", kind: .ghost) {
                        isEditing = false
                        objective = ""
                    }
                }
                Text("↩")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.color("fg-dim"))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(theme.color("bg-4"), in: RoundedRectangle(cornerRadius: 3))
                    .accessibilityHidden(true)
                ACPGoalFooterButton(title: goal == nil ? "Set Goal" : "Update Goal", kind: .primary) {
                    perform(.set)
                }
                .disabled(!canMutate || trimmedObjective.isEmpty)
                .accessibilityLabel(goal == nil ? "Set goal" : "Update goal")
            } else {
                if actions.contains(.pause) {
                    ACPGoalFooterButton(title: "Pause", icon: "pause.fill") { perform(.pause) }
                        .disabled(!canMutate)
                        .accessibilityLabel("Pause goal")
                }
                if actions.contains(.resume) {
                    ACPGoalFooterButton(title: "Resume", icon: "play.fill") { perform(.resume) }
                        .disabled(!canMutate)
                        .accessibilityLabel("Resume goal")
                }
                if actions.contains(.set) {
                    ACPGoalFooterButton(title: "Change", icon: "pencil", kind: .ghost) {
                        objective = goal?.objective ?? ""
                        errorMessage = nil
                        isEditing = true
                    }
                    .accessibilityLabel("Change goal objective")
                }
                Spacer(minLength: 0)
                progressIndicator
                if actions.contains(.clear) {
                    ACPGoalFooterButton(title: "Clear", kind: .destructive) { confirmsClear = true }
                        .disabled(!canMutate)
                        .accessibilityLabel("Clear goal")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(confirmsClear ? theme.color("del").opacity(0.10) : theme.color("section-head-bg"))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.color("line")).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if isSubmitting {
            Spinner(lineWidth: 1.5)
                .frame(width: 10, height: 10)
        }
    }

    private func perform(_ action: ACPGoalAction) {
        guard canMutate else { return }
        if action == .set, trimmedObjective.isEmpty { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await onAction(action, action == .set ? objective : nil)
                switch action {
                case .set:
                    objective = ""
                    isEditing = false
                case .clear:
                    confirmsClear = false
                case .pause, .resume:
                    break
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}

private struct ACPGoalFooterButton: View {
    enum Kind {
        case primary
        case normal
        case ghost
        case destructive
        case destructiveFilled
    }

    let title: String
    var icon: String? = nil
    var kind: Kind = .normal
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: isFilled ? .semibold : .medium))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if kind == .normal {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                }
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.toolbarControl)
        .onHover { hovering = $0 }
    }

    private var isFilled: Bool {
        kind == .primary || kind == .destructiveFilled
    }

    private var lit: Bool { hovering && isEnabled }

    private var background: Color {
        switch kind {
        case .primary: theme.color("goal").opacity(lit ? 0.85 : 1)
        case .normal: theme.color(lit ? "bg-4" : "bg-3")
        case .ghost: lit ? theme.color("bg-3") : .clear
        case .destructive: lit ? theme.color("del").opacity(0.12) : .clear
        case .destructiveFilled: theme.color("del").opacity(lit ? 0.8 : 0.9)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: theme.color("bg-0")
        case .normal: theme.color("fg")
        case .ghost: theme.color("fg-muted")
        case .destructive: theme.color("del")
        case .destructiveFilled: .white
        }
    }
}
