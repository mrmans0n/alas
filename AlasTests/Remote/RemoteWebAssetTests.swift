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

    // Cache-busting versions (`/app.js?v=N`) are bumped routinely. Tests derive
    // them from the assets rather than pinning literals, so a bump only has to
    // touch index.html and sw.js — pinning them here meant every bump silently
    // rotted a dozen unrelated expectations.
    /// Every `"/path?v=N"` reference in `text`, keyed by path.
    private func versionedAssets(in text: String) -> [String: Int] {
        // Held locally rather than in a `static let`: `Regex` is not `Sendable`,
        // so a stored static trips strict concurrency checking.
        let versionedReference = #/"(/[^"?]+)\?v=(\d+)"/#
        var assets: [String: Int] = [:]
        for match in text.matches(of: versionedReference) {
            assets[String(match.1)] = Int(match.2)
        }
        return assets
    }

    /// Where `index.html` requests `path`, ignoring the version.
    private func referencePosition(
        of path: String,
        in html: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String.Index {
        try #require(
            html.range(of: "\(path)?v="),
            "index.html does not reference \(path)",
            sourceLocation: sourceLocation
        ).lowerBound
    }

    /// Asserts `index.html` requests `path` and `sw.js` precaches the same version.
    private func expectReferencedAndPrecached(
        _ path: String,
        html: String,
        sw: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let requested = try #require(
            versionedAssets(in: html)[path],
            "index.html does not reference \(path)",
            sourceLocation: sourceLocation
        )
        let precached = try #require(
            versionedAssets(in: sw)[path],
            "sw.js does not precache \(path)",
            sourceLocation: sourceLocation
        )
        #expect(
            requested == precached,
            "index.html requests \(path)?v=\(requested) but sw.js precaches v=\(precached)",
            sourceLocation: sourceLocation
        )
    }

    /// Asserts `path` is requested before `/app.js`, which depends on it.
    private func expectLoadsBeforeApp(
        _ path: String,
        in html: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let dependency = try referencePosition(of: path, in: html, sourceLocation: sourceLocation)
        let app = try referencePosition(of: "/app.js", in: html, sourceLocation: sourceLocation)
        #expect(
            dependency < app,
            "\(path) must be loaded before /app.js",
            sourceLocation: sourceLocation
        )
    }

    @Test func remoteWebHTMLAndServiceWorkerAgreeOnAssetVersions() throws {
        let html = try asset("index.html")
        let sw = try asset("sw.js")

        // A version the page requests but the worker never precached (or vice
        // versa) leaves the shell fetching an asset that was warmed under a
        // stale URL, which is how a bumped asset reaches users late.
        #expect(versionedAssets(in: html) == versionedAssets(in: sw))
        #expect(!versionedAssets(in: html).isEmpty)
        #expect(sw.contains(#"const CACHE_NAME = "alas-remote-shell-v"#))
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
        #expect(app.contains(#"toggle.append(el("span", "tool-verb", verb));"#))
        #expect(app.contains(#"toggle.append(el("span", "tool-cmd", name || preview || ""));"#))
        #expect(app.contains(#"preview || toolCollapsedPreview(tc)"#))
        #expect(css.contains(".tool-verb"))
        #expect(css.contains(".tool-cmd"))
        #expect(css.contains(".tool-toggle"))
    }

    @Test func remoteSessionOrderingAssetsAreLoadedAndCached() throws {
        let html = try asset("index.html")
        let sw = try asset("sw.js")

        try expectLoadsBeforeApp("/session-ordering.js", in: html)
        try expectReferencedAndPrecached("/session-ordering.js", html: html, sw: sw)
        try expectReferencedAndPrecached("/app.js", html: html, sw: sw)
        try expectReferencedAndPrecached("/style.css", html: html, sw: sw)
    }

    @Test func remoteWebToolRowsAvoidNativeButtonRenderingOnMobileSafari() throws {
        let app = try asset("app.js")
        let html = try asset("index.html")
        let sw = try asset("sw.js")

        #expect(app.contains(#"const toggle = el("div", "tool-toggle")"#))
        #expect(app.contains(#"toggle.setAttribute("role", "button")"#))
        #expect(app.contains("toggle.tabIndex = 0"))
        #expect(app.contains("function handleCardToggleKeydown"))
        #expect(!app.contains(#"const button = el("button", "tool-toggle")"#))
        try expectReferencedAndPrecached("/app.js", html: html, sw: sw)
        try expectReferencedAndPrecached("/style.css", html: html, sw: sw)
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

    @Test func repoFilterModuleExposesPureHelpers() throws {
        let js = try asset("repo-filter.js")
        let html = try asset("index.html")
        let sw = try asset("sw.js")

        #expect(js.contains("function repoTileColor(name)"))
        #expect(js.contains("function repoInitials(name)"))
        #expect(js.contains("function worktreeIsPrimaryBranch(name)"))
        #expect(js.contains("function worktreeIsActive(worktree)"))
        #expect(js.contains("function worktreeIsDirty(worktree)"))
        #expect(js.contains("function relativeTimeShort(updatedAtMs, nowMs)"))
        #expect(js.contains("function diffBarSegments(added, deleted)"))
        #expect(js.contains("function sectionMatchesFilter(section, filter)"))
        #expect(js.contains("function sectionMatchesQuery(section, query)"))
        #expect(js.contains("function sectionCounts(sections)"))
        #expect(js.contains("globalThis.RemoteRepoFilter ="))
        // Pure module: no DOM access.
        #expect(!js.contains("document."))
        #expect(!js.contains("window."))

        try expectLoadsBeforeApp("/repo-filter.js", in: html)
        try expectReferencedAndPrecached("/repo-filter.js", html: html, sw: sw)
    }

    @Test func repoHeadersAreCollapsibleWithColorTiles() throws {
        let js = try asset("app.js")
        let css = try asset("style.css")

        #expect(js.contains("let repoOverrides = new Map();"))
        #expect(js.contains("function defaultSectionExpanded(section)"))
        #expect(js.contains("function renderRepoHeader(section, expanded, forceExpanded)"))
        #expect(js.contains("RemoteRepoFilter.repoTileColor(section.title)"))
        #expect(js.contains("RemoteRepoFilter.repoInitials(section.title)"))
        #expect(js.contains("repoOverrides.has(section.id)"))
        #expect(js.contains("repoOverrides.set(section.id, !expanded);"))
        #expect(css.contains(".rh {"))
        #expect(css.contains(".chev {"))
        #expect(css.contains(".tile {"))
        #expect(css.contains(".cnt {"))
    }

    // Rename is reachable only from the session's own header now — the
    // repos list shows a worktree card's branch as its identity, not a
    // custom session title, so there is no per-row rename affordance to
    // preserve there (see sessionRenameUpdatesTheCachedListedSessionsEntry
    // for the cache-consistency half of the rename flow).
    @Test func remoteWebExposesSessionRenameControls() throws {
        let app = try asset("app.js")
        let css = try asset("style.css")
        let html = try asset("index.html")

        #expect(html.contains(#"id="detail-title""#))
        #expect(html.contains(#"id="detail-rename""#))
        #expect(html.contains(#"id="rename-sheet" class="sheet hidden" role="dialog""#))
        #expect(html.contains(#"aria-labelledby="rename-title""#))
        #expect(html.contains(#"id="rename-input""#))
        #expect(html.contains(#"aria-label="Session title""#))
        #expect(app.contains(#"type: "renameSession""#))
        #expect(app.contains("function showRenameSheet"))
        #expect(app.contains(#"case "sessionRenamed""#))
        #expect(app.contains(#"$("detail-rename").onclick = () => { if (currentSession) showRenameSheet(currentSession); };"#))
        #expect(css.contains(".iconbtn"))
        #expect(css.contains("#detail-title"))
        #expect(css.contains(".sheet-input"))
    }

    @Test func sessionNavBarShowsStreamingStateAndBranch() throws {
        let html = try asset("index.html")
        let js = try asset("app.js")
        let css = try asset("style.css")

        #expect(html.contains(#"id="detail-subtitle""#))
        #expect(js.contains("function setDetailSubtitle(sessionId)"))
        #expect(js.contains(#"lastStreamingState === "idle" ? "idle" : "streaming""#))
        #expect(js.contains("setDetailSubtitle(id)"))
        #expect(css.contains("#detail-subtitle"))
    }

    @Test func configSheetScrollsWhenModelListOverflows() throws {
        let html = try asset("index.html")
        let css = try asset("style.css")

        // The config sheet content lives in a dedicated scroll region so that a
        // long model list stays reachable instead of overflowing off the top of
        // the viewport (the sheet is anchored to the bottom via align-items: flex-end).
        #expect(html.contains(#"<div id="cfg-scroll">"#))
        #expect(css.contains("#cfg .sheet-card { max-height: min(85vh, 640px); display: flex; flex-direction: column; }"))
        #expect(css.contains("#cfg-scroll { min-height: 0; overflow-y: auto; -webkit-overflow-scrolling: touch; }"))
        #expect(css.contains("#cfg-close { flex: 0 0 auto; }"))
    }

    @Test func messageRowsDoNotShrinkInTranscriptFlexColumn() throws {
        let css = try asset("style.css")

        // #messages is a flex column; its children must not shrink or tool cards
        // (overflow: hidden → automatic min-size 0) collapse to ~1px lines once
        // the transcript fills the viewport.
        #expect(css.contains("#messages > * { flex-shrink: 0; }"))
    }

    @Test func remoteWebIncludesNewSessionControls() throws {
        let html = try asset("index.html")
        #expect(html.contains(#"id="fab-new-session""#))
        #expect(html.contains(#"id="new-session-sheet""#))
        #expect(html.contains(#"id="worktree-search""#))
    }

    @Test func bottomTabBarSwitchesRepoAndSettingsWithFAB() throws {
        let html = try asset("index.html")
        let js = try asset("app.js")
        let css = try asset("style.css")

        #expect(html.contains(#"id="bottom-tabbar""#))
        #expect(html.contains(#"id="tab-repos""#))
        #expect(html.contains(#"id="tab-settings""#))
        #expect(html.contains(#"id="fab-new-session""#))
        #expect(html.contains(#"<section id="settings" class="view hidden">"#))
        #expect(!html.contains(#"id="new-session" aria-label"#))

        #expect(js.contains(#"let topLevelTab = "repos";"#))
        #expect(js.contains("function showRepos()"))
        #expect(js.contains("function showSettings()"))
        #expect(js.contains(#"$("fab-new-session").onclick = showCreateSheet;"#))
        #expect(js.contains(#"$("tab-repos").addEventListener("click", showRepos);"#))
        #expect(js.contains(#"$("tab-settings").addEventListener("click", showSettings);"#))

        #expect(css.contains("#bottom-tabbar"))
        #expect(css.contains("#fab-new-session"))
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

    @Test func remoteWebIntegratesWorktreeCreationController() throws {
        let html = try asset("index.html")
        let js = try asset("app.js")
        let creation = try asset("worktree-creation.js")
        let sw = try asset("sw.js")

        try expectLoadsBeforeApp("/worktree-creation.js", in: html)
        #expect(js.contains("const worktreeCreation = RemoteWorktreeCreation.createFlow(send);"))
        #expect(js.contains(#"case "projectList":"#))
        #expect(js.contains(#"case "branchList":"#))
        #expect(js.contains(#"case "branchListFailed":"#))
        #expect(js.contains(#"case "worktreeSessionCreated":"#))
        #expect(js.contains(#"case "worktreeSessionCreationFailed":"#))
        #expect(js.contains("worktreeCreation.disconnect();"))
        #expect(js.contains(#"worktreeCreation.markRecoveryListLoaded("sessions");"#))
        #expect(js.contains(#"worktreeCreation.markRecoveryListLoaded("worktrees");"#))
        #expect(js.contains("function reloadNewWorktreeCatalog()"))
        #expect(js.contains("worktreeCreation.reloadCatalog();"))
        #expect(js.contains("reloadNewWorktreeCatalog();"))
        #expect(js.contains("worktreeCreation.reconcileAgents(createState.agents);"))
        #expect(!js.contains("`Worktree created. ${creationError.message}`"))
        #expect(creation.contains(#"type: "listProjects""#))
        #expect(creation.contains(#"type: "createWorktreeSession""#))
        #expect(creation.contains("function reloadCatalog()"))
        #expect(creation.contains("function reconcileAgents(agents)"))
        try expectReferencedAndPrecached("/worktree-creation.js", html: html, sw: sw)
    }

    @Test func remoteWebScopesBranchFailuresToTheBaseBranchControl() throws {
        let html = try asset("index.html")
        let js = try asset("app.js")

        #expect(html.contains(#"id="create-error" class="sheet-error hidden" role="alert" aria-live="assertive""#))
        #expect(html.contains(#"id="branch-status" class="form-guidance" role="status""#))
        #expect(html.contains(#"id="retry-branches""#))
        #expect(js.contains("creationState.error && creationState.error.stage !== \"branches\""))
        #expect(js.contains("worktreeCreation.canRetry()"))
    }

    @Test func remoteWebClearsSessionSheetsWhenOpeningSession() throws {
        let js = try asset("app.js")

        #expect(js.contains("function hideCreateSheet(force)"))
        #expect(js.contains("const forced = force === true;"))
        #expect(js.contains("function clearSessionSheetsForOpen()"))
        #expect(js.contains("hidePermission();"))
        #expect(js.contains("hideQuestion();"))
        #expect(js.contains("hideElicitation();"))
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
        #expect(js.contains(#"case "elicitationRequest": handlePromptRequest("elicitation", msg.sessionId, msg.payload);"#))
        #expect(js.contains(#"clearDeferredCreatePrompt("permission", msg.sessionId);"#))
        #expect(js.contains(#"clearDeferredCreatePrompt("question", msg.sessionId);"#))
        #expect(js.contains(#"clearDeferredCreatePrompt("elicitation", msg.sessionId);"#))
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

    @Test func remoteElicitationSerializerPreservesRequiredAndOptionalSemantics() throws {
        let js = try asset("app.js")

        #expect(js.contains("const hasDefault = field.defaultValue !== null && field.defaultValue !== undefined;"))
        #expect(js.components(separatedBy: "if (!field.required && !state.touched) continue;").count == 3)
        #expect(js.contains("function elicitationRequiredValueIsMissing(field, value)"))
        #expect(js.contains(#"["date", "date-time", "email", "uri"].includes(field.format)"#))
        #expect(js.contains("if (field.minLength && field.minLength > 0) return true;"))
        #expect(js.contains("return !new RegExp(field.pattern).test(value);"))
        #expect(js.contains("return showElicitationError(`Enter a value for ${field.title}.`);"))
        #expect(js.contains(#"!field.required && (field.type === "number" || field.type === "integer") && input.value.trim() === """#))
        #expect(js.contains(#"!field.required && field.type === "string" && input.value === """#))
        #expect(js.contains("if (!Number.isInteger(value)) return showElicitationError(`Enter a whole number for ${field.title}.`);"))
        #expect(!js.contains("Number.parseInt(input.value, 10)"))
        #expect(js.contains(#"field.format === "email" ? "email""#))
        #expect(js.contains(#"field.format === "uri" ? "url""#))
        #expect(js.contains("function elicitationFormatIsValid(field, value)"))
        #expect(!js.contains("input.pattern = field.pattern;"))
        #expect(js.contains("if (!new RegExp(field.pattern).test(value)) return false;"))
        #expect(js.contains("function elicitationDateTimeLocalValue(raw)"))
        #expect(js.contains(#"if (field.format === "date-time") input.step = "0.001";"#))
        #expect(js.contains("date.getMilliseconds()"))
        #expect(js.contains(#"!["string", "number", "integer", "boolean", "array"].includes(field.type)"#))
        #expect(js.contains("elicitationInputs.set(field.key, { field, unsupported: true });"))
        #expect(js.contains("if (field.required) return showElicitationError(`Cannot submit the unsupported field ${field.title}.`);"))

        let formSend = try #require(js.range(of: #"send({ type: "elicitationResponse", sessionId, requestId: payload.requestId, action: "accept", content });"#))
        let validationHelper = try #require(js.range(of: "function elicitationRequiredValueIsMissing"))
        #expect(!js[formSend.upperBound..<validationHelper.lowerBound].contains("hideElicitation();"))

        let urlAccept = try #require(js.range(of: #"send({ type: "elicitationResponse", sessionId, requestId: payload.requestId, action: "accept" });"#))
        let urlNavigation = try #require(js.range(of: "opened.location.replace(payload.url);"))
        #expect(urlAccept.lowerBound < urlNavigation.lowerBound)
    }

    @Test func remoteWebCompactsHeaderOnNarrowScreens() throws {
        let css = try asset("style.css")

        #expect(css.contains("@media (max-width: 360px)"))
        #expect(css.contains("#status.chip { font-size: 0;"))
        #expect(css.contains("#status.chip::before"))
    }

    // Regression: the redesign's `#bar` layout keeps back/title/rename/status
    // pill on the list AND in a session, which is exactly what the narrow
    // compacting rule above protects — pin that it survives layout changes to
    // `#bar` (unlike `#detail-title`'s hide-on-narrow-screens rule, which the
    // design mock explicitly contradicts by showing the session title, and
    // was dropped rather than preserved).
    @Test func detailBarHidesTheOkStatusPillButKeepsBadOrConnectingVisible() throws {
        let css = try asset("style.css")

        #expect(css.contains(#"#bar.is-detail #status[data-state="ok"] { display: none; }"#))
        #expect(!css.contains(#"#bar.is-detail #status { display: none; }"#))
    }

    // Regression: syncing the fixed shell to visualViewport immediately during
    // page load can capture Safari's transient, shorter viewport before its
    // toolbar settles, leaving an unpainted strip above the browser controls.
    @Test func remoteWebDoesNotTrackVisualViewportUntilInputFocus() throws {
        let js = try asset("app.js")
        let viewportSetup = try #require(js.range(of: "const vp = window.visualViewport;").map { js[$0.lowerBound...] })

        #expect(viewportSetup.contains("const beginViewportTracking = () =>"))
        #expect(viewportSetup.contains(#"document.addEventListener("focusin", (event) => {"#))
        #expect(viewportSetup.contains(#"event.target.matches("input, textarea, select")"#))
        let trackingStart = try #require(viewportSetup.range(of: "const beginViewportTracking = () =>")?.lowerBound)
        #expect(!viewportSetup[..<trackingStart].contains(#"vp.addEventListener("resize", syncViewport);"#))
        #expect(!viewportSetup[..<trackingStart].contains(#"vp.addEventListener("scroll", syncViewport);"#))
        let trackingSetup = viewportSetup[trackingStart...]
        #expect(trackingSetup.contains(#"vp.addEventListener("resize", syncViewport);"#))
        #expect(trackingSetup.contains(#"vp.addEventListener("scroll", syncViewport);"#))
    }

    @Test func remoteWebSpeaksIncrementalTranscriptProtocol() throws {
        let js = try asset("app.js")
        #expect(js.contains(#"case "transcriptPage""#))
        #expect(js.contains(#"case "stopPending""#))
        #expect(js.contains(#"type: "fetchOlder""#))
    }

    @Test func remoteWebStopDoesNotTakeOverFirst() throws {
        let js = try asset("app.js")
        let stopHandler = try #require(js.range(of: #"$("stop").onclick"#).map { js[$0.lowerBound...].prefix(220) })
        #expect(!stopHandler.contains("ensureWriter"))
    }

    // Regression (codex review, PR #775): applyPage used to clear the
    // shared (single-session) olderFetchInFlight/loading-row state BEFORE
    // checking whether the page belonged to the currently open session —
    // so a stale page for a session the user already left could clear the
    // CURRENT session's own in-flight backfill indicator and allow a
    // duplicate fetch while the real request was still pending.
    @Test func applyPageChecksSessionBeforeClearingSharedInFlightState() throws {
        let js = try asset("app.js")
        let body = try #require(js.range(of: "function applyPage(msg) {").map { js[$0.lowerBound...].prefix(400) })
        let sessionCheckIndex = try #require(body.range(of: "msg.sessionId !== currentSession")?.lowerBound)
        let clearInFlightIndex = try #require(body.range(of: "olderFetchInFlight = false")?.lowerBound)
        #expect(
            sessionCheckIndex < clearInFlightIndex,
            "the sessionId check must run before clearing shared in-flight state"
        )
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

    @Test func remoteWebDerivesComposerActionLikeNativePane() throws {
        let js = try asset("app.js")

        #expect(js.contains("function composerAction(streamingState, hasText)"))
        #expect(js.contains(#"return hasText ? "send" : "hidden";"#))
        #expect(js.contains(#"return hasText ? "queue" : "stop";"#))
        #expect(js.contains("function queueBadgeCount()"))
        #expect(js.contains("function submitPrompt(intent)"))
        #expect(js.contains(#"intent: intent || "auto""#))
    }

    @Test func remoteWebRendersQueueSplitCapsule() throws {
        let html = try asset("index.html")
        let css = try asset("style.css")

        #expect(html.contains(#"id="queue-capsule""#))
        #expect(html.contains(#"id="queue-primary""#))
        #expect(html.contains(#"id="queue-menu""#))
        #expect(html.contains(#"id="queue-badge""#))
        #expect(html.contains(#"id="steer-sheet""#))
        #expect(html.contains(#"id="steer-now""#))
        #expect(html.contains(#"id="steer-stop""#))
        #expect(css.contains("#queue-capsule"))
        #expect(css.contains("#queue-badge"))
    }

    @Test func remoteWebHandlesQueueStateMessage() throws {
        let js = try asset("app.js")

        #expect(js.contains(#"case "queueState""#))
        #expect(js.contains("function applyQueueState(msg)"))
        #expect(js.contains("let queueItems = [];"))
    }

    @Test func remoteWebDisplaysScheduledQueueDeadlines() throws {
        let js = try asset("app.js")

        #expect(js.contains("function queuedStatus(item)"))
        #expect(js.contains("Scheduled for"))
    }

    // Regression (review, task 6): pendingAttachments feeds hasText in
    // composerAction, but the mutation sites (attach picker, chip removal,
    // restoreRejectedPrompt) only ever called renderChips(), never
    // renderDriveBar() — so attaching or removing an image-only message's
    // photo could leave Send/Queue stuck hidden until some unrelated event
    // happened to recompute the button. renderChips is the common funnel for
    // all three mutations, so the fix lives there.
    @Test func renderChipsRecomputesComposerActionOnAttachmentChanges() throws {
        let js = try asset("app.js")

        let body = try #require(js.range(of: "function renderChips() {").map { js[$0.lowerBound...].prefix(900) })
        let closingBrace = try #require(body.range(of: "\n}"))
        #expect(body[..<closingBrace.lowerBound].contains("renderDriveBar(lastStreamingState);"))
    }

    // Regression (review, task 6): the CSS fix for `#queue-badge` (Finding 2)
    // styles the badges purely by id, and renderQueueBadges selects by id
    // too — so the `queue-badge` class on the badge spans no longer has any
    // reader and must not linger as a dead attribute implying a styling
    // mechanism that doesn't exist.
    @Test func badgeSpansDoNotCarryTheVestigialQueueBadgeClass() throws {
        let html = try asset("index.html")

        #expect(!html.contains(#"class="queue-badge hidden""#))
        #expect(html.contains(#"id="send-badge" class="hidden""#))
        #expect(html.contains(#"id="queue-badge" class="hidden""#))
    }

    @Test func remoteWebRendersQueuedBubblesOutsideTheTranscriptScroller() throws {
        let html = try asset("index.html")
        let js = try asset("app.js")
        let css = try asset("style.css")

        #expect(html.contains(#"<div id="queued" class="hidden"></div>"#))
        #expect(js.contains("function renderQueue()"))
        #expect(js.contains(#"el("div", "queued-bubble")"#))
        #expect(js.contains("function setQueuedOpen(id)"))
        #expect(js.contains("function queueAction(type, itemId)"))
        #expect(css.contains("#queued"))
        #expect(css.contains(".queued-bubble"))
        #expect(css.contains(".queued-actions"))
    }

    @Test func queuedBubblesDispatchEveryQueueVerb() throws {
        let js = try asset("app.js")

        #expect(js.contains(#""queueForceSend""#))
        #expect(js.contains(#""queueRemove""#))
        #expect(js.contains(#""queueRetry""#))
        #expect(js.contains(#""queueEdit""#))
        #expect(js.contains(#""queueClear""#))
        #expect(js.contains(#"case "queueEditRestored""#))
    }

    @Test func queuedBubblesHideEditWhenTheItemCarriesImages() throws {
        let js = try asset("app.js")
        #expect(js.contains("🖼"))
    }

    // Regression (codex review, PR #964): the web client must never offer an
    // action that would silently discard content it cannot represent. A
    // queued item with a resource/file mention is just as lossy to edit as
    // one with an image (the browser never gets the URI), so Edit must be
    // gated on BOTH counts and the resource chip must be visible so the
    // user can see why.
    @Test func queuedBubblesHideEditWhenTheItemCarriesResources() throws {
        let js = try asset("app.js")
        #expect(js.contains("if (item.imageCount === 0 && item.resourceCount === 0)"))
        #expect(js.contains("📎"))
        #expect(js.contains("queued-resources"))
    }

    // Regression (final branch review): native never renders a `.sending`
    // queue item (ACPTranscriptQueuePolicy.shouldRenderQueueBubble returns
    // false for it) — flushQueueIfIdle marks the head `.sending` while it's still in
    // session.queue, and sendNow records the same prompt into the
    // transcript, so a `.sending` bubble here would double-show that text
    // for the whole duration of the queued turn. renderQueue() must filter
    // `.sending` out before building any rows, not merely gate a row's
    // actions/status on it.
    @Test func sendingQueueItemsAreSkippedEntirely() throws {
        let js = try asset("app.js")
        let body = try #require(js.range(of: "function renderQueue() {").map { js[$0.lowerBound...].prefix(1250) })
        #expect(body.contains(#"const visible = queueItems.filter(i => i.status !== "sending");"#))
        #expect(body.contains("visible.forEach(item => box.appendChild(queuedRow(item)));"))
        #expect(!body.contains("queueItems.forEach(item => box.appendChild(queuedRow(item)));"))
        // queuedRow itself no longer branches on status — every row it builds
        // is implicitly `.pending` since renderQueue() filters upstream.
        #expect(!js.contains(#"item.status === "pending""#))
        #expect(!js.contains("is-sending"))
    }

    @Test func remoteWebShipsChangesAndFilesTabs() throws {
        let html = try asset("index.html")
        let sw = try asset("sw.js")

        #expect(html.contains(#"id="detail-tabs""#))
        #expect(html.contains(#"id="tab-chat""#))
        #expect(html.contains(#"id="tab-changes""#))
        #expect(html.contains(#"id="tab-files""#))
        #expect(html.contains(#"<section id="changes" class="view hidden">"#))
        #expect(html.contains(#"<section id="files" class="view hidden">"#))
        #expect(html.contains(#"id="changes-summary""#))
        #expect(html.contains(#"id="changes-refresh""#))
        #expect(html.contains(#"id="changes-list""#))
        #expect(html.contains(#"id="diff-rows""#))
        #expect(html.contains(#"id="file-list""#))
        #expect(html.contains(#"id="file-view-body""#))

        try expectLoadsBeforeApp("/changes-view.js", in: html)
        try expectLoadsBeforeApp("/file-browser.js", in: html)
        try expectReferencedAndPrecached("/changes-view.js", html: html, sw: sw)
        try expectReferencedAndPrecached("/file-browser.js", html: html, sw: sw)
    }

    @Test func remoteWebWiresTabSwitching() throws {
        let js = try asset("app.js")
        #expect(js.contains("function showTab(name)"))
        #expect(js.contains("const changesTree = RemoteFileBrowser.createTree();"))
        #expect(js.contains(#"type: "listChanges""#))
        #expect(js.contains(#"type: "listFiles""#))
    }

    @Test func remoteWebHandlesChangesAndFilesMessages() throws {
        let js = try asset("app.js")

        #expect(js.contains(#"case "changeList":"#))
        #expect(js.contains(#"case "changeListFailed":"#))
        #expect(js.contains(#"case "fileDiffResult":"#))
        #expect(js.contains(#"case "fileDiffFailed":"#))
        #expect(js.contains(#"case "fileTree":"#))
        #expect(js.contains(#"case "fileTreeFailed":"#))
        #expect(js.contains(#"case "fileContents":"#))
        #expect(js.contains(#"case "fileUnavailable":"#))
        #expect(js.contains("function renderChanges()"))
        #expect(js.contains("function renderDiff("))
        #expect(js.contains("function renderFileTree()"))
        #expect(js.contains("RemoteChangesView.diffRows("))
        #expect(js.contains("RemoteChangesView.formatSummary("))
    }

    @Test func remoteWebRefreshesChangesWhenATurnGoesIdle() throws {
        let js = try asset("app.js")
        #expect(js.contains("function noteStreamingStateForChanges(state)"))
        #expect(js.contains(#"activeTab !== "changes""#))
    }

    /// Regression: the Files tab had no way to invalidate a stale cached
    /// listing — once loaded, switching back to it (or an idle turn
    /// transition while it was open) never re-requested the tree, so an
    /// agent creating/deleting/renaming files left the tab showing the old
    /// tree for the rest of the session.
    @Test func remoteWebRefreshesFilesTreeOnReopenAndWhenATurnGoesIdle() throws {
        let js = try asset("app.js")
        #expect(js.contains("function refreshFileTree()"))
        // `showTab`'s files branch must unconditionally refresh on every
        // reopen, not just the first time (`needsChildren(null)`).
        let showTabBody = try #require(
            js.range(of: "function showTab(name) {").map { js[$0.lowerBound...].prefix(1200) })
        #expect(showTabBody.contains(#"if (name === "files") refreshFileTree();"#))
        // The old gate (only fetch the FIRST time this tab is opened) must
        // be gone from the live condition — a bare `needsChildren` check
        // isn't enough since the explanatory comment above mentions it too.
        #expect(!showTabBody.contains("changesTree.needsChildren"))
        // The idle-transition refresh (shared with Changes) must also cover
        // Files when that's the open tab.
        let idleBody = try #require(
            js.range(of: "function noteStreamingStateForChanges(state) {").map { js[$0.lowerBound...].prefix(500) })
        #expect(idleBody.contains(#"activeTab !== "files""#))
        let scheduleBody = try #require(
            js.range(of: "function scheduleListRefresh() {").map { js[$0.lowerBound...].prefix(700) })
        #expect(scheduleBody.contains("refreshFileTree()"))
    }

    /// Regression: `refreshFileTree()` used to send the root request AND
    /// every expanded descendant's request in the same synchronous burst,
    /// before the root response could prune a since-deleted/renamed
    /// directory from `expandedPaths()` — so a vanished nested directory's
    /// (now-invalid) request still went out, failing with `fileTreeFailed`
    /// and leaving a stale error banner over the freshly refreshed tree.
    /// Descendant requests must wait for the root response to be applied.
    @Test func remoteWebRequestsExpandedDescendantsOnlyAfterTheRootResponseIsApplied() throws {
        let js = try asset("app.js")
        #expect(js.contains("let pendingExpandedPathsRefresh = false;"))
        let refreshBody = try #require(
            js.range(of: "function refreshFileTree() {").map { js[$0.lowerBound...].prefix(300) })
        #expect(refreshBody.contains("pendingExpandedPathsRefresh = true;"))
        #expect(!refreshBody.contains("expandedPaths()"))
        let fileTreeBody = try #require(
            js.range(of: #"case "fileTree": {"#).map { js[$0.lowerBound...].prefix(3000) })
        let applyNodes = try #require(fileTreeBody.range(of: "changesTree.applyNodes("))
        let expandedPaths = try #require(fileTreeBody.range(of: "changesTree.expandedPaths()"))
        #expect(applyNodes.lowerBound < expandedPaths.lowerBound)
        let fileTreeFailedBody = try #require(
            js.range(of: #"case "fileTreeFailed":"#).map { js[$0.lowerBound...].prefix(300) })
        #expect(fileTreeFailedBody.contains("pendingExpandedPathsRefresh = false;"))
    }

    /// Regression: refreshing several expanded directories in one
    /// `refreshFileTree()` batch succeeds or fails per directory. The
    /// `fileTree` success handler used to unconditionally hide the shared
    /// error banner, so ONE sibling directory succeeding wiped out the
    /// error a DIFFERENT sibling's failure had just shown — leaving that
    /// failed directory's stale cached children on screen with no
    /// indication anything went wrong. The banner must only clear once
    /// every request in the batch has resolved AND none of them failed.
    @Test func remoteWebPreservesTheFileErrorBannerAcrossASiblingDirectorysSuccessInTheSameRefreshBatch() throws {
        let js = try asset("app.js")
        #expect(js.contains("let expandedPathsRefreshInFlight = 0;"))
        #expect(js.contains("let expandedPathsRefreshHadFailure = false;"))

        // The unconditional top-of-case hide (any successful `fileTree`
        // response, root or not, immediately clearing the banner) is gone.
        #expect(!js.contains("""
        $("file-error").classList.add("hidden");
              const treeKey = msg.path === undefined || msg.path === null ? "" : msg.path;
        """))

        let fileTreeBody = try #require(
            js.range(of: #"case "fileTree": {"#).map { js[$0.lowerBound...].prefix(3000) })
        // Replaced by a gate that gives up clearing unless every in-flight
        // sibling has resolved without a failure.
        #expect(fileTreeBody.contains("expandedPathsRefreshInFlight -= 1;"))
        #expect(fileTreeBody.contains("expandedPathsRefreshInFlight === 0 && !expandedPathsRefreshHadFailure"))
        #expect(fileTreeBody.contains("expandedPathsRefreshInFlight = expandedPaths.length;"))
        #expect(fileTreeBody.contains("expandedPathsRefreshHadFailure = false;"))

        let fileTreeFailedBody = try #require(
            js.range(of: #"case "fileTreeFailed":"#).map { js[$0.lowerBound...].prefix(500) })
        #expect(fileTreeFailedBody.contains("expandedPathsRefreshInFlight -= 1;"))
        #expect(fileTreeFailedBody.contains("expandedPathsRefreshHadFailure = true;"))
    }

    // Regression (final whole-branch review, finding 4): a `listChanges` per
    // idle DELTA (rather than per idle TRANSITION) can back up the gateway's
    // serialized per-connection message queue behind a burst of git
    // subprocess calls. The fix must edge-trigger on the transition into
    // idle AND debounce as defense in depth — either alone was flagged as
    // insufficient during the plan's self-review.
    @Test func remoteWebEdgeTriggersAndDebouncesTheIdleChangesRefresh() throws {
        let js = try asset("app.js")
        let body = try #require(
            js.range(of: "function noteStreamingStateForChanges(state) {")
                .map { js[$0.lowerBound...].prefix(800) }
        )
        #expect(body.contains("previousChangesStreamingState"))
        #expect(body.contains("wasIdle"))
        let scheduleBody = try #require(
            js.range(of: "function scheduleListRefresh() {")
                .map { js[$0.lowerBound...].prefix(400) }
        )
        #expect(scheduleBody.contains("setTimeout"))
        #expect(scheduleBody.contains("clearTimeout"))
        #expect(js.contains("let changesRefreshDebounceTimer = null;"))
    }

    /// Regression: an idle transition while a diff/file detail view is open
    /// used to be dropped entirely — `previousChangesStreamingState` was
    /// already updated to "idle" before the `detailStack` check, so no LATER
    /// edge would ever fire once the user closed the detail, leaving the
    /// list showing the pre-turn snapshot until a manual refresh or tab
    /// switch. The refresh must be deferred (not dropped) and delivered when
    /// the detail view closes.
    @Test func remoteWebDefersTheIdleRefreshUntilADetailViewCloses() throws {
        let js = try asset("app.js")
        #expect(js.contains("let pendingListRefresh = false;"))
        let idleBody = try #require(
            js.range(of: "function noteStreamingStateForChanges(state) {").map { js[$0.lowerBound...].prefix(500) })
        #expect(idleBody.contains("pendingListRefresh = true;"))
        let closeBody = try #require(
            js.range(of: "function closeDetailLevel() {").map { js[$0.lowerBound...].prefix(400) })
        #expect(closeBody.contains("pendingListRefresh"))
        #expect(closeBody.contains("scheduleListRefresh()"))
    }

    // Regression (sixth review pass, finding 4): the server's byte cap alone
    // does not bound the NUMBER of DOM rows `renderFileContents` creates — a
    // file near that cap made of many short lines can still produce enough
    // rows to freeze a phone browser. The client must cap rendered lines
    // separately and surface a distinct notice, since this can trip even
    // when the server reports `truncated: false`.
    @Test func remoteWebCapsTheNumberOfRenderedFileLines() throws {
        let js = try asset("app.js")
        let changesView = try asset("changes-view.js")

        #expect(js.contains("const MAX_RENDERED_FILE_LINES = 5000;"))
        #expect(js.contains("const linesTruncated = lines.length > MAX_RENDERED_FILE_LINES;"))
        #expect(js.contains(#"RemoteChangesView.truncationNotice(linesTruncated, "lines")"#))
        #expect(changesView.contains(#"if (kind === "lines") return "File truncated — too many lines to show.";"#))
    }

    @Test func detailTabsShowChangesCountBadge() throws {
        let html = try asset("index.html")
        let js = try asset("app.js")
        let css = try asset("style.css")

        #expect(html.contains(#"id="tab-changes-count""#))
        #expect(js.contains("function updateChangesTabBadge()"))
        #expect(js.contains(#"$("tab-changes-count")"#))
        #expect(css.contains(".tab-count"))
    }

    @Test func repoListHasSearchAndFilterChips() throws {
        let html = try asset("index.html")
        let js = try asset("app.js")
        let css = try asset("style.css")

        #expect(html.contains(#"id="repo-search""#))
        #expect(html.contains(#"id="repo-filters""#))
        #expect(html.contains(#"data-filter="all""#))
        #expect(html.contains(#"data-filter="running""#))
        #expect(html.contains(#"data-filter="dirty""#))

        #expect(js.contains(#"let repoSearchQuery = "";"#))
        #expect(js.contains(#"let repoActiveFilter = "all";"#))
        #expect(js.contains("function filterVisibleSections(sections)"))
        #expect(js.contains("RemoteRepoFilter.sectionMatchesFilter(section, repoActiveFilter)"))
        #expect(js.contains("RemoteRepoFilter.sectionMatchesQuery(section, repoSearchQuery)"))
        #expect(js.contains("function renderRepoFilterCounts(sections)"))
        #expect(js.contains("RemoteRepoFilter.sectionCounts(sections)"))
        #expect(js.contains(#"$("repo-search").addEventListener("input""#))

        #expect(css.contains("#repo-search"))
        #expect(css.contains("#repo-filters"))
        #expect(css.contains(".filter-chip"))
    }

    @Test func composerUsesModTokenAndRedesignedRadii() throws {
        let css = try asset("style.css")

        #expect(css.contains("--mod:"))
        #expect(css.contains("#composer-row { display: flex; gap: 8px; align-items: flex-end; }"))
        #expect(css.contains("#field { flex: 1; min-width: 0; min-height: 46px; border-radius: 14px;"))
    }

    // Regression (PR #1285 review): `session.updatedAt` is Unix
    // seconds on the wire (matches RemoteSessionSummary /
    // Date().timeIntervalSince1970 elsewhere in the app), but
    // RemoteRepoFilter.relativeTimeShort and Date.now() are milliseconds —
    // every session appeared ~53 years old until this converted units.
    @Test func sessionRecencyConvertsWireSecondsToMilliseconds() throws {
        let js = try asset("app.js")
        #expect(js.contains("return Number.isFinite(updatedAt) ? updatedAt * 1000 : Date.now();"))
    }

    // Regression (PR #1285 review): the primary-branch (home) icon
    // was keyed off `worktree.worktreeName` (a display name that can differ
    // from the actual checked-out branch) instead of `worktree.branch`.
    @Test func sessionCardIconChecksTheActualBranchField() throws {
        let js = try asset("app.js")
        #expect(js.contains("RemoteRepoFilter.worktreeIsPrimaryBranch(summary.branch)"))
        #expect(!js.contains("RemoteRepoFilter.worktreeIsPrimaryBranch(summary.worktreeName)"))
        #expect(!js.contains("RemoteRepoFilter.worktreeIsPrimaryBranch(worktree.worktreeName)"))
    }

    // Regression (PR #1285 review): the Changes tab badge was sourced
    // only from the session-list snapshot's `worktree.changedFileCount`,
    // which the gateway does not repush after an idle-turn edit — so the
    // badge could stay stale (including stuck hidden at zero) while the
    // Changes tab itself showed fresh files. It must prefer the loaded,
    // live `changesState` (kept current by every listChanges response) and
    // only fall back to the snapshot before that first load.
    @Test func changesTabBadgePrefersLiveChangeStateOverStaleSnapshot() throws {
        let js = try asset("app.js")
        let changesView = try asset("changes-view.js")

        #expect(js.contains("changesState.loaded && changesState.metricsAvailable"))
        #expect(js.contains("RemoteChangesView.changedFileCount(changesState)"))
        #expect(changesView.contains("function changedFileCount(state)"))
        #expect(changesView.contains("changedFileCount,"))
    }

    // Regression (PR #1285 review): a heavy add/delete imbalance
    // (e.g. 999 added, 1 deleted) rounded to 5 add-colored segments,
    // dropping the sole deleted line's segment entirely and contradicting
    // the function's own "each present side gets a segment" guarantee.
    @Test func diffBarSegmentsReservesASegmentForEachNonzeroSide() throws {
        let js = try asset("repo-filter.js")
        #expect(js.contains("const cap = deleted > 0 ? 4 : 5;"))
        #expect(js.contains("const addSegments = Math.min(cap, Math.max(added > 0 ? 1 : 0, Math.round((5 * added) / total)));"))
    }

    // Regression (PR #1285 review): the synthetic "Other" section
    // (sessions with no project/worktree) unconditionally bypassed search
    // and filter chips, so it stayed visible for any query and under the
    // Active/Dirty chips even when none of its sessions matched.
    @Test func otherSectionIsSubjectToSearchAndFilters() throws {
        let js = try asset("app.js")
        #expect(!js.contains("if (section.isOther) return true;"))
        let body = try #require(
            js.range(of: "function filterVisibleSections(sections) {").map { js[$0.lowerBound...].prefix(700) })
        #expect(body.contains("RemoteRepoFilter.sectionMatchesFilter(section, repoActiveFilter)"))
        #expect(body.contains("RemoteRepoFilter.sectionMatchesQuery(section, repoSearchQuery)"))
    }

    // Regression (PR #1285 review): the idle-transition list refresh only
    // ran while the Changes or Files tab was open, so the Changes badge
    // (visible on every tab) kept showing the stale pre-turn count whenever
    // an agent edited files while the default Chat tab was selected.
    @Test func idleRefreshAlsoCoversTheChatTabForTheBadge() throws {
        let js = try asset("app.js")

        let noteBody = try #require(
            js.range(of: "function noteStreamingStateForChanges(state) {").map { js[$0.lowerBound...].prefix(400) })
        #expect(noteBody.contains(#"activeTab !== "changes" && activeTab !== "files" && activeTab !== "chat""#))

        let scheduleBody = try #require(
            js.range(of: "function scheduleListRefresh() {").map { js[$0.lowerBound...].prefix(700) })
        #expect(scheduleBody.contains(#"activeTab === "changes" || activeTab === "chat""#))
    }

    // Regression (PR #1329 review, chatgpt-codex-connector): sessionList is a
    // pure pull snapshot — the gateway never pushes one when a session's
    // streaming state changes elsewhere (another tab, another device, or a
    // turn this client started and navigated away from) — so the Running
    // filter, per-worktree status dot, and run-state pips would otherwise
    // freeze at whatever they were when the list was last fetched.
    @Test func sessionListPollsWhileTheRepoListIsVisible() throws {
        let js = try asset("app.js")

        #expect(js.contains("const SESSION_LIST_POLL_MS = 15 * 1000;"))
        let body = try #require(
            js.range(of: "const SESSION_LIST_POLL_MS").map { js[$0.lowerBound...].prefix(300) })
        #expect(body.contains("setInterval("))
        #expect(body.contains(#"if ($("sessions").classList.contains("hidden")) return;"#))
        #expect(body.contains(#"send({ type: "listSessions" });"#))
    }

    // Regression (PR #1285 review): a truncated changesState (worktrees
    // over the server's changed-file cap) made the badge show the capped
    // array length as if it were the exact total. changedFileCount is the
    // server's untruncated unique-path count and must win once truncated.
    // Regression (PR #1285 review): the worktree summary (working-tree
    // status) and the change list (diff against the comparison ref) are
    // different git computations, so swapping in the summary's count when
    // changesState.truncated is set could show a number from an unrelated
    // scope — including zero on an otherwise clean branch with hundreds of
    // committed changes. A truncated live count must stay in its own scope,
    // marked "N+" rather than presented as exact or replaced outright.
    @Test func changesTabBadgeMarksATruncatedCountRatherThanSubstitutingAnUnrelatedTotal() throws {
        let js = try asset("app.js")
        let body = try #require(
            js.range(of: "function updateChangesTabBadge() {").map { js[$0.lowerBound...].prefix(1450) })
        #expect(body.contains("count = RemoteChangesView.changedFileCount(changesState);"))
        #expect(body.contains(#"suffix = changesState.truncated ? "+" : "";"#))
        #expect(body.contains("badge.textContent = String(count) + suffix;"))
    }

    // Regression (PR #1285 review): reconnecting while Chat was the active
    // tab left changesState at its stale pre-disconnect value — the reconnect
    // replay only requested changes for the Changes tab, so edits made
    // during the outage never reached the badge until another turn or a
    // manual tab switch.
    @Test func reconnectReplayAlsoCoversTheChatTab() throws {
        let js = try asset("app.js")
        let body = try #require(
            js.range(of: "function replayActiveListRequest() {").map { js[$0.lowerBound...].prefix(500) })
        #expect(body.contains(#"activeTab === "changes" || activeTab === "chat""#))
    }

    // Regression (PR #1285 review): an acknowledged rename only updated
    // sessionTitles and the live DOM, leaving the cached listedSessions
    // entry (renderSessions()'s only source of truth) on the old title —
    // any full rerender before the gateway's own sessionList refresh
    // landed would visibly revert the rename.
    @Test func sessionRenameUpdatesTheCachedListedSessionsEntry() throws {
        let js = try asset("app.js")
        let body = try #require(
            js.range(of: "function applySessionRenamed(sessionId, title) {").map { js[$0.lowerBound...].prefix(700) })
        #expect(body.contains("const cached = listedSessions.get(sessionId);"))
        #expect(body.contains("if (cached) cached.title = title;"))
    }

    // Regression (PR #1285 review): opening a session straight to the
    // default Chat tab never requested the change list, so the badge
    // stayed sourced from the session summary's working-tree-only count
    // (a different scope from what the Changes tab itself shows) until
    // some other trigger — a turn, a reconnect, a tab switch — refreshed it.
    @Test func openingASessionRequestsChangesForTheBadgesScope() throws {
        let js = try asset("app.js")
        let body = try #require(
            js.range(of: "function openSession(id) {").map { js[$0.lowerBound...].prefix(2000) })
        #expect(body.contains("if (summary && summary.worktree) requestChanges();"))
    }

    // Regression (PR #1285 review): a failed listChanges request set
    // changesState.loaded = true (correctly, to stop showing "Loading
    // changes…") while leaving files/staged/unstaged at their initialized
    // empty arrays — the badge then read that as a genuine zero and
    // replaced a valid worktree-summary count with a hidden badge. Track
    // failure separately so the badge keeps using the summary fallback.
    @Test func changesTabBadgeKeepsTheSummaryFallbackAfterAFailedLoad() throws {
        let js = try asset("app.js")

        let failedBody = try #require(
            js.range(of: #"case "changeListFailed":"#).map { js[$0.lowerBound...].prefix(250) })
        #expect(failedBody.contains("changesState.failed = true;"))

        let badgeBody = try #require(
            js.range(of: "function updateChangesTabBadge() {").map { js[$0.lowerBound...].prefix(1200) })
        #expect(badgeBody.contains("changesState.loaded && changesState.metricsAvailable && !changesState.failed"))
    }

    @Test func remoteWebLoadsAndPrecachesTheHubModules() throws {
        let html = try asset("index.html")
        let sw = try asset("sw.js")
        let registry = try asset("hub-registry.js")
        let links = try asset("hub-links.js")

        try expectLoadsBeforeApp("/hub-registry.js", in: html)
        try expectLoadsBeforeApp("/hub-links.js", in: html)
        try expectReferencedAndPrecached("/hub-registry.js", html: html, sw: sw)
        try expectReferencedAndPrecached("/hub-links.js", html: html, sw: sw)
        // hub-links derives counts through the registry, so it must load second.
        let registryAt = try referencePosition(of: "/hub-registry.js", in: html)
        let linksAt = try referencePosition(of: "/hub-links.js", in: html)
        #expect(registryAt < linksAt)
        #expect(registry.contains("globalThis.RemoteHubRegistry ="))
        #expect(links.contains("globalThis.RemoteHubLinks ="))
        // Pure modules: no DOM access.
        #expect(!registry.contains("document."))
        #expect(!links.contains("document."))
    }

    @Test func serviceWorkerIgnoresCrossOriginRequests() throws {
        let sw = try asset("sw.js")
        let fetchHandler = try #require(sw.range(of: #"self.addEventListener("fetch""#).map { sw[$0.lowerBound...].prefix(600) })
        #expect(fetchHandler.contains("if (url.origin !== self.location.origin) return;"))
    }

    @Test func appDrivesTheActiveLinkThroughTheHubModules() throws {
        let js = try asset("app.js")

        #expect(js.contains("const hub = RemoteHubRegistry.load(localStorage, location.origin, location.hostname, Date.now());"))
        #expect(js.contains("const links = RemoteHubLinks.createLinks({"))
        #expect(js.contains("function send(obj) { links.sendActive(obj); }"))
        #expect(js.contains("function handleLinkStateChange(link)"))
        #expect(js.contains("function handleLinkHello(link, hello)"))
        #expect(js.contains("function onActiveOpen()"))
        #expect(js.contains("function onActiveClose()"))
        #expect(js.contains("function pairAndAdd(input, options)"))
        #expect(js.contains("function resetServerScopedState()"))
        #expect(js.contains("function switchServer(id)"))
        #expect(js.contains("function applyHubFlag(enabled)"))
        #expect(js.contains(#"document.addEventListener("visibilitychange""#))
        // The single-socket client is gone: the only WebSocket construction
        // is the factory handed to the link manager; no token key, no
        // page-level reconnect timer.
        #expect(js.components(separatedBy: "new WebSocket(").count == 2)
        #expect(js.contains("createSocket: (url, protocols) => new WebSocket(url, protocols),"))
        #expect(!js.contains(#"const tokenKey = "alas.remote.token";"#))
        #expect(!js.contains("function scheduleReconnect()"))
        #expect(!js.contains("async function ensureToken()"))
        #expect(!js.contains(#"fetch("/pair""#))
    }

    // The old ?code= flow must survive: a scanned QR (re)pairs and strips the
    // code from the URL before anything else happens.
    @Test func bootStillHonoursAPairingCodeInTheURL() throws {
        let js = try asset("app.js")
        let boot = try #require(js.range(of: "function boot() {").map { js[$0.lowerBound...].prefix(1200) })
        #expect(boot.contains("RemoteHubRegistry.parsePairingLink(location.href)"))
        #expect(boot.contains(#"history.replaceState({}, "", "/");"#))
        #expect(boot.contains("pairAndAdd(fromLink, { activate: true })"))
    }

    @Test func settingsTabRendersTheHubServerList() throws {
        let html = try asset("index.html")
        let js = try asset("app.js")
        let css = try asset("style.css")

        #expect(html.contains(#"<div id="hub-section" class="hidden">"#))
        #expect(html.contains(#"id="server-list""#))
        #expect(html.contains(#"id="add-server""#))
        #expect(html.contains(#"id="settings-placeholder""#))
        #expect(html.contains(#"id="tab-settings-badge" class="tab-count hidden""#))
        #expect(html.contains(#"id="add-server-sheet" class="sheet hidden" role="dialog""#))
        #expect(html.contains(#"id="add-server-link""#))
        #expect(html.contains(#"id="add-server-address""#))
        #expect(html.contains(#"id="add-server-code""#))
        #expect(html.contains(#"id="add-server-error" class="sheet-error hidden""#))
        #expect(html.contains(#"id="server-actions-sheet" class="sheet hidden" role="dialog""#))
        #expect(html.contains(#"id="server-repair""#))
        #expect(html.contains(#"id="server-forget""#))
        #expect(html.contains(#"id="gate-pair" class="hidden""#))

        #expect(js.contains("function renderServerList()"))
        #expect(js.contains("function renderSettingsBadge()"))
        #expect(js.contains("function showAddServerSheet(targetId)"))
        #expect(js.contains("async function submitAddServer()"))
        #expect(js.contains("function forgetServer(id)"))
        #expect(js.contains("RemoteHubRegistry.otherAttentionTotal(links.all(), hub.activeId)"))
        #expect(js.contains(#"$("tab-settings").disabled = !enabled;"#))
        #expect(js.contains(#"$("status").onclick = () => { if (hubUIEnabled && !currentSession) showSettings(); };"#))

        #expect(css.contains(".server-row {"))
        #expect(css.contains(".server-row.is-active"))
        #expect(css.contains("#tab-settings-badge"))
        #expect(css.contains(".dot.off"))
        #expect(css.contains(".dot.warn"))
    }

    // Flag off must look exactly like today: the tab stays disabled and no
    // server row is ever rendered.
    @Test func hubSurfacesStayHiddenUntilTheFlagIsOn() throws {
        let html = try asset("index.html")
        let js = try asset("app.js")
        #expect(html.contains(#"id="tab-settings" class="bt-tab" aria-label="Settings" disabled"#))
        let body = try #require(js.range(of: "function applyHubFlag(enabled) {").map { js[$0.lowerBound...].prefix(600) })
        #expect(body.contains(#"$("hub-section").classList.toggle("hidden", !enabled);"#))
        #expect(body.contains(#"$("settings-placeholder").classList.toggle("hidden", enabled);"#))
        #expect(body.contains("if (enabled) links.connectAll(); else links.disableIdle();"))
    }

    // Regression (Codex review, PR #1337): forgetServer's non-active branch
    // used to only re-render, never recomputing the aggregate hub flag — so
    // forgetting the one server that had ever reported hubEnabled, while it
    // was inactive, left the hub UI stuck on with no server authorizing it.
    @Test func forgettingAnInactiveServerRecomputesTheAggregateHubFlag() throws {
        let js = try asset("app.js")
        let body = try #require(js.range(of: "function forgetServer(id) {").map { js[$0.lowerBound...].prefix(700) })
        #expect(body.contains("if (!wasActive) {"))
        #expect(body.contains("applyHubFlag(anyServerHasHubEnabled());"))
        #expect(!body.contains("if (!wasActive) { refreshHubViews(); return; }"))
    }

    // Regression (Codex review, PR #1337): a disallowed cross-origin /pair
    // request answered with a bare 403 — no Access-Control-Allow-Origin —
    // so the browser surfaced an opaque CORS network error instead of a
    // readable 403, and hub-links.js's pair() could never distinguish
    // "this origin isn't allowed" from "unreachable."
    @Test func originRejectionIsCORSReadableSoPairCanDistinguishItFromUnreachable() throws {
        // The server-side fix lives in RemoteConnection.swift, outside this
        // web-asset bundle; RemoteConnectionOriginRejectionTests covers it
        // directly. This test only pins the client-side contract the fix
        // exists to satisfy: `pair()` must branch on `res.status === 403`.
        let js = try asset("hub-links.js")
        #expect(js.contains(#"res.status === 403"#))
    }

    // Regression (Codex review, PR #1337): setVisible() used to reconnect
    // every idle link on a visibility change regardless of whether the hub
    // was actually enabled, so backgrounding and foregrounding the page
    // while the flag was off resurrected the idle sockets disableIdle()
    // had just suspended.
    @Test func idleLinksStaySuspendedAcrossAVisibilityCycleWhileTheHubIsOff() throws {
        let js = try asset("hub-links.js")
        #expect(js.contains("let idleAllowed = false;"))
        #expect(js.contains("function disableIdle() {"))
        let setVisible = try #require(js.range(of: "function setVisible(next) {").map { js[$0.lowerBound...].prefix(900) })
        #expect(setVisible.contains(#"if (link.role !== "active" && !idleAllowed) continue;"#))
    }

    // Regression (Codex review, PR #1337): adopt() promoted a fallback
    // origin only in memory — the registry's own lastOrigin was never
    // updated, so a page reload retried the dead remembered origin first
    // again and paid its full handshake timeout before falling through.
    @Test func adoptingAFallbackOriginPersistsItToTheRegistry() throws {
        let js = try asset("hub-links.js")
        #expect(js.contains("onOriginChange(link, origin)"))
        let adopt = try #require(js.range(of: "function adopt(link, socket, origin) {").map { js[$0.lowerBound...].prefix(700) })
        #expect(adopt.contains("if (link.lastOrigin !== origin && h.onOriginChange) h.onOriginChange(link, origin);"))
        let appJS = try asset("app.js")
        #expect(appJS.contains("onOriginChange: (link, origin) => {"))
        #expect(appJS.contains("RemoteHubRegistry.setLastOrigin(hub, link.id, origin);"))
    }

    // Regression (Codex review, PR #1337): when a hello reveals that a link
    // duplicates an already-paired server, handleLinkHello merged the two
    // registry entries and returned before recomputing the aggregate hub
    // flag — so a surviving entry whose fresh hello reported hubEnabled:
    // false could leave the hub UI stuck on with nothing left authorizing it.
    @Test func mergingADuplicateLinkRecomputesTheAggregateHubFlag() throws {
        let js = try asset("app.js")
        let body = try #require(js.range(of: "function handleLinkHello(link, hello) {").map { js[$0.lowerBound...].prefix(700) })
        #expect(body.contains("applyHubFlag(anyServerHasHubEnabled());"))
        let flagIndex = try #require(body.range(of: "applyHubFlag(anyServerHasHubEnabled());"))
        let mergeIndex = try #require(body.range(of: "if (result.mergedFromId) {"))
        #expect(flagIndex.lowerBound < mergeIndex.lowerBound, "the aggregate flag must be recomputed before the merge branch's early return")
    }

    // Regression (Codex review, PR #1337): every pairing link advertises
    // "localhost" alongside a server's real addresses, so two different Macs
    // used to collide on that shared origin and pairing the second silently
    // overwrote the first's registry entry. See hub-registry.js's
    // upsertPaired / isLoopbackOrigin and the matching node-executed
    // coverage in scripts/tests/remote-web-hub/test-hub-registry.js.
    @Test func pairingDedupIgnoresTheSharedLocalhostOrigin() throws {
        let js = try asset("hub-registry.js")
        #expect(js.contains("function isLoopbackOrigin(origin)"))
        let body = try #require(js.range(of: "function upsertPaired(doc, { origins, token, now }) {").map { js[$0.lowerBound...].prefix(500) })
        #expect(body.contains("const matchable = normalized.filter((o) => !isLoopbackOrigin(o));"))
    }

    // Regression (Codex review, PR #1337): a non-loopback origin can also be
    // reused (a DHCP-reassigned LAN address, a shared custom hostname), so
    // origin overlap must stop being trusted once an entry has confirmed its
    // identity via hello. See test-hub-registry.js for the node-executed
    // reconciliation coverage.
    @Test func pairingDedupOnlyMatchesServersNotYetIdentifiedByHello() throws {
        let js = try asset("hub-registry.js")
        let body = try #require(js.range(of: "function upsertPaired(doc, { origins, token, now }) {").map { js[$0.lowerBound...].prefix(500) })
        #expect(body.contains("doc.servers.find((s) => !s.serverId && s.origins.some((o) => !isLoopbackOrigin(o) && matchable.includes(o)))"))
    }

    // Regression (Codex review, PR #1337): probe() collapsed every non-2xx
    // /health response — including a 403 origin rejection — into
    // "unreachable," so a Mac that was online but rejecting this address
    // looked identical to an offline one and retried forever instead of
    // surfacing the allowlist remediation.
    @Test func originRejectionDuringHealthProbeSurfacesAsBlockedNotOffline() throws {
        let links = try asset("hub-links.js")
        #expect(links.contains(#"state: "idle"|"connecting"|"online"|"offline"|"unauthorized"|"blocked""#))
        #expect(links.contains("blocked: statuses.some((s) => s === 403),"))
        let onAllFailed = try #require(links.range(of: "function onAllOriginsFailed(link, order, attempt) {").map { links[$0.lowerBound...].prefix(400) })
        #expect(onAllFailed.contains(#"if (blocked) { setState(link, "blocked"); return; }"#))

        let app = try asset("app.js")
        #expect(app.contains("function showOriginBlockedGate(link) {"))
        let stateChange = try #require(app.range(of: "function handleLinkStateChange(link) {").map { app[$0.lowerBound...].prefix(700) })
        #expect(stateChange.contains(#"case "blocked":"#))
        #expect(stateChange.contains("showOriginBlockedGate(link);"))
        let switchServer = try #require(app.range(of: "function switchServer(id) {").map { app[$0.lowerBound...].prefix(900) })
        #expect(switchServer.contains(#"if (link.state === "blocked") { showOriginBlockedGate(link); return; }"#))
    }
}
