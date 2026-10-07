import AppKit
import SwiftUI
import WebKit

/// One visual aid's page: a WKWebView with a non-persistent data store, served
/// only by its scheme handler, plus an isolated bridge that reports height,
/// `data-choice` clicks and link clicks.
@MainActor
@Observable
final class VisualAidWebPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    enum Status: Equatable {
        case loading
        case ready
        case sandboxFailed
        case stopped(canReload: Bool)
    }

    static let maxCrashes = 3
    @ObservationIgnored private static let bridgeWorld = WKContentWorld.world(name: VisualAidWebPolicy.bridgeWorldName)
    @ObservationIgnored private static var compiledRules: Task<WKContentRuleList?, Never>?
    @ObservationIgnored private static var compiledLockedRules: Task<WKContentRuleList?, Never>?

    @ObservationIgnored let webView: VisualAidWKWebView
    /// True once a question visual's network is shut; always false for visuals without a question.
    private(set) var isLocked = false
    @ObservationIgnored private let locksNetworkAfterLoad: Bool
    @ObservationIgnored private let networkLockDeadline: Duration
    @ObservationIgnored private var loadingRules: WKContentRuleList?
    @ObservationIgnored private var lockedRules: WKContentRuleList?
    @ObservationIgnored private var lockDeadline: Task<Void, Never>?
    private(set) var status: Status = .loading
    private(set) var contentHeight: CGFloat = VisualAidWebPolicy.minCardHeight
    @ObservationIgnored var onChoice: (String) -> Void = { _ in }
    @ObservationIgnored var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored private let visualID: UUID
    @ObservationIgnored private let schemeHandler: VisualAidSchemeHandler
    @ObservationIgnored private var crashes = 0
    @ObservationIgnored private var isClosed = false
    /// Theme variables baked into a fragment's frame; nil for a full document, which is served unmodified.
    @ObservationIgnored private let documentThemeVariables: [String: String]?
    @ObservationIgnored private var themeVariables: [String: String]

    init(
        visualID: UUID, html: String, theme: Theme, locksNetworkAfterLoad: Bool,
        networkLockDeadline: Duration = VisualAidWebPolicy.networkLockDeadline
    ) {
        self.locksNetworkAfterLoad = locksNetworkAfterLoad
        self.networkLockDeadline = networkLockDeadline
        self.visualID = visualID
        let variables = PluginWebPolicy.cssVariables(theme)
        documentThemeVariables = VisualAidWebPolicy.isFullDocument(html) ? nil : variables
        themeVariables = variables
        schemeHandler = VisualAidSchemeHandler(
            visualID: visualID,
            document: VisualAidWebPolicy.document(
                html: html,
                themeVariables: variables,
                frameTemplate: VisualAidFrameTemplate.html
            )
        )
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: VisualAidWebPolicy.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // WebKit skips user scripts in srcdoc frames, so the lockdown script alone
        // leaves `RTCPeerConnection` in them; switch WebRTC off at the engine too,
        // and never load the document if that did not take.
        let peerConnectionDisabled = Self.disablePeerConnection(on: configuration.preferences)
        let webView = VisualAidWKWebView(frame: .zero, configuration: configuration)
        webView.blocksInteraction = locksNetworkAfterLoad
        self.webView = webView
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.allowsLinkPreview = false
        super.init()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: VisualAidWebPolicy.pageLockdownScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addUserScript(WKUserScript(
            source: VisualAidWebPolicy.bridgeScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.bridgeWorld))
        // Removed in `close`; the controller retains its handler.
        controller.add(self, contentWorld: Self.bridgeWorld, name: VisualAidWebPolicy.bridgeHandlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        guard peerConnectionDisabled else {
            status = .sandboxFailed
            return
        }
        Task { await load() }
    }

    /// Switches WebRTC off through WebKit's private preference and reads it back.
    /// False when the setter is missing or the value did not stick.
    static func disablePeerConnection(on preferences: WKPreferences) -> Bool {
        guard preferences.responds(to: NSSelectorFromString("_setPeerConnectionEnabled:")) else { return false }
        preferences.setValue(false, forKey: "peerConnectionEnabled")
        return preferences.value(forKey: "peerConnectionEnabled") as? Bool == false
    }

    /// Loads the document once the content rules are in place; without them it never loads. A question
    /// visual also needs the locked rules compiled up front, so locking later cannot fail halfway.
    private func load() async {
        guard let rules = await Self.contentRuleList() else {
            status = .sandboxFailed
            return
        }
        if locksNetworkAfterLoad {
            guard let locked = await Self.lockedRuleList() else {
                status = .sandboxFailed
                return
            }
            lockedRules = locked
        }
        guard !isClosed else { return }
        loadingRules = rules
        webView.configuration.userContentController.add(rules)
        if locksNetworkAfterLoad { startLockDeadline() }
        webView.load(URLRequest(url: VisualAidWebPolicy.documentURL(visualID: visualID)))
    }

    private static func contentRuleList() async -> WKContentRuleList? {
        // One decision per app run: a failed compilation is remembered, not retried by every card.
        if let compiledRules { return await compiledRules.value }
        let task = Task { @MainActor in
            try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: VisualAidWebPolicy.contentRuleListIdentifier,
                encodedContentRuleList: VisualAidWebPolicy.contentRules)
        }
        compiledRules = task
        return await task.value
    }

    private static func lockedRuleList() async -> WKContentRuleList? {
        if let compiledLockedRules { return await compiledLockedRules.value }
        let task = Task { @MainActor in
            try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: VisualAidWebPolicy.lockedContentRuleListIdentifier,
                encodedContentRuleList: VisualAidWebPolicy.lockedContentRules)
        }
        compiledLockedRules = task
        return await task.value
    }

    /// Question visuals ignore choices until the network is locked.
    private var acceptsInput: Bool { !locksNetworkAfterLoad || isLocked }

    /// After a crash the same cycle runs again: a question visual gets its loading rules back and the
    /// network lock is undone, so the reloaded page can fetch its CDN resources and is locked again after.
    func reload() {
        guard !isClosed, case .stopped(true) = status else { return }
        if locksNetworkAfterLoad {
            guard let loadingRules, let lockedRules else {
                status = .sandboxFailed
                return
            }
            let controller = webView.configuration.userContentController
            controller.remove(lockedRules)
            controller.add(loadingRules)
            isLocked = false
            webView.blocksInteraction = true
            startLockDeadline()
        }
        status = .loading
        webView.load(URLRequest(url: VisualAidWebPolicy.documentURL(visualID: visualID)))
    }

    /// Shuts the network for a question visual: the locked rules go in before the loading rules come out,
    /// so there is no moment without a block-all list. False when the locked rules are unavailable (fails
    /// closed with `.sandboxFailed`); idempotent, and a no-op once closed or for visuals without a question.
    @discardableResult
    private func lockNetwork() -> Bool {
        guard locksNetworkAfterLoad, !isClosed else { return true }
        guard !isLocked else { return true }
        guard let loadingRules, let lockedRules else {
            lockDeadline?.cancel()
            status = .sandboxFailed
            return false
        }
        lockDeadline?.cancel()
        lockDeadline = nil
        let controller = webView.configuration.userContentController
        controller.add(lockedRules)
        controller.remove(loadingRules)
        isLocked = true
        webView.blocksInteraction = false
        return true
    }

    private func startLockDeadline() {
        lockDeadline?.cancel()
        let deadline = networkLockDeadline
        lockDeadline = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            self?.lockNetwork()
        }
    }

    func setSelected(_ ids: [String]) {
        guard !isClosed, status == .ready, acceptsInput else { return }
        webView.callAsyncJavaScript(
            "alasVisualSelect(ids)", arguments: ["ids": ids], in: nil, in: Self.bridgeWorld, completionHandler: nil)
    }

    func applyTheme(_ theme: Theme) {
        themeVariables = PluginWebPolicy.cssVariables(theme)
        guard !isClosed, status == .ready else { return }
        pushTheme()
    }

    private func pushTheme() {
        webView.callAsyncJavaScript(
            "alasVisualTheme(variables)", arguments: ["variables": themeVariables],
            in: nil, in: Self.bridgeWorld, completionHandler: nil)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        lockDeadline?.cancel()
        lockDeadline = nil
        let controller = webView.configuration.userContentController
        controller.removeAllScriptMessageHandlers()
        controller.removeAllUserScripts()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: Bridge

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !isClosed, message.world.name == Self.bridgeWorld.name, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any]
        else { return }
        if let height = body["height"] as? Double {
            contentHeight = max(0, CGFloat(height))
        } else if let choice = body["choice"] as? String {
            guard acceptsInput else { return }
            onChoice(choice)
        } else if let link = body["open"] as? String, let url = PluginWebPolicy.externalLink(link) {
            openExternal(url)
        }
    }

    // MARK: Navigation

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let allowed = !isClosed && !navigationAction.shouldPerformDownload && VisualAidWebPolicy.allowsNavigation(
            to: navigationAction.request.url,
            mainFrame: navigationAction.targetFrame?.isMainFrame == true,
            visualID: visualID)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(!isClosed && navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed else { return }
        if locksNetworkAfterLoad, !lockNetwork() { return }
        status = .ready
        // Fragments bake the theme into their frame; a full document is served unmodified, so it always gets
        // the theme pushed. Either way, replay any theme change made while it was loading or crashed.
        if themeVariables != documentThemeVariables {
            pushTheme()
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
        crashes += 1
        status = .stopped(canReload: crashes < Self.maxCrashes)
    }

    /// `target=_blank` and `window.open` never get a window; https targets open in the browser.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let text = navigationAction.request.url?.absoluteString, let url = PluginWebPolicy.externalLink(text) {
            openExternal(url)
        }
        return nil
    }
}

/// Refuses hit testing while a question visual still has its network open, so no click reaches the page.
final class VisualAidWKWebView: WKWebView {
    var blocksInteraction = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        blocksInteraction ? nil : super.hitTest(point)
    }
}

@MainActor
private final class VisualAidSchemeHandler: NSObject, WKURLSchemeHandler {
    let visualID: UUID
    let document: Data

    init(visualID: UUID, document: Data) {
        self.visualID = visualID
        self.document = document
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let response = VisualAidWebPolicy.response(for: url, visualID: visualID, document: document)
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

struct VisualAidWebSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
