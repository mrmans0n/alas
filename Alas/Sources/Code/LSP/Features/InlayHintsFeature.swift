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

/// One active request and one replaceable pending viewport. Source invalidation
/// clears immediately; presentation changes never advance source freshness.
@MainActor
final class InlayHintsFeature {
    private let request: (NSRange) async -> [LSPInlayHint]?
    private let apply: ([LSPInlayHint]) -> Void
    private let clear: () -> Void
    private var generation = 0
    private var pending: (range: NSRange, deadline: ContinuousClock.Instant, generation: Int)?
    private var worker: Task<Void, Never>?
    private var workerID = UUID()

    init(request: @escaping (NSRange) async -> [LSPInlayHint]?, apply: @escaping ([LSPInlayHint]) -> Void, clear: @escaping () -> Void) {
        self.request = request
        self.apply = apply
        self.clear = clear
    }

    nonisolated static func isVisible(kind: Int?, settings: InlayHintSettings) -> Bool {
        settings.enabled && (kind == 1 ? settings.types : kind == 2 ? settings.parameters : true)
    }

    func refresh(range: NSRange, debounce: Duration = .milliseconds(80)) {
        generation &+= 1
        pending = (range, .now.advanced(by: debounce), generation)
        guard worker == nil else { return }
        let id = UUID()
        workerID = id
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if workerID == id { worker = nil } }
            while let next = pending, !Task.isCancelled {
                do { try await ContinuousClock().sleep(until: next.deadline) } catch { return }
                guard pending?.generation == next.generation else { continue }
                pending = nil
                let result = await request(next.range)
                guard !Task.isCancelled else { return }
                guard generation == next.generation else { continue }
                if let result { apply(result) } else { clear() }
            }
        }
    }

    func invalidate() {
        generation &+= 1
        pending = nil
        clear()
    }

    func stop() {
        invalidate()
        workerID = UUID()
        worker?.cancel()
        worker = nil
    }
}
