import Foundation

/// The sandbox a visual aid runs in: what the scheme handler serves, what may
/// load, and how agent HTML becomes a document. Pure, so it is testable without
/// a web view. Agent pages get inline scripts and https CDN loads, which the
/// plugin sandbox forbids, because they hold nothing but the agent's own HTML.
public enum VisualAidWebPolicy: Sendable {
    public static let scheme = "alas-visual"
    public static let contentRuleListIdentifier = "alas-visual-aid-v1"
    public static let bridgeWorldName = "alas-visual-bridge"
    public static let bridgeHandlerName = "alasVisual"
    public static let minCardHeight: CGFloat = 120
    public static let maxCardHeight: CGFloat = 720
    public static let maxLivePages = 4

    public static let contentSecurityPolicy =
        "default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:; "
        + "img-src data: blob: https:; font-src data: https:; connect-src 'none'; frame-src 'none'; "
        + "worker-src 'none'; form-action 'none'; base-uri 'none'"

    public static let contentRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^alas-visual:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^https:", "resource-type": ["script", "style-sheet", "image", "font"]}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:", "resource-type": ["image", "font"]}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^blob:", "resource-type": ["image"]}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    /// Swapped in once a question visual has loaded: the page keeps what it has but can no longer fetch
    /// anything, so script that sees the user's choices has no channel to send them out through.
    public static let lockedContentRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^alas-visual:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:", "resource-type": ["image", "font"]}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^blob:", "resource-type": ["image"]}, "action": {"type": "ignore-previous-rules"}}
    ]
    """
    public static let lockedContentRuleListIdentifier = "alas-visual-aid-locked-v1"
    /// How long a question visual may keep loading before the network is shut regardless; agent HTML can
    /// hold `didFinish` open forever with a request that never answers.
    public static let networkLockDeadline: Duration = .seconds(10)

    /// A question visual's links stay dead until the question is answered: a click would otherwise put the
    /// page's URL, and any choice encoded in it, in front of the browser first. A dismissal sends nothing,
    /// so it must not unlock them either.
    public static func allowsExternalLinks(hasQuestion: Bool, answer: ACPVisualAid.Answer?) -> Bool {
        guard hasQuestion else { return true }
        if case .answered = answer { return true }
        return false
    }

    public static func documentURL(visualID: UUID) -> URL {
        URL(string: "\(scheme)://\(visualID.uuidString.lowercased())/")!
    }

    public static func response(for url: URL, visualID: UUID, document: Data) -> PluginWebPolicy.Response {
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
    public static func allowsNavigation(to url: URL?, mainFrame: Bool, visualID: UUID) -> Bool {
        guard mainFrame, let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        components.fragment = nil
        return components.url == documentURL(visualID: visualID)
    }

    /// True when `html`, after leading whitespace and comments, opens with a doctype or `<html`.
    public static func isFullDocument(_ html: String) -> Bool {
        var rest = Substring(html)
        while true {
            rest = rest.drop(while: \.isWhitespace)
            guard rest.hasPrefix("<!--") else { break }
            guard let end = rest.range(of: "-->") else { return false }
            rest = rest[end.upperBound...]
        }
        let opening = rest.prefix(10).lowercased()
        return ["<!doctype", "<html"].contains { token in
            guard opening.hasPrefix(token) else { return false }
            guard let next = opening.dropFirst(token.count).first else { return true }
            return next.isWhitespace || next == ">" || next == "/"
        }
    }

    /// Fragments go inside the frame template with the CSP meta and the theme
    /// variables. Full documents are served byte for byte: the scheme handler
    /// sends the CSP as an HTTP header, and the page pushes theme variables
    /// after load.
    public static func document(html: String, themeVariables: [String: String], frameTemplate: String) -> Data {
        guard isFullDocument(html) else {
            let css = themeVariables.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value);" }.joined(separator: " ")
            let head = #"<meta http-equiv="Content-Security-Policy" content="\#(contentSecurityPolicy)"><style>:root { \#(css) }</style>"#
            // Split rather than replace so the agent's HTML is never scanned for placeholders.
            let parts = frameTemplate.replacingOccurrences(of: "{{HEAD}}", with: head).components(separatedBy: "{{CONTENT}}")
            return Data((parts.first ?? "").appending(html).appending(parts.dropFirst().joined(separator: "{{CONTENT}}")).utf8)
        }
        return Data(html.utf8)
    }

    /// Runs in the page world before any page script. CSP does not cover
    /// WebRTC, so agent scripts could otherwise open peer connections and send
    /// data out; this removes every `RTC*` / `webkitRTC*` global.
    public static let pageLockdownScript = """
    (() => {
      for (const name of Object.getOwnPropertyNames(window)) {
        if (/^(webkit)?RTC/.test(name)) { try { delete window[name]; } catch (e) {} }
      }
    })();
    """

    public static func cardHeight(forContentHeight height: CGFloat) -> CGFloat {
        min(max(height, minCardHeight), maxCardHeight)
    }

    /// Runs in the isolated bridge world at document end. Page scripts cannot
    /// reach `webkit.messageHandlers` from their own world.
    public static let bridgeScript = """
    (() => {
      const post = (message) => window.webkit.messageHandlers.\(bridgeHandlerName).postMessage(message);
      // Whether the page can still scroll up or down under the pointer, so the app can hand a wheel
      // gesture to the transcript once nothing there has room left to scroll.
      let edgesFrame = 0;
      let lastEdges = '';
      let pointer = null;
      const blocksScrolling = (overflow) => overflow === 'hidden' || overflow === 'clip';
      // Named so tests can call it with a point. Scroll chaining moves whichever box under the point still
      // can, so the page has room when any scroll container there does, or the viewport itself. The
      // viewport scrolls per the root's overflow, or the body's when the root leaves it visible.
      globalThis.alasVisualScrollEdges = (x, y) => {
        let scrollUp = false;
        let scrollDown = false;
        const add = (box) => {
          scrollUp ||= box.scrollTop > 1;
          scrollDown ||= box.scrollTop < box.scrollHeight - box.clientHeight - 1;
        };
        const root = document.documentElement;
        const at = x === undefined ? (pointer && document.elementFromPoint(pointer[0], pointer[1])) : document.elementFromPoint(x, y);
        for (let box = at; box && box !== root && box !== document.body; box = box.parentElement) {
          const style = getComputedStyle(box);
          if (style.overflowY !== 'auto' && style.overflowY !== 'scroll') continue;
          add(box);
          // WebKit does not chain a wheel past an overscroll barrier, so nothing beyond it can move.
          if (style.overscrollBehaviorY === 'contain' || style.overscrollBehaviorY === 'none') {
            return { scrollUp, scrollDown };
          }
        }
        let overflow = getComputedStyle(root).overflowY;
        if (overflow === 'visible' && document.body) overflow = getComputedStyle(document.body).overflowY;
        if (!blocksScrolling(overflow)) add(document.scrollingElement || root);
        return { scrollUp, scrollDown };
      };
      const reportEdges = () => {
        edgesFrame = 0;
        const edges = globalThis.alasVisualScrollEdges();
        const key = JSON.stringify(edges);
        if (key === lastEdges) return;
        lastEdges = key;
        post({ scrollEdges: edges });
      };
      const scheduleEdges = () => { if (!edgesFrame) edgesFrame = requestAnimationFrame(reportEdges); };
      const reportHeight = () => {
        post({ height: Math.ceil(document.documentElement.getBoundingClientRect().height) });
        scheduleEdges();
      };
      const observer = new ResizeObserver(reportHeight);
      observer.observe(document.documentElement);
      if (document.body) observer.observe(document.body);
      addEventListener('load', reportHeight);
      // Captured so nested scroll containers, whose scroll events do not bubble, report too.
      document.addEventListener('scroll', scheduleEdges, { passive: true, capture: true });
      document.addEventListener('mousemove', (event) => { pointer = [event.clientX, event.clientY]; scheduleEdges(); }, { passive: true, capture: true });
      addEventListener('resize', scheduleEdges);
      // Content or style can change scrollability without resizing either observed box.
      new MutationObserver(scheduleEdges).observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
      // Named so tests can drive it with a fake event.
      globalThis.alasVisualHandleClick = (event) => {
        if (!event.isTrusted || !(event.target instanceof Element)) return;
        // A choice is picked first, even when its element is or sits inside a link.
        const choice = event.target.closest('[data-choice]');
        if (choice) {
          // Never truncate: a longer value must not turn into a valid id.
          const value = String(choice.getAttribute('data-choice'));
          if (value.length <= 64) post({ choice: value });
        }
        const link = event.target.closest('a[href]');
        if (!link) return;
        // Same-document anchors keep their default navigation.
        if ((link.getAttribute('href') || '').startsWith('#')) return;
        event.preventDefault();
        post({ open: link.href });
      };
      document.addEventListener('click', (event) => globalThis.alasVisualHandleClick(event), true);
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
public enum VisualAidFrameTemplate: Sendable {
    public static let html: String = {
        guard let url = Bundle.main.url(forResource: "frame", withExtension: "html", subdirectory: "VisualAid"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("VisualAid/frame.html is missing from the app bundle")
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">{{HEAD}}</head><body>{{CONTENT}}</body></html>"
        }
        return text
    }()
}
