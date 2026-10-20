import CryptoKit
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// The sandbox a web tab's page runs in (API 12): what the scheme handler serves, what may load, and the bridge
/// scripts. Kept apart from the web view so the policy can be tested without one.
public enum PluginWebPolicy: Sendable {
    public static let scheme = "alas-plugin"
    public static let scriptPath = "/ui.js"
    /// Live pages per plugin, across its projects; each costs a WebContent process.
    public static let maxLivePagesPerPlugin = 4
    /// Problems the bridge reports per document, and the page reports per web view, so a failing page can't flood the log.
    public static let maxProblemsPerDocument = 5
    public static let maxProblemsPerPage = 20

    public static func shellURL(pluginID: String) -> URL { URL(string: "\(scheme)://\(pluginID)/")! }

    /// Sent as a header, which the page cannot remove, and repeated in the shell's `<meta>`. No inline or eval'd
    /// script, nothing from the network but images from `imageHosts` (API 15), and no frames or workers, which would
    /// get a fresh realm.
    public static func contentSecurityPolicy(pluginID: String, imageHosts: [String] = []) -> String {
        let images = (["data:", "blob:"] + imageHosts.map { "https://\($0)" }).joined(separator: " ")
        return "default-src 'none'; script-src \(scheme)://\(pluginID)\(scriptPath); style-src 'unsafe-inline'; "
            + "img-src \(images); font-src data:; connect-src 'none'; frame-src 'none'; worker-src 'none'; "
            + "form-action 'none'; base-uri 'none'"
    }

    public struct Response: Equatable, Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data

