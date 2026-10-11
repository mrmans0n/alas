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
    /// Fetches what fills the window. Nil for harnesses without a breakdown,
    /// which keep the plain `used / size` view.
    var loadBreakdown: (() async -> ACPContextBreakdown?)? = nil

    @State private var showDetails = false
    @State private var breakdown: ACPContextBreakdown?
    /// The `usage_update` the breakdown was measured at: a newer one means the
    /// window changed, so the next open fetches again.
    @State private var breakdownUsage: ACPUsageInfo?
    @State private var loadingBreakdown = false
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
                    .task { await refreshBreakdown() }
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
                if let breakdown, !loadingBreakdown {
                    ACPContextBreakdownView(breakdown: breakdown)
                } else if loadingBreakdown {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Measuring context…")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-muted"))
                    }
                } else {
                    ProgressView(value: ratio)
                        .tint(theme.color(ContextRingLevel(ratio: ratio).token))
                        .frame(width: 200)
                }
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
                    quotaRow(label: "Total", tokens: total.displayTotal)
                }
            } else {
                ForEach(quota.modelUsage, id: \.model) { usage in
                    quotaRow(label: usage.model, tokens: usage.tokenCount.displayTotal)
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

    private func refreshBreakdown() async {
        guard let loadBreakdown, !loadingBreakdown, breakdown == nil || breakdownUsage != usage else { return }
        let measuredAt = usage
        loadingBreakdown = true
        defer { loadingBreakdown = false }
        guard let fetched = await loadBreakdown(), !fetched.categories.isEmpty else { return }
        breakdown = fetched
        breakdownUsage = measuredAt
    }

    private func formatCost(_ cost: ACPUsageInfo.Cost) -> String {
        let symbol = cost.currency == "USD" ? "$" : "\(cost.currency) "
        return symbol + String(format: "%.3f", cost.amount)
    }
}

/// Defrag-style view of what fills the context window: one square per 1% of
/// the window, a legend, and per-item drill-down.
struct ACPContextBreakdownView: View {
    let breakdown: ACPContextBreakdown

    @Environment(\.theme) private var theme

    private static let columns = 10
    private static let squareSize: CGFloat = 11
    private static let maxDetailRows = 12
    /// Theme tokens for `used` categories, by their order in the breakdown.
    /// The adapter sends no stable category id, and its color names are
    /// Claude terminal colors.
    private static let usedPalette = [
        "fg-dim", "info", "accent", "mod", "goal", "accent-2", "add", "syntax-function", "syntax-keyword",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                grid
                legend
            }
            details
        }
        .frame(width: 440, alignment: .leading)
    }

    // MARK: Grid

    @ViewBuilder
    private var grid: some View {
        let cells = breakdown.gridCells(squares: Self.columns * Self.columns)
        if cells.count == Self.columns * Self.columns {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(0..<Self.columns, id: \.self) { row in
                    GridRow {
                        ForEach(0..<Self.columns, id: \.self) { column in
                            square(cells[row * Self.columns + column])
                        }
                    }
                }
            }
        }
    }

    private func square(_ cell: ACPContextBreakdown.GridCell) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        let fill = fillColor(category: cell.category)
        return shape
            .fill(theme.color("bg-4").opacity(0.35))
            .overlay(alignment: .bottom) {
                if let fill {
                    // A sliver under a quarter square is hard to see.
                    Rectangle().fill(fill).frame(height: Self.squareSize * max(cell.fullness, 0.25))
                }
            }
            .overlay {
                if fill == nil { shape.strokeBorder(theme.color("bg-5"), lineWidth: 1) }
            }
            .clipShape(shape)
            .frame(width: Self.squareSize, height: Self.squareSize)
    }

    /// Nil draws an outlined free square.
    private func fillColor(category index: Int) -> Color? {
        guard breakdown.categories.indices.contains(index) else { return nil }
        switch breakdown.categories[index].kind {
        case .used:
            let rank = breakdown.categories[..<index].filter { $0.kind == .used }.count
            return theme.color(Self.usedPalette[rank % Self.usedPalette.count])
        case .buffer:
            return theme.color("warn").opacity(0.45)
        case .free, .deferred, .unknown:
            return nil
        }
    }

    // MARK: Legend

    private var legend: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach(Array(breakdown.categories.enumerated()), id: \.offset) { index, category in
                if [.used, .free, .buffer].contains(category.kind), category.tokens > 0 {
                    GridRow {
                        legendSwatch(index: index)
                        Text(category.name)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg"))
                            .lineLimit(1)
                        tokenText(category.tokens)
                            .gridColumnAlignment(.trailing)
                        Text(percentText(category.tokens))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.color("fg-faint"))
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }

    private func legendSwatch(index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        return Group {
            if let fill = fillColor(category: index) {
                shape.fill(fill)
            } else {
                shape.strokeBorder(theme.color("bg-5"), lineWidth: 1)
            }
        }
        .frame(width: 9, height: 9)
    }

    private func percentText(_ tokens: Int) -> String {
        guard breakdown.maxTokens > 0 else { return "" }
        return String(format: "%.1f%%", Double(tokens) / Double(breakdown.maxTokens) * 100)
    }

    // MARK: Details

    private typealias DetailRow = (label: String, tag: String?, tokens: Int)

    @ViewBuilder
    private var details: some View {
        let sections = detailSections
        if !sections.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("Details")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.color("fg-faint"))
                ForEach(sections, id: \.title) { section in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(section.rows.prefix(Self.maxDetailRows).enumerated()), id: \.offset) { _, row in
                                detailRow(row)
                            }
                            if section.rows.count > Self.maxDetailRows {
                                Text("\(section.rows.count - Self.maxDetailRows) more")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.color("fg-faint"))
                            }
                        }
                        .padding(.leading, 4)
                    } label: {
                        HStack {
                            Text(section.title)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.color("fg"))
                            Spacer(minLength: 12)
                            tokenText(section.tokens)
                        }
                    }
                }
            }
        }
    }

    private var detailSections: [(title: String, tokens: Int, rows: [DetailRow])] {
        var sections: [(title: String, tokens: Int, rows: [DetailRow])] = []
        let memory = breakdown.memoryFiles
        if !memory.isEmpty {
            sections.append((
                "Memory files", memory.reduce(0) { $0 + $1.tokens },
                memory.map { (($0.path as NSString).abbreviatingWithTildeInPath, $0.type, $0.tokens) }))
        }
        let loaded = breakdown.mcpTools.filter { $0.isLoaded != false }
        if !breakdown.mcpTools.isEmpty {
            let deferred = breakdown.mcpTools.count - loaded.count
            sections.append((
                "MCP tools · \(loaded.count) loaded" + (deferred > 0 ? ", \(deferred) deferred" : ""),
                loaded.reduce(0) { $0 + $1.tokens },
                loaded.sorted { $0.tokens > $1.tokens }.map { ($0.name, $0.serverName, $0.tokens) }))
        }
        if let skills = breakdown.skills, skills.totalSkills > 0 {
            sections.append((
                "Skills · \(skills.includedSkills) of \(skills.totalSkills)", skills.tokens,
                (skills.skillFrontmatter ?? []).sorted { $0.tokens > $1.tokens }.map { ($0.name, nil, $0.tokens) }))
        }
        if !breakdown.agents.isEmpty {
            sections.append((
                "Custom agents · \(breakdown.agents.count)", breakdown.agents.reduce(0) { $0 + $1.tokens },
                breakdown.agents.map { ($0.agentType, nil, $0.tokens) }))
        }
        if let messages = breakdown.messageBreakdown {
            let rows: [DetailRow] = [
                ("User messages", nil, messages.userMessageTokens),
                ("Assistant messages", nil, messages.assistantMessageTokens),
                ("Tool calls", nil, messages.toolCallTokens),
                ("Tool results", nil, messages.toolResultTokens),
                ("Attachments", nil, messages.attachmentTokens),
            ].filter { $0.tokens > 0 }
            if !rows.isEmpty {
                sections.append(("Messages", rows.reduce(0) { $0 + $1.tokens }, rows))
            }
        }
        return sections
    }

    private func detailRow(_ row: DetailRow) -> some View {
        HStack(spacing: 6) {
            Text(row.label)
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)
            if let tag = row.tag {
                Text(tag)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            tokenText(row.tokens)
        }
    }

    private func tokenText(_ tokens: Int) -> some View {
        Text(formatContextTokens(tokens))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(theme.color("fg-muted"))
    }
}
