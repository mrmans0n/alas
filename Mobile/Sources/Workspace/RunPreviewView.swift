import AlasRemoteKit
import SwiftUI
import WebKit

@MainActor @Observable
final class RunPreviewSession: Identifiable {
    let id = UUID()
    let endpoint: URL
    private(set) var localURL: URL?
    private(set) var error: String?

    private let hub: HostHub
    private let hostID: UUID
    private let worktreeID: String
    private var listener: ListenerToken?
    private var forwarder: PeerPortForwarder?
    private var pending: Task<Void, Never>?

    init(hub: HostHub, hostID: UUID, worktreeID: String, endpoint: URL) {
        self.hub = hub
        self.hostID = hostID
        self.worktreeID = worktreeID
        self.endpoint = endpoint
    }

    var connection: Int? {
        hub.state(of: hostID) == .online ? hub.onlineCount(of: hostID) : nil
    }

    func start() {
        guard listener == nil, error == nil else { return }
        guard let connection else { return fail("Reconnect to the host to open this preview.") }
        guard hub.supports(PeerPortForwardCapability.v1, on: hostID) else {
            return fail("This host doesn't support run previews.")
        }
        let requestID = hub.nextHostRequestId()
        listener = hub.addListener(hostID) { [weak self] message in
            guard let self, self.connection == connection else { return }
            switch message {
            case .host(let reply):
                guard self.forwarder == nil, let runs = RemoteRunPreview.matchingRunIDs(
                    replying: requestID, in: reply, worktreeID: self.worktreeID, url: self.endpoint)
                else { return }
                guard runs.count == 1, let runID = runs.first else {
                    return self.fail("Start an Alas run script in this worktree with a matching endpoint.")
                }
                self.open(runID, connection: connection)
            case .portForward(let event):
                self.forwarder?.receive(event)
            default:
                break
            }
        }
        hub.send(.host(RemoteRunPreview.snapshotRequest(id: requestID)), to: hostID)
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { self?.fail("The host didn't send its run list.") }
        }
    }

    private func open(_ runID: String, connection: Int) {
        pending?.cancel()
        let hub = self.hub
        let hostID = self.hostID
        let forwarder = PeerPortForwarder(runID: runID, endpoint: endpoint, onRefused: { [weak self] message in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.forwarder != nil, self.connection == connection else { return }
                self.fail(message)
            }
        }) { [weak hub] request in
            // Preserve stream order and keep pending frames off a replacement socket.
            DispatchQueue.main.async { [weak hub] in
                guard let hub, hub.onlineCount(of: hostID) == connection else { return }
                hub.send(.portForward(request), to: hostID)
            }
        }
        self.forwarder = forwarder
        pending = Task { [weak self] in
            do {
                let url = try await forwarder.start(preferEndpointPort: false)
                if !Task.isCancelled { self?.localURL = url }
            } catch {
                if !Task.isCancelled { self?.fail("Couldn't open a local connection for the preview.") }
            }
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        listener?.cancel()
        listener = nil
        forwarder?.stop()
        forwarder = nil
        localURL = nil
    }

    func fail(_ message: String) {
        guard error == nil else { return }
        stop()
        error = message
    }
}

struct RunPreviewView: View {
    let session: RunPreviewSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if let error = session.error {
                    ContentUnavailableView("Preview unavailable", systemImage: "globe", description: Text(error))
                } else if let url = session.localURL {
                    RunPreviewBrowser(url: url, onFailure: session.fail)
                } else {
                    ProgressView("Opening preview…")
                }
            }
            .navigationTitle("Web Preview")
            .navigationSubtitle(session.endpoint.host ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .onChange(of: session.connection) {
            session.fail("The host connection changed. Reopen the link to try again.")
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background { session.fail("Reopen the link to resume the preview.") }
        }
    }
}

private struct RunPreviewBrowser: UIViewRepresentable {
    let url: URL
    let onFailure: (String) -> Void

    func makeCoordinator() -> Page { Page(url: url, onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsLinkPreview = false
        view.navigationDelegate = context.coordinator
        context.coordinator.load(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Page) {
        coordinator.loading?.cancel()
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Page: NSObject, WKNavigationDelegate {
        let url: URL
        let onFailure: (String) -> Void
        var loading: Task<Void, Never>?

        init(url: URL, onFailure: @escaping (String) -> Void) {
            self.url = url
            self.onFailure = onFailure
        }

        func load(_ view: WKWebView) {
            loading = Task { [weak self, weak view] in
                guard let self, let scheme = url.scheme?.lowercased(), let host = url.host, let port = url.port
                else { return }
                let origin = NSRegularExpression.escapedPattern(for: "\(host):\(port)")
                let socketScheme = scheme == "https" ? "wss" : "ws"
                let rules = [
                    Self.rule("^http", "block"), Self.rule("^ws", "block"),
                    Self.rule("^\(scheme)://\(origin)/", "ignore-previous-rules"),
                    Self.rule("^\(socketScheme)://\(origin)/", "ignore-previous-rules"),
                ]
                let id = UUID().uuidString
                guard let store = WKContentRuleListStore.default(),
                      let data = try? JSONEncoder().encode(rules),
                      let list = try? await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: String(decoding: data, as: UTF8.self))
                else {
                    if !Task.isCancelled { onFailure("Couldn't configure the preview browser.") }
                    return
                }
                try? await store.removeContentRuleList(forIdentifier: id)
                guard !Task.isCancelled, let view else { return }
                view.configuration.userContentController.add(list)
                view.load(URLRequest(url: url))
            }
        }

        private static func rule(_ pattern: String, _ action: String) -> [String: [String: String]] {
            ["trigger": ["url-filter": pattern], "action": ["type": action]]
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let destination = action.request.url,
                  destination.scheme?.lowercased() == url.scheme?.lowercased(),
                  destination.host?.lowercased() == url.host?.lowercased(),
                  destination.runEndpointPort == url.runEndpointPort,
                  destination.user == nil, destination.password == nil else { return .cancel }
            return .allow
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onFailure(error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onFailure(error.localizedDescription) }
        }
    }
}
