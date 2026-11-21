import AlasHighlight
import Charts
import SwiftUI

/// A ```` ```chart ```` fence drawn with Swift Charts, sized and formatted like the Mac's. Touching a
/// label shows its values.
struct MarkdownChart: View {
    let chart: ChartSpec
    @State private var selectedSlot: String?

    private static let colors: [Color] = [.accentColor, .blue, .green, .orange, .red, .purple]

    private var points: [Point] {
        chart.series.flatMap { series in
            zip(chart.labels, series.values).enumerated().map { index, pair in
                Point(id: "\(series.name)#\(index)", slot: String(index), series: series.name, value: pair.1)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = chart.title {
                Text(title).font(.subheadline.weight(.semibold))
            }
            plot
                .chartForegroundStyleScale(
                    domain: chart.series.map(\.name),
                    range: chart.series.indices.map { Self.colors[$0 % Self.colors.count] }
                )
                .chartLegend(chart.showsLegend ? .visible : .hidden)
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: chart.height)
                .accessibilityLabel(chart.title ?? (chart.kind == .line ? "Line chart" : "Bar chart"))
            if let slot = selectedSlot, let index = Int(slot), chart.labels.indices.contains(index) {
            let label = chart.labels[index]
                Text(label + ": " + chart.series.map {
                    (chart.series.count > 1 ? $0.name + " " : "") + ChartSpec.format($0.values[index]) + chart.unit
                }.joined(separator: ", "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
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
            }
            .chartYAxis { valueAxis }
            .chartXAxis { labelAxis }
            .chartXSelection(value: $selectedSlot)
        case .hbar:
            Chart(points) { point in
                BarMark(x: .value("Value", point.value), y: .value("Position", point.slot))
                    .position(by: .value("Series", point.series))
                    .foregroundStyle(by: .value("Series", point.series))
                    .cornerRadius(2)
            }
            .chartXAxis { valueAxis }
            .chartYAxis { labelAxis }
            .chartYSelection(value: $selectedSlot)
        case .line:
            Chart(points) { point in
                LineMark(x: .value("Position", point.slot), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                PointMark(x: .value("Position", point.slot), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .symbolSize(24)
            }
            .chartYAxis { valueAxis }
            .chartXAxis { labelAxis }
            .chartXSelection(value: $selectedSlot)
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
                if let number = value.as(Double.self) { Text(ChartSpec.format(number) + chart.unit) }
            }
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
