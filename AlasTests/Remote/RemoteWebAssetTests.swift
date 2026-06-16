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

    @Test func toolCardsAlwaysExposeCollapsedMetadata() throws {
        let app = try asset("app.js")
        let css = try asset("style.css")

        #expect(app.contains("function toolCollapsedPreview"))
        #expect(app.contains("function toolDisplayName"))
        #expect(app.contains("function toolMetadataRows"))
        #expect(app.contains(#""toolCallId""#))
        #expect(app.contains(#""rawInput""#))
        #expect(app.contains(#""params""#))
        #expect(app.contains(#"button.append(el("span", "tool-glyph", toolGlyph(verb)))"#))
        #expect(app.contains(#"preview || toolCollapsedPreview(tc)"#))
        #expect(css.contains(".tool-glyph"))
        #expect(css.contains(".tool-toggle"))
    }

    @Test func toolCardMobileFixBustsServiceWorkerAssetCache() throws {
        let html = try asset("index.html")
        let sw = try asset("sw.js")

        #expect(html.contains(#"/app.js?v=46"#))
        #expect(html.contains(#"/style.css?v=31"#))
        #expect(sw.contains(#"const CACHE_NAME = "alas-remote-shell-v22";"#))
        #expect(sw.contains(#""/app.js?v=46""#))
        #expect(sw.contains(#""/style.css?v=31""#))
    }

    @Test func remoteBareURLLinkifierPreservesIndentedCodeBlocks() throws {
        let app = try asset("app.js")

        #expect(app.contains("function markdownIndentedCodeBlockLine"))
        #expect(app.contains("function markdownBlankLine"))
        #expect(app.contains("function markdownAllowsIndentedCodeBlockAfterLine"))
        #expect(app.contains("function markdownThematicBreakLine"))
        #expect(app.contains("function rawHtmlBlockEndsAtBlankLine"))
        #expect(app.contains("function markdownReferenceDefinitionDestinationContent"))
        #expect(app.contains("isAngleBracketDestination"))
        #expect(app.contains("markdownThematicBreakLine(line)"))
        #expect(app.contains("markdownIndentedCodeBlockLine(line)"))
        #expect(app.components(separatedBy: "rawHtmlBlockEndsAtBlankLine(line, openingHtmlBlockTag)").count == 3)
        #expect(app.contains("if (canStartTitleQuote) return -1;"))
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
        #expect(html.contains("/app.js?v=46"))
        #expect(html.contains("/style.css?v=31"))
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
        #expect(sw.contains(#""/app.js?v=46""#))
        #expect(sw.contains(#""/style.css?v=31""#))
    }

    @Test func remoteWebIncludesNewSessionControls() throws {
        let html = try asset("index.html")
        #expect(html.contains(#"id="new-session""#))
        #expect(html.contains(#"id="new-session-sheet""#))
        #expect(html.contains(#"id="worktree-search""#))
    }

    @Test func remoteWebIncludesNewSessionMessageTypes() throws {
        let js = try asset("app.js")
        #expect(js.contains(#"type: "listWorktrees""#))
        #expect(js.contains(#"type: "listAgents""#))
        #expect(js.contains(#"type: "createSession""#))
        #expect(js.contains(#"case "worktreeList""#))
        #expect(js.contains(#"case "agentList""#))
        #expect(js.contains(#"case "sessionCreated""#))
        #expect(js.contains(#"case "createSessionFailed""#))
    }

    @Test func remoteWebClearsSessionSheetsWhenOpeningSession() throws {
        let js = try asset("app.js")

        #expect(js.contains("function hideCreateSheet(force)"))
        #expect(js.contains("const forced = force === true;"))
        #expect(js.contains("function clearSessionSheetsForOpen()"))
        #expect(js.contains("hidePermission();"))
        #expect(js.contains("hideQuestion();"))
        #expect(js.contains("hideConfig();"))
        #expect(js.contains("hideRenameSheet();"))
        #expect(js.contains("hideCreateSheet(true);"))
        #expect(js.contains("clearSessionSheetsForOpen();"))
        #expect(js.contains("let deferredCreatePrompt = null;"))
        #expect(js.contains("function handlePromptRequest(kind, sessionId, payload)"))
        #expect(js.contains("deferredCreatePrompt = { kind, sessionId, payload };"))
        #expect(js.contains("function replayDeferredCreatePrompt()"))
        #expect(js.contains("deferredCreatePrompt = null;"))
        #expect(js.contains("function clearDeferredCreatePrompt(kind, sessionId)"))
        #expect(js.contains("function failCreateOnDisconnect()"))
        #expect(js.contains(#"createState.error = wasBusy ? "Connection lost. Reconnect and try again." : "Connection lost. Reconnecting...";"#))
        #expect(js.contains("function requestCreateLists()"))
        #expect(js.contains("if (createState.open) {"))
        #expect(js.contains("requestCreateLists();"))
        #expect(js.contains(#"case "permissionRequest": handlePromptRequest("permission", msg.sessionId, msg.payload);"#))
        #expect(js.contains(#"case "questionRequest": handlePromptRequest("question", msg.sessionId, msg.payload);"#))
        #expect(js.contains(#"clearDeferredCreatePrompt("permission", msg.sessionId);"#))
        #expect(js.contains(#"clearDeferredCreatePrompt("question", msg.sessionId);"#))
    }

    @Test func remoteWebRefreshesCreateSelectionsFromServerLists() throws {
        let js = try asset("app.js")

        #expect(js.contains("createState.worktrees = msg.worktrees || [];"))
        #expect(js.contains("!createState.worktrees.some(w => w.id === createState.selectedWorktreeId)"))
        #expect(js.contains("createState.agents = msg.agents || [];"))
        #expect(js.contains("!createState.agents.some(a => a.id === createState.selectedAgentId)"))
        #expect(js.contains("!!createState.selectedWorktreeId && !!createState.selectedAgentId"))
        #expect(js.contains("worktrees: [],"))
        #expect(js.contains("agents: [],"))
    }

    @Test func remoteWebCompactsHeaderOnNarrowScreens() throws {
        let css = try asset("style.css")

        #expect(css.contains("@media (max-width: 360px)"))
        #expect(css.contains(#"#new-session { font-size: 0;"#))
        #expect(css.contains(#"#new-session::before { content: "+";"#))
        #expect(css.contains("#status.chip { font-size: 0;"))
        #expect(css.contains("#status.chip::before"))
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
