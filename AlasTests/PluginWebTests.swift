import AppKit
import Foundation
import Network
import Observation
import SwiftUI
import Testing
import WebKit
@testable import Alas

struct PluginWebTests {
    static let id = "io.x.p"

    @Test(arguments: [
        ("alas-plugin://io.x.p/", 200, "shell"),
        ("alas-plugin://io.x.p/ui.js", 200, "script"),
        ("alas-plugin://io.x.p/plugin.js", 404, ""),
        ("alas-plugin://io.x.p/ui.js?x=1", 404, ""),
        ("alas-plugin://io.x.p/ui%2Ejs", 404, ""),
        ("alas-plugin://io.x.p/UI.js", 404, ""),
        ("alas-plugin://io.x.other/ui.js", 404, ""),
        ("alas-plugin://io.x.p:80/ui.js", 404, ""),
        ("https://io.x.p/ui.js", 404, ""),
    ])
    func theSchemeHandlerServesExactlyTheShellAndThePageScript(url: String, status: Int, body: String) throws {
        let response = PluginWebPolicy.response(
            for: try #require(URL(string: url)), pluginID: Self.id, shell: Data("shell".utf8), script: Data("script".utf8))
        #expect(response.status == status)
        #expect(response.body == Data(body.utf8))
        // Every response, 404s included, carries the policy.
        #expect(response.headers["Content-Security-Policy"] == PluginWebPolicy.contentSecurityPolicy(pluginID: Self.id))
        #expect(response.headers["X-DNS-Prefetch-Control"] == "off")
    }

    /// The page gets the colors Alas draws with: the user's accent overrides the theme's, and missing tokens are left
    /// out rather than sent as the missing-token sentinel.
    @Test func themeVariablesFollowTheAccentOverride() {
        var theme = Theme(id: "dark", name: "Dark", tokens: ["accent": "oklch(0.74 0.11 195)", "fg": "oklch(1 0 0)"])
        let plain = PluginWebPolicy.cssVariables(theme)
        #expect(plain["--alas-text"] == "rgb(255 255 255 / 1.000)")
        #expect(plain["--alas-dim"] == nil)
        theme.accentOverrideHex = "#ff0000"
        let overridden = PluginWebPolicy.cssVariables(theme)
        #expect(overridden["--alas-accent"] == "rgb(255 0 0 / 1.000)")
        #expect(plain["--alas-accent"] != overridden["--alas-accent"])
    }

    /// What `alas.context` holds, sent as data to a running page when the theme changes.
    @Test func theContextNamesTheTabAndWhetherTheThemeIsDark() {
        #expect(PluginWebPolicy.context(tab: 2, theme: Theme(id: "light", name: "Light", tokens: [:])) == #"{"tab":2,"theme":"light"}"#)
        #expect(PluginWebPolicy.context(tab: 0, theme: .fallback) == #"{"tab":0,"theme":"dark"}"#)
    }

    @Test func theCSPAllowsOnlyThePageScriptAndInlineData() {
        #expect(PluginWebPolicy.contentSecurityPolicy(pluginID: Self.id) == "default-src 'none'; "
            + "script-src alas-plugin://io.x.p/ui.js; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; "
            + "connect-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'")
    }

    @Test(arguments: [
        ("alas-plugin://io.x.p/", true, true),
        ("alas-plugin://io.x.p/#section", true, true),
        ("alas-plugin://io.x.p/", false, false),
        ("alas-plugin://io.x.p/ui.js", true, false),
        ("alas-plugin://io.x.p/?leak=1", true, false),
        ("alas-plugin://io.x.other/", true, false),
        ("https://example.com/", true, false),
        ("about:blank", true, false),
        ("data:text/html,x", true, false),
    ])
    func onlyTheShellMayLoad(url: String, mainFrame: Bool, allowed: Bool) {
        #expect(PluginWebPolicy.allowsNavigation(to: URL(string: url), mainFrame: mainFrame, pluginID: Self.id) == allowed)
    }

    /// A plugin gets `limit` live pages; a freed slot is observable, so a refused tab can open its page then.
    @MainActor
    @Test func livePageSlotsAdmitUpToTheLimitAndAnnounceFreedOnes() {
        let slots = PluginWebPageSlots(limit: 2)
        #expect(slots.take("io.x.p") && slots.take("io.x.p"))
        #expect(!slots.take("io.x.p") && !slots.hasRoom("io.x.p"))
        #expect(slots.take("io.x.other"))
        nonisolated(unsafe) var announced = false  // onChange is @Sendable; it fires synchronously here
        withObservationTracking { _ = slots.hasRoom("io.x.p") } onChange: { announced = true }
        slots.release("io.x.p")
        #expect(announced && slots.hasRoom("io.x.p"))
        #expect(slots.take("io.x.p") && !slots.take("io.x.p"))
    }

    @Test(arguments: [
        ("https://example.com/a?b", true), ("http://example.com/", false), ("javascript:alert(1)", false),
        ("file:///etc/passwd", false), ("alas://session/new", false), ("https:///nohost", false),
    ])
    func clickedLinksOpenOnlyOverHTTPS(link: String, opens: Bool) {
        #expect((PluginWebPolicy.externalLink(link) != nil) == opens)
    }

