import AppKit
import CryptoKit
import SwiftUI
import WebKit

/// Serves the shell and the page script from `alas-plugin://<id>/`.
@MainActor
private final class PluginWebSchemeHandler: NSObject, WKURLSchemeHandler {
    let pluginID: String
    let imageHosts: [String]
    var shell: Data
    let script: Data

    init(pluginID: String, imageHosts: [String], shell: Data, script: Data) {
        self.pluginID = pluginID
        self.imageHosts = imageHosts
        self.shell = shell
        self.script = script
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let response = PluginWebPolicy.response(for: url, pluginID: pluginID, imageHosts: imageHosts, shell: shell, script: script)
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

/// One web tab's or panel's page: a WKWebView with its own non-persistent data store, served only by the scheme handler, and a
/// bridge that carries messages between the page and its own plugin instance.
@MainActor
final class PluginWebPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    static let bridgeWorld = WKContentWorld.world(name: "alas-plugin-bridge")
    private static var compiledRules: [String: Task<WKContentRuleList?, Never>] = [:]

    let webView: WKWebView
    private let host: PluginHost
    private let surface: PluginSurface
    private let pluginID: String
    private let imageHosts: [String]
    private let inEvent = "alas-in-" + UUID().uuidString
    private let outEvent = "alas-out-" + UUID().uuidString
    private let themeEvent = "alas-theme-" + UUID().uuidString
    private let schemeHandler: PluginWebSchemeHandler
    private var token: UUID?
    private var isClosed = false
    private var problems = 0
    private var crashes = 0
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Each problem the page had, after it went to the plugin's log; the tab shows the latest.
    var onProblem: (String) -> Void = { _ in }

    private let slots: PluginWebPageSlots

    /// Nil when the plugin's pages already fill every slot.
    static func open(
        host: PluginHost, surface: PluginSurface, script: Data, theme: Theme, slots: PluginWebPageSlots = .shared
    ) -> PluginWebPage? {
        guard slots.take(host.manifest.id) else { return nil }
        return PluginWebPage(host: host, surface: surface, script: script, theme: theme, slots: slots)
    }

    private init(host: PluginHost, surface: PluginSurface, script: Data, theme: Theme, slots: PluginWebPageSlots) {
        self.host = host
        self.slots = slots
        self.surface = surface
        pluginID = host.manifest.id
        imageHosts = host.manifest.webImageHosts
        schemeHandler = PluginWebSchemeHandler(
            pluginID: pluginID, imageHosts: imageHosts,
            shell: PluginWebPolicy.shell(pluginID: pluginID, imageHosts: imageHosts, variables: PluginWebPolicy.cssVariables(theme)),
            script: script)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: PluginWebPolicy.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let controller = configuration.userContentController
        webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.allowsLinkPreview = false
        super.init()
        installScripts(theme)
        // Added after `super.init`, since the controller retains its handler; `close` removes it.
        controller.addScriptMessageHandler(self, contentWorld: Self.bridgeWorld, name: "alas")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        attach()
        Task { await self.load() }
    }

    /// Loads the shell once the content rules are in place; without them the page stays blank.
    private func load() async {
        guard let rules = await Self.contentRuleList(imageHosts: imageHosts) else {
            return report("could not set up the page's sandbox (its content rules did not compile)")
        }
        guard !isClosed else { return }
        webView.configuration.userContentController.add(rules)
        webView.load(URLRequest(url: PluginWebPolicy.shellURL(pluginID: pluginID)))
    }

    private static func contentRuleList(imageHosts: [String]) async -> WKContentRuleList? {
        let identifier = PluginWebPolicy.ruleListIdentifier(imageHosts: imageHosts)
        if let compiled = compiledRules[identifier], let rules = await compiled.value { return rules }
        let task = Task { @MainActor in
            try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: PluginWebPolicy.contentRules(imageHosts: imageHosts))
        }
        compiledRules[identifier] = task
        return await task.value
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let token { host.detachWebPage(surface: surface, token) }
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
        schemeHandler.shell = PluginWebPolicy.shell(pluginID: pluginID, imageHosts: imageHosts, variables: variables)
        // The next document starts with the new context; the current one gets it as data.
        installScripts(theme)
        webView.callAsyncJavaScript(
            """
            for (const [name, value] of Object.entries(variables)) document.documentElement.style.setProperty(name, value);
            document.dispatchEvent(new CustomEvent(name, { detail: context }));
            """,
            arguments: ["variables": variables, "name": themeEvent, "context": PluginWebPolicy.context(surface: surface, theme: theme)],
            in: nil, in: Self.bridgeWorld, completionHandler: nil)
    }

