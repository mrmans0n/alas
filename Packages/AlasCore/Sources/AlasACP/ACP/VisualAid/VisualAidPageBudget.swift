import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

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
