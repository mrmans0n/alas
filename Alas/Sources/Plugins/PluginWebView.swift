import AppKit
import SwiftUI
import WebKit

/// The sandbox a web tab's page runs in (API 12): what the scheme handler serves, what may load, and the bridge
/// scripts. Kept apart from the web view so the policy can be tested without one.
enum PluginWebPolicy {
    static let scheme = "alas-plugin"
    static let scriptPath = "/ui.js"
    /// Live pages per plugin, across its projects; each costs a WebContent process.
    static let maxLivePagesPerPlugin = 4

    static func shellURL(pluginID: String) -> URL { URL(string: "\(scheme)://\(pluginID)/")! }

    /// Sent as a header, which the page cannot remove, and repeated in the shell's `<meta>`. No inline or eval'd
    /// script, nothing from the network, and no frames or workers, which would get a fresh realm.
    static func contentSecurityPolicy(pluginID: String) -> String {
        "default-src 'none'; script-src \(scheme)://\(pluginID)\(scriptPath); style-src 'unsafe-inline'; "
            + "img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; worker-src 'none'; "
            + "form-action 'none'; base-uri 'none'"
    }

    struct Response: Equatable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    /// The scheme handler serves exactly two resources, the shell and the page script; anything else is a 404.
    static func response(for url: URL, pluginID: String, shell: Data, script: Data) -> Response {
        var headers = [
            "Content-Security-Policy": contentSecurityPolicy(pluginID: pluginID),
            "X-DNS-Prefetch-Control": "off",
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
        ]
        let path = url.path(percentEncoded: true)
        guard url.scheme == scheme, url.host(percentEncoded: true) == pluginID, url.user == nil, url.port == nil,
              url.query(percentEncoded: true) == nil, path == "/" || path == scriptPath
        else {
            headers["Content-Type"] = "text/plain; charset=utf-8"
            return Response(status: 404, headers: headers, body: Data())
        }
        headers["Content-Type"] = path == "/" ? "text/html; charset=utf-8" : "text/javascript; charset=utf-8"
        return Response(status: 200, headers: headers, body: path == "/" ? shell : script)
    }

    /// Only the shell itself, in the main frame. Links, forms, reloads elsewhere and every frame are cancelled;
    /// links the user clicks reach the browser through the bridge instead.
    static func allowsNavigation(to url: URL?, mainFrame: Bool, pluginID: String) -> Bool {
        guard mainFrame, let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        components.fragment = nil
        return components.url == shellURL(pluginID: pluginID)
    }

    /// A link the user clicked in the page, opened by Alas in the default browser: https only.
    static func externalLink(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host()?.isEmpty == false else { return nil }
        return url
    }

