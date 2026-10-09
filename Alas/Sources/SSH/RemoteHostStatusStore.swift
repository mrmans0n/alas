import Combine
import Foundation

enum RemoteHostReachability: Equatable {
    case unknown
    case online
    case offline
}

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
        // Touch the published set only on a real change: every mutation, even
        // a no-op one, re-renders each view observing this store.
        if count >= 2, !offlineHosts.contains(host) {
            offlineHosts.insert(host)
            observedHosts.insert(host)
            onStatusTransition?(host, true, now())
        }
    }

    func reportSuccess(host: String) {
        consecutiveFailures[host] = nil
        // Polls report success many times a second; see above.
        let wasOffline = offlineHosts.contains(host)
        if wasOffline { offlineHosts.remove(host) }
        let isFirstObservation = observedHosts.insert(host).inserted
        if wasOffline || isFirstObservation {
            onStatusTransition?(host, false, now())
        }
    }

    func isOffline(_ host: String) -> Bool {
        offlineHosts.contains(host)
    }

    func reachability(for host: String) -> RemoteHostReachability {
        if offlineHosts.contains(host) { return .offline }
        if observedHosts.contains(host) { return .online }
        return .unknown
    }
}
