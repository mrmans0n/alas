import Charts
import SwiftUI

/// A ```` ```chart ```` fence drawn with Swift Charts in the theme's chart colours, sized and
/// formatted like `<alas-chart>`. Hovering a label shows its values.
struct ACPMarkdownChart: View {
    let chart: ChartSpec
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var selectedSlot: String?

    /// `--alas-chart-1` to `6` in `PluginWebPolicy`, so a fence matches the same chart in a visual.
    private static let colorTokens = ["accent", "info", "add", "warn", "del", "goal"]

    private var points: [Point] {
        chart.series.flatMap { series in
            zip(chart.labels, series.values).enumerated().map { index, pair in
                Point(id: "\(series.name)#\(index)", slot: String(index), series: series.name, value: pair.1)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            if let title = chart.title {
                Text(title)
                    .font(scale.meta.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
            }
            plot
                .chartForegroundStyleScale(
                    domain: chart.series.map(\.name),
                    range: chart.series.indices.map { theme.color(Self.colorTokens[$0 % Self.colorTokens.count]) }
                )
                .chartLegend(chart.showsLegend ? .visible : .hidden)
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: chart.height)
                .accessibilityLabel(chart.title ?? (chart.kind == .line ? "Line chart" : "Bar chart"))
        }
        .padding(.vertical, scale.space[1])
    }

    @ViewBuilder
    private var plot: some View {
        let points = points
        switch chart.kind {
        case .bar:
            Chart(points) { point in
                BarMark(x: .value("Position", point.slot), y: .value("Value", point.value))
                    .position(by: .value("Series", point.series))
                    .foregroundStyle(by: .value("Series", point.series))
                    .cornerRadius(2)
                    .opacity(opacity(for: point.slot))
            }
            .chartYAxis { valueAxis }
            .chartXAxis { labelAxis }
            .chartXSelection(value: $selectedSlot)
            .overlay(alignment: .topTrailing) { selection }
        case .hbar:
            Chart(points) { point in
                BarMark(x: .value("Value", point.value), y: .value("Position", point.slot))
                    .position(by: .value("Series", point.series))
                    .foregroundStyle(by: .value("Series", point.series))
                    .cornerRadius(2)
                    .opacity(opacity(for: point.slot))
            }
            .chartXAxis { valueAxis }
            .chartYAxis { labelAxis }
            .chartYSelection(value: $selectedSlot)
            .overlay(alignment: .bottomTrailing) { selection }
        case .line:
            Chart(points) { point in
                LineMark(x: .value("Position", point.slot), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                PointMark(x: .value("Position", point.slot), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .symbolSize(24)
                if point.slot == selectedSlot {
                    RuleMark(x: .value("Position", point.slot))
                        .foregroundStyle(theme.color("fg-faint").opacity(0.4))
                }
            }
            .chartYAxis { valueAxis }
            .chartXAxis { labelAxis }
            .chartXSelection(value: $selectedSlot)
            .overlay(alignment: .topTrailing) { selection }
        }
    }

    private var labelAxis: some AxisContent {
        AxisMarks { value in
            AxisValueLabel {
                if let slot = value.as(String.self), let index = Int(slot), chart.labels.indices.contains(index) {
                    Text(chart.labels[index])
                }
            }
        }
    }

    private var valueAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine()
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(ChartSpec.format(number) + chart.unit)
                }
            }
        }
    }

    private func opacity(for slot: String) -> Double {
        selectedSlot == nil || selectedSlot == slot ? 1 : 0.45
    }

    /// The hovered label's values, one line per series.
    @ViewBuilder
    private var selection: some View {
        if let slot = selectedSlot, let index = Int(slot), chart.labels.indices.contains(index) {
            let label = chart.labels[index]
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(scale.caption.font(weight: .semibold))
                ForEach(chart.series, id: \.name) { series in
                    Text((chart.series.count > 1 ? series.name + ": " : "")
                        + ChartSpec.format(series.values[index]) + chart.unit)
                        .font(scale.caption.font(weight: .regular, design: .monospaced))
                }
            }
            .foregroundStyle(theme.color("fg"))
            .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[1])
            .background(RoundedRectangle(cornerRadius: scale.radius.small).fill(theme.color("bg-2")))
            .allowsHitTesting(false)
        }
    }

    /// Positioned by index, so repeated labels keep their own bars and points; the axis shows the text.
    private struct Point: Identifiable {
        let id: String
        let slot: String
        let series: String
        let value: Double
    }
}