    /// Blocks every load outside `alas-plugin:`, besides the `data:` and `blob:` resources the CSP allows.
    static let contentRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^alas-plugin:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:", "resource-type": ["image", "font"]}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^blob:", "resource-type": ["image"]}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    /// Theme tokens the page gets as CSS variables.
    static let themeVariables: [(variable: String, token: String)] = [
        ("--alas-text", "fg"), ("--alas-dim", "fg-dim"), ("--alas-accent", "accent"), ("--alas-background", "bg-1"),
        ("--alas-line", "line"), ("--alas-tone-danger", "del"), ("--alas-tone-success", "add"),
        ("--alas-tone-warning", "warn"), ("--alas-tone-info", "info"),
    ]

    /// The colors Alas's own views draw with (`Theme.nsColor`), so the user's accent and contrast overrides apply,
    /// written as numeric `rgb(…)` values: a theme file can't put arbitrary CSS into the shell. Tokens the theme
    /// lacks are left out, so the page falls back instead of getting the missing-token sentinel.
    static func cssVariables(_ theme: Theme) -> [String: String] {
        var variables: [String: String] = [:]
        for (variable, token) in themeVariables {
            let overridden = theme.resolvedColorOverrides[token] != nil || (token == "accent" && theme.accentOverride != nil)
            guard overridden || theme.tokens[token] != nil, let color = theme.nsColor(token).usingColorSpace(.sRGB) else { continue }
            func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            let alpha = String(format: "%.3f", min(max(color.alphaComponent, 0), 1))
            variables[variable] = "rgb(\(channel(color.redComponent)) \(channel(color.greenComponent)) \(channel(color.blueComponent)) / \(alpha))"
        }
        return variables
    }

    static func shell(pluginID: String, variables: [String: String]) -> Data {
        let css = variables.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value);" }.joined(separator: " ")
        return Data("""
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(pluginID: pluginID))">
        <style>:root { color-scheme: light dark; font: 13px -apple-system, system-ui, sans-serif; \(css) }
        body { margin: 0; color: var(--alas-text, CanvasText); background: var(--alas-background, Canvas); }</style>
        </head><body><script src="ui.js"></script></body></html>
        """.utf8)
    }

    private static func literal(_ value: some Encodable) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("null".utf8), as: UTF8.self)
    }

    /// The page world's only addition, `window.alas`, defined before any page script along with removing WebRTC,
    /// which CSP does not cover. `post` hands the JSON text to the bridge with a `CustomEvent` named `outEvent`;
    /// messages arrive as `inEvent`. Both names are random per page.
    static func pageScript(outEvent: String, inEvent: String, maxBytes: Int, tab: Int, theme: String) -> String {
        """
        (() => {
          "use strict";
          for (const name of Object.getOwnPropertyNames(window)) {
            if (/^(webkit)?RTC/.test(name)) { try { delete window[name]; } catch (e) {} }
          }
          const OUT = \(literal(outEvent)), IN = \(literal(inEvent)), MAX = \(maxBytes);
          const apply = Reflect.apply, dispatch = EventTarget.prototype.dispatchEvent;
          const listen = EventTarget.prototype.addEventListener, Custom = CustomEvent, doc = document;
          const stringify = JSON.stringify, parse = JSON.parse, encoder = new TextEncoder();
          const encode = TextEncoder.prototype.encode;
          let handler = null;
          const alas = Object.freeze({
            post(value) {
              const text = stringify(value);
              if (typeof text !== "string") throw new TypeError("alas.post takes a JSON value");
              if (apply(encode, encoder, [text]).length > MAX) throw new RangeError("message too large");
              if (!apply(dispatch, doc, [new Custom(OUT, { detail: text, cancelable: true })])) throw new Error("busy");
            },
            onMessage(fn) {
              if (fn !== null && typeof fn !== "function") throw new TypeError("alas.onMessage takes a function");
              handler = fn;
            },
            context: Object.freeze({ tab: \(tab), theme: \(literal(theme)) }),
          });
          apply(listen, doc, [IN, (event) => { if (handler) handler(parse(event.detail)); }]);
          Object.defineProperty(window, "alas", { value: alas });
        })();
        """
    }

    /// Runs in the bridge's isolated world, the only one with the message handler. Enforces the size and queue
    /// limits before forwarding, and turns trusted clicks on https links into requests to open them.
    static func relayScript(outEvent: String, maxBytes: Int, queue: Int) -> String {
        """
        (() => {
          "use strict";
          const OUT = \(literal(outEvent)), MAX = \(maxBytes), QUEUE = \(queue);
          const handler = window.webkit.messageHandlers.alas, encoder = new TextEncoder();
          let pending = 0;
          document.addEventListener(OUT, (event) => {
            const text = event.detail;
            if (typeof text !== "string" || pending >= QUEUE || encoder.encode(text).length > MAX) {
              event.preventDefault();
              return;
            }
            pending += 1;
            const settle = () => { pending -= 1; };
            handler.postMessage({ post: text }).then(settle, settle);
          });
          document.addEventListener("click", (event) => {
            if (!event.isTrusted) return;
            const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
            if (!link) return;
            event.preventDefault();
            if (link.protocol === "https:") handler.postMessage({ open: link.href });
          }, true);
        })();
        """
    }
}

