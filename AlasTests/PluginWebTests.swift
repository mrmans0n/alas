import Foundation
import Network
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
        let server = try ConnectionCounter()
        defer { server.listener.cancel() }
        let origin = "http://127.0.0.1:\(try await server.port())"
        let ping = "</script><img src=x onerror=alert(1)>\"'`${x}\u{2028}"
        let manifest = try PluginManifest.parse(
            Data(#"{"id":"io.x.p","name":"P","version":"1","api":12,"entry":"p.js","web":"ui.js","contributes":{"tabs":[{"id":"w","title":"W","kind":"web"}]}}"#.utf8),
            supportedAPIs: 4...12)
        let host = PluginHost(
            manifest: manifest, source: Data(Self.plugin(ping: ping).utf8),
            project: PluginProjectRef(id: "proj", name: "Project", host: nil), grants: [], actions: .inert,
            storage: PluginStorage(file: FileManager.default.temporaryDirectory.appending(path: "plugin-web-\(UUID().uuidString).json")),
            pluginStorage: PluginStorage(file: FileManager.default.temporaryDirectory.appending(path: "plugin-web-\(UUID().uuidString).json")),
            settings: PluginSettings.make(pluginID: manifest.id, declared: []))
        await host.activate()
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
        #expect(server.connections == 0)
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

/// Counts every TCP connection the page manages to open to it.
private final class ConnectionCounter: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    var connections: Int { lock.withLock { count } }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.lock.withLock { self?.count += 1 }
            connection.cancel()
        }
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
