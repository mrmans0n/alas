import AlasRemoteKit
import UserNotifications

/// Rewrites the relay's fixed "An agent needs you." alert into what the
/// session is waiting on, by asking the paired Mac. Anything that goes wrong
/// delivers the alert as it arrived.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private var job: Job?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let box = Unsendable(request: request, deliver: contentHandler)
        Task { @MainActor in
            let job = Job(request: box.request, deliver: box.deliver)
            self.job = job
            job.start()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        Task { @MainActor in self.job?.finish() }
    }
}

/// UNNotificationRequest and the handler are only touched from the main actor
/// once inside `Job`; this carries them across the hop.
private struct Unsendable: @unchecked Sendable {
    let request: UNNotificationRequest
    let deliver: (UNNotificationContent) -> Void
}

@MainActor
private final class Job {
    /// The extension is killed shortly after 30 s; leave room to deliver.
    private static let deadline: Duration = .seconds(20)

    private let original: UNNotificationContent
    private let deliver: (UNNotificationContent) -> Void
    private let serverId: String?
    private let sessionId: String?
    private var connections: [UUID: PhoneConnection] = [:]
    private var pending: PhoneServerMessage?
    private var title: String?
    private var listed = false
    private var finished = false

    init(request: UNNotificationRequest, deliver: @escaping (UNNotificationContent) -> Void) {
        original = request.content
        self.deliver = deliver
        let alas = request.content.userInfo["alas"] as? [String: Any]
        serverId = alas?["serverId"] as? String
        sessionId = alas?["sessionId"] as? String
    }

    func start() {
        Task {
            try? await Task.sleep(for: Self.deadline)
            finish()
        }
        guard let serverId, let sessionId else { return finish() }
        let store = HostStore()
        let hosts = store.load()
        // Direct: the Mac that owns the session. Otherwise ask every host,
        // since a gateway lists the session under its namespaced id.
        // ponytail: asks all hosts; a cached session list would pick one.
        let direct = hosts.filter { $0.serverId == serverId }
        let candidates = direct.isEmpty ? hosts : direct
        let target = direct.isEmpty ? RemoteFederatedSessionID.compose(serverId: serverId, sessionId: sessionId) : sessionId
        for host in candidates {
            guard let token = store.token(for: host.id) else { continue }
            let id = host.id
            connections[id] = PhoneConnection(
                origins: host.origins, lastOrigin: host.lastOrigin, token: token,
                expectedServerId: host.serverId, expectedPublicKey: host.publicKey
            ) { [weak self] event in
                self?.handle(event, target: target, direct: !direct.isEmpty, host: id)
            }
        }
        if connections.isEmpty { return finish() }
        connections.values.forEach { $0.connect() }
    }

    private func handle(_ event: PhoneConnection.Event, target: String, direct: Bool, host: UUID) {
        guard !finished else { return }
        switch event {
        case .stateChanged(.online):
            connections[host]?.send(.listSessions)
            if direct { connections[host]?.send(.subscribe(sessionId: target)) }
        case .message(let message):
            switch message {
            case .sessionList(let sessions):
                // A direct host's list settles the title even when the session
                // is missing from it; a gateway's only counts if it has it.
                let session = sessions.first(where: { $0.id == target })
                guard session != nil || direct else { return }
                title = session?.title
                listed = true
                if !direct { connections[host]?.send(.subscribe(sessionId: target)) }
            case .permissionRequest(let id, _), .questionRequest(let id, _), .planRequest(let id, _), .elicitationRequest(let id, _):
                guard id == target, pending == nil else { return }
                pending = message
            default:
                return
            }
            if pending != nil, listed { finish() }
        default:
            break
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        connections.values.forEach { $0.disconnect() }
        connections = [:]
        deliver(content())
    }

    private func content() -> UNNotificationContent {
        guard let pending, let alert = RemotePushAlert.content(for: pending, sessionTitle: title),
              let updated = original.mutableCopy() as? UNMutableNotificationContent else { return original }
        updated.title = alert.title
        updated.body = alert.body
        if alert.isPermission { updated.categoryIdentifier = "permission" }
        return updated
    }
}