    /// Hostile page code in a real, headless web view: it can't see the bridge's message handler, its inline script,
    /// inline handlers, eval, WebRTC and every network load (fetch, images, prefetch, preconnect, WebSocket) are
    /// blocked, a scripted click opens nothing, and messages travel page → plugin → page as data.
    /// Main actor: WKWebView is main-thread-only.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func aHostilePageStaysInsideTheSandbox() async throws {
        let server = try RequestRecorder()
        defer { server.listener.cancel() }
        let origin = "http://127.0.0.1:\(try await server.port())"
        // Positive control: an unsandboxed web view loading from the same listener is seen, so the zero below means
        // the sandbox blocked every load, not that the listener saw nothing.
        let control = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        control.loadHTMLString(#"<img src="\#(origin)/control.png">"#, baseURL: nil)
        #expect(await server.nextRequest() == "/control.png")
        control.stopLoading()
        let ping = "</script><img src=x onerror=alert(1)>\"'`${x}\u{2028}"
        let host = try await Self.webHost(source: Self.plugin(ping: ping))
        var opened: [URL] = []
        var page: PluginWebPage?
        let done = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            var resumed = false
            _ = host.attachWebPage(tab: 0) { json in
                guard !resumed, json.contains(#""done":true"#) else { return }
                resumed = true
                continuation.resume(returning: json)
            }
            page = PluginWebPage.open(host: host, tab: 0, script: Data(Self.hostilePage(origin: origin).utf8), theme: .fallback)
            page?.openExternal = { opened.append($0) }
        }
        defer { page?.close() }
        let result = try #require(try JSONSerialization.jsonObject(with: Data(done.utf8)) as? [String: Any])
        #expect(result["echo"] as? String == ping)
        let report = try #require(result["report"] as? [String: Bool])
        #expect(report.filter { !$0.value }.keys.sorted() == [])
        #expect(report.count == 9)
        #expect(opened.isEmpty)
        // Only the control's request; a sandbox leak, even a bare preconnect that sends nothing, adds another entry.
        #expect(server.requests.allSatisfy { $0 == "/control.png" })
    }

