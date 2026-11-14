import AlasRemoteKit
import SwiftUI
import UIKit
import WebKit

/// One visual aid's page in a sandboxed WKWebView, mirroring the Mac's `VisualAidWebPage`: a non-persistent
/// data store, a scheme handler that serves only the document, content rule lists that block every other load
/// (and, for a question visual, all network once it has loaded), WebRTC switched off, and an isolated bridge
/// that reports height, `data-choice` taps and link taps. It lives only while its cell is configured.
// ponytail: no live-page cap like the web's 3 frames, because a screen shows only a few cells. Add one if a
// device profile shows memory pressure.
struct VisualAidWebView: UIViewRepresentable {
    let visual: ACPVisualAid
    let themeVariables: [String: String]
    let selected: [String]
    let linksEnabled: Bool
    let onHeight: (Double) -> Void
    let onChoice: (String) -> Void
    let onFailure: (VisualAidPage.Failure) -> Void

    func makeCoordinator() -> VisualAidPage {
        VisualAidPage(visual: visual, themeVariables: themeVariables)
    }

    func makeUIView(context: Context) -> WKWebView {
        update(context.coordinator)
        context.coordinator.start()
        return context.coordinator.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        update(context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: VisualAidPage) {
        coordinator.close()
    }

    private func update(_ page: VisualAidPage) {
        page.onHeight = onHeight
        page.onChoice = onChoice
        page.onFailure = onFailure
        page.externalLinksEnabled = linksEnabled
        page.setSelected(selected)
        page.applyTheme(themeVariables)
    }

    /// The Mac's theme variables (`visual-aid.js` FRAME_CSS lists them), from the app's own colors in `traits`, and
    /// the transcript's body font, standing in for the Mac's `layoutVariables`.
    static func themeVariables(_ traits: UITraitCollection) -> [String: String] {
        func css(_ color: UIColor, alpha: CGFloat = 1) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            return "rgb(\(channel(r)) \(channel(g)) \(channel(b)) / \(String(format: "%.3f", min(max(a * alpha, 0), 1))))"
        }
        let accent = UIColor.tintColor
        let fontSize = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
        return [
            "--alas-text": css(.label),
            "--alas-dim": css(.secondaryLabel),
            "--alas-muted": css(.tertiaryLabel),
            "--alas-accent": css(accent),
            "--alas-accent-soft": css(accent, alpha: 0.18),
            "--alas-background": css(.secondarySystemBackground),
            "--alas-card": css(.tertiarySystemBackground),
            "--alas-line": css(.separator),
            "--alas-border": css(.separator),
            "--alas-tone-success": css(.systemGreen),
            "--alas-tone-danger": css(.systemRed),
            "--alas-tone-warning": css(.systemOrange),
            "--alas-tone-info": css(.systemBlue),
            "--alas-chart-1": css(accent),
            "--alas-chart-2": css(.systemTeal),
            "--alas-chart-3": css(.systemGreen),
            "--alas-chart-4": css(.systemOrange),
            "--alas-chart-5": css(.systemRed),
            "--alas-chart-6": css(.systemPurple),
            "--alas-font-sans": "-apple-system, system-ui, sans-serif",
            "--alas-font-mono": "ui-monospace, SFMono-Regular, Menlo, monospace",
            "--alas-font-size": "\(fontSize)px",
            "--alas-radius": "6px",
        ]
    }
}

