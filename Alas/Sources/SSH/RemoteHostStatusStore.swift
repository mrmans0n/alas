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

    func reportConnectionFailure(host: String) {
        let count = (consecutiveFailures[host] ?? 0) + 1
        consecutiveFailures[host] = count
        if count >= 2 {
            offlineHosts.insert(host)
        }
    }

    func reportSuccess(host: String) {
        consecutiveFailures[host] = nil
        offlineHosts.remove(host)
    }

    func isOffline(_ host: String) -> Bool {
        offlineHosts.contains(host)
    }
}
