import AppKit
import SwiftUI
import WebKit

enum WebPreviewNavigation {
    static func allows(_ url: URL, remoteHost: String?) -> Bool {
        guard RunEndpointPolicy.endpoint(from: url.absoluteString) != nil else { return false }
        return remoteHost == nil || !RunEndpointPolicy.isLoopback(url)
    }

    static func captureRect(_ rect: CGRect, viewport: CGSize) -> CGRect? {
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: viewport))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped
    }
}

@MainActor
@Observable
final class WebPreviewBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let ownerKey: String
    let remoteHost: String?
    let webView: WKWebView
    var address = ""
    var error: String?
    var consoleErrors: [String] = []
    var canGoBack = false
    var canGoForward = false
    var loading = false
    var capturing = false
    var capture: WebPreviewCapture?
    var onNavigate: ((URL) -> Void)?
    private var navigationGeneration = 0
    private var consoleHandler: PreviewConsoleHandler?
    private var urlObservation: NSKeyValueObservation?

    init(ownerKey: String, remoteHost: String?) {
        self.ownerKey = ownerKey
        self.remoteHost = remoteHost
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
                      WebPreviewNavigation.allows(url, remoteHost: self.remoteHost) else { return }
                self.address = url.absoluteString
                self.canGoBack = self.webView.canGoBack
                self.canGoForward = self.webView.canGoForward
                self.onNavigate?(url)
            }
        }
    }

    func close() {
        navigationGeneration += 1
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

    func navigate(_ url: URL) {
        guard WebPreviewNavigation.allows(url, remoteHost: remoteHost) else {
            error = remoteHost != nil && RunEndpointPolicy.isLoopback(url)
                ? "This endpoint is on \(remoteHost!). Enter a remotely reachable URL; localhost would open a service on this Mac."
                : "Only HTTP and HTTPS pages can be opened in previews."
            return
        }
        error = nil
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              WebPreviewNavigation.allows(url, remoteHost: remoteHost) else {
            error = "Navigation blocked. Previews accept HTTP(S) pages and cannot open remote localhost endpoints."
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url,
              WebPreviewNavigation.allows(url, remoteHost: remoteHost), navigationResponse.canShowMIMEType else {
            error = "This response cannot be displayed in a web preview."
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { navigate(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationGeneration += 1
        loading = true
        error = nil
        consoleErrors = []
        consoleHandler?.reset(in: webView.configuration.userContentController)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        guard let url = webView.url, WebPreviewNavigation.allows(url, remoteHost: remoteHost) else {
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
        loading = false
        error = "The preview process stopped. Reload to reconnect."
    }

    private func failed(_ failure: Error) {
        loading = false
        if (failure as NSError).code != NSURLErrorCancelled {
            error = "Endpoint unavailable: \(failure.localizedDescription)"
        }
    }

    func captureRegion(_ selection: CGRect? = nil, elementAt point: CGPoint? = nil) {
        guard !capturing, !loading, let url = webView.url,
              WebPreviewNavigation.allows(url, remoteHost: remoteHost) else { return }
        capturing = true
        let generation = navigationGeneration
        let viewport = webView.bounds.size
        let capturedAt = Date()
        let errors = consoleErrors
        Task { @MainActor in
            defer { capturing = false }
            do {
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
                guard generation == navigationGeneration, webView.url == url,
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
