import AlasRemoteKit
import SwiftUI

/// Context-window fill as a small ring; tapping opens the numbers.
struct UsageRing: View {
    let usage: RemoteUsage
    @State private var showing = false

    /// Nil when the agent reports token totals but no context window: the button still opens them, as on the Mac.
    private var context: RemoteContextWindow? { usage.context }
    private var fraction: Double {
        guard let context, context.size > 0 else { return 0 }
        return min(1, Double(context.used) / Double(context.size))
    }

    private var color: Color {
        fraction >= 0.95 ? .red : fraction >= 0.8 ? .orange : .accentColor
    }

    var body: some View {
        Button { showing = true } label: {
            Group {
                if context != nil {
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 3)
                        Circle().trim(from: 0, to: fraction)
                            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                } else {
                    Image(systemName: "chart.bar.doc.horizontal").foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(context != nil ? "Context used" : "Token usage")
        .accessibilityValue(context != nil ? "\(Int(fraction * 100)) percent" : "")
        .sheet(isPresented: $showing) {
            UsageSheet(usage: usage, fraction: fraction)
                .presentationDetents([.medium])
        }
    }
}

private struct UsageSheet: View {
    let usage: RemoteUsage
    let fraction: Double

    var body: some View {
        NavigationStack {
            List {
                if let context = usage.context {
                    Section("Context") {
                        LabeledContent("Used", value: "\(format(context.used)) of \(format(context.size)) (\(Int(fraction * 100))%)")
                        if let cost = context.costAmount {
                            LabeledContent("Cost", value: cost.formatted(.currency(code: context.costCurrency ?? "USD")))
                        }
                    }
                }
                rows("Last turn", usage.lastTurn)
                rows("Cumulative", usage.cumulative)
            }
            .navigationTitle(usage.modelName ?? "Usage")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func rows(_ title: String, _ items: [RemoteTokenUsage]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items, id: \.label) { LabeledContent($0.label, value: format($0.tokens)) }
            }
        }
    }

    private func format(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 1000...: String(format: "%.1fk", Double(tokens) / 1000)
        default: "\(tokens)"
        }
    }
}
