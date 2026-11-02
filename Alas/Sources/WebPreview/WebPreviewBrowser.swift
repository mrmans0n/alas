import AppKit
import CryptoKit
import Network
import SwiftUI
import Synchronization
import WebKit

enum WebPreviewNavigation {
    typealias HostResolver = @Sendable (String) async -> [String]?

    /// `allowedLoopback` pins the one Mac loopback address a remote owner may
    /// load (a paired host's forwarded endpoint). Nil keeps loopback refused.
    static func allows(_ url: URL, remoteHost: String?, allowedLoopback: WebPreviewLoopbackPin? = nil) -> Bool {
        guard RunEndpointPolicy.endpoint(from: url.absoluteString) != nil else { return false }
        guard remoteHost != nil, RunEndpointPolicy.isLoopback(url) else { return true }
        return allowedLoopback?.matches(url) == true
    }

    /// A remote owner's navigation must not resolve to this Mac or a
    /// link-local address. Only the pinned address itself may be loopback,
    /// never another name for it.
    @MainActor
    static func allowsResolved(_ url: URL, remoteHost: String?, allowedLoopback: WebPreviewLoopbackPin? = nil,
                               localAddresses: Set<Data> = WebPreviewLocalAddresses.read(),
                               resolveHost: HostResolver) async -> Bool {
        guard allows(url, remoteHost: remoteHost, allowedLoopback: allowedLoopback) else { return false }
        guard remoteHost != nil else { return true }
        if allowedLoopback?.matches(url) == true { return true }
        guard let host = url.host(percentEncoded: false),
              let answers = await resolveHost(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))),
              !answers.isEmpty else { return false }
        let addresses = answers.compactMap(WebPreviewEgressPolicy.address)
        return addresses.count == answers.count
            && WebPreviewEgressPolicy.refusal(forAny: addresses, localAddresses: localAddresses) == nil
    }

    static func captureRect(_ rect: CGRect, viewport: CGSize) -> CGRect? {
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: viewport))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped
    }
}

/// The one loopback address, host and port, a host run's forward listens on.
/// The forward binds only that host's address family, so another spelling of
/// loopback on the same port could reach a different service on this Mac.
struct WebPreviewLoopbackPin: Equatable {
    let host: String
    let port: Int

    init?(_ url: URL) {
        guard let host = url.host(percentEncoded: false), let port = url.runEndpointPort else { return nil }
        self.host = Self.normalized(host)
        self.port = port
    }

    func matches(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false) else { return false }
        return Self.normalized(host) == self.host && url.runEndpointPort == port
    }

    private static func normalized(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}

