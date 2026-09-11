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
    var onStatusTransition: ((String, Bool, Date) -> Void)?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func reportConnectionFailure(host: String) {
        let count = (consecutiveFailures[host] ?? 0) + 1
        consecutiveFailures[host] = count
        if count >= 2, offlineHosts.insert(host).inserted {
            onStatusTransition?(host, true, now())
        }
    }

    func reportSuccess(host: String) {
        consecutiveFailures[host] = nil
        if offlineHosts.remove(host) != nil {
            onStatusTransition?(host, false, now())
        }
    }

    func isOffline(_ host: String) -> Bool {
        offlineHosts.contains(host)
    }
}
