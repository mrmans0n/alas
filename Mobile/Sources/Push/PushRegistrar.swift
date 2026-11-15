import AlasRemoteKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Registers this phone for push: asks permission, trades the APNs token for a
/// relay token, and hands that to the paired hosts through `HostHub`.
@MainActor @Observable
final class PushRegistrar {
    /// Empty means push is off.
    static var relayURL: String {
        Bundle.main.object(forInfoDictionaryKey: "AlasPushRelayURL") as? String ?? ""
    }

    private(set) var relayToken: String?
    /// Called when `relayToken` changes, so the hub can resend it to hosts.
    @ObservationIgnored var onTokenChange: (() -> Void)?
    @ObservationIgnored private weak var hub: HostHub?
    @ObservationIgnored private let defaults = UserDefaults(suiteName: AppGroup.id) ?? .standard
    private static let tokenKey = "pushRelayToken"

    init(hub: HostHub) {
        self.hub = hub
        relayToken = defaults.string(forKey: Self.tokenKey)
    }

    /// Asks for permission and registers, once a host is paired. Call again
    /// after pairing so the prompt appears then, not at first launch.
    func start() {
        guard !Self.relayURL.isEmpty, hub?.hosts.isEmpty == false else { return }
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "attention", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission", actions: [
                UNNotificationAction(identifier: "allow", title: "Allow", options: [.authenticationRequired]),
                UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive, .authenticationRequired]),
            ], intentIdentifiers: []),
        ])
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await register(apnsToken: hex) }
    }

    private func register(apnsToken: String) async {
        let environment = Bundle.main.object(forInfoDictionaryKey: "AlasPushEnvironment") as? String
        // Info.plist holds the aps-environment value; the relay says "sandbox".
        let body: [String: String] = [
            "apnsToken": apnsToken,
            "topic": Bundle.main.bundleIdentifier ?? "",
            "environment": environment == "production" ? "production" : "sandbox",
        ]
        guard let url = URL(string: Self.relayURL)?.appending(path: "register"),
              let data = try? JSONEncoder().encode(body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = data
        // A failure keeps the old token; the next launch registers again.
        guard let (reply, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let token = (try? JSONDecoder().decode([String: String].self, from: reply))?["relayToken"],
              token != relayToken else { return }
        relayToken = token
        defaults.set(token, forKey: Self.tokenKey)
        onTokenChange?()
    }

    /// Removes delivered alerts whose session no longer waits on any host
    /// whose list is current. Catches clear pings iOS never delivered.
    func reconcile() async {
        guard let hub else { return }
        var waiting = Set<String>()
        var covered = Set<String>()
        for host in hub.hosts {
            guard let list = hub.freshSessions(of: host.id) else { continue }
            if let serverId = host.serverId { covered.insert(serverId) }
            for session in list {
                guard let origin = session.serverId ?? host.serverId else { continue }
                covered.insert(origin)
                let id = session.serverId.map { session.id.dropFirst($0.count + 1) } ?? Substring(session.id)
                if session.isActive, session.status == "awaitingPermission" || session.status == "awaitingInput" {
                    waiting.insert(RemotePushID.collapseId(originServerId: origin, sessionId: String(id)))
                }
            }
        }
        let center = UNUserNotificationCenter.current()
        let stale = await center.deliveredNotifications().compactMap { note -> String? in
            guard let alas = note.request.content.userInfo["alas"] as? [String: Any],
                  let origin = alas["serverId"] as? String, covered.contains(origin),
                  !waiting.contains(note.request.identifier) else { return nil }
            return note.request.identifier
        }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
    }
}
