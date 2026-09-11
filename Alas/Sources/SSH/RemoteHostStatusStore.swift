import Combine
import Foundation

/// Tracks per-host reachability from background poll results. Two
/// consecutive connection failures flip a host offline (one can be a
/// transient blip mid-roam); any success flips it back.
@MainActor
final class RemoteHostStatusStore: ObservableObject {
    static let shared = RemoteHostStatusStore()

    @Published private(set) var offlineHosts: Set<String> = []
    private var consecutiveFailures: [String: Int] = [:]
    private var observedHosts: Set<String> = []
    /// Includes the first confirmed reachable state so persisted outages can end after relaunch.
    var onStatusTransition: ((String, Bool, Date) -> Void)?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func reportConnectionFailure(host: String) {
        let count = (consecutiveFailures[host] ?? 0) + 1
        consecutiveFailures[host] = count
        if count >= 2, offlineHosts.insert(host).inserted {
            observedHosts.insert(host)
            onStatusTransition?(host, true, now())
        }
    }

    func reportSuccess(host: String) {
        consecutiveFailures[host] = nil
        let wasOffline = offlineHosts.remove(host) != nil
        let isFirstObservation = observedHosts.insert(host).inserted
        if wasOffline || isFirstObservation {
            onStatusTransition?(host, false, now())
        }
    }

    func isOffline(_ host: String) -> Bool {
        offlineHosts.contains(host)
    }
}
