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

    @ObservationIgnored let webView: WKWebView
    private(set) var status: Status = .loading
    private(set) var contentHeight: CGFloat = VisualAidWebPolicy.minCardHeight
    @ObservationIgnored var onChoice: (String) -> Void = { _ in }
    @ObservationIgnored var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored private let visualID: UUID
    @ObservationIgnored private let schemeHandler: VisualAidSchemeHandler
    @ObservationIgnored private var crashes = 0
    @ObservationIgnored private var isClosed = false
    /// Theme variables baked into the served document, and the latest ones requested since.
    @ObservationIgnored private let documentThemeVariables: [String: String]
    @ObservationIgnored private var themeVariables: [String: String]

    init(visualID: UUID, html: String, theme: Theme) {
        self.visualID = visualID
        let variables = PluginWebPolicy.cssVariables(theme)
        documentThemeVariables = variables
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
        webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.allowsLinkPreview = false
        super.init()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: VisualAidWebPolicy.pageLockdownScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(
            source: VisualAidWebPolicy.bridgeScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.bridgeWorld))
        // Removed in `close`; the controller retains its handler.
        controller.add(self, contentWorld: Self.bridgeWorld, name: VisualAidWebPolicy.bridgeHandlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        Task { await load() }
    }

    /// Loads the document once the content rules are in place; without them it never loads.
    private func load() async {
        guard let rules = await Self.contentRuleList() else {
            status = .sandboxFailed
            return
        }
        guard !isClosed else { return }
        webView.configuration.userContentController.add(rules)
        webView.load(URLRequest(url: VisualAidWebPolicy.documentURL(visualID: visualID)))
    }

    private static func contentRuleList() async -> WKContentRuleList? {
        if let compiledRules, let rules = await compiledRules.value { return rules }
        let task = Task { @MainActor in
            try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: VisualAidWebPolicy.contentRuleListIdentifier,
                encodedContentRuleList: VisualAidWebPolicy.contentRules)
        }
        compiledRules = task
        return await task.value
    }

    func reload() {
        guard !isClosed, case .stopped(true) = status else { return }
        status = .loading
        webView.load(URLRequest(url: VisualAidWebPolicy.documentURL(visualID: visualID)))
    }

    func setSelected(_ ids: [String]) {
        guard !isClosed, status == .ready else { return }
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
        status = .ready
        // The served document is immutable; replay any theme change made while it was loading or crashed.
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