    private func installScripts(_ theme: Theme) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let limit = host.webMessageLimit(surface: surface)
        controller.addUserScript(WKUserScript(
            source: PluginWebPolicy.pageScript(
                outEvent: outEvent, inEvent: inEvent, themeEvent: themeEvent, maxBytes: limit,
                context: PluginWebPolicy.context(surface: surface, theme: theme)),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(
            source: PluginWebPolicy.relayScript(outEvent: outEvent, maxBytes: limit, queue: PluginHost.maxWebQueue),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.bridgeWorld))
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
        } else if let text = body["problem"] as? String {
            report(text)
            replyHandler(nil, nil)
        } else if let json = body["post"] as? String, let token {
            // A page that posts is running: only crashes in a row count towards giving up.
            crashes = 0
            // Queued synchronously, so posts reach the plugin in the order the page made them.
            host.webMessage(surface: surface, page: token, json: json) { replyHandler(nil, $0) }
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

    /// Each document is its own page for the host: its bridge starts with an empty queue, so the host's count for
    /// it starts over too, and late replies or posts for the previous document go to a token that is gone. The post
    /// budget is the view's, so a page reloading itself gets no more through than one that doesn't.
    private func attach() {
        token = host.attachWebPage(surface: surface, replacing: token) { [weak self] json in self?.receive(json) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !isClosed else { return }
        attach()
    }

    /// Reloaded a few times; a page whose web process keeps stopping before it posts anything is left stopped, and
    /// says so.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
        crashes += 1
        guard crashes <= 3 else { return report("the page's web process keeps stopping; close and reopen the tab to try again") }
        report("the page's web process stopped; reloading")
        attach()
        webView.load(URLRequest(url: PluginWebPolicy.shellURL(pluginID: pluginID)))
    }

    /// Only the shell loads in the main frame, so its failure is the page's. Navigations the policy cancels (links,
    /// other URLs) end the same way and are not problems.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard !isClosed, !Self.isCancellation(error) else { return }
        report("could not load the page: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard !isClosed, !Self.isCancellation(error) else { return }
        report("could not load the page: \(error.localizedDescription)")
    }

    static func isCancellation(_ error: any Error) -> Bool {
        let error = error as NSError
        // WebKitErrorFrameLoadInterruptedByPolicyChange: a navigation the policy delegate cancelled.
        return (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102)
    }

    /// Logs a problem with the page to its plugin and shows it on the tab, up to `maxProblemsPerPage`.
    private func report(_ text: String) {
        guard !isClosed, problems < PluginWebPolicy.maxProblemsPerPage else { return }
        problems += 1
        host.webPageProblem(surface: surface, text)
        onProblem(text)
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

/// A web tab or panel: the page while it is on screen, or a placeholder when the plugin has too many open.
struct PluginWebTabView: View {
    let host: PluginHost
    let surface: PluginSurface
    let script: Data
    @Environment(\.theme) private var theme
    @State private var page: PluginWebPage?
    @State private var refused = false
    @State private var problem: String?
    private let slots = PluginWebPageSlots.shared

    var body: some View {
        let hasRoom = slots.hasRoom(host.manifest.id)
        // A container that is always there: SwiftUI never calls `onAppear` for a view with nothing in it, which is
        // what this is until the page it opens exists, so the tab stayed blank.
        ZStack {
            Color.clear
            if let page {
                PluginWebSurface(webView: page.webView).id(ObjectIdentifier(page))
                    .overlay(alignment: .top) {
                        if let problem {
                            Text("\(host.manifest.name)'s page: \(problem) — more in Settings → Plugins")
                                .font(.caption).foregroundColor(theme.color("del")).lineLimit(3)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                        }
                    }
            } else if refused {
                Text("\(host.manifest.name) already shows \(PluginWebPolicy.maxLivePagesPerPlugin) web pages. Close one to show this one.")
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
            problem = nil
        }
        .onChange(of: theme) { _, theme in page?.apply(theme) }
    }

    private func open() {
        page = PluginWebPage.open(host: host, surface: surface, script: script, theme: theme)
        page?.onProblem = { problem = $0 }
        refused = page == nil
    }
}

private struct PluginWebSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
