import Foundation
import Testing
import WebKit
@testable import Alas

/// File scope so `@Test(arguments:)` can interpolate it.
private let visualHost = "6f0c2d4e-8b1a-4c3d-9e5f-1a2b3c4d5e6f"

struct VisualAidWebPolicyTests {
    private static let id = UUID(uuidString: "6F0C2D4E-8B1A-4C3D-9E5F-1A2B3C4D5E6F")!
    private static let template = "<html><head>{{HEAD}}</head><body>{{CONTENT}}</body></html>"

    @Test(arguments: [
        ("alas-visual://\(visualHost)/", 200),
        ("alas-visual://\(visualHost)/other", 404),
        ("alas-visual://\(visualHost)/?x=1", 404),
        ("alas-visual://\(visualHost):80/", 404),
        ("alas-visual://u@\(visualHost)/", 404),
        ("alas-visual://00000000-0000-0000-0000-000000000000/", 404),
        ("https://\(visualHost)/", 404),
    ])
    func theSchemeHandlerServesOnlyTheDocument(url: String, status: Int) throws {
        let response = VisualAidWebPolicy.response(for: try #require(URL(string: url)), visualID: Self.id, document: Data("doc".utf8))
        #expect(response.status == status)
        #expect(response.body == (status == 200 ? Data("doc".utf8) : Data()))
        #expect(response.headers["Content-Security-Policy"] == VisualAidWebPolicy.contentSecurityPolicy)
    }

    @Test(arguments: [
        ("alas-visual://\(visualHost)/", true, true),
        ("alas-visual://\(visualHost)/#section", true, true),
        ("alas-visual://\(visualHost)/", false, false),
        ("https://example.com/", true, false),
    ])
    func navigationStaysOnTheDocument(url: String, mainFrame: Bool, allowed: Bool) {
        #expect(VisualAidWebPolicy.allowsNavigation(to: URL(string: url), mainFrame: mainFrame, visualID: Self.id) == allowed)
    }

    @Test(arguments: [
        ("<!DOCTYPE html><html></html>", true),
        ("  \n<!doctype html>", true),
        ("<!-- note --> <HTML lang=\"en\">", true),
        ("<!-- unterminated <html>", false),
        ("<div>hi</div>", false),
        ("<h2>html</h2>", false),
        ("<html-preview>x</html-preview>", false),
        ("<!doctype-widget>", false),
        ("<html>", true),
        ("<html/>", true),
        ("<!DOCTYPE\nhtml>", true),
    ])
    func fullDocumentDetection(html: String, full: Bool) {
        #expect(VisualAidWebPolicy.isFullDocument(html) == full)
    }

    @Test("fragments go inside the template verbatim, placeholders included")
    func fragmentAssembly() {
        let html = "<p>{{CONTENT}} and {{HEAD}}</p>"
        let document = String(decoding: VisualAidWebPolicy.document(html: html, themeVariables: ["--alas-text": "red"], frameTemplate: Self.template), as: UTF8.self)
        #expect(document.contains("<body><p>{{CONTENT}} and {{HEAD}}</p></body>"))
        #expect(document.contains("--alas-text: red;"))
        #expect(document.contains(VisualAidWebPolicy.contentSecurityPolicy))
    }

    @Test("a full document is returned unchanged", arguments: [
        "<!DOCTYPE html><html><HEAD lang=\"x\"><title>t</title></HEAD><body>b</body></html>",
        "<html><body>b</body></html>",
        "<html><!-- <head> --><head><title>t</title></head></html>",
        "<html><head data-x=\"a>b\"><title>t</title></head></html>",
        "<html><header>h</header><head><title>t</title></head></html>",
        "<html data-note=\"<head>\"><body>b</body></html>",
        "<html><body><script>const tag = '<head>';</script></body></html>",
    ])
    func fullDocumentIsReturnedUnchanged(html: String) {
        let document = VisualAidWebPolicy.document(html: html, themeVariables: ["--alas-text": "red"], frameTemplate: Self.template)
        #expect(document == Data(html.utf8))
    }

    @Test("the sandbox never allows connections or form posts")
    func cspBlocksExfiltrationChannels() {
        #expect(VisualAidWebPolicy.contentSecurityPolicy.contains("connect-src 'none'"))
        #expect(VisualAidWebPolicy.contentSecurityPolicy.contains("form-action 'none'"))
    }

    @Test("a question visual's links stay dead until it is answered, and a dismissal does not unlock them", arguments: [
        (false, ACPVisualAid.Answer?.none, true),
        (true, ACPVisualAid.Answer?.none, false),
        (true, .dismissed(at: Date(timeIntervalSince1970: 0)), false),
        (true, .answered(selectedOptionIds: ["a"], note: nil, at: Date(timeIntervalSince1970: 0)), true),
    ])
    func externalLinksWaitForTheAnswer(hasQuestion: Bool, answer: ACPVisualAid.Answer?, allowed: Bool) {
        #expect(VisualAidWebPolicy.allowsExternalLinks(hasQuestion: hasQuestion, answer: answer) == allowed)
    }

    @Test("only the loading rules let https resources in; the locked rules keep the scheme, data and blob")
    func lockedRulesDropHttps() throws {
        func filters(_ rules: String) throws -> [String] {
            let list = try #require(JSONSerialization.jsonObject(with: Data(rules.utf8)) as? [[String: Any]])
            return list.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        }
        let loading = try filters(VisualAidWebPolicy.contentRules)
        let locked = try filters(VisualAidWebPolicy.lockedContentRules)
        #expect(loading.contains { $0.hasPrefix("^https:") })
        #expect(!locked.contains { $0.hasPrefix("^https:") })
        #expect(locked.contains("^alas-visual:"))
    }

    @Test("the page budget closes the least recently admitted page")
    func pageBudgetEvictsLeastRecent() {
        var lru = VisualAidPageLRU(limit: 2)
        let a = UUID(), b = UUID(), c = UUID()
        #expect(lru.admit(a).isEmpty)
        #expect(lru.admit(b).isEmpty)
        #expect(lru.admit(a).isEmpty)
        #expect(lru.admit(c) == [b])
        lru.release(a)
        #expect(lru.admit(b).isEmpty)
    }
}

extension VisualAidWebPolicyTests {
    /// `@MainActor` on this test only: WKWebView needs the main thread.
    @MainActor
    @Test("WebRTC is gone from the page and from every about:blank or srcdoc child frame")
    func webRTCIsRemovedInEveryFrame() async throws {
        let page = VisualAidWebPage(
            visualID: UUID(),
            html: #"<p>probe</p><iframe id="static"></iframe><iframe id="doc" srcdoc="<p>x</p>"></iframe>"#,
            theme: try Theme.loadBundled(id: "cool-slate"), locksNetworkAfterLoad: false)
        defer { page.close() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while page.status != .ready {
            try #require(page.status == .loading && ContinuousClock.now < deadline, "page never became ready: \(page.status)")
            try await Task.sleep(for: .milliseconds(20))
        }

        let probe = """
        (() => {
          const dynamic = document.createElement('iframe');
          document.body.appendChild(dynamic);
          const typeOf = w => w ? [typeof w.RTCPeerConnection, typeof w.webkitRTCPeerConnection].join('/') : 'no-window';
          return {
            main: typeOf(window),
            static: typeOf(document.getElementById('static').contentWindow),
            srcdoc: typeOf(document.getElementById('doc').contentWindow),
            dynamic: typeOf(dynamic.contentWindow),
          };
        })()
        """
        let result = try await page.webView.evaluateJavaScript(probe, in: nil, contentWorld: .page)
        let types = try #require(result as? [String: String])
        #expect(types == [
            "main": "undefined/undefined",
            "static": "undefined/undefined",
            "srcdoc": "undefined/undefined",
            "dynamic": "undefined/undefined",
        ])
    }