@MainActor
final class VisualAidPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    enum Failure {
        /// The sandbox could not be set up, so the document never loaded.
        case sandbox
        /// The page tried to leave its document; it is torn down.
        case blocked
        /// The web content process died.
        case stopped
    }

    private static let bridgeWorld = WKContentWorld.world(name: RemoteVisualAidWebPolicy.bridgeWorldName)
    /// One compilation per rule list per app run: a failed one is remembered, not retried by every card.
    private static var compiledRules: [String: Task<WKContentRuleList?, Never>] = [:]

    /// The bundled template fragments are wrapped in, shared with the Mac (`Alas/Resources/VisualAid/frame.html`).
    private static let frameTemplate: String = {
        guard let url = Bundle.main.url(forResource: "frame", withExtension: "html"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("frame.html is missing from the app bundle")
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">{{HEAD}}</head><body>{{CONTENT}}</body></html>"
        }
        return text
    }()

    let webView: WKWebView
    var onHeight: (Double) -> Void = { _ in }
    var onChoice: (String) -> Void = { _ in }
    var onFailure: (Failure) -> Void = { _ in }
    /// False while a question is open: a link's URL could carry the user's choice out before they submit.
    var externalLinksEnabled = false

    private let visualID: UUID
    private let presentation: ACPVisualAid.Presentation
    private let locksNetworkAfterLoad: Bool
    private let schemeHandler: SchemeHandler
    private let peerConnectionDisabled: Bool
    /// Theme variables baked into a fragment's frame; nil for a full document, which is served unmodified.
    private let documentThemeVariables: [String: String]?
    private var themeVariables: [String: String]
    private var selected: [String] = []
    private var loadingRules: WKContentRuleList?
    private var lockedRules: WKContentRuleList?
    private var lockDeadline: Task<Void, Never>?
    private var isLocked = false
    private var isReady = false
    private var isClosed = false
    private var hasCommitted = false
    private var mainFrameLoads = 0

    init(visual: ACPVisualAid, themeVariables: [String: String]) {
        visualID = visual.id
        presentation = visual.presentation
        locksNetworkAfterLoad = visual.question != nil
        self.themeVariables = themeVariables
        documentThemeVariables = RemoteVisualAidWebPolicy.isFullDocument(visual.html) ? nil : themeVariables
        schemeHandler = SchemeHandler(
            visualID: visual.id,
            document: RemoteVisualAidWebPolicy.document(
                html: visual.html, themeVariables: themeVariables,
                frameTemplate: Self.frameTemplate, presentation: visual.presentation))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: RemoteVisualAidWebPolicy.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.dataDetectorTypes = []
        // WebKit skips user scripts in srcdoc frames, so the lockdown script alone leaves `RTCPeerConnection`
        // in them; switch WebRTC off at the engine too, and never load the document if that did not take.
        peerConnectionDisabled = Self.disablePeerConnection(on: configuration.preferences)
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: RemoteVisualAidWebPolicy.pageLockdownScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addUserScript(WKUserScript(
            source: RemoteVisualAidWebPolicy.bridgeScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.bridgeWorld))
        webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.allowsLinkPreview = false
        // The web makes a question visual's frame `inert`: the native controls answer it, and a tap could reach
        // page script while the network is still open.
        webView.isUserInteractionEnabled = !locksNetworkAfterLoad
        // VoiceOver activation is the other way in; it stays out until the network is shut.
        webView.accessibilityElementsHidden = locksNetworkAfterLoad
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if presentation == .embedded {
            // Part of the reply, not a card: nothing opaque behind the page, before or after it loads.
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
        }
        super.init()
        // Removed in `close`; the controller retains its handler.
        controller.add(self, contentWorld: Self.bridgeWorld, name: RemoteVisualAidWebPolicy.bridgeHandlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Switches WebRTC off through WebKit's private preference and reads it back.
    /// False when the setter is missing or the value did not stick.
    private static func disablePeerConnection(on preferences: WKPreferences) -> Bool {
        guard preferences.responds(to: NSSelectorFromString("_setPeerConnectionEnabled:")) else { return false }
        preferences.setValue(false, forKey: "peerConnectionEnabled")
        return preferences.value(forKey: "peerConnectionEnabled") as? Bool == false
    }

    func start() {
        guard peerConnectionDisabled else {
            // A turn later: this runs inside `makeUIView`, where the failure must not update SwiftUI state.
            Task { fail(.sandbox) }
            return
        }
        Task { await load() }
    }

    /// Loads the document once the content rules are in place; without them it never loads. A question
    /// visual also needs the locked rules compiled up front, so locking later cannot fail halfway.
    private func load() async {
        guard let rules = await Self.ruleList(RemoteVisualAidWebPolicy.contentRuleListIdentifier,
                                              RemoteVisualAidWebPolicy.contentRules)
        else { return fail(.sandbox) }
        if locksNetworkAfterLoad {
            guard let locked = await Self.ruleList(RemoteVisualAidWebPolicy.lockedContentRuleListIdentifier,
                                                   RemoteVisualAidWebPolicy.lockedContentRules)
            else { return fail(.sandbox) }
            lockedRules = locked
        }
        guard !isClosed else { return }
        loadingRules = rules
        webView.configuration.userContentController.add(rules)
        if locksNetworkAfterLoad {
            lockDeadline = Task { [weak self] in
                try? await Task.sleep(for: RemoteVisualAidWebPolicy.networkLockDeadline)
                guard !Task.isCancelled else { return }
                self?.lockNetwork()
            }
        }
        webView.load(URLRequest(url: RemoteVisualAidWebPolicy.documentURL(visualID: visualID)))
    }

    private static func ruleList(_ identifier: String, _ rules: String) async -> WKContentRuleList? {
        if let task = compiledRules[identifier] { return await task.value }
        let task = Task { @MainActor in
            try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: rules)
        }
        compiledRules[identifier] = task
        return await task.value
    }

    /// Question visuals ignore choices until the network is locked.
    private var acceptsInput: Bool { !locksNetworkAfterLoad || isLocked }

    /// Shuts the network for a question visual: the locked rules go in before the loading rules come out, so
    /// there is no moment without a block-all list. Fails closed when the locked rules are unavailable.
    private func lockNetwork() {
        guard locksNetworkAfterLoad, !isClosed, !isLocked else { return }
        lockDeadline?.cancel()
        lockDeadline = nil
        guard let loadingRules, let lockedRules else { return fail(.sandbox) }
        let controller = webView.configuration.userContentController
        controller.add(lockedRules)
        controller.remove(loadingRules)
        // The locked rules only refuse new requests; a load already admitted would stay open as a channel the
        // page could close selectively once it sees the user's choice. After `didFinish` this is a no-op.
        if hasCommitted { webView.stopLoading() }
        isLocked = true
        webView.accessibilityElementsHidden = false
        // Cancelling the stalled loads means no `didFinish` will follow, so a committed page is ready now.
        if hasCommitted, !isReady { markReady() }
    }

    func setSelected(_ ids: [String]) {
        guard ids != selected else { return }
        selected = ids
        pushSelection()
    }

    private func pushSelection() {
        guard !isClosed, isReady, acceptsInput else { return }
        webView.callAsyncJavaScript(
            "alasVisualSelect(ids)", arguments: ["ids": selected], in: nil, in: Self.bridgeWorld, completionHandler: nil)
    }

    func applyTheme(_ variables: [String: String]) {
        guard variables != themeVariables else { return }
        themeVariables = variables
        guard !isClosed, isReady else { return }
        pushTheme()
    }

    private func pushTheme() {
        webView.callAsyncJavaScript(
            "alasVisualTheme(variables)", arguments: ["variables": themeVariables],
            in: nil, in: Self.bridgeWorld, completionHandler: nil)
    }

    private func markReady() {
        isReady = true
        // Fragments bake the theme into their frame; a full document is served unmodified, so it always gets
        // the theme pushed. Either way, replay any change made while it was loading.
        if themeVariables != documentThemeVariables { pushTheme() }
        if !selected.isEmpty { pushSelection() }
    }

    private func fail(_ failure: Failure) {
        guard !isClosed else { return }
        close()
        onFailure(failure)
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
            let shown = RemoteVisualAidWebPolicy.contentHeight(forContentHeight: height, presentation: presentation)
            // Taller than the card may grow: the page scrolls inside it instead.
            webView.scrollView.isScrollEnabled = height > shown
            onHeight(shown)
        } else if let choice = body["choice"] as? String {
            guard acceptsInput else { return }
            onChoice(choice)
        } else if let link = body["open"] as? String {
            openExternalLink(link)
        }
        // `scrollEdges` routes the Mac's wheel between page and transcript; touch scrolling nests natively.
    }

    /// The one exit to Safari, for both bridge link taps and `window.open`: http(s) only, and only when the
    /// policy allows links for this visual's question state.
    private func openExternalLink(_ text: String) {
        guard externalLinksEnabled, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host()?.isEmpty == false
        else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Navigation

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let mainFrame = navigationAction.targetFrame?.isMainFrame == true
        let allowed = !isClosed && !navigationAction.shouldPerformDownload && RemoteVisualAidWebPolicy.allowsNavigation(
            to: navigationAction.request.url, mainFrame: mainFrame, visualID: visualID)
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed, mainFrame { fail(.blocked) }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(!isClosed && navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    /// Same-document (fragment) navigations start no provisional load, so a second one is the page reloading
    /// or replacing its own document, which the web treats as leaving the page.
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        mainFrameLoads += 1
        if mainFrameLoads > 1 { fail(.blocked) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasCommitted = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed else { return }
        if locksNetworkAfterLoad {
            lockNetwork()
            // Locking marks a committed page ready itself.
            if isReady || isClosed { return }
        }
        if !isReady { markReady() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail(.stopped)
    }

    /// `target=_blank` and `window.open` never get a window; http(s) targets may open in Safari.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let text = navigationAction.request.url?.absoluteString { openExternalLink(text) }
        return nil
    }
}

/// Serves the visual's document at its own URL and a 404 for anything else, with the policy's headers.
private final class SchemeHandler: NSObject, WKURLSchemeHandler {
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
        let (status, headers) = RemoteVisualAidWebPolicy.responseHeaders(for: url, visualID: visualID)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(status == 200 ? document : Data())
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
