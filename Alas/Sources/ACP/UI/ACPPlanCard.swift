import SwiftUI

/// Glass-panel checklist. Each step has a circular checkbox that fills in
/// when complete, a spinner ring while in progress, or a hollow dot when
/// pending. Strikethrough for done items.
struct ACPPlanCard: View {
    let items: [ACPMessage.PlanItem]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.color("accent"))
                Text("Plan")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.color("accent"))
                Text("\(doneCount) / \(items.count)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.color("fg-faint"))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    PlanRow(item: item)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [theme.color("bg-2").opacity(0.85), theme.color("bg-1").opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color("line"), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    private var doneCount: Int { items.filter { $0.status == "completed" }.count }
}

private struct PlanRow: View {
    let item: ACPMessage.PlanItem
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            checkbox
            Text(item.content)
                .font(.system(size: 12.5))
                .foregroundStyle(item.status == "completed" ? theme.color("fg-faint") : theme.color("fg"))
                .strikethrough(item.status == "completed", color: theme.color("fg-faint").opacity(0.5))
            Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(
            item.status == "in_progress"
                ? theme.color("accent").opacity(0.10)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) {
            if item.status == "in_progress" {
                Rectangle()
                    .fill(theme.color("accent"))
                    .frame(width: 2)
                    .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var checkbox: some View {
        ZStack {
            Circle()
                .fill(theme.color("bg-0").opacity(0.6))
            Circle()
                .strokeBorder(borderColor, lineWidth: 1)
            switch item.status {
            case "completed":
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.color("add"))
            case "in_progress":
                Spinner()
                    .frame(width: 9, height: 9)
            default:
                Circle()
                    .fill(theme.color("fg-faint").opacity(0.6))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 16, height: 16)
    }

    private var borderColor: Color {
        switch item.status {
        case "completed":   return theme.color("add").opacity(0.5)
        case "in_progress": return theme.color("accent")
        default:            return theme.color("line")
        }
    }
}

private struct Spinner: View {
    @State private var angle: Double = 0
    @Environment(\.theme) private var theme
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(theme.color("accent"), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(angle))
            .animation(.linear(duration: 0.7).repeatForever(autoreverses: false), value: angle)
            .onAppear { angle = 360 }
    }
}