    /// Polls until the page is ready, no fixed sleep.
    @MainActor
    private func waitUntilReady(_ page: VisualAidWebPage) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while page.status != .ready {
            try #require(page.status == .loading && ContinuousClock.now < deadline, "page never became ready: \(page.status)")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private func makePage(locks: Bool) throws -> VisualAidWebPage {
        let page = VisualAidWebPage(
            visualID: UUID(), html: "<p>x</p>", theme: try Theme.loadBundled(id: "cool-slate"), locksNetworkAfterLoad: locks)
        page.webView.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        return page
    }

    @MainActor
    @Test("a question visual stays untouchable until its network is shut, then takes clicks")
    func questionVisualLocksAfterLoad() async throws {
        let page = try makePage(locks: true)
        defer { page.close() }
        #expect(page.webView.hitTest(CGPoint(x: 100, y: 100)) == nil)
        try await waitUntilReady(page)
        #expect(page.isLocked)
        #expect(page.webView.hitTest(CGPoint(x: 100, y: 100)) != nil)
    }

    @MainActor
    @Test("a visual without a question never swaps its rules and is never blocked from clicks")
    func visualWithoutQuestionNeverLocks() async throws {
        let page = try makePage(locks: false)
        defer { page.close() }
        #expect(page.webView.hitTest(CGPoint(x: 100, y: 100)) != nil)
        try await waitUntilReady(page)
        #expect(!page.isLocked)
    }

    @MainActor
    @Test("a link click reaches the browser only while external links are enabled")
    func bridgeOpenHonorsExternalLinksEnabled() async throws {
        let page = try makePage(locks: false)
        defer { page.close() }
        try await waitUntilReady(page)
        var opened: [URL] = []
        page.openExternal = { opened.append($0) }
        let world = WKContentWorld.world(name: VisualAidWebPolicy.bridgeWorldName)
        func post(_ link: String) async throws {
            _ = try await page.webView.evaluateJavaScript(
                "window.webkit.messageHandlers.\(VisualAidWebPolicy.bridgeHandlerName).postMessage({open: '\(link)'}) && null",
                in: nil, contentWorld: world)
        }

        page.externalLinksEnabled = false
        try await post("https://example.com/choice-a")
        page.externalLinksEnabled = true
        try await post("https://example.com/choice-b")

        // Messages arrive in order, so once the second landed the first has been handled.
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while opened.isEmpty {
            try #require(ContinuousClock.now < deadline, "the enabled link never opened")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(opened.map(\.absoluteString) == ["https://example.com/choice-b"])
    }
}