    /// A page whose script fails says why in its plugin's log and on the tab, instead of leaving only a blank tab.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func aFailingPageReportsWhyInThePluginLog() async throws {
        let host = try await Self.webHost(source: Self.plugin(ping: ""))
        let page = try #require(PluginWebPage.open(host: host, tab: 0, script: Data(#"throw new Error("boom");"#.utf8), theme: .fallback))
        defer { page.close() }
        var shown: [String] = []
        page.onProblem = { shown.append($0) }
        #expect(await awaitCondition { host.log.contains { $0.level == "error" && $0.message.contains("boom") } })
        #expect(shown.contains { $0.contains("boom") })
    }

    /// An approved web tab, shown through the real plugin tab view, opens its page and the page draws. The tab used to
    /// stay blank: its page was opened from an `onAppear` on a view with nothing in it, which SwiftUI never calls.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func aWebTabOpensAndDrawsItsPageInThePluginTabView() async throws {
        struct MemoryStore: PersistenceStoreProtocol {
            func write<T: Encodable>(_: T, to _: URL) throws {}
            func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "plugin-web-tab-\(UUID().uuidString)")
        let folder = root.appending(path: Self.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "PluginWebTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try Data(#"{"id":"\#(Self.id)","name":"P","version":"1","api":12,"entry":"p.js","web":"ui.js","contributes":{"tabs":[{"id":"w","title":"W","kind":"web"}]}}"#.utf8)
            .write(to: folder.appending(path: "plugin.json"))
        try PluginJSFixture.source([[.send(#"{"jsonrpc":"2.0","id":0,"result":{}}"#)]]).write(to: folder.appending(path: "p.js"))
        try Data(#"document.body.textContent = "drawn";"#.utf8).write(to: folder.appending(path: "ui.js"))
        let project = ProjectConfig(id: "proj", name: "Project", path: "/tmp/proj", color: "blue", addedAt: Date())
        let manager = PluginManager(
            directory: root, approvals: PluginApprovalStore(defaults: defaults), projects: { [project] }, actions: { _ in .inert })
        await manager.reload()
        await manager.approve(try #require(manager.plugin(id: Self.id)))
        let state = AppState(store: MemoryStore())
        state.pluginManager = manager
        let worktree = Worktree(
            id: "wt", projectId: "proj", name: "main", branch: "main", path: URL(fileURLWithPath: "/tmp/proj"), status: .clean,
            lastActivity: Date())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PluginTabView(
            state: state, worktree: worktree, tab: PluginTabState(pluginID: Self.id, contributionID: "w", title: "W")))
        window.orderFrontRegardless()
        defer { window.close() }

        func webView(in view: NSView) -> WKWebView? {
            (view as? WKWebView) ?? view.subviews.lazy.compactMap(webView(in:)).first
        }
        var page: WKWebView?
        #expect(await awaitCondition { page = webView(in: window.contentView!)
        return page != nil })
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var text = ""
        while text != "drawn", ContinuousClock.now < deadline {
            text = (try? await page?.evaluateJavaScript("document.body?.textContent ?? ''") as? String) ?? ""
            if text != "drawn" { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(text == "drawn")
    }

    @MainActor
    static func webHost(source: String) async throws -> PluginHost {
        let manifest = try PluginManifest.parse(
            Data(#"{"id":"io.x.p","name":"P","version":"1","api":12,"entry":"p.js","web":"ui.js","contributes":{"tabs":[{"id":"w","title":"W","kind":"web"}]}}"#.utf8))
        let host = PluginHost(
            manifest: manifest, source: Data(source.utf8),
            project: PluginProjectRef(id: "proj", name: "Project", host: nil), grants: [], actions: .inert,
            storage: PluginStorage(file: FileManager.default.temporaryDirectory.appending(path: "plugin-web-\(UUID().uuidString).json")),
            pluginStorage: PluginStorage(file: FileManager.default.temporaryDirectory.appending(path: "plugin-web-\(UUID().uuidString).json")),
            settings: PluginSettings.make(pluginID: manifest.id, declared: []))
        await host.activate()
        return host
    }

    /// Echoes the page: its report and the echo of a tricky string come back in one final `web/post`.
    static func plugin(ping: String) -> String {
        let literal = String(decoding: try! JSONEncoder().encode(ping), as: UTF8.self)
        return """
        let report = null;
        globalThis.handle = (text) => {
          const m = JSON.parse(text);
          if (m.method === "alas/activate") alas.send(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: {} }));
          if (m.method !== "web/message") return;
          const post = (message) => alas.send(JSON.stringify({ jsonrpc: "2.0", method: "web/post", params: { tab: 0, message } }));
          const message = m.params.message;
          if (message.report) report = message.report;
          if (message.ready) post({ ping: \(literal) });
          if (message.echo !== undefined) post({ done: true, report, echo: message.echo.ping });
        };
        """
    }

    static func hostilePage(origin: String) -> String {
        """
        (async () => {
          const ORIGIN = \(String(decoding: try! JSONEncoder().encode(origin), as: UTF8.self));
          const report = {};
          report.handlerHidden = !(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.alas);
          report.webRTCRemoved = typeof RTCPeerConnection === "undefined" && typeof webkitRTCPeerConnection === "undefined";
          report.dnsPrefetchOff = !!document.querySelector('meta[http-equiv="x-dns-prefetch-control"][content="off"]');
          const script = document.createElement("script");
          script.textContent = "window.inlineRan = true;";
          document.body.appendChild(script);
          report.inlineScriptBlocked = window.inlineRan !== true;
          report.inlineHandlerBlocked = await new Promise((resolve) => {
            const box = document.createElement("div");
            box.innerHTML = '<img src="data:," onerror="window.handlerRan = true">';
            box.firstChild.addEventListener("error", () => resolve(window.handlerRan !== true));
            document.body.appendChild(box);
          });
          try { eval("1"); report.evalBlocked = false; } catch (e) { report.evalBlocked = true; }
          try { await fetch(ORIGIN + "/fetch"); report.fetchBlocked = false; } catch (e) { report.fetchBlocked = true; }
          report.imageBlocked = await new Promise((resolve) => {
            const image = new Image();
            image.onload = () => resolve(false);
            image.onerror = () => resolve(true);
            image.src = ORIGIN + "/image.png";
          });
          for (const rel of ["dns-prefetch", "preconnect", "prefetch", "preload"]) {
            const link = document.createElement("link");
            link.rel = rel;
            link.as = "image";
            link.href = ORIGIN + "/" + rel;
            document.head.appendChild(link);
          }
          try { new WebSocket(ORIGIN.replace("http:", "ws:") + "/socket"); } catch (e) {}
          let posted = false;
          try { alas.post(undefined); } catch (e) { posted = true; }
          report.postNeedsJSON = posted;
          const link = document.createElement("a");
          link.href = "https://example.com/leak";
          document.body.appendChild(link);
          link.click();
          alas.onMessage((message) => alas.post({ echo: message }));
          alas.post({ report });
          alas.post({ ready: true });
        })();
        """
    }
}

/// Records every TCP connection the web views open to it: the request path, or "?" for one that sends nothing.
private final class RequestRecorder: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var recorded: [String] = []
    private let (stream, continuation) = AsyncStream<String>.makeStream()
    var requests: [String] { lock.withLock { recorded } }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let index = lock.withLock {
                recorded.append("?")
                return recorded.count - 1
            }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
                let line = data.map { String(decoding: $0, as: UTF8.self) }?.split(separator: "\r\n").first ?? ""
                let parts = line.split(separator: " ")
                let path = parts.count > 1 ? String(parts[1]) : "?"
                self?.lock.withLock { self?.recorded[index] = path }
                self?.continuation.yield(path)
                connection.send(
                    content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// The path of the next request that arrives; the test's time limit is the deadline.
    func nextRequest() async -> String? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    func port() async throws -> UInt16 {
        let listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }
}