/// A content rule list that stops a remote owner's page from reaching this
/// Mac by IP literal or `localhost` with any request, not only navigations:
/// fetch, XHR, images, scripts, frames, and WebSockets. WebKit connects to
/// these directly, around the preview's egress proxy, so the proxy cannot
/// check them. Every name goes through the proxy.
@MainActor
enum WebPreviewLoopbackRules {
    /// WebKit's matcher has no alternation, so each spelling gets its own
    /// rule. Hosts are matched after WebKit canonicalizes them (`0x7f.1`
    /// becomes `127.0.0.1`, `[0::1]` becomes `[::1]`). `selfAddresses` are
    /// this Mac's interface addresses, canonical.
    static func json(allowing pin: WebPreviewLoopbackPin?, selfAddresses: Set<Data> = []) -> String {
        let authority = #"^[^:/]+://([^/@]*@)?"#
        let blocked = [
            #"([^/:@]*\.)?localhost\.?[:/]"#,
            #"127\.[0-9.]+[:/]"#,
            #"0\.0\.0\.0[:/]"#,
            #"\[::1?\][:/]"#,
            #"\[::ffff:7f[0-9a-f][0-9a-f]:[0-9a-f]+\][:/]"#,
            #"\[::ffff:0:0\][:/]"#,
            #"169\.254\.[0-9.]+[:/]"#,
            #"\[::ffff:a9fe:[0-9a-f]+\][:/]"#,
            // Tailscale's MagicDNS and service addresses terminate on this Mac.
            #"100\.100\.100\.100[:/]"#,
            #"\[::ffff:6464:6464\][:/]"#,
            #"\[fd7a:115c:a1e0::53\][:/]"#,
        ] + selfAddresses.sorted { $0.lexicographicallyPrecedes($1) }.flatMap(selfHostPatterns)
        var rules = blocked.map { rule(authority + $0, action: "block") }
        if let pin {
            let host = NSRegularExpression.escapedPattern(for: pin.host.contains(":") ? "[\(pin.host)]" : pin.host)
            rules.append(rule(authority + host + ":\(pin.port)/", action: "ignore-previous-rules"))
            // WebKit drops a scheme's default port from the URL it matches.
            let defaultSchemes = [80: ["http", "ws"], 443: ["https", "wss"]][pin.port] ?? []
            for scheme in defaultSchemes {
                rules.append(rule("^\(scheme)://([^/@]*@)?\(host)/", action: "ignore-previous-rules"))
            }
        }
        let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    /// The URL host spellings of one of this Mac's addresses, as WebKit
    /// canonicalizes them. Addresses the fixed rules or the proxy already
    /// refuse need none.
    private static func selfHostPatterns(_ address: Data) -> [String] {
        guard WebPreviewEgressPolicy.refusal(for: address, localAddresses: []) == nil else { return [] }
        let bytes = [UInt8](address)
        let hosts = bytes.count == 4
            ? [bytes.map(String.init).joined(separator: "."), "[\(ipv6URLText([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff] + bytes))]"]
            : ["[\(ipv6URLText(bytes))]"]
        return hosts.map { NSRegularExpression.escapedPattern(for: $0) + "[:/]" }
    }

    /// The WHATWG URL serialization of an IPv6 address: lowercase hex without
    /// leading zeros, and the first longest run of two or more zero pieces
    /// compressed to `::`.
    static func ipv6URLText(_ bytes: [UInt8]) -> String {
        let pieces = stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        var compress = (start: -1, length: 1)
        var index = 0
        while index < 8 {
            var end = index
            while end < 8, pieces[end] == 0 { end += 1 }
            if end - index > compress.length { compress = (index, end - index) }
            index = max(end, index + 1)
        }
        var text = ""
        index = 0
        while index < 8 {
            if index == compress.start {
                text += index == 0 ? "::" : ":"
                index += compress.length
                continue
            }
            text += String(pieces[index], radix: 16)
            if index < 7 { text += ":" }
            index += 1
        }
        return text
    }

    private static func rule(_ filter: String, action: String) -> [String: Any] {
        ["trigger": ["url-filter": filter], "action": ["type": action]]
    }

    private static var compiled: [String: Task<WKContentRuleList?, Never>] = [:]
    // Each forward pins a new port, so keep the compiled files out of the
    // app's persistent WebKit store and drop the last launch's on first use.
    private static let store: WKContentRuleListStore? = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AlasWebPreviewRules-\(Bundle.main.bundleIdentifier ?? "alas")", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        return WKContentRuleListStore(url: folder)
    }()

