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
    /// The host sends the requests a follow has pending right after its snapshot.
    private static let settle: Duration = .seconds(1)

    private let original: UNNotificationContent
    private let deliver: (UNNotificationContent) -> Void
    private let serverId: String?
    private let sessionId: String?
    private var connections: [UUID: PhoneConnection] = [:]
    private var pending: PhoneServerMessage?
    private var title: String?
    private var listed = false
    /// The host that listed the session first; the rest are ignored.
    private var source: UUID?
    /// The target's snapshot arrived and the requests behind it had time to.
    private var settled = false
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
        // Ask every host: the Mac that owns the session may be out of reach from
        // this network while a gateway, listing it under its namespaced id, is not.
        // ponytail: asks all hosts; a cached session list would pick one.
        let namespaced = RemoteFederatedSessionID.compose(serverId: serverId, sessionId: sessionId)
        for host in hosts {
            guard let token = store.token(for: host.id) else { continue }
            let id = host.id
            let direct = host.serverId == serverId
            connections[id] = PhoneConnection(
                origins: host.origins, lastOrigin: host.lastOrigin, token: token,
                expectedServerId: host.serverId, expectedPublicKey: host.publicKey
            ) { [weak self] event in
                self?.handle(event, target: direct ? sessionId : namespaced, direct: direct, host: id)
            }
        }
        if connections.isEmpty { return finish() }
        connections.values.forEach { $0.connect() }
    }

    private func handle(_ event: PhoneConnection.Event, target: String, direct: Bool, host: UUID) {
        guard !finished, source == nil || source == host else { return }
        switch event {
        case .stateChanged(.online):
            connections[host]?.send(.listSessions)
        case .message(let message):
            switch message {
            case .sessionList(let sessions):
                // A direct host's list settles the title even when the session
                // is missing from it; a gateway's only counts if it has it.
                let session = sessions.first(where: { $0.id == target })
                guard source == nil, session != nil || direct else { return }
                source = host
                title = session?.title
                listed = true
                connections[host]?.send(.subscribe(sessionId: target))
            case .permissionRequest(let id, _), .questionRequest(let id, _), .planRequest(let id, _), .elicitationRequest(let id, _):
                guard id == target, pending == nil else { return }
                pending = message
            case .transcriptSnapshot(let id, _, _, _, _, _, _, _, _) where id == target:
                Task { [weak self] in
                    try? await Task.sleep(for: Self.settle)
                    guard let self, !finished else { return }
                    settled = true
                    if listed { finish() }
                }
                return
            case .sessionClosed(let id) where id == target:
                // Nothing to wait for: the host does not have it open.
                settled = true
            default:
                return
            }
            if listed, pending != nil || settled { finish() }
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
              let updated = original.mutableCopy() as? UNMutableNotificationContent else {
            // Nothing pending, as after a finished turn: the relay's text stands, under the session's name.
            guard let title, !title.isEmpty, let titled = original.mutableCopy() as? UNMutableNotificationContent else { return original }
            titled.title = title
            return titled
        }
        updated.title = alert.title
        updated.body = alert.body
        // Allow and Deny answer only the request this names, so they never approve one the user did not see.
        if alert.isPermission, case .permissionRequest(_, let payload) = pending,
           let identity = RemoteRequestIdentity.of(payload),
           var alas = updated.userInfo["alas"] as? [String: Any] {
            alas["request"] = identity
            updated.userInfo["alas"] = alas
            updated.categoryIdentifier = "permission"
        }
        return updated
    }
}
