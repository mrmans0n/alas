import AlasRemoteKit
import UIKit
import UserNotifications

/// Receives the APNs token, presents alerts in the foreground, routes taps and
/// removes alerts on clear pings. The app hands it the hub and registrar.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var hub: HostHub?
    @MainActor static var registrar: PushRegistrar?
    /// Opens the Inbox and pushes the route; set once the UI exists.
    @MainActor static var open: (@MainActor (SessionRoute?) -> Void)? {
        didSet {
            guard let open, !pending.isEmpty else { return }
            pending.forEach(open)
            pending = []
        }
    }

    /// Taps that arrived before the UI set `open` (cold launch).
    @MainActor private static var pending: [SessionRoute?] = []

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in Self.registrar?.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let alas = userInfo["alas"] as? [String: Any], alas["clear"] as? Bool == true,
              let serverId = alas["serverId"] as? String, let sessionId = alas["sessionId"] as? String else { return .noData }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [RemotePushID.collapseId(originServerId: serverId, sessionId: sessionId)])
        return .noData
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let alas = response.notification.request.content.userInfo["alas"] as? [String: Any]
        let serverId = alas?["serverId"] as? String
        let sessionId = alas?["sessionId"] as? String
        await MainActor.run {
            var route: SessionRoute?
            if let serverId, let sessionId { route = Self.hub?.route(serverId: serverId, sessionId: sessionId) }
            if let open = Self.open { open(route) } else { Self.pending.append(route) }
        }
    }
}

extension HostHub {
    /// The host to open a pushed session on: the Mac itself, else a gateway
    /// that lists it under its namespaced id.
    func route(serverId: String, sessionId: String) -> SessionRoute? {
        if let host = hosts.first(where: { $0.serverId == serverId }) {
            return SessionRoute(hostID: host.id, sessionId: sessionId)
        }
        let namespaced = RemoteFederatedSessionID.compose(serverId: serverId, sessionId: sessionId)
        return hosts.first { host in sessions(of: host.id).contains { $0.id == namespaced } }
            .map { SessionRoute(hostID: $0.id, sessionId: namespaced) }
    }
}
