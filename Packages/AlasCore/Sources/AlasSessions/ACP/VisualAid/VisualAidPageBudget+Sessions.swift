import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

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
