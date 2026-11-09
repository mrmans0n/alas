import SwiftUI

/// Shared body of the plan UI — header (`done / total`) plus the list
/// of rows with completed / in-progress / pending marks.
struct ACPPlanChecklist: View {
    @Environment(\.designScale) private var scale
    let items: [ACPMessage.PlanItem]
    var isTurnActive = false
    @Environment(\.theme) private var theme

    private var done: Int { items.filter { $0.status == "completed" }.count }
    private var total: Int { items.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(theme.color("line"))
            VStack(alignment: .leading, spacing: scale.space[0]) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    row(item: item)
                }
            }
            .padding(.vertical, scale.space[2])
        }
        .background(theme.color("bg-1"))
    }

    private var header: some View {
        HStack(spacing: scale.space[2]) {
            Image(systemName: "sparkles")
                .font(scale.caption.font(weight: .regular))
                .foregroundStyle(theme.color("accent"))
            Text("Plan")
                .font(scale.caption.font(weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("accent"))
            Text("\(done) / \(total)")
                .font(scale.caption.font(weight: .regular, design: .monospaced))
                .foregroundStyle(theme.color("fg-faint"))
            Spacer()
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        .background(theme.color("bg-2").opacity(0.4))
    }

    @ViewBuilder
    private func row(item: ACPMessage.PlanItem) -> some View {
        HStack(spacing: scale.space[2]) {
            mark(for: item)
            Text(item.content)
                .font(scale.metaFont)
                .foregroundStyle(item.status == "completed" ? theme.color("fg-faint") : theme.color("fg"))
                .strikethrough(item.status == "completed", color: theme.color("fg-faint").opacity(0.5))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[1])
        .background(item.status == "in_progress" ? theme.color("accent").opacity(theme.darkMode ? 0.10 : 0.18) : Color.clear)
    }

    @ViewBuilder
    private func mark(for item: ACPMessage.PlanItem) -> some View {
        switch item.status {
        case "completed":
            Image(systemName: "checkmark")
                .font(scale.glyph.font(weight: .bold))
                .foregroundStyle(theme.color("add"))
                .frame(width: 12)
        case "in_progress" where isTurnActive:
            Spinner(lineWidth: 1.5, duration: 0.7)
                .frame(width: 10, height: 10)
                .frame(width: 12)
        case "in_progress":
            Image(systemName: "circle.dashed")
                .font(scale.caption.font(weight: .regular))
                .foregroundStyle(theme.color("accent"))
                .frame(width: 12)
        default:
            Circle()
                .fill(theme.color("fg-faint").opacity(0.6))
                .frame(width: 5, height: 5)
                .frame(width: 12)
        }
    }
}
