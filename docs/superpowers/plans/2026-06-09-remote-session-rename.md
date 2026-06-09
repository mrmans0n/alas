# Remote Session Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any paired Alas Remote client rename ACP sessions from the sessions list and the session detail screen.

**Architecture:** Add a focused remote protocol verb for rename, route it through `RemoteSessionGateway` to `RemoteSessionsProvider`, and have `AppState` apply the same manual-title semantics as the native rename flow. The remote web client owns the mobile UI and receives a `sessionRenamed` push to keep an open detail title in sync.

**Tech Stack:** Swift 5.9, Swift Testing, SwiftUI/AppKit host app, bundled vanilla JavaScript/CSS remote client.

---

## File Structure

- `Alas/Sources/Remote/Protocol/RemoteProtocol.swift`: Add client/server wire cases and Codable handling.
- `Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift`: Add provider rename API.
- `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift`: Handle rename requests and emit `sessionRenamed`.
- `Alas/Sources/Center/TabsManager.swift`: Add helper to rename all ACP tabs that reference a session id.
- `Alas/Sources/App/AppState.swift`: Implement provider rename by finding the owning manager, materializing if needed, renaming as `.manual`, and syncing tabs.
- `Alas/Resources/RemoteWeb/index.html`: Add detail title, rename sheet, and cache-bust asset versions.
- `Alas/Resources/RemoteWeb/app.js`: Add rename state, list/detail actions, sheet behavior, and wire messages.
- `Alas/Resources/RemoteWeb/style.css`: Style edit buttons, detail title, and rename sheet field.
- `Alas/Resources/RemoteWeb/sw.js`: Cache-bust remote assets.
- `AlasTests/Remote/RemoteProtocolTests.swift`: Round-trip protocol coverage.
- `AlasTests/Remote/RemoteSessionGatewayTests.swift`: Gateway behavior with fake provider.
- `AlasTests/TabsManagerTests.swift`: ACP tab rename helper behavior.
- `AlasTests/Remote/RemoteAppStateAccessTests.swift`: Provider-level AppState rename sync behavior.
- `AlasTests/Remote/RemoteWebAssetTests.swift`: Static asset coverage for remote controls/messages/cache-bust versions.

---

### Task 1: Remote Protocol And Gateway Rename

**Files:**
- Modify: `Alas/Sources/Remote/Protocol/RemoteProtocol.swift`
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift`
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift`
- Modify: `AlasTests/Remote/RemoteProtocolTests.swift`
- Modify: `AlasTests/Remote/RemoteSessionGatewayTests.swift`

- [ ] **Step 1: Write failing protocol tests**

Add these tests to `RemoteProtocolTests` near the other client/server round-trip tests:

```swift
@Test func clientRenameSessionRoundTrips() throws {
    let msg = RemoteClientMessage.renameSession(sessionId: "s1", title: "Build feature")
    #expect(try roundTrip(msg) == msg)
}

@Test func clientRenameSessionDecodes() throws {
    let json = #"{"type":"renameSession","sessionId":"s1","title":"Build feature"}"#
    let msg = try JSONDecoder().decode(RemoteClientMessage.self, from: Data(json.utf8))
    #expect(msg == .renameSession(sessionId: "s1", title: "Build feature"))
}

@Test func sessionRenamedRoundTrips() throws {
    let msg = RemoteServerMessage.sessionRenamed(sessionId: "s1", title: "Build feature")
    #expect(try roundTrip(msg) == msg)
}
```

- [ ] **Step 2: Write failing gateway tests**

Update `FakeSessionsProvider` in `RemoteSessionGatewayTests` with the intended fake API before production supports it:

```swift
var renamed: [(id: String, title: String)] = []
var renameSucceeds = true
func renameSession(for id: String, title: String) -> Bool {
    renamed.append((id, title))
    return renameSucceeds
}
```

Add these tests to `RemoteSessionGatewayTests` near the config verb tests:

