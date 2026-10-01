import Foundation
import SwiftUI

struct ACPGoalPill: View {
    let goal: ACPGoalState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "target")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
            Text(Self.summary(goal))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.color("bg-1"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .help(Self.summary(goal))
        .transition(.opacity)
    }

    static func summary(_ goal: ACPGoalState) -> String {
        var parts = ["Goal: \(truncatedObjective(goal.objective))"]
        if let status = goal.status?.replacingOccurrences(of: "_", with: " "),
           !status.isEmpty {
            parts.append(status)
        }
        if let tokenBudget = goal.tokenBudget {
            parts.append(formattedTokenBudget(tokenBudget))
        }
        return parts.joined(separator: " · ")
    }

    static func actions(for goal: ACPGoalState?, capability: ACPGoalCapability) -> [ACPGoalAction] {
        let allowed: [ACPGoalAction]
        guard let goal else {
            allowed = [.set]
            return allowed.filter(capability.actions.contains)
        }
        switch goal.status?.lowercased() {
        case "active", "in_progress":
            allowed = [.set, .pause, .clear]
        case "paused":
            allowed = [.set, .resume, .clear]
        default:
            allowed = [.set, .clear]
        }
        return allowed.filter(capability.actions.contains)
    }

    private static func truncatedObjective(_ objective: String) -> String {
        guard objective.count > 60 else { return objective }
        return "\(objective.prefix(60))…"
    }

    private static func formattedTokenBudget(_ tokenBudget: Int) -> String {
        guard tokenBudget >= 1_000 else { return "\(tokenBudget)" }
        let thousands = Double(tokenBudget) / 1_000
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

    @State private var isPresented = false
    @State private var objective = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var confirmsClear = false

    var body: some View {
        if let capability = session.goalCapability,
           session.currentGoal != nil || capability.actions.contains(.set) {
            Button {
                isPresented.toggle()
            } label: {
                if let goal = session.currentGoal {
                    ACPGoalPill(goal: goal)
                } else {
                    Label("Set goal", systemImage: "target")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.currentGoal == nil ? "Set goal" : "View and control goal")
            .popover(isPresented: $isPresented) {
                content(capability: capability)
            }
            .confirmationDialog("Clear this goal?", isPresented: $confirmsClear) {
                Button("Clear Goal", role: .destructive) { perform(.clear) }
                Button("Cancel", role: .cancel) {}
            }
        } else if let goal = session.currentGoal {
            ACPGoalPill(goal: goal)
        }
    }

    private var canMutate: Bool {
        session.agentState == .ready && !isSubmitting
    }

    @ViewBuilder
    private func content(capability: ACPGoalCapability) -> some View {
        let actions = ACPGoalPill.actions(for: session.currentGoal, capability: capability)
        VStack(alignment: .leading, spacing: 12) {
            if let goal = session.currentGoal {
                goalDetails(goal)
                Divider()
            }

            if actions.contains(.set) {
                TextField("Goal objective", text: $objective)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { perform(.set) }
                Button("Set Goal") { perform(.set) }
                    .disabled(!canMutate || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Set goal")
            }

            HStack {
                if actions.contains(.pause) {
                    Button("Pause") { perform(.pause) }
                        .accessibilityLabel("Pause goal")
                }
                if actions.contains(.resume) {
                    Button("Resume") { perform(.resume) }
                        .accessibilityLabel("Resume goal")
                }
                if actions.contains(.clear) {
                    Button("Clear", role: .destructive) { confirmsClear = true }
                        .accessibilityLabel("Clear goal")
                }
            }
            .disabled(!canMutate)

            if isSubmitting {
                ProgressView().controlSize(.small)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .buttonStyle(.bordered)
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private func goalDetails(_ goal: ACPGoalState) -> some View {
        Text(goal.objective).font(.headline).textSelection(.enabled)
        if let status = goal.status, !status.isEmpty {
            LabeledContent("Status", value: status.replacingOccurrences(of: "_", with: " "))
        }
        if let tokensUsed = goal.tokensUsed, let tokenBudget = goal.tokenBudget {
            LabeledContent("Tokens", value: "\(tokensUsed) / \(tokenBudget)")
        } else if let tokensUsed = goal.tokensUsed {
            LabeledContent("Tokens used", value: "\(tokensUsed)")
        } else if let tokenBudget = goal.tokenBudget {
            LabeledContent("Token budget", value: "\(tokenBudget)")
        }
        if let seconds = goal.timeUsedSeconds {
            LabeledContent("Elapsed", value: Self.formattedDuration(seconds))
        }
        if let iterations = goal.iterations {
            LabeledContent("Iterations", value: "\(iterations)")
        }
        if let createdAt = goal.createdAt {
            LabeledContent("Created", value: createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        if let updatedAt = goal.updatedAt {
            LabeledContent("Updated", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
        }
        if let lastReason = goal.lastReason, !lastReason.isEmpty {
            LabeledContent("Reason", value: lastReason)
        }
    }

    private func perform(_ action: ACPGoalAction) {
        guard canMutate else { return }
        if action == .set,
           objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await onAction(action, action == .set ? objective : nil)
                if action == .set { objective = "" }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }
}