/// Serves the shell and the page script from `alas-plugin://<id>/`.
@MainActor
private final class PluginWebSchemeHandler: NSObject, WKURLSchemeHandler {
    let pluginID: String
    var shell: Data
    let script: Data

    init(pluginID: String, shell: Data, script: Data) {
        self.pluginID = pluginID
        self.shell = shell
        self.script = script
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let response = PluginWebPolicy.response(for: url, pluginID: pluginID, shell: shell, script: script)
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)
        else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(http)
        task.didReceive(response.body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Live pages per plugin, observable so a tab refused for want of a slot opens its page as soon as one frees.
@MainActor
@Observable
final class PluginWebPageSlots {
    static let shared = PluginWebPageSlots()

    let limit: Int
    private var live: [String: Int] = [:]

    init(limit: Int = PluginWebPolicy.maxLivePagesPerPlugin) {
        self.limit = limit
    }

    func hasRoom(_ pluginID: String) -> Bool { live[pluginID, default: 0] < limit }

    /// Takes a slot for a page of `pluginID`; false when the plugin's pages already fill them all.
    func take(_ pluginID: String) -> Bool {
        guard hasRoom(pluginID) else { return false }
        live[pluginID, default: 0] += 1
        return true
    }

    func release(_ pluginID: String) {
        let left = live[pluginID, default: 0] - 1
        live[pluginID] = left > 0 ? left : nil
    }
}

/// One web tab's page: a WKWebView with its own non-persistent data store, served only by the scheme handler, and a
/// bridge that carries messages between the page and its own plugin instance.
@MainActor
final class PluginWebPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    static let bridgeWorld = WKContentWorld.world(name: "alas-plugin-bridge")
    private static var compiledRules: Task<WKContentRuleList?, Never>?

    let webView: WKWebView
    private let host: PluginHost
    private let tab: Int
    private let pluginID: String
    private let inEvent = "alas-in-" + UUID().uuidString
    private let schemeHandler: PluginWebSchemeHandler
    private var token: UUID?
    private var isClosed = false
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private let slots: PluginWebPageSlots

    /// Nil when the plugin's pages already fill every slot.
    static func open(
        host: PluginHost, tab: Int, script: Data, theme: Theme, slots: PluginWebPageSlots = .shared
    ) -> PluginWebPage? {
        guard slots.take(host.manifest.id) else { return nil }
        return PluginWebPage(host: host, tab: tab, script: script, theme: theme, slots: slots)
    }

    private init(host: PluginHost, tab: Int, script: Data, theme: Theme, slots: PluginWebPageSlots) {
        self.host = host
        self.slots = slots
        self.tab = tab
        pluginID = host.manifest.id
        schemeHandler = PluginWebSchemeHandler(
            pluginID: pluginID, shell: PluginWebPolicy.shell(pluginID: pluginID, variables: PluginWebPolicy.cssVariables(theme)),
            script: script)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: PluginWebPolicy.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let outEvent = "alas-out-" + UUID().uuidString
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: PluginWebPolicy.pageScript(
                outEvent: outEvent, inEvent: inEvent, maxBytes: host.webMessageLimit(tab: tab), tab: tab,
                theme: theme.darkMode ? "dark" : "light"),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(
            source: PluginWebPolicy.relayScript(outEvent: outEvent, maxBytes: host.webMessageLimit(tab: tab), queue: PluginHost.maxWebQueue),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.bridgeWorld))
        webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.allowsLinkPreview = false
        super.init()
        // Added after `super.init`, since the controller retains its handler; `close` removes it.
        controller.addScriptMessageHandler(self, contentWorld: Self.bridgeWorld, name: "alas")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        token = host.attachWebPage(tab: tab) { [weak self] json in self?.receive(json) }
        Task { await self.load() }
    }