    /// Compiled once per pin and address set and reused; nil if WebKit
    /// refused the rules.
    static func ruleList(allowing pin: WebPreviewLoopbackPin?, selfAddresses: Set<Data>) async -> WKContentRuleList? {
        let json = json(allowing: pin, selfAddresses: selfAddresses)
        let identifier = "loopback-" + SHA256.hash(data: Data(json.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        if let task = compiled[identifier] { return await task.value }
        let task = Task { @MainActor () -> WKContentRuleList? in
            guard let store else { return nil }
            return try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
        }
        compiled[identifier] = task
        let list = await task.value
        if list == nil { compiled[identifier] = nil }
        return list
    }
}

/// This Mac's own interface addresses, canonical, which a remote preview
/// must not reach. `read()` is current; it is cheap enough to call per
/// connection. A path monitor posts `didChange` so remote browsers recompile
/// their rules, and each navigation also checks for a change the monitor
/// missed, such as a rotated IPv6 temporary address.
final class WebPreviewLocalAddresses: Sendable {
    static let shared = WebPreviewLocalAddresses()
    static let didChange = Notification.Name("WebPreviewLocalAddressesDidChange")

    private let snapshot = Mutex(WebPreviewLocalAddresses.read())
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] _ in self?.refresh() }
        monitor.start(queue: DispatchQueue(label: "io.nlopez.alas.web-preview-local-addresses"))
    }

    private func refresh() {
        let addresses = Self.read()
        let changed = snapshot.withLock { current in
            defer { current = addresses }
            return current != addresses
        }
        guard changed else { return }
        Task { @MainActor in NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    static func read() -> Set<Data> {
        Set(RemoteNetwork.interfaces().compactMap { WebPreviewEgressPolicy.address($0.host).map(WebPreviewEgressPolicy.canonical) })
    }
}

@MainActor
@Observable
final class WebPreviewBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let ownerKey: String
    let remoteHost: String?
    /// The single Mac loopback address this remote-owned browser may load.
    let allowedLoopback: WebPreviewLoopbackPin?
    let automationID = UUID().uuidString
    let webView: WKWebView
    var address = ""
    var error: String?
    var consoleErrors: [String] = []
    var canGoBack = false
    var canGoForward = false
    var loading = false
    var capturing = false
    var capture: WebPreviewCapture?
    private(set) var isClosed = false
    var onNavigate: ((URL) -> Void)?
    private var navigationGeneration = 0
    private var consoleHandler: PreviewConsoleHandler?
    private var urlObservation: NSKeyValueObservation?
    private let resolveHost: WebPreviewNavigation.HostResolver
    /// Remote owners load nothing until the loopback rules are installed and
    /// the egress proxy is listening.
    private var protection: Protection
    private enum Protection { case installed, pending, failed }
    private var loadAwaitingRules: URL?
    private var rules: WKContentRuleList?
    private var rulesAddresses: Set<Data> = []
    /// The about:blank load that clears a page whose protection failed.
    private var blanking: WKNavigation?
    private var proxy: WebPreviewEgressProxy?
    private var addressObserver: NSObjectProtocol?
    let automationState = WebPreviewBrowserAutomationState()
    var automationDocumentGeneration: Int { navigationGeneration }

    init(ownerKey: String, remoteHost: String?, allowedLoopback: WebPreviewLoopbackPin? = nil,
         resolveHost: @escaping WebPreviewNavigation.HostResolver = { await WebPreviewHostLookup.resolve($0) }) {
        self.ownerKey = ownerKey
        self.remoteHost = remoteHost
        self.allowedLoopback = allowedLoopback
        self.resolveHost = resolveHost
        protection = remoteHost == nil ? .installed : .pending
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let handler = PreviewConsoleHandler()
        handler.receive = { [weak self] value in
            guard let self else { return }
            self.consoleErrors.append(String(value.prefix(2000)))
        }
        consoleHandler = handler
        handler.reset(in: configuration.userContentController)
        configuration.userContentController.addUserScript(WKUserScript(source: Self.consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let url = self.webView.url,
                      WebPreviewNavigation.allows(url, remoteHost: self.remoteHost, allowedLoopback: self.allowedLoopback) else { return }
                self.address = url.absoluteString
                self.canGoBack = self.webView.canGoBack
                self.canGoForward = self.webView.canGoForward
                self.onNavigate?(url)
            }
        }
        if remoteHost != nil {
            // Starts the shared path monitor, which posts `didChange`; it's lazy and nothing else touches it.
            _ = WebPreviewLocalAddresses.shared
            installProtection()
            addressObserver = NotificationCenter.default.addObserver(
                forName: WebPreviewLocalAddresses.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed, self.protection == .installed else { return }
                    Task { @MainActor in
                        if !(await self.installRules()) { self.protectionFailed() }
                    }
                }
            }
        }
    }

    private func installProtection() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            async let rulesReady = installRules()
            async let proxyReady = startProxy()
            let ready = await (rulesReady, proxyReady)
            guard !isClosed else { return }
            guard ready.0, ready.1 else { return protectionFailed() }
            protection = .installed
            if let url = loadAwaitingRules {
                loadAwaitingRules = nil
                webView.load(URLRequest(url: url))
            }
        }
    }

    /// Fails closed: a page already showing stops, since its rules may be stale.
    private func protectionFailed() {
        protection = .failed
        loadAwaitingRules = nil
        if webView.url != nil {
            webView.stopLoading()
            blanking = webView.load(URLRequest(url: Self.blank))
        }
        loading = false
        error = Self.protectionFailure
    }

    /// Compiles the rules for this Mac's current addresses and swaps them in.
    private func installRules() async -> Bool {
        while true {
            let addresses = WebPreviewLocalAddresses.read()
            guard let list = await WebPreviewLoopbackRules.ruleList(allowing: allowedLoopback, selfAddresses: addresses),
                  !isClosed else { return false }
            // The addresses changed while compiling; compile for the new ones.
            guard addresses == WebPreviewLocalAddresses.read() else { continue }
            let controller = webView.configuration.userContentController
            if let rules { controller.remove(rules) }
            controller.add(list)
            rules = list
            rulesAddresses = addresses
            return true
        }
    }

    /// Starts the egress proxy, unless it is already listening, and points the
    /// data store at it with failover off, so a dead proxy fails every load.
    private func startProxy() async -> Bool {
        if proxy?.isListening == true { return true }
        proxy?.stop()
        let proxy = WebPreviewEgressProxy(
            resolve: resolveHost, localAddresses: { WebPreviewLocalAddresses.read() },
            onBlocked: { [weak self] host, port, refusal in
                let line = "Blocked request to \(host):\(port): \(refusal.description)"
                Task { @MainActor in self?.recordBlocked(line) }
            })
        self.proxy = proxy
        guard let port = try? await proxy.start(), let port = NWEndpoint.Port(rawValue: port),
              !isClosed, self.proxy === proxy else {
            proxy.stop()
            return false
        }
        var configuration = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .ipv4(.loopback), port: port))
        configuration.allowFailover = false
        webView.configuration.websiteDataStore.proxyConfigurations = [configuration]
        return true
    }

    private func recordBlocked(_ line: String) {
        // WebKit retries a refused connection, so report each destination once.
        guard !isClosed, consoleErrors.count < 100, !consoleErrors.contains(line) else { return }
        consoleErrors.append(line)
    }

    /// Drops a load still waiting for the loopback rules, as Stop expects.
    func cancelPendingLoad() {
        guard loadAwaitingRules != nil else { return }
        loadAwaitingRules = nil
        loading = false
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        navigationGeneration += 1
        proxy?.stop()
        proxy = nil
        if let addressObserver { NotificationCenter.default.removeObserver(addressObserver) }
        addressObserver = nil
        automationState.invalidate()
        webView.stopLoading()
        urlObservation?.invalidate()
        urlObservation = nil
        onNavigate = nil
        capture = nil
        consoleErrors = []
        consoleHandler?.receive = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "previewConsole")
        webView.configuration.userContentController.removeAllUserScripts()
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    @discardableResult
    func navigate(_ url: URL) -> WKNavigation? {
        guard !isClosed else { return nil }
        guard WebPreviewNavigation.allows(url, remoteHost: remoteHost, allowedLoopback: allowedLoopback) else {
            if let remoteHost, RunEndpointPolicy.isLoopback(url) {
                error = allowedLoopback.map { "This preview can only open its forwarded address, \($0.host) port \($0.port), on this Mac." }
                    ?? "This endpoint is on \(remoteHost). Enter a remotely reachable URL; localhost would open a service on this Mac."
            } else {
                error = "Only HTTP and HTTPS pages can be opened in previews."
            }
            return nil
        }
        error = nil
        address = url.absoluteString
        blanking = nil
        // A proxy that died fails every load, and rules for old addresses
        // miss new ones; set both up again.
        if protection == .installed, remoteHost != nil,
           proxy?.isListening != true || rulesAddresses != WebPreviewLocalAddresses.read() {
            protection = .failed
        }
        switch protection {
        case .installed: break
        case .pending:
            loadAwaitingRules = url
            loading = true
            return nil
        case .failed:
            // Retry, so a transient failure doesn't strand the tab.
            protection = .pending
            loadAwaitingRules = url
            loading = true
            installProtection()
            return nil
        }
        return webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard !isClosed else {
            decisionHandler(.cancel)
            return
        }
        if blanking != nil, navigationAction.request.url == Self.blank {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url,
              WebPreviewNavigation.allows(url, remoteHost: remoteHost, allowedLoopback: allowedLoopback) else {
            error = "Navigation blocked. Previews accept HTTP(S) pages and cannot open remote localhost endpoints."
            decisionHandler(.cancel)
            return
        }
        validateRemoteURL(url) { decisionHandler($0 ? .allow : .cancel) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard !isClosed else {
            decisionHandler(.cancel)
            return
        }
        if blanking != nil, navigationResponse.response.url == Self.blank {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationResponse.response.url,
              WebPreviewNavigation.allows(url, remoteHost: remoteHost, allowedLoopback: allowedLoopback), navigationResponse.canShowMIMEType else {
            error = "This response cannot be displayed in a web preview."
            decisionHandler(.cancel)
            return
        }
        validateRemoteURL(url) { decisionHandler($0 ? .allow : .cancel) }
    }

    private func validateRemoteURL(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard remoteHost != nil else { completion(true)
        return }
        let generation = navigationGeneration
        Task { @MainActor [weak self] in
            guard let self else { completion(false)
            return }
            guard !isClosed else { completion(false)
            return }
            let allowed = await WebPreviewNavigation.allowsResolved(
                url, remoteHost: remoteHost, allowedLoopback: allowedLoopback, resolveHost: resolveHost)
            guard !isClosed, generation == navigationGeneration else { completion(false)
            return }
            if !allowed {
                loading = false
                error = "Navigation blocked. The remote endpoint resolves to this Mac or a local address, or its address could not be verified."
            }
            completion(allowed)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !isClosed else { return nil }
        if let url = navigationAction.request.url { navigate(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isClosed else { return }
        navigationGeneration += 1
        automationDocumentWillChange(navigation)
        // Clearing a failed page keeps its error and console.
        guard navigation !== blanking else { return }
        loading = true
        error = nil
        consoleErrors = []
        consoleHandler?.reset(in: webView.configuration.userContentController)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed else { return }
        loading = false
        if navigation === blanking {
            blanking = nil
            return
        }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        guard let url = webView.url, WebPreviewNavigation.allows(url, remoteHost: remoteHost, allowedLoopback: allowedLoopback) else {
            error = "Endpoint unavailable: WebKit could not display this URL."
            return
        }
        address = url.absoluteString
        onNavigate?(url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
        loading = false
        error = "The preview process stopped. Reload to reconnect."
    }

    private func failed(_ failure: Error) {
        guard !isClosed else { return }
        loading = false
        if (failure as NSError).code != NSURLErrorCancelled {
            error = "Endpoint unavailable: \(failure.localizedDescription)"
        }
    }

    func captureRegion(_ selection: CGRect? = nil, elementAt point: CGPoint? = nil) {
        guard !isClosed, !capturing, !loading, let url = webView.url,
              WebPreviewNavigation.allows(url, remoteHost: remoteHost, allowedLoopback: allowedLoopback) else { return }
        capturing = true
        let generation = navigationGeneration
        let viewport = webView.bounds.size
        let capturedAt = Date()
        let errors = consoleErrors
        Task { @MainActor in
            defer { capturing = false }
            do {
                guard !isClosed else { return }
                let metrics = try? await webView.callAsyncJavaScript(
                    "return {scale: devicePixelRatio, x: scrollX, y: scrollY};",
                    arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Double]
                var element: String?
                var rect = selection ?? CGRect(origin: .zero, size: viewport)
                if let point {
                    let result = try? await webView.callAsyncJavaScript(Self.elementScript,
                        arguments: ["x": point.x, "y": point.y], in: nil, contentWorld: .defaultClient)
                    if let info = result as? [String: Any],
                       let description = info["description"] as? String {
                        element = description
                        if let x = info["x"] as? Double, let y = info["y"] as? Double,
                           let width = info["width"] as? Double, let height = info["height"] as? Double {
                            rect = CGRect(x: x, y: y, width: width, height: height)
                        }
                    } else {
                        element = "Element inspection is unavailable for this page. The screenshot shows the viewport."
                    }
                }
                guard let region = WebPreviewNavigation.captureRect(rect, viewport: viewport) else {
                    error = "Select a visible region of the page."
                    return
                }
                let configuration = WKSnapshotConfiguration()
                configuration.rect = region
                let image = try await webView.takeSnapshot(configuration: configuration)
                guard !isClosed, generation == navigationGeneration, webView.url == url,
                      viewport == webView.bounds.size else {
                    error = "The page changed during capture. Capture again."
                    return
                }
                guard let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    error = "Could not encode the screenshot."
                    return
                }
                capture = WebPreviewCapture(ownerKey: ownerKey, url: url, capturedAt: capturedAt,
                    viewport: viewport,
                    devicePixelRatio: metrics?["scale"] ?? 1,
                    scrollPosition: CGPoint(x: metrics?["x"] ?? 0, y: metrics?["y"] ?? 0),
                    region: region, png: png, element: element, consoleErrors: errors)
            } catch {
                self.error = "Capture unavailable: \(error.localizedDescription)"
            }
        }
    }

    private static let blank = URL(string: "about:blank")!

    private static let protectionFailure = "This preview could not block requests to this Mac, so it will not load pages."

    private static let consoleScript = #"""
    (() => {
      let sent = 0;
      const send = value => { if (sent >= 100) return; sent++; try { window.webkit.messageHandlers.previewConsole.postMessage(String(value).slice(0, 2000)); } catch (_) {} };
      const original = console.error;
      console.error = function(...args) { if (sent < 100) send(args.map(v => { try { return String(v); } catch (_) { return '[unavailable]'; } }).join(' ')); return original.apply(this, args); };
      window.addEventListener('error', e => send(`${e.message} (${e.filename}:${e.lineno})`));
      window.addEventListener('unhandledrejection', e => send(`Unhandled rejection: ${String(e.reason)}`));
    })();
    """#

    private static let elementScript = #"""
    const e = document.elementFromPoint(x, y);
    if (!e) return { description: 'No inspectable element at this position.' };
    const r = e.getBoundingClientRect();
    const style = getComputedStyle(e);
    const data = { tag: e.tagName, id: e.id.slice(0, 256), class: String(e.className).slice(0, 1000), role: (e.getAttribute('role') || '').slice(0, 256),
      ariaLabel: (e.getAttribute('aria-label') || '').slice(0, 500), text: (e.innerText || '').slice(0, 2000),
      bounds: { x:r.x, y:r.y, width:r.width, height:r.height },
      viewport: { width:innerWidth, height:innerHeight, devicePixelRatio, scrollX, scrollY },
      style: Object.fromEntries(['display','position','overflow','white-space','font-size','font-family','line-height','width','height','padding','margin','color','background-color'].map(k => [k, style.getPropertyValue(k).slice(0, 1000)])) };
    if (e.tagName === 'IFRAME' || e.tagName === 'FRAME') data.note = 'Frame contents are not inspected. Metadata describes the frame element only.';
    return { description: JSON.stringify(data, null, 2), x:r.x, y:r.y, width:r.width, height:r.height };
    """#
}

@MainActor
private final class PreviewConsoleHandler: NSObject, WKScriptMessageHandler {
    var receive: ((String) -> Void)?
    private var remainingMessages = 100

    func reset(in controller: WKUserContentController) {
        remainingMessages = 100
        controller.removeScriptMessageHandler(forName: "previewConsole")
        controller.add(self, name: "previewConsole")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard remainingMessages > 0 else { return }
        remainingMessages -= 1
        if remainingMessages == 0 {
            userContentController.removeScriptMessageHandler(forName: "previewConsole")
        }
        guard let text = message.body as? String else { return }
        receive?(text)
    }
}

struct WebPreviewSurface: NSViewRepresentable {
    let browser: WebPreviewBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
