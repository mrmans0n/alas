# iOS Changes, Files, Visual Aids, New Session and Session-List Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** This plan closes web-client parity on the phone:
- a session screen with Transcript, Changes and Files views (the changed-file list with a read-only diff, and a lazy file tree with a file viewer);
- visual aids rendered in a locked-down web view, with native answer and dismiss controls;
- a new session on an existing worktree, or a new worktree followed by a session;
- session lists cached on disk, so a cold start shows them before any host answers.

This is plan 3c. 3a (#2482) shipped hosts, the session list and the read-only transcript; 3b (#2492) shipped the composer, queue, requests, Inbox and settings.

**Architecture:** Every message already exists in `AlasRemoteKit`, and diffs arrive already split into hunks, so nothing on the wire changes. Pure rules move to the kit, or are ported there, and `swift test --package-path Packages/AlasCore` pins them:
- the new-session sheet rules, moved from the Mac's `NativePeerNewSession`;
- a branch-name check, ported from the web;
- file-tree merging and the Changes summary;
- the visual-aid web policy (CSP, content rules, document wrapping, scripts, navigation), moved from `AlasSessions`;
- visual-aid answer validation, moved from `RemoteSessionGateway`.

The Mac calls the moved code. On the phone:
- a `SessionWorkspace` per session sends the Changes and Files requests and keeps their replies;
- the transcript screen gains a three-way switch;
- the visual-aid card hosts a `WKWebView` the same way the Mac does: a custom URL scheme served with a CSP header, content rule lists, a lockdown script and a bridge script in its own content world.

**Tech Stack:** Swift 6, SwiftUI/UIKit and WebKit on iOS 26, `AlasRemoteKit`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-11-native-ios-app-design.md`, under Goals, "Design" and "Left to the builder" (the visual aid host). Previous plans: `docs/superpowers/plans/2026-11-14-ios-hosts-sessions-transcript.md` and `docs/superpowers/plans/2026-11-14-ios-composer-requests.md`. Their Global Constraints still hold.

## Global Constraints

- Everything in the Global Constraints of plans 3a and 3b still applies:
  - kit imports;
  - the `Phone*` typealiases;
  - no wire change (`RemoteProtocolVersion` stays 1);
  - the design guide and xcodegen;
  - Conventional Commits with no agent attribution;
  - writer-lease take-over through `TranscriptSession.drive`;
  - `withObservationTracking` rather than `Observations {}`, because Xcode 26.6 crashes on it;
  - no pairing with the owner's running Alas.app.
- Add WebKit to the app's allowed imports. Visual aids only.
- No `hello` capability or `hostVersion` gates any of this; the web checks none. The only gate: hide the Changes view, and never send `listChanges`, when `summary.worktree?.isFolder == true`.
- `comparisonMode` is always `nil` on `listChanges`, `fileDiff` and `listFiles`, as on the web. `fileDiff.stage` is `"staged"`, `"unstaged"` or `nil`, for the section the row came from.
- Host caps the phone must respect, never work around:
  - 500 changed files, 2,000 diff lines, 512 KiB per diff;
  - 1,000 nodes per directory listing;
  - 512 KiB per file read; binary files come back as `fileUnavailable(reason: .binary)`.
  - The file viewer renders at most 5,000 lines (the web's `MAX_RENDERED_FILE_LINES`).
- Copy the web's user-facing texts verbatim where the web has one. Sources:
  - `app.js:976-985, 1022, 1222-1233` (Changes and file access);
  - `file-browser.js` (Files);
  - `visual-aid.js:13-14, 250-258` (visual aid states and rejections);
  - `worktree-creation.js` (new worktree).
- Visual aids:
  - the CSP, the content rules, the lockdown script and the bridge script are the Mac's, moved to the kit in Task 3, not copied;
  - frame height is clamped to 120-720 pt for cards and up to 2,000 pt for embedded visuals;
  - a question visual's frame ignores touches (the web makes it `inert`);
  - links open in Safari only when `allowsExternalLinks` says so, and only for http/https;
  - `visualAidResponse.requestId` is a fresh UUID string per send;
  - `selectedOptionIds` is `[]` on dismiss;
  - the note is trimmed, omitted when empty, and at most 2,000 characters.
- New worktree: send `repoHook: .ask`. On `worktreeSessionNeedsRepoHookApproval`, show the hook's text, then resend with `.approve(hash:)` or `.skip`, as the Mac does.
  - Ruling (2026-11-14): the web sends nil, which silently skips the hook. Asking costs one dialog and matches the Mac.
  - Send `modelId` and `effortId` only when the agent lists models or efforts (`NativePeerNewSession.chipVisibility`).
- Tests: Swift Testing in `Packages/AlasCore/Tests/AlasCoreTests`, under the AGENTS.md policy. Moves bring their existing tests along; no new tests for moves, and no view tests.
- Smoke tests run against a local `alas-host` with an isolated `ALAS_APP_SUPPORT_DIR` (plan 3a, Task 4). Record any flow that went unexercised.

## Review Focus

1. **A visual aid tries to get out**: a script `fetch`, an `<img>` to a tracking host, an `RTCPeerConnection`, `location = …`, or a link click while its question is open.
   - All of them fail.
   - A navigation away removes the frame and shows "Visual blocked: it tried to leave the page."
   - (Task 3 pins the policy; Task 6 wires it.)
2. **A late reply for something the user has left.** File A's diff arrives after the user opened file B, or a reply belongs to another session or a stale `projectId`. It is ignored and never shown under the wrong title. (Tasks 4, 5 and 7, via the request key each model keeps.)
3. **The agent edits files while Changes is open.**
   - The list refreshes 500 ms after streaming goes idle.
   - While a diff is open, the refresh waits until it closes.
   - A reconnect replays the open list, diff, tree or file request.
   - (Tasks 4 and 5.)
4. **The connection drops while a worktree is being created.** The sheet shows "Connection lost while creating the worktree." and won't retry until both `sessionList` and `worktreeList` have reloaded, so the same branch isn't created twice. (Task 7)
5. **A cold start with every host offline.** The cached lists show at once, the hosts read as offline, and a forgotten host's cache is deleted with it. A cache file that won't decode is discarded, not fatal. (Task 8)

---

### Task 1: New-session rules in `AlasRemoteKit`

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Client/RemoteNewSession.swift`
- Modify: `Alas/Sources/Remote/Native/NativePeerNewSession.swift`. Keep only a Mac extension holding `branchValidationMessage` and `canCreateWorktree`, which use `GitNameValidator`. Mac call sites use `RemoteNewSession`, through a typealias if that keeps the diff small.
- Test: move the `NativePeerNewSession` tests (around `AlasTests/Remote/NativePeerSessionsTests.swift:2640-2670`) that don't touch `GitNameValidator` into `Packages/AlasCore/Tests/AlasCoreTests/RemoteNewSessionTests.swift`.

**Interfaces (produces):**
- `public struct RemoteNewSession`: everything in `NativePeerNewSession` today except the two `GitNameValidator` statics. That means `Phase`, `WorktreeMode`, `Branches`, the option arrays, `recoveredWorktreeId`, `preselectedBase`, `defaultWorktreeMode`, `worktrees(_:projectId:repoName:)`, `preselectedWorktreeId`, `preselectedAgentId`, `ChipVisibility` and `chipVisibility(for:)`. Add `agents(_ all: [RemoteAgentOption], projectId: String?) -> [RemoteAgentOption]`, which drops agents whose `unavailableProjectIds` contains `projectId`.
- `public enum RemoteBranchName`: `validationMessage(_ name: String) -> String?`, a port of `worktree-creation.js:34-45`. Nil when valid; otherwise the web's message.

- [ ] **Step 1: Write the tests for `RemoteBranchName`**, parameterized: `"feature/x"` and `"a.b"` are valid; each of these is rejected with the web's message: `""`, a space, a leading `/`, `-` or `.` in a component, `..`, a `.lock` suffix, `@{`, each of `~^:\?*[`, and 251 characters. Add one test for `agents(_:projectId:)`.
- [ ] **Step 2: Run them to see them fail:** `swift test --package-path Packages/AlasCore --filter RemoteNewSession`.
- [ ] **Step 3: Move the struct and implement both additions.** Build the Mac app: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build`.
- [ ] **Step 4: Run the moved and new tests** (expect a PASS), plus `-only-testing AlasTests/NativePeerSessionsTests` for what stayed.
- [ ] **Step 5: Commit** as `refactor(remote): share new-session rules with the phone`.

### Task 2: Changes and file-tree rules in `AlasRemoteKit`

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Client/RemoteWorkspaceRules.swift`
- Test: create `Packages/AlasCore/Tests/AlasCoreTests/RemoteWorkspaceRulesTests.swift`

**Interfaces (produces):**
- `public struct RemoteFileTree: Equatable`:
  - `children: [String: [RemoteFileNode]]`, keyed by directory path, with `""` for the root;
  - `expanded: Set<String>`;
  - `mutating func apply(path: String?, nodes: [RemoteFileNode])`: stores the listing sorted directories first, then by name (case-insensitive, as `file-browser.js`). When a directory disappears from its parent's listing, it forgets that directory, and every descendant, from `children` and `expanded`;
  - `func rows() -> [(node: RemoteFileNode, depth: Int)]`: the visible flattened tree;
  - `func pathsToRefresh() -> [String]`: the expanded directories still present, parents first, to re-request after the root reply arrives;
  - `static func canExpand(_ node: RemoteFileNode) -> Bool`: false for files and submodules.
- `public enum RemoteChangesRules`:
  - `summary(comparisonRef:fileCount:add:del:commitCount:) -> String`, the `changes-view.js:71-85` format `vs <ref> · N files · +a −d · N commits`;
  - `badge(loaded: Int?, truncated: Bool, fallback: Int) -> String?`, per `app.js:1025-1049`;
  - `grouped(_ files: [RemoteChangedFile]) -> [(directory: String, files: [RemoteChangedFile])]`, per `changes-view.js` `fileRows`;
  - `accessMessage(_ reason: RemoteFileAccessReason, message: String?, byteSize: Int?) -> String`, the `app.js:1222-1233` texts.

- [ ] **Step 1: Write the failing tests.** One behavior each:
  - an apply sorts directories before files;
  - a directory missing from a re-listing takes its descendants out of `children` and `expanded`;
  - `rows()` shows only the children of expanded directories;
  - `pathsToRefresh()` is parents-first and skips forgotten directories;
  - `summary`, parameterized over a nil ref, zero commits and singular/plural;
  - `badge` with truncation and with the fallback;
  - `accessMessage`, parameterized over every reason.
- [ ] **Step 2: Run them to see them fail:** `swift test --package-path Packages/AlasCore --filter RemoteWorkspaceRules`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them again** (expect a PASS).
- [ ] **Step 5: Commit** as `feat(remote): add Changes and file-tree rules for the phone`.

### Task 3: The visual-aid web policy and answer rule in `AlasRemoteKit`

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Transcript/RemoteVisualAidWebPolicy.swift`
- Modify: `Packages/AlasCore/Sources/AlasSessions/ACP/VisualAid/VisualAidWebPolicy.swift`. The moved members forward to the kit, or the call sites switch to the kit. `response(for:visualID:document:)` stays here, wrapping the kit's headers in `PluginWebPolicy.Response`. `layoutVariables` and `VisualAidFrameTemplate` (which uses `Bundle.main`) stay here too.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteSessionGateway.swift:1287-1311`. `visualAidAnswer` moves to the kit, and the gateway calls it.
- Modify: `Packages/AlasCore/Sources/AlasSessions/ACP/Session/ACPVisualAidQuestionForm.swift`. `noteMaxLength` reads the kit constant.
- Test: move the existing tests for the moved members (search `AlasTests` and `Packages/AlasCore/Tests` for `VisualAidWebPolicy.` and `visualAidAnswer`) to `Packages/AlasCore/Tests/AlasCoreTests/RemoteVisualAidWebPolicyTests.swift`.

**Interfaces (produces):**
- `public enum RemoteVisualAidWebPolicy`, holding these as they are today:
  - `scheme`, `bridgeWorldName`, `bridgeHandlerName`;
  - `contentSecurityPolicy`, `contentRules`, `contentRuleListIdentifier`, `lockedContentRules`, `lockedContentRuleListIdentifier`, `networkLockDeadline`;
  - `minCardHeight`, `maxCardHeight`, `maxEmbeddedHeight`, `contentHeight(forContentHeight:presentation:)`;
  - `allowsExternalLinks(hasQuestion:answer:)`;
  - `documentURL(visualID:)`, `allowsNavigation(to:mainFrame:visualID:)`;
  - `isFullDocument(_:)`, `document(html:themeVariables:frameTemplate:presentation:)`;
  - `pageLockdownScript`, `bridgeScript`.

  Two members change shape:
  - `responseHeaders(for url: URL, visualID: UUID) -> (status: Int, headers: [String: String])`, the header and status half of today's `response`;
  - heights become `Double`, because the kit has no CoreGraphics.
- `public enum RemoteVisualAidAnswer`:
  - `noteMaxLength = 2000`;
  - `answer(to:action:selectedOptionIds:note:at:) -> ACPVisualAid.Answer?`, moved verbatim from the gateway.

- [ ] **Step 1: Move the members and their tests.** Keep the Mac's behavior byte for byte; the tests are the proof.
- [ ] **Step 2: Run the moved tests and the build.**
  - `swift test --package-path Packages/AlasCore --filter "RemoteVisualAid|RemoteSessionGateway"`;
  - the macOS build;
  - `-only-testing` for any `AlasTests` suite that referenced the moved members.
- [ ] **Step 3: Commit** as `refactor(remote): share the visual-aid web policy and answer rule with the phone`.

### Task 4: Session screen switch, `SessionWorkspace`, and the Changes view

**Files:**
- Create: `Mobile/Sources/Workspace/SessionWorkspace.swift`, `Mobile/Sources/Workspace/ChangesView.swift`, `Mobile/Sources/Workspace/DiffView.swift`
- Modify: `Mobile/Sources/Transcript/TranscriptScreen.swift` (the switch), `Mobile/Sources/Transcript/SessionRegistry.swift` (one workspace per session, kept like the `TranscriptSession`)
- Run `cd Mobile && xcodegen` for the new folder.

**Interfaces:**
- Consumes: `RemoteChangesRules` and `RemoteFileTree` (Task 2), `HostHub.addListener`/`send`, and `TranscriptSession.streamingState`.
- Produces: `@MainActor @Observable final class SessionWorkspace`, `init(hub:hostID:sessionId:)`, with:
  - `changes: Load<ChangeListReply>`;
  - `diff: (key: DiffKey, Load<DiffReply>)?`;
  - `tree: RemoteFileTree`;
  - `file: (path: String, Load<FileReply>)?`;
  - `error: String?`.

  `enum Load<T> { case idle, loading, loaded(T), failed(String) }`. `DiffKey` is `{path, stage}`. Methods:
  - `refreshChanges()`, `openDiff(_:stage:)`, `closeDiff()`;
  - `loadTree()`, `toggle(_ dir:)`, `openFile(_:)`, `closeFile()`;
  - `noteStreaming(_ state: String)`, which drives the idle refresh;
  - `activate()` and `deactivate()`, which add and remove the listener.

  Task 5 uses the Files half.

Notes:
- The switch is a glass segmented `Picker` (Transcript / Changes / Files) in a top `safeAreaInset`. Changes is left out when `worktree?.isFolder == true`. The composer and request cards show only on Transcript.
- A reply is applied only when its `sessionId` matches and its path and stage match the open key. Otherwise it is dropped (Review Focus 2).
- `changeList` and its failure update `changes`. The first switch to Changes, the refresh button, and `noteStreaming` going to `"idle"` request it. The idle refresh is debounced 500 ms, and deferred while a diff is open until `closeDiff` (Review Focus 3).
- On the hub's next `.online`, replay whatever list, diff, tree or file is open. `TranscriptSession.watchHost` shows the pattern.
- The Changes list is flat (no glass). It has:
  - a summary line;
  - the sections "Branch Changes", "Staged", "Unstaged" and "Commits" (`changes-view.js:44-56`), with files grouped under directory headers;
  - each row showing status, a conflict tag, and `+add −del`;
  - commits that aren't tappable;
  - the empty, unavailable-metrics and truncation texts from the web.
- The diff view is pushed in the session's `NavigationStack`. It shows hunks with old/new line numbers, add/delete tinting in the style of `TranscriptRowView.diffPreview`, monospaced text, and horizontal scrolling for long lines.
  - To keep 2,000-line diffs smooth, render a hunk's lines in chunks of 100 per `Text`, as `MarkdownBlock.code` does.
  - Show `metadataNote` when there are no hunks, and the web's truncation text.

- [ ] **Step 1: Implement `SessionWorkspace` (the Changes half), the switch, `ChangesView` and `DiffView`.**
- [ ] **Step 2: Build:** `cd Mobile && xcodebuild -project AlasMobile.xcodeproj -scheme AlasMobile -destination 'generic/platform=iOS Simulator' -quiet build`.
- [ ] **Step 3: Commit** as `feat(ios): show a session's changes and diffs`.

### Task 5: The Files view and file viewer

**Files:**
- Create: `Mobile/Sources/Workspace/FilesView.swift`, `Mobile/Sources/Workspace/FileViewer.swift`
- Modify: `Mobile/Sources/Workspace/SessionWorkspace.swift` (the Files half)

**Interfaces:** consumes `RemoteFileTree` (Task 2) and the `SessionWorkspace` file methods (Task 4).

Notes:
- The first switch to Files sends a root `listFiles` (with `path` nil).
- Each `fileTree` reply goes through `tree.apply`. After a root reply, re-request `tree.pathsToRefresh()`.
- Tapping a directory toggles it. Expanding one sends `listFiles(path)` unless its children are already loaded.
- Submodules show the "submodule" badge and don't expand. Other nodes show their `badge`.
- The file viewer:
  - is pushed;
  - shows "Loading…", then numbered monospaced lines, chunked by 100 like the diff;
  - renders at most 5,000 lines and then shows the web's "too many lines" text;
  - adds "File truncated." when the host set `truncated`;
  - shows `RemoteChangesRules.accessMessage` for `fileUnavailable`.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Build** with the Task 4 command.
- [ ] **Step 3: Commit** as `feat(ios): browse a session's files`.

### Task 6: Visual aids

**Files:**
- Create: `Mobile/Sources/Transcript/VisualAidCard.swift` (the card and answer controls) and `Mobile/Sources/Transcript/VisualAidWebView.swift` (a `UIViewRepresentable` around `WKWebView`)
- Modify:
  - `Mobile/Sources/Transcript/TranscriptRowView.swift:66-67`, so the `.visualAid` row renders `VisualAidCard`;
  - `Mobile/Sources/Transcript/TranscriptSession.swift`, which gains `answerVisualAid(_ id: UUID, action: String, selectedOptionIds: [String], note: String?)` and handles `.visualAidRejected`;
  - `Mobile/project.yml`, which adds `Alas/Resources/VisualAid/frame.html` as a resource of the app by path (no copy). Then run xcodegen.

**Interfaces:** consumes `RemoteVisualAidWebPolicy` and `RemoteVisualAidAnswer` (Task 3), and `TranscriptSession.drive`.

Notes:
- **Web view.** Mirror `Alas/Sources/ACP/VisualAid/VisualAidWebPage.swift:72-227`, minus AppKit:
  - a `.nonPersistent()` data store;
  - a `WKURLSchemeHandler` for `RemoteVisualAidWebPolicy.scheme`, serving `document(…)` with `responseHeaders`;
  - the theme variables come from the app's colors and fonts, standing in for `layoutVariables`;
  - `javaScriptCanOpenWindowsAutomatically = false`;
  - both content rule lists, with the locked list added after load (or after `networkLockDeadline`) for question visuals;
  - `pageLockdownScript` at document start in the page world;
  - `bridgeScript` in the `bridgeWorldName` content world, with a handler named `bridgeHandlerName`;
  - navigation decided by `allowsNavigation`.
- **What happens on a blocked navigation or a second main-frame load:** the web view is torn down and "Visual blocked: it tried to leave the page." is shown.
- **Bridge messages:**
  - height messages size the card through `contentHeight(forContentHeight:presentation:)`;
  - `choice` messages select that option in the native controls;
  - `open` messages open the URL in Safari only when it is http/https and `allowsExternalLinks` is true.
- **Question visuals:** the web view has `isUserInteractionEnabled = false`.
- **Frame lifecycle:**
  - a web view lives only while its cell is configured;
  - `ponytail:` no least-recently-used cap like the web's 3 live frames, because a screen shows only a few cells. Add a cap if a device profile shows memory pressure.
- **Answer controls** (`app.js:3465-3537`):
  - radio buttons or checkboxes;
  - "Add a note (optional)";
  - Submit, which reads "Sending…" while pending, and Dismiss.
  - The answered state reads "Answered: <labels>" plus the note; the dismissed state reads "Dismissed".
  - The controls use `drive`, so a phone that isn't the writer takes over first.
  - Each send carries a new UUID `requestId`.
  - A `visualAidRejected` applies only when its `requestId` matches the pending send. It shows the `visual-aid.js:250-258` text.
  - If the row comes back unanswered after a send, the card shows "Couldn't send your answer. Try again."
  - Drafts live on `TranscriptSession`, keyed by visual id, so they survive cell reuse and a resubscribe.
- Validate with `RemoteVisualAidAnswer.answer` before sending; Submit is disabled when it returns nil.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Build** with the Task 4 command.
- [ ] **Step 3: Commit** as `feat(ios): show visual aids and answer them`.

### Task 7: New session and new worktree

**Files:**
- Create: `Mobile/Sources/Sessions/NewSessionSheet.swift` and `Mobile/Sources/Sessions/NewSessionModel.swift`
- Modify: `Mobile/Sources/Sessions/WorktreesView.swift` (a "+" toolbar button; on success, push the new session's `SessionRoute`)

**Interfaces:** consumes `RemoteNewSession` and `RemoteBranchName` (Task 1), and `HostHub`.

Notes:
- **Host.** It is chosen first only when more than one host is online; otherwise the only online host is used. Federated rows are excluded, because sessions are created on the host itself.
- **Mode.** Existing or New worktree (`defaultWorktreeMode`).
- **Existing mode:**
  - send `listWorktrees` and `listAgents`;
  - a filterable list over project, worktree, branch, path and ref, with row metadata as the web shows it;
  - then the agent, from `RemoteNewSession.agents(_:projectId:)` with `preselectedAgentId`;
  - model and effort pickers only per `chipVisibility`;
  - `createSession`.
- **New mode:**
  - send `listProjects`, and select the first project;
  - `listBranches` for the selected project; ignore a reply whose `projectId` is stale;
  - the base comes from `preselectedBase`;
  - the branch-name field shows `RemoteBranchName.validationMessage` inline;
  - then the agent, a review (repo, base, branch), and `createWorktreeSession(… repoHook: .ask)`.
  - On `worktreeSessionNeedsRepoHookApproval`, show a confirmation dialog with the hook's event and text, offering Run and Skip. Resend with `.approve(hash:)` or `.skip`.
- **Failures:**
  - `createSessionFailed` and `worktreeSessionCreationFailed` show their message in the sheet.
  - A failure at stage `"session"` that carries a `worktreeId` switches to Existing with that worktree selected (`recoveredWorktreeId`).
- **Connection lost mid-create** (Review Focus 4): the sheet shows "Connection lost while creating the worktree." Retry stays disabled until both `sessionList` and `worktreeList` have arrived again.
- **On success:** dismiss the sheet and push the new session.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Build** with the Task 4 command.
- [ ] **Step 3: Commit** as `feat(ios): start a session on a worktree or a new one`.

### Task 8: Session-list cache, then the smoke test

**Files:**
- Create: `Mobile/Sources/Hosts/SessionListCache.swift`
- Modify: `Mobile/Sources/Hosts/HostHub.swift`. Load the cache in `init`; write it when `.sessionList` arrives; delete it in `forget`.

Notes:
- One JSON file per host: `applicationSupportDirectory/session-lists/<host uuid>.json`, holding `[RemoteSessionSummary]`. Follow `HostStore`'s pattern: atomic writes, and an unreadable file is deleted and ignored.
- Writes happen off the main actor. When lists arrive faster than writes finish, only the newest list per host is written.
- Cached lists show at once. Each host's state still says offline until it connects, so the UI needs no "stale" badge beyond what the host row already shows.

- [ ] **Step 1: Implement and build.**
- [ ] **Step 2: Smoke test the whole plan** against a local `alas-host` with an isolated `ALAS_APP_SUPPORT_DIR`, on the simulator. Check:
  - Changes, with a diff, an idle refresh after the agent edits a file, and a folder session that has no Changes;
  - Files, with expanding, a file, a binary file and a large file;
  - a visual aid with a question: answer it, then a dismiss, then a take-over answer from a phone that isn't the writer. Ask the agent for one; also check it is blocked when it tries to navigate;
  - a new session on an existing worktree, and a new worktree, including the repo-hook prompt if the repo has one;
  - a cold start with the host stopped.

  Record anything that went unexercised.
- [ ] **Step 3: Commit** as `feat(ios): cache session lists for cold start`.

---

## Not in this plan

- Push, Allow/Deny from the notification, and pairing with a phone key (plan 4).
- Commit file lists and commit diffs. The web defines them but doesn't use them.
- Syntax highlighting in the diff and file viewers. The web has none.
- Visual aids in the Inbox. The spec lists them for push, so they come with plan 4.
- The web's least-recently-used cap on live visual frames (see the `ponytail:` note in Task 6).
