import Foundation

@MainActor
final class SemanticTokensFeature {
    struct Result: Sendable {
        let spans: [HighlightSpan]
        let context: EditorRequestContext
    }

    private let request: (NSRange) async -> Result?
    private let apply: ([HighlightSpan], EditorRequestContext) -> Void
    private let clear: () -> Void
    private var revision: UInt64 = 0
    private var pending: (range: NSRange, deadline: ContinuousClock.Instant, revision: UInt64)?
    private var worker: Task<Void, Never>?
    private var workerID = UUID()

    init(request: @escaping (NSRange) async -> Result?, apply: @escaping ([HighlightSpan], EditorRequestContext) -> Void, clear: @escaping () -> Void) {
        self.request = request
        self.apply = apply
        self.clear = clear
    }

    func refresh(range: NSRange, debounce: Duration) {
        revision &+= 1
        pending = (range, .now.advanced(by: debounce), revision)
        guard worker == nil else { return }
        let id = UUID()
        workerID = id
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.workerID == id { self.worker = nil } }
            while let next = self.pending, !Task.isCancelled {
                do { try await ContinuousClock().sleep(until: next.deadline) } catch { return }
                guard self.pending?.revision == next.revision else { continue }
                self.pending = nil
                let result = await self.request(next.range)
                guard !Task.isCancelled else { return }
                if self.revision == next.revision, let result { self.apply(result.spans, result.context) }
            }
        }
    }

    func invalidate() {
        revision &+= 1
        pending = nil
        clear()
    }

    func stop() {
        invalidate()
        workerID = UUID()
        worker?.cancel()
        worker = nil
    }

    enum DecodeError: Swift.Error { case malformed, tooLarge }
    nonisolated static let maximumIntegers = 1_000_000

    /// Tokens use UTF-16 coordinates, relative to the previous token's start.
    /// Build line bounds once so a full response is linear in document size.
    nonisolated static func decode(_ data: [Int], legend: [String], text: String,
                                   modifiers: [String] = [], allowedRange: NSRange? = nil) throws -> [HighlightSpan] {
        guard data.count <= maximumIntegers else { throw DecodeError.tooLarge }
        guard data.count.isMultiple(of: 5), legend.count <= 65536, modifiers.count <= 31 else { throw DecodeError.malformed }
        let units = Array(text.utf16)
        var lines: [(start: Int, end: Int)] = []
        var start = 0
        for index in units.indices where units[index] == 10 {
            lines.append((start, index > start && units[index - 1] == 13 ? index - 1 : index))
            start = index + 1
        }
        lines.append((start, units.count > start && units.last == 13 ? units.count - 1 : units.count))
        func boundary(_ offset: Int) -> Bool {
            offset == 0 || offset == units.count || !(0xD800...0xDBFF).contains(units[offset - 1]) || !(0xDC00...0xDFFF).contains(units[offset])
        }
        if let allowedRange {
            guard allowedRange.location >= 0, allowedRange.location <= units.count,
                  allowedRange.length >= 0, allowedRange.length <= units.count - allowedRange.location else { throw DecodeError.malformed }
        }
        var line = 0
        var column = 0
        var previousEnd = 0
        var spans: [HighlightSpan] = []
        for index in stride(from: 0, to: data.count, by: 5) {
            let tuple = data[index..<index + 5]
            guard tuple.allSatisfy({ $0 >= 0 && $0 <= 0x7FFF_FFFF }) else { throw DecodeError.malformed }
            let deltaLine = data[index], deltaColumn = data[index + 1], length = data[index + 2]
            let type = data[index + 3], mask = data[index + 4]
            guard deltaLine < lines.count - line, length > 0, type < legend.count,
                  mask < (1 << modifiers.count) else { throw DecodeError.malformed }
            line += deltaLine
            column = deltaLine == 0 ? column + deltaColumn : deltaColumn
            let bounds = lines[line]
            guard column <= bounds.end - bounds.start, length <= bounds.end - bounds.start - column else { throw DecodeError.malformed }
            let offset = bounds.start + column
            let end = offset + length
            guard offset >= previousEnd, boundary(offset), boundary(end) else { throw DecodeError.malformed }
            previousEnd = end
            if let allowedRange {
                guard offset >= allowedRange.location, end <= NSMaxRange(allowedRange) else { throw DecodeError.malformed }
            }
            let readonly = modifiers.enumerated().contains { $0.element == "readonly" && mask & (1 << $0.offset) != 0 }
            if let capture = HighlightCapture.fromSemanticToken(legend[type], readonly: readonly) {
                spans.append(.init(range: NSRange(location: offset, length: length), capture: capture))
            }
        }
        return spans
    }
}
