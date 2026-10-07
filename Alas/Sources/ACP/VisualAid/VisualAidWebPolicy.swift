import Foundation

/// The sandbox a visual aid runs in: what the scheme handler serves, what may
/// load, and how agent HTML becomes a document. Pure, so it is testable without
/// a web view. Agent pages get inline scripts and https CDN loads, which the
/// plugin sandbox forbids, because they hold nothing but the agent's own HTML.
enum VisualAidWebPolicy {
    static let scheme = "alas-visual"
    static let contentRuleListIdentifier = "alas-visual-aid-v1"
    static let bridgeWorldName = "alas-visual-bridge"
    static let bridgeHandlerName = "alasVisual"
    static let minCardHeight: CGFloat = 120
    static let maxCardHeight: CGFloat = 720
    static let maxLivePages = 4

    static let contentSecurityPolicy =
        "default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:; "
        + "img-src data: blob: https:; font-src data: https:; connect-src 'none'; frame-src 'none'; "
        + "worker-src 'none'; form-action 'none'; base-uri 'none'"

    static let contentRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^alas-visual:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^https:", "resource-type": ["script", "style-sheet", "image", "font"]}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:", "resource-type": ["image", "font"]}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^blob:", "resource-type": ["image"]}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    static func documentURL(visualID: UUID) -> URL {
        URL(string: "\(scheme)://\(visualID.uuidString.lowercased())/")!
    }

    static func response(for url: URL, visualID: UUID, document: Data) -> PluginWebPolicy.Response {
        var headers = [
            "Content-Security-Policy": contentSecurityPolicy,
            "X-DNS-Prefetch-Control": "off",
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
        ]
        guard url.scheme == scheme,
              url.host(percentEncoded: true) == visualID.uuidString.lowercased(),
              url.user == nil, url.port == nil,
              url.query(percentEncoded: true) == nil,
              url.path(percentEncoded: true) == "/"
        else {
            headers["Content-Type"] = "text/plain; charset=utf-8"
            return .init(status: 404, headers: headers, body: Data())
        }
        headers["Content-Type"] = "text/html; charset=utf-8"
        return .init(status: 200, headers: headers, body: document)
    }

    /// Only the document itself, in the main frame. Links reach the browser through the bridge instead.
    static func allowsNavigation(to url: URL?, mainFrame: Bool, visualID: UUID) -> Bool {
        guard mainFrame, let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        components.fragment = nil
        return components.url == documentURL(visualID: visualID)
    }

    /// True when `html`, after leading whitespace and comments, opens with a doctype or `<html`.
    static func isFullDocument(_ html: String) -> Bool {
        var rest = Substring(html)
        while true {
            rest = rest.drop(while: \.isWhitespace)
            guard rest.hasPrefix("<!--") else { break }
            guard let end = rest.range(of: "-->") else { return false }
            rest = rest[end.upperBound...]
        }
        let opening = rest.prefix(9).lowercased()
        return opening.hasPrefix("<!doctype") || opening.hasPrefix("<html")
    }

    /// Fragments go inside the frame template. Full documents stay as written,
    /// with the CSP meta and theme variables inserted after `<head>`, or
    /// appended when there is none (the CSP header applies either way).
    static func document(html: String, themeVariables: [String: String], frameTemplate: String) -> Data {
        let css = themeVariables.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value);" }.joined(separator: " ")
        let head = #"<meta http-equiv="Content-Security-Policy" content="\#(contentSecurityPolicy)"><style>:root { \#(css) }</style>"#
        guard isFullDocument(html) else {
            // Split rather than replace so the agent's HTML is never scanned for placeholders.
            let parts = frameTemplate.replacingOccurrences(of: "{{HEAD}}", with: head).components(separatedBy: "{{CONTENT}}")
            return Data((parts.first ?? "").appending(html).appending(parts.dropFirst().joined(separator: "{{CONTENT}}")).utf8)
        }
        if let range = html.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            var result = html
            result.insert(contentsOf: head, at: range.upperBound)
            return Data(result.utf8)
        }
        return Data((html + head).utf8)
    }

    static func cardHeight(forContentHeight height: CGFloat) -> CGFloat {
        min(max(height, minCardHeight), maxCardHeight)
    }

    /// Runs in the isolated bridge world at document end. Page scripts cannot
    /// reach `webkit.messageHandlers` from their own world.
    static let bridgeScript = """
    (() => {
      const post = (message) => window.webkit.messageHandlers.\(bridgeHandlerName).postMessage(message);
      const reportHeight = () => post({ height: Math.ceil(document.documentElement.getBoundingClientRect().height) });
      const observer = new ResizeObserver(reportHeight);
      observer.observe(document.documentElement);
      if (document.body) observer.observe(document.body);
      addEventListener('load', reportHeight);
      document.addEventListener('click', (event) => {
        if (!event.isTrusted || !(event.target instanceof Element)) return;
        const link = event.target.closest('a[href]');
        if (link) {
          event.preventDefault();
          post({ open: link.href });
          return;
        }
        const choice = event.target.closest('[data-choice]');
        if (choice) post({ choice: String(choice.getAttribute('data-choice')).slice(0, 64) });
      }, true);
      globalThis.alasVisualSelect = (ids) => {
        for (const element of document.querySelectorAll('[data-choice]')) {
          element.classList.toggle('selected', ids.includes(element.getAttribute('data-choice')));
        }
      };
      globalThis.alasVisualTheme = (variables) => {
        for (const [name, value] of Object.entries(variables)) {
          document.documentElement.style.setProperty(name, value);
        }
      };
    })();
    """
}

/// The bundled frame template fragments are wrapped in.
enum VisualAidFrameTemplate {
    static let html: String = {
        guard let url = Bundle.main.url(forResource: "frame", withExtension: "html", subdirectory: "VisualAid"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("VisualAid/frame.html is missing from the app bundle")
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">{{HEAD}}</head><body>{{CONTENT}}</body></html>"
        }
        return text
    }()
}
