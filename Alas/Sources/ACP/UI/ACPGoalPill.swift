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