```swift
@Test func renameSessionTrimsTitleDoesNotRequireWriterAndRefreshesList() async {
    let provider = FakeSessionsProvider()
    provider.summaries = [RemoteSessionSummary(id: "s1", title: "Renamed", agentId: "claude", status: "idle", canDrive: false)]
    var sent: [RemoteServerMessage] = []
    let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

    await gw.handle(.renameSession(sessionId: "s1", title: "  Renamed  "))
    await Task.yield()

    #expect(provider.renamed.map(\.id) == ["s1"])
    #expect(provider.renamed.map(\.title) == ["Renamed"])
    #expect(sent.contains(.sessionRenamed(sessionId: "s1", title: "Renamed")))
    #expect(sent.contains(.sessionList(sessions: provider.summaries)))
    #expect(provider.sessionSummariesCallCount == 1)
}

@Test func renameSessionIgnoresEmptyTitle() async {
    let provider = FakeSessionsProvider()
    var sent: [RemoteServerMessage] = []
    let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

    await gw.handle(.renameSession(sessionId: "s1", title: " \n\t "))
    await Task.yield()

    #expect(provider.renamed.isEmpty)
    #expect(sent.isEmpty)
}

@Test func renameSessionFailureEmitsError() async {
    let provider = FakeSessionsProvider()
    provider.renameSucceeds = false
    var sent: [RemoteServerMessage] = []
    let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

    await gw.handle(.renameSession(sessionId: "missing", title: "Name"))
    await Task.yield()

    #expect(provider.renamed == [(id: "missing", title: "Name")])
    #expect(sent.contains { if case .error(let message) = $0 { return message.contains("rename") } else { return false } })
}
```

- [ ] **Step 3: Run red tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteProtocolTests -only-testing:AlasTests/RemoteSessionGatewayTests test
```

Expected: FAIL because `renameSession`, `sessionRenamed`, and the provider API do not exist yet.

- [ ] **Step 4: Implement protocol cases**

In `RemoteClientMessage`, add:

```swift
case renameSession(sessionId: String, title: String)
```

Extend its `CodingKeys` with `title`, decode:

```swift
case "renameSession":
    self = .renameSession(
        sessionId: try c.decode(String.self, forKey: .sessionId),
        title: try c.decode(String.self, forKey: .title))
```

Encode:

```swift
case .renameSession(let id, let title):
    try c.encode("renameSession", forKey: .type)
    try c.encode(id, forKey: .sessionId)
    try c.encode(title, forKey: .title)
```

In `RemoteServerMessage`, add:

```swift
case sessionRenamed(sessionId: String, title: String)
```

Extend server `CodingKeys` with `title`, decode:

```swift
case "sessionRenamed":
    self = .sessionRenamed(
        sessionId: try c.decode(String.self, forKey: .sessionId),
        title: try c.decode(String.self, forKey: .title))
```

Encode:

```swift
case .sessionRenamed(let id, let title):
    try c.encode("sessionRenamed", forKey: .type)
    try c.encode(id, forKey: .sessionId)
    try c.encode(title, forKey: .title)
```

- [ ] **Step 5: Implement provider API and gateway handling**

Add to `RemoteSessionsProvider`:

```swift
func renameSession(for id: String, title: String) -> Bool
```

Add this case to `RemoteSessionGateway.handle(_:)`:

```swift
case .renameSession(let id, let title):
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard provider.renameSession(for: id, title: trimmed) else {
        send(.error(message: "Could not rename session."))
        return
    }
    send(.sessionRenamed(sessionId: id, title: trimmed))
    refreshSessionList()
```

- [ ] **Step 6: Run green tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteProtocolTests -only-testing:AlasTests/RemoteSessionGatewayTests test
```

Expected: PASS for the touched test suites.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Remote/Protocol/RemoteProtocol.swift Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift AlasTests/Remote/RemoteProtocolTests.swift AlasTests/Remote/RemoteSessionGatewayTests.swift
git commit -m "feat(remote): add session rename protocol"
```

---

### Task 2: TabsManager ACP Session Rename Helper

**Files:**
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Modify: `AlasTests/TabsManagerTests.swift`

- [ ] **Step 1: Write failing TabsManager tests**

Add these tests after the existing ACP/session rename-related tests in `TabsManagerTests`:

```swift
@Test func renamingACPSessionTabsBySessionIdUpdatesAllMatchingTabsAndTrims() {
    let worktreeId = "tabs-manager-rename-acp-by-session"
    defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
    let mgr = TabsManager()
    _ = mgr.append(acpSession: ACPSessionTabState(sessionId: "s1", title: "Old A"), to: worktreeId)
    _ = mgr.append(acpSession: ACPSessionTabState(sessionId: "s2", title: "Other"), to: worktreeId)
    _ = mgr.append(acpSession: ACPSessionTabState(sessionId: "s1", title: "Old B"), to: worktreeId)

    let count = mgr.renameACPSessionTabs(worktreeId: worktreeId, sessionId: "s1", title: "  Renamed  ")

    #expect(count == 2)
    let titles = mgr.tabs(forWorktree: worktreeId).map(\.title)
    #expect(titles == ["Renamed", "Other", "Renamed"])
}

