import Foundation

/// Least-recently-admitted order behind the live visual page cap.
public struct VisualAidPageLRU: Equatable, Sendable {
    public let limit: Int
    public private(set) var order: [UUID] = []

    /// Admits `slot` as the most recent page and returns the slots that must close.
    public mutating func admit(_ slot: UUID) -> [UUID] {
        order.removeAll { $0 == slot }
        order.append(slot)
        let overflow = max(0, order.count - limit)
        let evicted = Array(order.prefix(overflow))
        order.removeFirst(overflow)
        return evicted
    }

    public mutating func release(_ slot: UUID) {
        order.removeAll { $0 == slot }
    }

    public init(limit: Int, order: [UUID] = []) {
        self.limit = limit
        self.order = order
    }
}

/// App-wide cap on live visual pages; each one costs a WebContent process.
/// Slots are per card instance, so an inline card and its pop-out tab count twice.
@MainActor
public final class VisualAidPageBudget {
    public static let shared = VisualAidPageBudget()

    private var lru = VisualAidPageLRU(limit: VisualAidWebPolicy.maxLivePages)
    private var evictors: [UUID: () -> Void] = [:]

    public func admit(_ slot: UUID, onEvict: @escaping () -> Void) {
        evictors[slot] = onEvict
        for evicted in lru.admit(slot) {
            evictors.removeValue(forKey: evicted)?()
        }
    }

    public func release(_ slot: UUID) {
        lru.release(slot)
        evictors.removeValue(forKey: slot)
    }

    public init() {}
}
