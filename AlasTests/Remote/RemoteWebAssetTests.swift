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
        #expect(!app.contains(#"const d = el("details", "msg m-tool")"#))
        #expect(!css.contains(".m-tool > summary"))
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
        #expect(html.contains("/app.js?v=28"))
        #expect(html.contains("/style.css?v=28"))
    }

    @Test func remoteWebExposesSessionRenameControls() throws {
        let app = try asset("app.js")
        let css = try asset("style.css")
        let html = try asset("index.html")
        let sw = try asset("sw.js")

        #expect(html.contains(#"id="detail-title""#))
        #expect(html.contains(#"id="detail-rename""#))
        #expect(html.contains(#"id="rename-sheet""#))
        #expect(html.contains(#"id="rename-input""#))
        #expect(app.contains(#"type: "renameSession""#))
        #expect(app.contains("function showRenameSheet"))
        #expect(app.contains(#"case "sessionRenamed""#))
        #expect(css.contains(".rename-btn"))
        #expect(css.contains("#detail-title"))
        #expect(css.contains(".sheet-input"))
        #expect(sw.contains(#""/app.js?v=28""#))
        #expect(sw.contains(#""/style.css?v=28""#))
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