@Test func renamingACPSessionTabsBySessionIdRejectsEmptyTitle() {
    let worktreeId = "tabs-manager-rename-acp-by-session-empty"
    defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
    let mgr = TabsManager()
    _ = mgr.append(acpSession: ACPSessionTabState(sessionId: "s1", title: "Old"), to: worktreeId)

    let count = mgr.renameACPSessionTabs(worktreeId: worktreeId, sessionId: "s1", title: "   ")

    #expect(count == 0)
    #expect(mgr.tabs(forWorktree: worktreeId).first?.title == "Old")
}
```

- [ ] **Step 2: Run red tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/TabsManagerTests test
```

Expected: FAIL because `renameACPSessionTabs(worktreeId:sessionId:title:)` does not exist.

- [ ] **Step 3: Implement helper**

Add this method near `renameACPSession(worktreeId:tabId:title:)` in `TabsManager.swift`:

```swift
@discardableResult
func renameACPSessionTabs(worktreeId: String, sessionId: ACPSession.ID, title: String) -> Int {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var file = byWorktree[worktreeId] else { return 0 }

    var updatedCount = 0
    for idx in file.tabs.indices {
        guard case .acpSession(var state) = file.tabs[idx],
              state.sessionId == sessionId else { continue }
        state.title = trimmed
        file.tabs[idx] = .acpSession(state)
        updatedCount += 1
    }

    guard updatedCount > 0 else { return 0 }
    byWorktree[worktreeId] = file
    persist(worktreeId)
    return updatedCount
}
```

- [ ] **Step 4: Run green tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/TabsManagerTests test
```

Expected: PASS for `TabsManagerTests`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Center/TabsManager.swift AlasTests/TabsManagerTests.swift
git commit -m "feat(remote): sync renamed ACP session tabs"
```

---

### Task 3: AppState Remote Provider Rename

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `AlasTests/Remote/RemoteAppStateAccessTests.swift`

- [ ] **Step 1: Write failing AppState provider test**

Add these helpers to `RemoteAppStateAccessTests`:

```swift
private struct ProjectMemoryStore: PersistenceStoreProtocol {
    let projectsFile: ProjectsFile

    func write<T: Encodable>(_: T, to _: URL) throws {}

    func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
        if type == ProjectsFile.self { return projectsFile as? T }
        if type == AppConfig.self { return AppConfig.defaults as? T }
        return nil
    }
}

private func makeRemoteRenameState() -> AppState {
    let project = ProjectConfig(
        id: UUID().uuidString,
        name: "Project",
        path: "/tmp/project-\(UUID().uuidString)",
        color: "blue",
        addedAt: Date()
    )
    let state = AppState(store: ProjectMemoryStore(projectsFile: ProjectsFile(projects: [project])))
    let worktree = Worktree(
        id: UUID().uuidString,
        projectId: project.id,
        name: "main",
        branch: "main",
        path: URL(fileURLWithPath: project.path),
        status: .clean,
        lastActivity: Date()
    )
    state.projectsManager.insertOptimisticWorktree(worktree)
    state.selectedWorktreeId = worktree.id
    state.config.changes.aiToolId = "test-agent"
    state.agentRegistry = AgentRegistry(
        builtinState: [:],
        customs: [
            AgentDefinition(
                id: "test-agent",
                displayName: "Test Agent",
                binary: "test-agent",
                binaryOverride: nil,
                promptModeArgs: [],
                bypassPermissionsFlag: nil,
                extraTerminalArgs: nil,
                isBuiltin: false,
                isEnabled: true,
                builtinLogoAssetName: nil
            )
        ],
        installedIds: ["test-agent"]
    )
    return state
}
```

Add this test:

```swift
@Test func remoteRenameSessionUpdatesManualSessionTitleAndOpenTab() throws {
    let state = makeRemoteRenameState()
    state.openNewACPSession(agentID: "test-agent")
    let worktreeId = try #require(state.selectedWorktreeId)
    let tab = try #require(state.tabs.tabs(forWorktree: worktreeId).compactMap {
        if case .acpSession(let tabState) = $0 { return tabState }
        return nil
    }.first)
    let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
    let session = try #require(manager.placeholderSession(id: tab.sessionId))

    let renamed = state.renameSession(for: tab.sessionId, title: "  Remote Title  ")

    #expect(renamed)
    #expect(session.title == "Remote Title")
    #expect(session.titleSource == .manual)
    #expect(state.tabs.tabs(forWorktree: worktreeId).first?.title == "Remote Title")
}
```

