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
        #expect(app.contains(#"toggle.append(el("span", "tool-glyph", toolGlyph(verb)))"#))
        #expect(app.contains(#"preview || toolCollapsedPreview(tc)"#))
        #expect(css.contains(".tool-glyph"))
        #expect(css.contains(".tool-toggle"))
    }

    @Test func remoteSessionOrderingAssetsAreLoadedAndCached() throws {
        let html = try asset("index.html")
        let sw = try asset("sw.js")

        #expect(html.contains(#"/session-ordering.js?v=1"#))
        #expect(html.range(of: #"/session-ordering.js?v=1"#)!.lowerBound < html.range(of: #"/app.js?v=64"#)!.lowerBound)
        #expect(html.contains(#"/app.js?v=64"#))
        #expect(html.contains(#"/style.css?v=42"#))
        #expect(sw.contains(#"const CACHE_NAME = "alas-remote-shell-v42";"#))
        #expect(sw.contains(#""/session-ordering.js?v=1""#))
        #expect(sw.contains(#""/app.js?v=64""#))
        #expect(sw.contains(#""/style.css?v=42""#))
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
        #expect(html.contains(#"/app.js?v=64"#))
        #expect(html.contains(#"/style.css?v=42"#))
        #expect(sw.contains(#"const CACHE_NAME = "alas-remote-shell-v42";"#))
        #expect(sw.contains(#""/app.js?v=64""#))
        #expect(sw.contains(#""/style.css?v=42""#))
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
        #expect(app.contains("RemoteSessionOrdering.groupSessions(sessions)"))
        #expect(app.contains("listedSessions.set(session.id, session);"))
        #expect(app.contains("renderSessions([...listedSessions.values()]);"))
        #expect(app.contains("session-section-title"))
        #expect(app.contains("s.worktree.worktreeName"))
        #expect(app.contains(#""session-row-active""#))
        #expect(app.contains(#""session-row-inactive""#))
        #expect(app.contains(#""Active""#))
        #expect(app.contains(#""Closed""#))
        #expect(app.contains(#""changes unavailable""#))
        #expect(app.contains(#""clean""#))
        #expect(css.contains(".session-row-card"))
        #expect(css.contains(".session-row-active"))
        #expect(css.contains(".session-row-inactive"))
        #expect(css.contains(".session-state-active"))
        #expect(css.contains(".session-state-inactive"))
        #expect(css.contains(".session-meta"))
        #expect(css.contains(".session-section"))
        #expect(css.contains(".session-section-title"))
        #expect(css.contains(".session-section-list"))
        #expect(html.contains("/app.js?v=64"))
        #expect(html.contains("/style.css?v=42"))
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
        #expect(sw.contains(#""/app.js?v=64""#))
        #expect(sw.contains(#""/style.css?v=42""#))
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

    @Test func remoteWebIntegratesWorktreeCreationController() throws {
        let html = try asset("index.html")
        let js = try asset("app.js")
        let creation = try asset("worktree-creation.js")
        let sw = try asset("sw.js")

        #expect(html.contains(#"/worktree-creation.js?v=1"#))
        #expect(html.range(of: #"/worktree-creation.js?v=1"#)!.lowerBound < html.range(of: #"/app.js?v=64"#)!.lowerBound)
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
        #expect(sw.contains(#""/worktree-creation.js?v=1""#))
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
        #expect(css.contains(#"#new-session { font-size: 0;"#))
        #expect(css.contains(#"#new-session::before { content: "+";"#))
        #expect(css.contains("#status.chip { font-size: 0;"))
        #expect(css.contains("#status.chip::before"))
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

    @Test func incrementalTranscriptBustsServiceWorkerAssetCache() throws {
        let sw = try asset("sw.js")
        let html = try asset("index.html")
        #expect(sw.contains("alas-remote-shell-v42"))
        #expect(sw.contains("/app.js?v=64"))
        #expect(html.contains("app.js?v=64"))
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
        #expect(js.contains("let steerUndoAvailable = false;"))
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

    @Test func queueParityBustsServiceWorkerAssetCache() throws {
        let html = try asset("index.html")
        let sw = try asset("sw.js")

        #expect(html.contains(#"/app.js?v=64"#))
        #expect(html.contains(#"/style.css?v=42"#))
        #expect(sw.contains(#"const CACHE_NAME = "alas-remote-shell-v42";"#))
        #expect(sw.contains(#""/app.js?v=64""#))
        #expect(sw.contains(#""/style.css?v=42""#))
    }

    @Test func remoteWebOffersUndoAfterASteerDiscardsTheQueue() throws {
        let js = try asset("app.js")
        let css = try asset("style.css")

        #expect(js.contains("function steerUndoToast()"))
        #expect(js.contains(#""queueSteerUndo""#))
        #expect(js.contains("Queue cleared by steer"))
        #expect(css.contains(".steer-undo"))
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

        #expect(html.contains(#"/changes-view.js?v=1"#))
        #expect(html.contains(#"/file-browser.js?v=1"#))
        #expect(html.range(of: #"/changes-view.js?v=1"#)!.lowerBound
            < html.range(of: #"/app.js?v=64"#)!.lowerBound)
        #expect(html.range(of: #"/file-browser.js?v=1"#)!.lowerBound
            < html.range(of: #"/app.js?v=64"#)!.lowerBound)
        #expect(sw.contains(#""/changes-view.js?v=1""#))
        #expect(sw.contains(#""/file-browser.js?v=1""#))
    }

    @Test func remoteWebWiresTabSwitching() throws {
        let js = try asset("app.js")
        #expect(js.contains("function showTab(name)"))
        #expect(js.contains("const changesTree = RemoteFileBrowser.createTree();"))
        #expect(js.contains(#"type: "listChanges""#))
        #expect(js.contains(#"type: "listFiles""#))
    }
}
