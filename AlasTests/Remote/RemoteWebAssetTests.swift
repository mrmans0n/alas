import Foundation
import Testing

struct RemoteWebAssetTests {
    private func asset(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("Alas")
            .appendingPathComponent("Resources")
            .appendingPathComponent("RemoteWeb")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func toolCardsUseExplicitToggleInsteadOfNativeDetails() throws {
        let app = try asset("app.js")
        let css = try asset("style.css")

        #expect(app.contains(#"const d = el("div", "msg m-tool m-collapsible")"#))
        #expect(app.contains("setCardOpen"))
        #expect(app.contains(#"setAttribute("aria-expanded""#))
        #expect(app.contains("function toolBody"))
        #expect(app.contains(#""toolCallId""#))
        #expect(!app.contains(#"const d = el("details", "msg m-tool")"#))
        #expect(!css.contains(".m-tool > summary"))
    }

    @Test func toolCardMobileFixBustsServiceWorkerAssetCache() throws {
        let html = try asset("index.html")
        let sw = try asset("sw.js")

        #expect(html.contains(#"/app.js?v=38"#))
        #expect(html.contains(#"/style.css?v=29"#))
        #expect(sw.contains(#"const CACHE_NAME = "alas-remote-shell-v14";"#))
        #expect(sw.contains(#""/app.js?v=38""#))
        #expect(sw.contains(#""/style.css?v=29""#))
    }

    @Test func remoteBareURLLinkifierPreservesIndentedCodeBlocks() throws {
        let app = try asset("app.js")

        #expect(app.contains("function markdownIndentedCodeBlockLine"))
        #expect(app.contains("function markdownBlankLine"))
        #expect(app.contains("function markdownAllowsIndentedCodeBlockAfterLine"))
        #expect(app.contains("function rawHtmlBlockEndsAtBlankLine"))
        #expect(app.contains("markdownIndentedCodeBlockLine(line)"))
        #expect(app.components(separatedBy: "rawHtmlBlockEndsAtBlankLine(line, openingHtmlBlockTag)").count == 3)
        #expect(app.contains("if (canStartTitleQuote) return -1;"))
        #expect(app.contains("return line.trim().length > 0;"))
        #expect(app.contains("function markdownEmphasisDelimiterRunBeforeUrlStart"))
    }

    @Test func sessionRowsRenderWorktreeSummaryCards() throws {
        let app = try asset("app.js")
        let css = try asset("style.css")
        let html = try asset("index.html")

        #expect(app.contains("function sessionMetaParts"))
        #expect(app.contains("function renderSessionRow"))
        #expect(app.contains(#""changes unavailable""#))
        #expect(app.contains(#""clean""#))
        #expect(css.contains(".session-row-card"))
        #expect(css.contains(".session-meta"))
        #expect(html.contains("/app.js?v=38"))
        #expect(html.contains("/style.css?v=29"))
    }

    @Test func remoteWebExposesSessionRenameControls() throws {
        let app = try asset("app.js")
        let css = try asset("style.css")
        let html = try asset("index.html")
        let sw = try asset("sw.js")

        #expect(html.contains(#"id="detail-title""#))
        #expect(html.contains(#"id="detail-rename""#))
        #expect(html.contains(#"id="rename-sheet" class="sheet hidden" role="dialog""#))
        #expect(html.contains(#"aria-labelledby="rename-title""#))
        #expect(html.contains(#"id="rename-input""#))
        #expect(html.contains(#"aria-label="Session title""#))
        #expect(app.contains(#"type: "renameSession""#))
        #expect(app.contains("function showRenameSheet"))
        #expect(app.contains(#"case "sessionRenamed""#))
        #expect(app.contains(#"open.className = "session-open""#))
        #expect(app.contains("row.append(open, rename);"))
        #expect(!app.contains(#"row.role = "button""#))
        #expect(css.contains(".rename-btn"))
        #expect(css.contains(".session-open"))
        #expect(css.contains("#detail-title"))
        #expect(css.contains(".sheet-input"))
        #expect(sw.contains(#""/app.js?v=38""#))
        #expect(sw.contains(#""/style.css?v=29""#))
    }

    @Test func serviceWorkerKeepsControlAndDiagnosticRoutesNetworkOnly() throws {
        let sw = try asset("sw.js")

        #expect(sw.contains(#"url.pathname === "/pair""#))
        #expect(sw.contains(#"url.pathname === "/ws""#))
        #expect(sw.contains(#"url.pathname === "/health""#))
        #expect(sw.contains(#"url.pathname === "/remote-info""#))
        #expect(sw.contains(#"url.pathname.startsWith("/api/")"#))
        #expect(!sw.contains(#""/health","#))
        #expect(!sw.contains(#""/remote-info","#))
    }
}