- [ ] **Step 2: Run red test**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteAppStateAccessTests test
```

Expected: FAIL because `AppState` does not implement `renameSession(for:title:)`.

- [ ] **Step 3: Implement AppState provider rename**

Add this method inside `extension AppState: RemoteSessionsProvider` in `AppState.swift`:

```swift
func renameSession(for id: String, title: String) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    for mgr in acpManagers.values {
        guard mgr.liveSession(for: id) != nil
                || mgr.sessionRows.contains(where: { $0.id == id && !$0.archived }) else { continue }
        guard let session = mgr.liveSession(for: id) ?? mgr.placeholderSession(id: id) else { return false }
        mgr.renameSession(id: session.id, title: trimmed, source: .manual)
        _ = tabs.renameACPSessionTabs(worktreeId: mgr.worktreeId, sessionId: session.id, title: trimmed)
        return true
    }

    return false
}
```

- [ ] **Step 4: Run green test**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteAppStateAccessTests test
```

Expected: PASS for `RemoteAppStateAccessTests`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/App/AppState.swift AlasTests/Remote/RemoteAppStateAccessTests.swift
git commit -m "feat(remote): apply session renames in app state"
```

---

### Task 4: Remote Web Rename UI

**Files:**
- Modify: `Alas/Resources/RemoteWeb/index.html`
- Modify: `Alas/Resources/RemoteWeb/app.js`
- Modify: `Alas/Resources/RemoteWeb/style.css`
- Modify: `Alas/Resources/RemoteWeb/sw.js`
- Modify: `AlasTests/Remote/RemoteWebAssetTests.swift`

- [ ] **Step 1: Write failing web asset test**

Add this test to `RemoteWebAssetTests`:

```swift
@Test func remoteWebExposesSessionRenameControls() throws {
    let app = try asset("app.js")
    let css = try asset("style.css")
    let html = try asset("index.html")
    let sw = try asset("sw.js")

    #expect(html.contains(#"id="detail-title""#))
    #expect(html.contains(#"id="rename-sheet""#))
    #expect(html.contains(#"id="rename-input""#))
    #expect(app.contains(#"type: "renameSession""#))
    #expect(app.contains("function showRenameSheet"))
    #expect(app.contains("case \"sessionRenamed\""))
    #expect(css.contains(".rename-btn"))
    #expect(css.contains("#detail-title"))
    #expect(html.contains("/app.js?v=28"))
    #expect(html.contains("/style.css?v=28"))
    #expect(sw.contains("/app.js?v=28"))
    #expect(sw.contains("/style.css?v=28"))
}
```

Update the existing `sessionRowsRenderWorktreeSummaryCards` expected versions from `v=27` to `v=28`.

- [ ] **Step 2: Run red test**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteWebAssetTests test
```

Expected: FAIL because the remote web rename controls and `v=28` asset references do not exist.

- [ ] **Step 3: Update `index.html` structure and cache busts**

Change the asset links/scripts to `v=28` for `style.css`, `app.js`, `marked.min.js`, and `purify.min.js`.

Replace the header body with:

```html
<button id="back" class="hidden">‹ Sessions</button>
<button id="detail-rename" class="rename-btn hidden" aria-label="Rename session">✎</button>
<span id="detail-title" class="hidden"></span>
<span id="nav-title">Alas Remote</span>
<span id="status" class="chip" data-state="connecting">connecting…</span>
```

Add the rename sheet before `#gate`:

```html
<div id="rename-sheet" class="sheet hidden">
  <div class="sheet-card">
    <p class="sheet-title">Rename Session</p>
    <input id="rename-input" class="sheet-input" type="text" autocomplete="off" />
    <button id="rename-submit" class="btn-submit">Rename</button>
    <button id="rename-cancel" class="sheet-close">Cancel</button>
  </div>
</div>
```

- [ ] **Step 4: Update web client state and rendering**

In `app.js`, add globals:

```javascript
let sessionTitles = new Map();
let renameTarget = null;       // { sessionId, title }
```

In the WebSocket message switch, add:

```javascript
case "sessionRenamed": applySessionRenamed(msg.sessionId, msg.title); break;
```

At the start of `renderSessions(sessions)`, record titles:

```javascript
sessionTitles = new Map(sessions.map(s => [s.id, s.title]));
```

In `renderSessionRow(s)`, replace the title/status header append with:

