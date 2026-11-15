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
            // Only the request the alert showed may be answered; an alert the extension did not rewrite names none.
            let request = alas?["request"] as? String
            var answered = false
            if let request {
                answered = await Self.answerInBackground(serverId: serverId, sessionId: sessionId, request: request,
                                                         allow: action == "allow")
            }
            if !answered { await Self.postCouldntAnswer(serverId: serverId, sessionId: sessionId, title: response.notification.request.content.title) }
            return
        }
        await Self.openTapped(serverId: serverId, sessionId: sessionId)
    }

    @MainActor private static func openTapped(serverId: String?, sessionId: String?) async {
        var route: SessionRoute?
        if let serverId, let sessionId {
            route = await hub?.route(serverId: serverId, sessionId: sessionId, before: .now + .seconds(5))
        }
        if let open { open(route) } else { pending.append(route) }
    }

    /// The actions do not open the app, so iOS may run this with the app in the background and its
    /// hosts disconnected: connect for the answer, and let go again unless the app came forward.
    @MainActor private static func answerInBackground(serverId: String, sessionId: String, request: String,
                                                      allow: Bool) async -> Bool {
        let app = UIApplication.shared
        // No expiration handler: `answer` gives up after 25 s, inside the system's budget.
        let task = app.beginBackgroundTask(withName: "Answer permission")
        defer {
            // Only from the background: a user opening the app meanwhile passes through inactive, and
            // disconnecting then would leave the screen they open offline until the next background trip.
            if app.applicationState == .background { hub?.disconnectAll() }
            app.endBackgroundTask(task)
        }
        return await answer(serverId: serverId, sessionId: sessionId, request: request, allow: allow)
    }

    /// Answers the session's pending permission once, if it is the request `request` names, taking over
    /// the writer lease when the Mac holds it, and waits until it resolves.
    @MainActor private static func answer(serverId: String, sessionId: String, request: String, allow: Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(25)
        guard let hub, let registry,
              let route = await hub.route(serverId: serverId, sessionId: sessionId, before: deadline) else { return false }
        // What a session already following the online host shows is current; anything else waits for a snapshot
        // sent after this began, since the one it holds may predate a disconnect.
        let wasLive = hub.state(of: route.hostID) == .online
            && registry.live(hostID: route.hostID, sessionId: route.sessionId)?.isOpen == true
        let (session, token) = registry.acquire(hostID: route.hostID, sessionId: route.sessionId)
        defer { token.cancel() }
        let snapshots = session.snapshotsReceived
        func wait(until done: () -> Bool) async -> Bool {
            while !done() {
                // A cancelled sleep returns at once: without the check this would spin the main actor.
                guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return true
        }
        if !wasLive || !session.hasSnapshot {
            guard await wait(until: { session.snapshotsReceived > snapshots }) else { return false }
            // The host surfaces pending requests right behind the snapshot, and the session briefly holds
            // the ones from before the resubscribe; answer only what the host sent again.
            try? await Task.sleep(for: .seconds(1))
        }
        var sent = false
        let settled = await wait(until: {
            // Nothing pending and nothing sent: it was answered elsewhere, so there is nothing to apologize for.
            guard let now = session.permission else { return !sent || !session.hasDeferredAnswer(.permission) }
            // A different request than the one the user saw must never get this answer.
            guard RemoteRequestIdentity.of(now) == request else { return true }
            if !sent {
                // `answerPermission` ignores a request that only just replaced another, so retry until it takes.
                // An already-answered kind is not re-sent: that guard is what keeps this a single answer.
                if let optionId = RemotePermissionQuickAnswer.optionId(in: now, allow: allow) {
                    session.answerPermission(optionId: optionId)
                }
                sent = session.answered.contains(.permission)
            }
            return false
        })
        // Done once no request is left: ours resolved after the answer went out, or was answered elsewhere.
        return settled && session.permission == nil
    }

    private static func postCouldntAnswer(serverId: String, sessionId: String, title: String) async {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Alas" : title
        content.body = "Couldn't answer. Open Alas to respond."
        content.categoryIdentifier = "attention"
        content.userInfo = ["alas": ["serverId": serverId, "sessionId": sessionId]]
        // Under the session's collapse id, so it replaces the alert and a clear ping or reconcile removes it.
        let identifier = RemotePushID.collapseId(originServerId: serverId, sessionId: sessionId)
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
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

    /// `route`, after connecting: a peer session created while the phone was away is only in a
    /// gateway's live list. Gives up at `deadline`, or once every host sent a live list without it.
    func route(serverId: String, sessionId: String, before deadline: ContinuousClock.Instant) async -> SessionRoute? {
        connectAll()
        while true {
            if let route = route(serverId: serverId, sessionId: sessionId) { return route }
            if ContinuousClock.now >= deadline || Task.isCancelled || hosts.allSatisfy({ freshSessions(of: $0.id) != nil }) { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