    /// Loads the shell once the content rules are in place; without them the page stays blank.
    private func load() async {
        guard let rules = await Self.contentRuleList(), !isClosed else { return }
        webView.configuration.userContentController.add(rules)
        webView.load(URLRequest(url: PluginWebPolicy.shellURL(pluginID: pluginID)))
    }

    private static func contentRuleList() async -> WKContentRuleList? {
        if let compiledRules, let rules = await compiledRules.value { return rules }
        let task = Task { @MainActor in
            try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "alas-plugin-web-v1", encodedContentRuleList: PluginWebPolicy.contentRules)
        }
        compiledRules = task
        return await task.value
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let token { host.detachWebPage(tab: tab, token) }
        slots.release(pluginID)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
    }

    /// Keeps the page's CSS variables in step with Alas's theme.
    func apply(_ theme: Theme) {
        guard !isClosed else { return }
        let variables = PluginWebPolicy.cssVariables(theme)
        schemeHandler.shell = PluginWebPolicy.shell(pluginID: pluginID, variables: variables)
        webView.callAsyncJavaScript(
            "for (const [name, value] of Object.entries(variables)) document.documentElement.style.setProperty(name, value);",
            arguments: ["variables": variables], in: nil, in: Self.bridgeWorld, completionHandler: nil)
    }

    /// A `web/post` from the plugin: dispatched to the page as data, a JSON string argument, never as code.
    private func receive(_ json: String) {
        guard !isClosed else { return }
        webView.callAsyncJavaScript(
            "document.dispatchEvent(new CustomEvent(name, { detail: message }));",
            arguments: ["name": inEvent, "message": json], in: nil, in: Self.bridgeWorld, completionHandler: nil)
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard !isClosed, message.world.name == Self.bridgeWorld.name, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any]
        else {
            replyHandler(nil, "refused")
            return
        }
        if let text = body["open"] as? String {
            if let url = PluginWebPolicy.externalLink(text) { openExternal(url) }
            replyHandler(nil, nil)
        } else if let json = body["post"] as? String, let token {
            let host = host, tab = tab
            Task {
                let failure = await host.webMessage(tab: tab, page: token, json: json)
                replyHandler(nil, failure)
            }
        } else {
            replyHandler(nil, "refused")
        }
    }

    // MARK: Navigation and UI

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let allowed = !isClosed && !navigationAction.shouldPerformDownload && PluginWebPolicy.allowsNavigation(
            to: navigationAction.request.url, mainFrame: navigationAction.targetFrame?.isMainFrame == true, pluginID: pluginID)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(!isClosed && navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
        webView.load(URLRequest(url: PluginWebPolicy.shellURL(pluginID: pluginID)))
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }
    // JavaScript alert, confirm and prompt are left unimplemented, so they return at once.
}

/// A web tab: the page while the tab is on screen, or a placeholder when the plugin has too many open.
struct PluginWebTabView: View {
    let host: PluginHost
    let tabIndex: Int
    let script: Data
    @Environment(\.theme) private var theme
    @State private var page: PluginWebPage?
    @State private var refused = false
    private let slots = PluginWebPageSlots.shared

    var body: some View {
        let hasRoom = slots.hasRoom(host.manifest.id)
        Group {
            if let page {
                PluginWebSurface(webView: page.webView).id(ObjectIdentifier(page))
            } else if refused {
                Text("\(host.manifest.name) already shows \(PluginWebPolicy.maxLivePagesPerPlugin) web tabs. Close one to show this one.")
                    .foregroundColor(theme.color("fg-dim")).multilineTextAlignment(.center).padding(24)
            }
        }
        .onAppear(perform: open)
        // A refused tab takes the first slot another page frees.
        .onChange(of: hasRoom) { _, hasRoom in
            if hasRoom, refused { open() }
        }
        .onDisappear {
            page?.close()
            page = nil
        }
        .onChange(of: theme) { _, theme in page?.apply(theme) }
    }

    private func open() {
        page = PluginWebPage.open(host: host, tab: tabIndex, script: script, theme: theme)
        refused = page == nil
    }
}

private struct PluginWebSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