```javascript
const title = el("span", "session-title", s.title);
const rename = el("button", "rename-btn", "✎");
rename.type = "button";
rename.setAttribute("aria-label", "Rename session");
rename.onclick = (event) => {
  event.stopPropagation();
  showRenameSheet(s.id, s.title);
};
const status = el("span", "status", s.status);
head.append(title, rename, status);
```

In `openSession(id)`, set the detail title:

```javascript
setDetailTitle(sessionTitles.get(id) || "Session");
$("detail-rename").classList.remove("hidden");
$("detail-title").classList.remove("hidden");
```

In `showSessions()`, hide detail title controls:

```javascript
$("detail-rename").classList.add("hidden");
$("detail-title").classList.add("hidden");
hideRenameSheet();
```

Add these functions:

```javascript
function setDetailTitle(title) {
  $("detail-title").textContent = title || "Session";
}

function showRenameSheet(sessionId, title) {
  renameTarget = { sessionId, title: title || "" };
  $("rename-input").value = renameTarget.title;
  $("rename-sheet").classList.remove("hidden");
  $("rename-input").focus();
  $("rename-input").select();
}

function hideRenameSheet() {
  $("rename-sheet").classList.add("hidden");
  renameTarget = null;
}

function submitRename() {
  if (!renameTarget) return;
  const title = $("rename-input").value.trim();
  if (!title) return;
  send({ type: "renameSession", sessionId: renameTarget.sessionId, title });
  hideRenameSheet();
}

function applySessionRenamed(sessionId, title) {
  sessionTitles.set(sessionId, title);
  if (sessionId === currentSession) setDetailTitle(title);
  send({ type: "listSessions" });
}
```

Add handlers near the other bottom handlers:

```javascript
$("detail-rename").onclick = () => {
  if (currentSession) showRenameSheet(currentSession, sessionTitles.get(currentSession) || $("detail-title").textContent);
};
$("rename-submit").onclick = submitRename;
$("rename-cancel").onclick = hideRenameSheet;
$("rename-sheet").onclick = (e) => { if (e.target.id === "rename-sheet") hideRenameSheet(); };
$("rename-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter") { e.preventDefault(); submitRename(); }
  if (e.key === "Escape") { e.preventDefault(); hideRenameSheet(); }
});
```

- [ ] **Step 5: Update CSS and service worker**

Add CSS near the header/session styles:

```css
#detail-title { min-width: 0; flex: 1; font-size: 15px; font-weight: 600; color: var(--fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rename-btn { flex-shrink: 0; width: 28px; height: 28px; display: inline-flex; align-items: center; justify-content: center; border: none; border-radius: 6px; background: transparent; color: var(--fg-dim); font: inherit; font-size: 15px; cursor: pointer; -webkit-tap-highlight-color: transparent; }
.rename-btn:active { background: var(--bg-3); color: var(--fg); }
.sheet-input { width: 100%; margin: 0 0 12px; padding: 10px 11px; border-radius: 8px; border: 0.5px solid var(--line); background: var(--bg-1); color: var(--fg); font: inherit; font-size: 15px; outline: none; }
.sheet-input:focus { border-color: color-mix(in oklab, var(--accent) 60%, var(--line)); box-shadow: 0 0 0 3px color-mix(in oklab, var(--accent) 18%, transparent); }
```

Change `sw.js` shell asset references from `v=27` to `v=28`.

- [ ] **Step 6: Run green web asset tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteWebAssetTests test
```

Expected: PASS for `RemoteWebAssetTests`.

- [ ] **Step 7: Commit**

```bash
git add Alas/Resources/RemoteWeb/index.html Alas/Resources/RemoteWeb/app.js Alas/Resources/RemoteWeb/style.css Alas/Resources/RemoteWeb/sw.js AlasTests/Remote/RemoteWebAssetTests.swift
git commit -m "feat(remote): add session rename UI"
```

---

### Task 5: Final Verification

**Files:**
- No code files expected.

- [ ] **Step 1: Run focused tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteProtocolTests -only-testing:AlasTests/RemoteSessionGatewayTests -only-testing:AlasTests/TabsManagerTests -only-testing:AlasTests/RemoteAppStateAccessTests -only-testing:AlasTests/RemoteWebAssetTests test
```

Expected: PASS for all focused tests.

- [ ] **Step 2: Regenerate project only if needed**

No `project.yml` edits are planned. Do not run `xcodegen` unless source membership changed unexpectedly.

- [ ] **Step 3: Run required build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build exits 0.

- [ ] **Step 4: Inspect final diff**

Run:

```bash
git status --short
git log --oneline -5
```

Expected: clean worktree after task commits, with the feature commits on top of the design/plan commits.
