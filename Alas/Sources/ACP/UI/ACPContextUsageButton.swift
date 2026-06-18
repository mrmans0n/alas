import SwiftUI

/// Footer affordance: a small context-usage ring that opens a details popover.
/// Renders nothing until the agent emits a `usage_update` (graceful degradation).
struct ACPContextUsageButton: View {
    let usage: ACPUsageInfo?
    let modelName: String?

    @State private var showDetails = false
    @Environment(\.theme) private var theme

    var body: some View {
        if let usage {
            let ratio = contextRatio(used: usage.used, size: usage.size)
            Button { showDetails.toggle() } label: {
                ACPContextRing(ratio: ratio)
            }
            .buttonStyle(.plain)
            .help("Context: \(contextPercent(ratio: ratio))% used")
            .popover(isPresented: $showDetails, arrowEdge: .top) {
                details(usage: usage, ratio: ratio)
            }
        }
    }

    @ViewBuilder
    private func details(usage: ACPUsageInfo, ratio: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let modelName {
                Text(modelName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
            }
            Text("\(formatContextTokens(usage.used)) / \(formatContextTokens(usage.size)) (\(contextPercent(ratio: ratio))%)")
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-muted"))
            ProgressView(value: ratio)
                .tint(theme.color(ContextRingLevel(ratio: ratio).token))
                .frame(width: 200)
            if let cost = usage.cost {
                Text(formatCost(cost))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-muted"))
            }
        }
        .padding(14)
        .frame(minWidth: 220, alignment: .leading)
    }

    private func formatCost(_ cost: ACPUsageInfo.Cost) -> String {
        let symbol = cost.currency == "USD" ? "$" : "\(cost.currency) "
        return symbol + String(format: "%.3f", cost.amount)
    }
}
