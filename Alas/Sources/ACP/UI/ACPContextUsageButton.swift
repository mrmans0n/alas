import SwiftUI

/// Footer affordance: a small context-usage ring that opens a details popover.
/// Renders nothing until the agent emits a `usage_update` (graceful degradation).
struct ACPContextUsageButton: View {
    let usage: ACPUsageInfo?
    let modelName: String?
    /// Per-model breakdown from the last `session/prompt` response's
    /// `_meta.quota`, and the running total for this in-memory session's
    /// lifetime — not the full persisted session, and not reset by a
    /// reconnect (see `ACPSession.sessionQuotaTotal`). Both nil for agents
    /// that don't send the extension — the popover just omits the section.
    var lastTurnQuota: ACPPromptQuota? = nil
    var sessionQuotaTotal: ACPPromptQuota? = nil

    @State private var showDetails = false
    @Environment(\.theme) private var theme

    /// `usage_update` (context ring) and `_meta.quota` (per-model
    /// breakdown) are decoded independently, so an adapter can supply one
    /// without the other. Gating the whole button on `usage` alone would
    /// make quota data unreachable when no usage update has landed yet
    /// (or a nonpositive size cleared it) — render whenever either exists.
    var hasContent: Bool {
        usage != nil || hasQuotaContent
    }

    private var hasQuotaContent: Bool {
        (lastTurnQuota?.hasDisplayableContent == true) || (sessionQuotaTotal?.hasDisplayableContent == true)
    }

    var body: some View {
        if hasContent {
            Group {
                if let usage {
                    let ratio = contextRatio(used: usage.used, size: usage.size)
                    ACPContextRing(
                        ratio: ratio,
                        help: "Context window: \(contextPercent(ratio: ratio))% in use",
                        action: { showDetails.toggle() }
                    )
                } else {
                    // No context-window ring to draw without `usage`; a
                    // plain icon button still surfaces the quota-only
                    // popover.
                    Button(action: { showDetails.toggle() }) {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.color("fg-faint"))
                    }
                    .buttonStyle(.plain)
                    .help("Token usage")
                }
            }
            .popover(isPresented: $showDetails, arrowEdge: .top) {
                details
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let modelName {
                Text(modelName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
            }
            if let usage {
                let ratio = contextRatio(used: usage.used, size: usage.size)
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
            if let lastTurnQuota, lastTurnQuota.hasDisplayableContent {
                if usage != nil { Divider() }
                quotaSection(title: "Last turn", quota: lastTurnQuota)
            }
            if let sessionQuotaTotal, sessionQuotaTotal.hasDisplayableContent {
                // Cumulative for this in-memory session's lifetime, not
                // necessarily the full persisted session, and *not* reset
                // by a reconnect — see `ACPSession.sessionQuotaTotal`.
                quotaSection(title: "Cumulative", quota: sessionQuotaTotal)
            }
        }
        .padding(14)
        .frame(minWidth: 220, alignment: .leading)
    }

    @ViewBuilder
    private func quotaSection(title: String, quota: ACPPromptQuota) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.color("fg-faint"))
            if quota.modelUsage.isEmpty {
                // Adapter sent only the top-level token_count, no
                // model_usage breakdown.
                if let total = quota.tokenCount {
                    quotaRow(label: "Total", tokens: total.totalTokens)
                }
            } else {
                ForEach(quota.modelUsage, id: \.model) { usage in
                    quotaRow(label: usage.model, tokens: usage.tokenCount.totalTokens)
                }
            }
        }
    }

    private func quotaRow(label: String, tokens: Int) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-muted"))
            Spacer(minLength: 12)
            Text(formatContextTokens(tokens))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.color("fg-muted"))
        }
    }

    private func formatCost(_ cost: ACPUsageInfo.Cost) -> String {
        let symbol = cost.currency == "USD" ? "$" : "\(cost.currency) "
        return symbol + String(format: "%.3f", cost.amount)
    }
}
