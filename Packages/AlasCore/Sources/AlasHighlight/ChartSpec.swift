import Foundation

/// A closed ```` ```chart ```` fence, read for a native chart. The data rules match `<alas-chart>`'s
/// in `frame.html`, so a fence draws the same chart the component would, or stays code.
public struct ChartSpec: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case bar, hbar, line
    }

    public struct Series: Equatable, Sendable {
        /// Never empty: an unnamed series is "Series N".
        public let name: String
        public let values: [Double]

        public init(name: String, values: [Double]) {
            self.name = name
            self.values = values
        }
    }

    public let kind: Kind
    /// Appended to every value, as in "120ms".
    public let unit: String
    /// The fence's `label`.
    public let title: String?
    public let labels: [String]
    public let series: [Series]
    /// The plot's height in points, as `<alas-chart>` sizes it.
    public let height: Double
    /// Whether the series need a legend: more than one, or one the data named.
    public let showsLegend: Bool

    public init(
        kind: Kind, unit: String, title: String?, labels: [String], series: [Series], height: Double, showsLegend: Bool
    ) {
        self.kind = kind
        self.unit = unit
        self.title = title
        self.labels = labels
        self.series = series
        self.height = height
        self.showsLegend = showsLegend
    }

    /// The chart a closed fence draws, or nil when it is not a chart fence or its data breaks a rule:
    /// a JSON object with `series` (each `values` all finite numbers, one per label) or a bare `values`
    /// array, and optional `labels`.
    public init?(language: String?, code: String) {
        guard let language, VisualFence.firstWord(language) == VisualFence.chartTag,
              let data = try? JSONDecoder().decode(Payload.self, from: Data(code.utf8)),
              let rawSeries = data.series ?? data.values.map({ [RawSeries(name: data.name, values: $0)] }),
              let first = rawSeries.first
        else { return nil }
        let labels = data.labels?.map(\.text) ?? first.values.indices.map { String($0 + 1) }
        guard rawSeries.allSatisfy({ $0.values.count == labels.count }) else { return nil }

        var series: [Series] = []
        var usedNames: Set<String> = []
        for (index, raw) in rawSeries.enumerated() {
            // Swift Charts groups by name, so two series never share one.
            var name = raw.name?.text ?? ""
            if name.isEmpty { name = "Series \(index + 1)" }
            var suffix = index + 1
            let base = name
            while usedNames.contains(name) {
                name = "\(base) (\(suffix))"
                suffix += 1
            }
            usedNames.insert(name)
            series.append(Series(name: name, values: raw.values))
        }

        let options = VisualFence.chartOptions(language.drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespaces))
        let kind = options.type.flatMap(Kind.init(rawValue:)) ?? .bar
        let rowHeight = max(14, Double(series.count * 12 + 8))
        let requested = options.attributes["height"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
        self.init(
            kind: kind,
            unit: options.attributes["unit"] ?? "",
            title: options.attributes["label"],
            labels: labels,
            series: series,
            height: min(800, max(80, requested ?? (kind == .hbar ? Double(labels.count) * rowHeight + 28 : 200))),
            showsLegend: series.count > 1 || rawSeries.contains { !($0.name?.text ?? "").isEmpty }
        )
    }

    /// `<alas-chart>`'s data. `JSONDecoder` reads a number only from a JSON number, as the component
    /// requires, and JSON has no infinities.
    private struct Payload: Decodable {
        let labels: [Text]?
        let series: [RawSeries]?
        let values: [Double]?
        let name: Text?
    }

    private struct RawSeries: Decodable {
        let name: Text?
        let values: [Double]
    }

    /// A label or name the component would pass through `String()`.
    private struct Text: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { text = "" }
            else if let string = try? c.decode(String.self) { text = string }
            else if let bool = try? c.decode(Bool.self) { text = String(bool) }
            else {
                let number = try c.decode(Double.self)
                text = number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
            }
        }
    }

    /// A value as `<alas-chart>` prints it: 1.2B, 3.4M, 12.5k, whole numbers from 100, and three
    /// significant digits below, so 0.001 and 0.002 stay apart.
    public static func format(_ value: Double) -> String {
        let magnitude = abs(value)
        func trimmed(_ number: Double, digits: Int) -> String {
            var text = String(format: "%.\(digits)f", number)
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            return text == "-0" ? "0" : text
        }
        if magnitude >= 1e9 { return trimmed(value / 1e9, digits: 1) + "B" }
        if magnitude >= 1e6 { return trimmed(value / 1e6, digits: 1) + "M" }
        if magnitude >= 1e4 { return trimmed(value / 1e3, digits: 1) + "k" }
        if magnitude >= 100 { return trimmed(value.rounded(), digits: 0) }
        guard value != 0 else { return "0" }
        let decimals = max(0, 2 - Int(floor(log10(magnitude))))
        return trimmed(value, digits: decimals)
    }
}