        public init(status: Int, headers: [String: String], body: Data) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    /// The scheme handler serves exactly two resources, the shell and the page script; anything else is a 404.
    public static func response(for url: URL, pluginID: String, imageHosts: [String] = [], shell: Data, script: Data) -> Response {
        var headers = [
            "Content-Security-Policy": contentSecurityPolicy(pluginID: pluginID, imageHosts: imageHosts),
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
    public static func allowsNavigation(to url: URL?, mainFrame: Bool, pluginID: String) -> Bool {
        guard mainFrame, let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        components.fragment = nil
        return components.url == shellURL(pluginID: pluginID)
    }

    /// A link the user clicked in the page, opened by Alas in the default browser: https only.
    public static func externalLink(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host()?.isEmpty == false else { return nil }
        return url
    }

    private static let baseRules = [
        #"{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}}"#,
        #"{"trigger": {"url-filter": "^alas-plugin:"}, "action": {"type": "ignore-previous-rules"}}"#,
        #"{"trigger": {"url-filter": "^data:", "resource-type": ["image", "font"]}, "action": {"type": "ignore-previous-rules"}}"#,
        #"{"trigger": {"url-filter": "^blob:", "resource-type": ["image"]}, "action": {"type": "ignore-previous-rules"}}"#,
    ]

    /// The rule list's name, which WebKit uses as a file name, so it is a digest of the hosts rather than the hosts
    /// themselves (a long list fails to compile). Pages without image hosts share one list.
    public static func ruleListIdentifier(imageHosts: [String]) -> String {
        guard !imageHosts.isEmpty else { return "alas-plugin-web-v1" }
        let digest = SHA256.hash(data: Data(imageHosts.joined(separator: ",").utf8))
        return "alas-plugin-web-v1-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Blocks every load outside `alas-plugin:`, besides the `data:` and `blob:` resources the CSP allows and, from API 15,
    /// `https` images from `imageHosts`. Hosts are validated lowercase names (letters, digits, `-`, `.`), so escaping the
    /// dots and requiring the `/` after the name makes an exact match: no other port, and no longer host.
    public static func contentRules(imageHosts: [String] = []) -> String {
        let images = imageHosts.map { host in
            let pattern = "^https://" + host.replacingOccurrences(of: ".", with: #"\\."#) + "/"
            return #"{"trigger": {"url-filter": "\#(pattern)", "resource-type": ["image"]}, "action": {"type": "ignore-previous-rules"}}"#
        }
        return "[\n" + (baseRules + images).map { "  " + $0 }.joined(separator: ",\n") + "\n]"
    }

    /// Theme tokens the page gets as CSS variables.
    public static let themeVariables: [(variable: String, token: String)] = [
        ("--alas-text", "fg"), ("--alas-dim", "fg-dim"), ("--alas-accent", "accent"), ("--alas-background", "bg-1"),
        ("--alas-line", "line"), ("--alas-tone-danger", "del"), ("--alas-tone-success", "add"),
        ("--alas-tone-warning", "warn"), ("--alas-tone-info", "info"),
        ("--alas-card", "bg-2"), ("--alas-border", "line-soft"), ("--alas-muted", "fg-faint"),
        ("--alas-accent-soft", "accent-soft"),
        ("--alas-chart-1", "accent"), ("--alas-chart-2", "info"), ("--alas-chart-3", "add"),
        ("--alas-chart-4", "warn"), ("--alas-chart-5", "del"), ("--alas-chart-6", "goal"),
    ]

    public static func shell(pluginID: String, imageHosts: [String] = [], variables: [String: String]) -> Data {
        let css = variables.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value);" }.joined(separator: " ")
        return Data("""
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(pluginID: pluginID, imageHosts: imageHosts))">
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
    /// messages arrive as `inEvent`, and a new `alas.context` as `themeEvent`. The names are random per page.
    public static func pageScript(
        outEvent: String, inEvent: String, themeEvent: String, maxBytes: Int, context: String
    ) -> String {
        """
        (() => {
          "use strict";
          for (const name of Object.getOwnPropertyNames(window)) {
            if (/^(webkit)?RTC/.test(name)) { try { delete window[name]; } catch (e) {} }
          }
          const OUT = \(literal(outEvent)), IN = \(literal(inEvent)), THEME = \(literal(themeEvent)), MAX = \(maxBytes);
          const apply = Reflect.apply, dispatch = EventTarget.prototype.dispatchEvent;
          const listen = EventTarget.prototype.addEventListener, Custom = CustomEvent, doc = document;
          const stringify = JSON.stringify, parse = JSON.parse, encoder = new TextEncoder();
          const encode = TextEncoder.prototype.encode;
          let handler = null, themeHandler = null, context = Object.freeze(parse(\(literal(context))));
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
            onThemeChange(fn) {
              if (fn !== null && typeof fn !== "function") throw new TypeError("alas.onThemeChange takes a function");
              themeHandler = fn;
            },
            get context() { return context; },
          });
          apply(listen, doc, [IN, (event) => { if (handler) handler(parse(event.detail)); }]);
          apply(listen, doc, [THEME, (event) => {
            context = Object.freeze(parse(event.detail));
            if (themeHandler) themeHandler(context);
          }]);
          Object.defineProperty(window, "alas", { value: alas });
        })();
        """
    }

    /// Runs in the bridge's isolated world, the only one with the message handler. Enforces the size, queue and
    /// rate limits before forwarding, so a page over them never costs the app anything, and turns trusted clicks on
    /// https links into requests to open them. It also reports what keeps a page from working (script errors,
    /// failed loads, blocked resources), a few per document, so they reach the plugin's log instead of a blank tab.
    public static func relayScript(
        outEvent: String, maxBytes: Int, queue: Int,
        bytesPerSecond: Int = PluginHost.maxWebBytesPerSecond, minCost: Int = PluginHost.minWebPostCost
    ) -> String {
        """
        (() => {
          "use strict";
          const OUT = \(literal(outEvent)), MAX = \(maxBytes), QUEUE = \(queue), RATE = \(bytesPerSecond), MIN = \(minCost);
          const handler = window.webkit.messageHandlers.alas, encoder = new TextEncoder();
          let pending = 0, budget = RATE, at = performance.now();
          document.addEventListener(OUT, (event) => {
            const text = event.detail;
            const size = typeof text === "string" ? encoder.encode(text).length : Infinity;
            const now = performance.now();
            budget = Math.min(RATE, budget + (now - at) / 1000 * RATE);
            at = now;
            const cost = Math.max(size, MIN);
            if (size > MAX || pending >= QUEUE || budget < cost) {
              event.preventDefault();
              return;
            }
            budget -= cost;
            pending += 1;
            const settle = () => { pending -= 1; };
            handler.postMessage({ post: text }).then(settle, settle);
          });
          let problems = 0;
          const problem = (text) => {
            if (problems++ < \(maxProblemsPerDocument)) handler.postMessage({ problem: String(text).slice(0, 500) });
          };
          window.addEventListener("error", (event) => {
            if (event instanceof ErrorEvent) {
              problem(`${event.message} (${String(event.filename).split("/").pop()}:${event.lineno})`);
            } else if (event.target instanceof Element) {
              problem(`could not load ${event.target.getAttribute("src") || event.target.localName}`);
            }
          }, true);
          window.addEventListener("unhandledrejection", (event) => {
            let reason = "";
            try { reason = String(event.reason); } catch (e) {}
            problem(`unhandled promise rejection: ${reason}`);
          });
          document.addEventListener("securitypolicyviolation", (event) => {
            problem(`blocked by the page's security policy: ${event.violatedDirective} ${event.blockedURI}`);
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
