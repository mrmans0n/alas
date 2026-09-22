import Foundation
import Network
import Observation

/// Another Alas instance seen on the local network. `id` is its `serverId`
/// from the TXT record. `endpoints` holds every Bonjour endpoint this
/// identity was seen at — one instance can be visible on several interfaces
/// (Ethernet, Wi-Fi, a bridge) as distinct browse results — tried in order,
/// resolved to an address only when the user picks it.
struct RemoteDiscoveredInstance: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let protocolVersion: Int
    let model: String?
    let endpoints: [NWEndpoint]
}

/// One raw browse result, before any Alas-specific interpretation.
struct RemoteServiceBrowseResult: Sendable {
    let name: String
    let endpoint: NWEndpoint
    let txt: NWTXTRecord?
}

/// The part of browsing that touches the network, so `RemotePeerBrowser`'s
/// filtering and lifecycle can be tested with scripted results.
@MainActor
protocol RemoteServiceBrowsing: AnyObject {
    /// The complete current result set, every time it changes.
    var onResults: (@MainActor ([RemoteServiceBrowseResult]) -> Void)? { get set }
    /// A terminal or blocking failure (for example local-network permission
    /// denied). Results may still arrive later if the condition clears.
    var onError: (@MainActor (String) -> Void)? { get set }
    func start()
    func stop()
}

/// `NWBrowser` over `_alas._tcp` with TXT records, hopping to the main actor.
@MainActor
final class NWServiceBrowser: RemoteServiceBrowsing {
    var onResults: (@MainActor ([RemoteServiceBrowseResult]) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "io.alas.remote.browser")

    func start() {
        stop()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteBonjourService.type, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error):
                let text = error.localizedDescription
                Task { @MainActor in
                    guard let self, self.browser === browser else { return }
                    self.onError?(text)
                }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let mapped = results.compactMap(Self.map)
            Task { @MainActor in
                guard let self, self.browser === browser else { return }
                self.onResults?(mapped)
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private nonisolated static func map(_ result: NWBrowser.Result) -> RemoteServiceBrowseResult? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var txt: NWTXTRecord?
        if case .bonjour(let record) = result.metadata { txt = record }
        return RemoteServiceBrowseResult(name: name, endpoint: result.endpoint, txt: txt)
    }
}

/// Nearby Alas instances for the Peers section. Runs only while that UI is
/// on screen and discovery is on; `stop()` clears the list. Results without
/// an Alas TXT record, and this Mac's own advertisement, never appear.
@MainActor
@Observable
final class RemotePeerBrowser {
    private(set) var instances: [RemoteDiscoveredInstance] = []
    private(set) var isBrowsing = false
    private(set) var lastError: String?

    @ObservationIgnored private let localServerId: () -> String
    @ObservationIgnored private let backend: any RemoteServiceBrowsing

    init(localServerId: @escaping () -> String, backend: any RemoteServiceBrowsing = NWServiceBrowser()) {
        self.localServerId = localServerId
        self.backend = backend
    }

    func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        lastError = nil
        backend.onResults = { [weak self] results in self?.apply(results) }
        backend.onError = { [weak self] error in self?.lastError = error }
        backend.start()
    }

    func stop() {
        guard isBrowsing else { return }
        backend.stop()
        backend.onResults = nil
        backend.onError = nil
        isBrowsing = false
        instances = []
        lastError = nil
    }

    private func apply(_ results: [RemoteServiceBrowseResult]) {
        let me = localServerId()
        var byId: [String: RemoteDiscoveredInstance] = [:]
        for result in results {
            guard let txt = result.txt, let record = RemoteBonjourTXT(txt: txt) else { continue }
            guard record.serverId != me else { continue }
            // Bonjour can report the same identity once per interface as
            // distinct results (Ethernet, Wi-Fi, a bridge). One is not
            // reliably reachable over another: an interface can be down,
            // firewalled, or on a subnet that can't route to this Mac.
            // Keep every endpoint so the resolver can fall back across
            // them instead of committing to whichever arrived first.
            if let existing = byId[record.serverId] {
                guard !existing.endpoints.contains(result.endpoint) else { continue }
                byId[record.serverId] = RemoteDiscoveredInstance(
                    id: existing.id, name: existing.name, protocolVersion: existing.protocolVersion,
                    model: existing.model, endpoints: existing.endpoints + [result.endpoint])
            } else {
                byId[record.serverId] = RemoteDiscoveredInstance(
                    id: record.serverId, name: result.name, protocolVersion: record.protocolVersion,
                    model: record.model, endpoints: [result.endpoint])
            }
        }
        let next = byId.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                || ($0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame && $0.id < $1.id)
        }
        if next != instances { instances = next }
        if !results.isEmpty { lastError = nil }
    }
}
