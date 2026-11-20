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
    /// The `RemotePushKind`s to be alerted for, on every host.
    var kinds: Set<String> {
        didSet {
            guard kinds != oldValue else { return }
            defaults.set(Array(kinds), forKey: Self.kindsKey)
            onTokenChange?()
        }
    }
    /// Called when `relayToken` or `kinds` changes, so the hub can resend them to hosts.
    @ObservationIgnored var onTokenChange: (() -> Void)?
    @ObservationIgnored private weak var hub: HostHub?
    @ObservationIgnored private let defaults = UserDefaults(suiteName: AppGroup.id) ?? .standard
    private static let tokenKey = "pushRelayToken"
    /// The APNs token the relay token was issued for. The relay seals with a fresh IV each time, so
    /// registering an unchanged token would still hand every host a "new" one.
    private static let apnsTokenKey = "pushAPNsToken"
    private static let registeredAtKey = "pushRegisteredAt"
    private static let kindsKey = "pushKinds"
    /// How long a relay token is reused for an unchanged APNs token. Rotating the relay's secret
    /// invalidates every token, and only the relay knows that, so each phone re-registers this often.
    private static let reregisterAfter: TimeInterval = 24 * 60 * 60

    init(hub: HostHub) {
        self.hub = hub
        relayToken = defaults.string(forKey: Self.tokenKey)
        kinds = (defaults.stringArray(forKey: Self.kindsKey)).map(Set.init) ?? RemotePushKind.defaults.union([RemotePushKind.inbox])
    }

    /// Asks for permission and registers, once a host is paired. Call again
    /// after pairing so the prompt appears then, not at first launch.
    func start() {
        guard !Self.relayURL.isEmpty, hub?.hosts.isEmpty == false else { return }
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "attention", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "inbox", actions: [
                UNNotificationAction(identifier: "dismiss", title: "Dismiss", options: []),
            ], intentIdentifiers: []),
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
        let registeredAt = Date(timeIntervalSince1970: defaults.double(forKey: Self.registeredAtKey))
        guard relayToken == nil || defaults.string(forKey: Self.apnsTokenKey) != hex
            || Date().timeIntervalSince(registeredAt) > Self.reregisterAfter else { return }
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
              let token = (try? JSONDecoder().decode([String: String].self, from: reply))?["relayToken"] else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: Self.registeredAtKey)
        guard token != relayToken else { return }
        relayToken = token
        defaults.set(token, forKey: Self.tokenKey)
        defaults.set(apnsToken, forKey: Self.apnsTokenKey)
        onTokenChange?()
    }

    /// Removes delivered alerts whose session a current list shows and not
    /// waiting, on any host, or whose own Mac's current list no longer has it.
    /// Catches clear pings iOS never delivered.
    func reconcile() async {
        guard let hub else { return }
        var waiting = Set<String>()
        var listed = Set<String>()
        /// Macs whose own live list is in: a session missing from it is gone.
        var origins = Set<String>()
        for host in hub.hosts {
            guard let list = hub.freshSessions(of: host.id) else { continue }
            if let serverId = host.serverId { origins.insert(serverId) }
            for session in list {
                guard let origin = session.serverId ?? host.serverId else { continue }
                let id = session.serverId.map { session.id.dropFirst($0.count + 1) } ?? Substring(session.id)
                let collapseId = RemotePushID.collapseId(originServerId: origin, sessionId: String(id))
                listed.insert(collapseId)
                // The host pushes for any waiting session, open in a tab or not.
                if session.status == "awaitingPermission" || session.status == "awaitingInput" { waiting.insert(collapseId) }
            }
        }
        let center = UNUserNotificationCenter.current()
        let stale = await center.deliveredNotifications().compactMap { note -> String? in
            let id = note.request.identifier
            // A finished turn's alert is news, not a wait: it stays until the user clears it. An inbox
            // alert names an inbox item, not a session; the Mac's clear ping removes it.
            // ponytail: a clear missed while offline leaves it; reconcile against the inbox list if that bites.
            let status = (note.request.content.userInfo["alas"] as? [String: Any])?["status"] as? String
            guard status != "finished", status != "inbox" else { return nil }
            let origin = (note.request.content.userInfo["alas"] as? [String: Any])?["serverId"] as? String
            return (listed.contains(id) || origin.map(origins.contains) == true) && !waiting.contains(id) ? id : nil
        }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
    }
}
