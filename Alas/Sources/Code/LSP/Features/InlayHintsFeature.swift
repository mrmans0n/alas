import Foundation

struct InlayHintSettings: Codable, Equatable, Sendable {
    var enabled = true
    var parameters = true
    var types = true

    init(enabled: Bool = true, parameters: Bool = true, types: Bool = true) {
        self.enabled = enabled
        self.parameters = parameters
        self.types = types
    }

    private enum CodingKeys: String, CodingKey { case enabled, parameters, types }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        parameters = try c.decodeIfPresent(Bool.self, forKey: .parameters) ?? true
        types = try c.decodeIfPresent(Bool.self, forKey: .types) ?? true
    }
}

/// Fetch stable source chunks once per revision. Scrolling changes request
/// priority without discarding valid replies or decorations from visited code.
@MainActor
final class InlayHintsFeature {
    private let request: (NSRange) async -> [LSPInlayHint]?
    private let apply: ([LSPInlayHint]) -> Void
    private let clear: () -> Void
    private var generation = 0
    private var pending: [NSRange] = []
    private var deadline: ContinuousClock.Instant = .now
    private var activeRange: NSRange?
    private var cached: [NSRange: [LSPInlayHint]] = [:]
    private var retryAfter: [NSRange: ContinuousClock.Instant] = [:]
    private var worker: Task<Void, Never>?
    private var workerID = UUID()
    private var presentationExpiry: Task<Void, Never>?

    init(request: @escaping (NSRange) async -> [LSPInlayHint]?, apply: @escaping ([LSPInlayHint]) -> Void, clear: @escaping () -> Void) {
        self.request = request
        self.apply = apply
        self.clear = clear
    }

    nonisolated static func isVisible(kind: Int?, settings: InlayHintSettings) -> Bool {
        settings.enabled && (kind == 1 ? settings.types : kind == 2 ? settings.parameters : true)
    }

    func refresh(range: NSRange, debounce: Duration = .milliseconds(80)) {
        refresh(ranges: [range], debounce: debounce)
    }

    func refresh(ranges: [NSRange], debounce: Duration = .zero) {
        let next = ranges.filter { cached[$0] == nil && $0 != activeRange && (retryAfter[$0].map { $0 <= .now } ?? true) }
        // Bounds notifications within a chunk must not keep postponing it.
        if next != pending {
            pending = next
            deadline = .now.advanced(by: debounce)
        }
        guard !pending.isEmpty else { return }
        guard worker == nil else { return }
        let id = UUID()
        workerID = id
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if workerID == id { worker = nil } }
            while !pending.isEmpty, !Task.isCancelled {
                let nextDeadline = deadline
                do { try await ContinuousClock().sleep(until: nextDeadline) } catch { return }
                guard deadline == nextDeadline, !pending.isEmpty else { continue }
                let range = pending.removeFirst()
                let requestGeneration = generation
                activeRange = range
                let result = await request(range)
                guard !Task.isCancelled else { return }
                activeRange = nil
                guard generation == requestGeneration else { continue }
                guard let result else {
                    retryAfter[range] = .now.advanced(by: .seconds(1))
                    continue
                }
                cached[range] = result
                retryAfter[range] = nil
                cancelPresentationExpiry()
                apply(cached.keys.sorted { $0.location < $1.location }.flatMap { self.cached[$0] ?? [] })
            }
        }
    }

    func invalidate(preservingPresentation: Bool = false) {
        generation &+= 1
        pending = []
        activeRange = nil
        cached = [:]
        retryAfter = [:]
        if !preservingPresentation {
            cancelPresentationExpiry()
            clear()
        } else if presentationExpiry == nil {
            // Repeated edits must not keep old labels alive indefinitely when
            // synchronization or the server stalls. Fresh results cancel this.
            presentationExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                presentationExpiry = nil
                clear()
            }
        }
    }

    private func cancelPresentationExpiry() {
        presentationExpiry?.cancel()
        presentationExpiry = nil
    }

    func stop() {
        invalidate()
        workerID = UUID()
        worker?.cancel()
        worker = nil
    }

    /// Request the visible 256-line chunks first, then their neighbors. Source
    /// line offsets avoid laying out offscreen text just to choose a request.
    nonisolated static func requestRanges(visibleRange: NSRange, lineStarts: [Int], sourceLength: Int) -> [NSRange] {
        guard !lineStarts.isEmpty else { return [] }
        func line(at offset: Int) -> Int {
            var low = 0, high = lineStarts.count
            while low < high {
                let middle = low + (high - low) / 2
                if lineStarts[middle] <= offset { low = middle + 1 } else { high = middle }
            }
            return max(0, low - 1)
        }
        let chunkSize = 256
        // A trailing empty line belongs to the last nonempty chunk, which
        // includes EOF. Do not request EOF twice at an exact chunk boundary.
        let lineCount = max(1, lineStarts.count - (lineStarts.last == sourceLength ? 1 : 0))
        let maximum = (lineCount - 1) / chunkSize
        let first = min(maximum, line(at: visibleRange.location) / chunkSize)
        let last = min(maximum, line(at: NSMaxRange(visibleRange)) / chunkSize)
        var chunks = Array(first...last)
        if last < maximum { chunks.append(last + 1) }
        if first > 0 { chunks.append(first - 1) }
        return chunks.map { chunk in
            let start = lineStarts[chunk * chunkSize]
            let nextLine = (chunk + 1) * chunkSize
            let end = nextLine < lineStarts.count ? lineStarts[nextLine] : sourceLength
            return NSRange(location: start, length: end - start)
        }
    }
}
