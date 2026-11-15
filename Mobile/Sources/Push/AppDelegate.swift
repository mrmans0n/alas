import AlasRemoteKit
import UIKit
import UserNotifications

/// Receives the APNs token, presents alerts in the foreground, routes taps and
/// removes alerts on clear pings. The app hands it the hub and registrar.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var hub: HostHub?
    @MainActor static var registrar: PushRegistrar?
    @MainActor static var registry: SessionRegistry?
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
        let action = response.actionIdentifier
        if action == "allow" || action == "deny", let serverId, let sessionId {
            let answered = await Self.answer(serverId: serverId, sessionId: sessionId, allow: action == "allow")
            if !answered { await Self.postCouldntAnswer(serverId: serverId, sessionId: sessionId) }
            return
        }
        await MainActor.run {
            var route: SessionRoute?
            if let serverId, let sessionId { route = Self.hub?.route(serverId: serverId, sessionId: sessionId) }
            if let open = Self.open { open(route) } else { Self.pending.append(route) }
        }
    }

    /// Answers the session's pending permission once, taking over the writer lease when the Mac holds it,
    /// and waits (within the system's budget for this callback) until the request resolves.
    @MainActor private static func answer(serverId: String, sessionId: String, allow: Bool) async -> Bool {
        guard let route = hub?.route(serverId: serverId, sessionId: sessionId),
              let (session, token) = registry?.acquire(hostID: route.hostID, sessionId: route.sessionId) else { return false }
        defer { token.cancel() }
        let deadline = ContinuousClock.now + .seconds(25)
        func wait(until done: () -> Bool) async -> Bool {
            while !done() {
                guard ContinuousClock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return true
        }
        guard await wait(until: { session.permission != nil }), let payload = session.permission,
              let optionId = RemotePermissionQuickAnswer.optionId(in: payload, allow: allow) else { return false }
        // `answerPermission` ignores a request that only just replaced another, so retry until it takes.
        var sent = false
        guard await wait(until: {
            if !sent {
                session.answerPermission(optionId: optionId)
                sent = session.answered.contains(.permission)
            }
            return sent
        }) else { return false }
        return await wait(until: { session.permission == nil })
    }

    private static func postCouldntAnswer(serverId: String, sessionId: String) async {
        let content = UNMutableNotificationContent()
        content.body = "Couldn't answer. Open Alas to respond."
        content.categoryIdentifier = "attention"
        content.userInfo = ["alas": ["serverId": serverId, "sessionId": sessionId]]
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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
