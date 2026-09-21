import SwiftUI

/// Footer affordance: a small context-usage ring that opens a details popover.
/// Renders nothing until the agent emits a `usage_update` (graceful degradation).
struct ACPContextUsageButton: View {
    let usage: ACPUsageInfo?
    let modelName: String?
    /// Per-model breakdown from the last `session/prompt` response's
    /// `_meta.quota`, and the running session total. Both nil for agents
    /// that don't send the extension — the popover just omits the section.
    var lastTurnQuota: ACPPromptQuota? = nil
    var sessionQuotaTotal: ACPPromptQuota? = nil

    @State private var showDetails = false
    @Environment(\.theme) private var theme

    var body: some View {
        if let usage {
            let ratio = contextRatio(used: usage.used, size: usage.size)
            ACPContextRing(
                ratio: ratio,
                help: "Context window: \(contextPercent(ratio: ratio))% in use",
                action: { showDetails.toggle() }
            )
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
            if let lastTurnQuota, !lastTurnQuota.modelUsage.isEmpty {
                Divider()
                quotaSection(title: "Last turn", quota: lastTurnQuota)
            }
            if let sessionQuotaTotal, !sessionQuotaTotal.modelUsage.isEmpty {
                quotaSection(title: "Session total", quota: sessionQuotaTotal)
            }
        }
        .padding(14)
        .frame(minWidth: 220, alignment: .leading)
    }

    private func quotaSection(title: String, quota: ACPPromptQuota) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.color("fg-faint"))
            ForEach(quota.modelUsage, id: \.model) { usage in
                HStack {
                    Text(usage.model)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("fg-muted"))
                    Spacer(minLength: 12)
                    Text(formatContextTokens(usage.tokenCount.totalTokens))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.color("fg-muted"))
                }
            }
        }
    }

    private func formatCost(_ cost: ACPUsageInfo.Cost) -> String {
        let symbol = cost.currency == "USD" ? "$" : "\(cost.currency) "
        return symbol + String(format: "%.3f", cost.amount)
    }
}
