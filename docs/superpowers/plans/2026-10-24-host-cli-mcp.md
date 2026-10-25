# The `alas` CLI and MCP tools on a headless host — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents and shells that `alas-host` starts get the `alas` CLI and the built-in `alas` MCP server, with every tool that can work without a screen. The rest are hidden and refused.

**Architecture:** PR 1 moves `AlasCLICommandRouter` and `AlasActionService` into `AlasHostCore` without changing behaviour. The app still passes its UI closures. PR 2 adds the headless pieces:
- a `headless(host:)` router that refuses screen-bound commands before it resolves the origin;
- `alas-host` serving the router on the harness socket it already binds;
- MCP and CLI env injection in the headless session-manager factory, plus `ALAS_MCP_HEADLESS=1`, which the Rust server reads to hide tools and rewrite schemas;
- packaging of the CLI next to the host;
- host-owned `awaitingInput`, plus a `notice` host event that only subscribers who opt in receive.

**Tech Stack:** Swift 6 / SwiftPM (`Packages/AlasCore`), Swift Testing, Rust (`AlasCLI/`), bash packaging script.

**Spec:** `docs/superpowers/specs/2026-10-24-host-cli-mcp-design.md`

## Global Constraints

- Swift Testing only (`import Testing`). Follow the AGENTS.md testing policy: test routing decisions, the tool filter, binary lookup and status. Don't test wiring or defaults.
- `Packages/AlasCore` must not import SwiftUI, AppKit, WebKit, GhosttyKit, MLX, `TreeSitterPack` or `FffC`. Anything the app or the tests use from it must be `public`.
- Core tests: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter <Suite>`.
- Rust tests: `cd AlasCLI && cargo test --locked`. Run it from `AlasCLI/` so `rust-toolchain.toml` applies, as CI does.
- The app target can't be built locally, so CI is its first build. Keep `Alas/` edits mechanical and say so in each PR description. Don't run `xcodebuild` locally.
- After adding or removing files under `Alas/` or `AlasTests/`, run `xcodegen` and commit `project.yml` and `Alas.xcodeproj` together.
- Commit titles follow Conventional Commits (`type(scope): summary`). Add no attribution trailers, footers or markers of any kind.
- Refusal copy for screen-bound commands is exactly `Not available on a headless host.`, with a non-zero exit code (`.error` gives exit 1).
- Headless MCP scope flag: env `ALAS_MCP_HEADLESS=1`, set only by the host's injection.
- The CLI ships in the host zip at `alas-cli/alas`. Lookup order: the `ALAS_CLI_BINARY` override, then beside the resolved executable, then the app bundle's copy. This is the same order as `ALAS_ZMX_BINARY` uses.
- Host shells get `PATH` (with the CLI first), `ALAS_WORKTREE` and `ALAS_REPO`. They never get `ALAS_SOCKET_PATH` or `ALAS_SESSION_ID`.
- The app's behaviour is unchanged. Every headless behaviour is gated on `HeadlessHostEnvironment` (`relaysNotices`) or on `AlasCLICommandRouter.isHeadless`.

## Review Focus

1. **A host shell runs `alas open x` or `alas wt switch y`.** This is the anonymous form: no session, only a cwd. It must get the headless refusal, not "not inside an Alas worktree" and not a silent `.ok`. Task 3's refusal test sends every case with `sessionId: nil, cwd:` set.
2. **`notify --needs-input` followed by the session's next prompt.** The `awaitingInput` status must clear and not stick. Task 6's session test sends a prompt and waits for the status to change.
3. **Bare local-changes forms.** `review` with no target, and `review_comment_add` or `review_finish` without `session_id`, must be refused by the host and must show as required in the headless MCP schema. Task 3 covers the refusal and Task 2 covers the schema.
4. **A delegated child on the host.** The child-only filter and the headless filter must both apply. Task 2 asserts that a headless child lists neither `session_new` nor `open`.
5. **No CLI on the host.** A missing binary, or an override that isn't executable, must make the lookup return nil, with no fallback. Then the host boots without the `alas` MCP server and logs why. Task 4's lookup test covers both nil cases.

---

## PR 1 — Move the router into core

### Task 1: `AlasCLICommandRouter` and `AlasActionService` move to `AlasHostCore`

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCLICommandRouter.swift`, a verbatim move of `Alas/Sources/App/AlasCLICommandRouter.swift:1-286`.
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasActionService.swift`, a verbatim move of `Alas/Sources/App/AlasActionService.swift:1-139`.
- Delete: both app files. Regenerate with `xcodegen`, which changes `Alas.xcodeproj`.
- Unchanged: `Alas/Sources/App/AppState.swift:7189-7287` (`makeCLICommandRouter`), `AlasTests/AlasCLICommandRouterTests.swift`, `AlasTests/WebPreviewAutomationRoutingTests.swift`. They already `import AlasCore`, which re-exports `AlasHostCore`.

**Interfaces:**
- Produces: `@MainActor public struct AlasCLICommandRouter`, with `public init(host:openRelativeFile:openExternalFile:openRelativeFileAtLines:openExternalFileAtLines:focusWorktree:createWorktree:deleteWorktree:openReviewChanges:openReview:workspaceCommand:previewCommand:computerCommand:activateApp:)`. Keep the same order, defaults and default copy as today's memberwise init. Mark every closure `@escaping`. Also `public func handle(_ request: AlasCLIRequest) async -> AlasCLIResponse` and `public static func visualShowReply(id: UUID, presentation: ACPVisualAid.Presentation) -> String`.
- `AlasActionService` stays internal to `AlasHostCore`. Nothing outside the router uses it.

- [ ] **Step 1:** Move both files with `git mv` into `AlasHostCore/Core/`. Add the module imports that `AlasHost+Attention.swift` uses, plus `AlasACP` and `AlasAgentKit`. Make the router struct, its init, `handle` and `visualShowReply` `public`. Change no logic.
- [ ] **Step 2:** Build core: `swift build --package-path Packages/AlasCore`. Expected: `Build complete!`.
- [ ] **Step 3:** Run the core suites near the router: `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter 'AlasHostTests|AlasCLIReviewTargetResolverTests'`. Expected: they pass. The router's own suites are app tests, so they first run in CI.
- [ ] **Step 4:** Run `xcodegen`, then `git status` should show only the two moves plus `Alas.xcodeproj/project.pbxproj`.
- [ ] **Step 5:** Commit:
```bash
git add -A Packages/AlasCore/Sources/AlasHostCore/Core Alas/Sources/App Alas.xcodeproj
git commit -m "refactor(core): move the CLI command router into AlasHostCore"
```

---

## PR 2 — Headless CLI, MCP, notify and packaging

### Task 2: Rust headless tool scope

**Files:**
- Modify: `AlasCLI/crates/alas/src/mcp.rs`:
  - `McpEnv` struct `:17-31` and its `Clone` `:92-104`;
  - `tool_scope` `:43-55`, `ToolScope` and its `allows` and `rejection` `:58-90`;
  - `env_from` `:128-150`, `initialize_result` `:177-224`, `tool_definitions_for_mode` `:239-249`.
- Test: the same file's `mod tests`. Add `headless: false` to every existing `McpEnv { .. }` literal in it.

**Interfaces:**
- Produces: `McpEnv.headless: bool`, read from `ALAS_MCP_HEADLESS` (`"1"` or `true`, the same parse as `ALAS_MCP_WORKSPACE_ONLY`). Also `ToolScope::Headless`. Precedence: relay, then headless, then workspace.
- Hidden in headless scope: `open`, `preview_*`, `computer_*`, `worktree_switch` and every `workspace_*`. The host has no workspace backing, as decided in the spec.
- Schema rewrite in headless scope: `review.inputSchema.required = ["target"]`. Add `"session_id"` to `required` for `review_comment_add` and `review_finish`.
- Rejection for a hidden tool: `(-32602, "Not available on a headless host: {name}")`.

- [ ] **Step 1: Write the failing test.** `headless_scope_hides_screen_bound_tools_and_requires_review_targets`:
```rust
let env = env_from(env(&[("ALAS_SOCKET_PATH", "/s"), ("ALAS_WORKTREE_DIR", "/wt"),
    ("ALAS_SESSION_ID", "s1"), ("ALAS_MCP_HEADLESS", "1")])).unwrap();
let scope = env.tool_scope();
assert_eq!(scope, ToolScope::Headless);
let listed = tool_definitions_for_session(scope, false);
let names: Vec<&str> = listed.iter().map(|t| t["name"].as_str().unwrap()).collect();
for hidden in ["open", "preview_list", "computer_apps", "worktree_switch", "workspace_list", "workspace_focus"] {
    assert!(!names.contains(&hidden), "{hidden}");
    let reply = handle_line_with_parent(&call(hidden, json!({})), "/wt", None, scope, |_| unreachable!()).unwrap();
    assert_eq!(reply["error"]["message"], json!(format!("Not available on a headless host: {hidden}")));
}
for kept in ["session_new", "review", "review_comments", "visual_show", "worktree_new", "worktree_delete", "notify", "pr_create"] {
    assert!(names.contains(&kept), "{kept}");
}
let schema = |n: &str| listed.iter().find(|t| t["name"] == n).unwrap()["inputSchema"]["required"].clone();
assert_eq!(schema("review"), json!(["target"]));
assert!(schema("review_comment_add").as_array().unwrap().contains(&json!("session_id")));
assert!(schema("review_finish").as_array().unwrap().contains(&json!("session_id")));
// Review Focus 4: a delegated child keeps both filters.
let child: Vec<String> = tool_definitions_for_session(scope, true).iter().map(|t| t["name"].as_str().unwrap().into()).collect();
assert!(!child.contains(&"session_new".into()) && !child.contains(&"open".into()));
```
- [ ] **Step 2:** `cd AlasCLI && cargo test --locked headless_scope`. Expected: FAIL to compile, because `headless` and `ToolScope::Headless` don't exist yet.
- [ ] **Step 3: Implement.**
  - Add `is_headless_hidden(name) -> bool` next to `is_workspace_tool` (`:1001`).
  - `ToolScope::Headless.allows(name) = !is_headless_hidden(name)`.
  - Do the schema rewrite in `tool_definitions_for_mode` when `scope == Headless`, by mutating the `required` array of the three tools.
  - Give headless scope its own `initialize_result` instructions, based on the root and child texts without "open files". Keep the delegated-child wording when `parent_session_id` is set.
- [ ] **Step 4:** `cd AlasCLI && cargo test --locked`. Expected: every test passes.
- [ ] **Step 5:** Commit: `git commit -am "feat(cli): hide screen-bound MCP tools on a headless host"`.

### Task 3: Headless router, delegated worktrees, CLI socket on `alas-host`

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCLICommandRouter.swift`. Add `isHeadless` to the init with default `false`, and check it first in `handle`.
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCLICommandRouter+Headless.swift`.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHostEnvironment.swift:167-172`. Replace the default `createDelegatedWorktree` refusal with the real one.
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift:181-186`. Call `host.serveCLI()` right after boot.
- Create: `Packages/AlasCore/Tests/AlasCoreTests/HeadlessCLIRouterTests.swift`. This is the first core suite for the router; its other suites are app tests that don't run without the app.
- Test: add the delegated worktree test to `Packages/AlasCore/Tests/AlasCoreTests/AlasHostTests.swift`.

**Interfaces:**
- Consumes: Task 1's public router init.
- Produces:
  - `public static func isScreenBound(_ command: AlasCLIRequest.Command) -> Bool`. It is true for: `.open`, `.openAt`, `.preview`, `.computer`, `.worktree(.switch)`, every `.workspace`, `.review(.localChanges)`, `.review(.commentAdd(…, sessionID: nil))` and `.review(.finish(sessionID: nil, …))`.
  - `public static let headlessRefusal = AlasCLIResponse.error("Not available on a headless host.")`.
  - `public static func headless(host: AlasHost) -> AlasCLICommandRouter`. Its UI closures are no-ops and it sets `isHeadless: true`. It also sets these closures:
    - `createWorktree`: calls `host.worktrees.prepareCreate`, then `beginCreate(prepared.request)`. It starts `finishCreate` in a `Task` and replies `.text(["creating \(branch) at \(prepared.shownPath)"])`, like `AppState.cliCreateWorktree`.
    - `deleteWorktree`: calls `host.worktrees.delete(worktree, force:, deleteBranchIfMerged: config.worktrees.deleteBranchOnRemove && !keepBranch, caller:)`. An error becomes `.error(error.localizedDescription)`. There is no dirty-tab preflight, since the host has no tabs.
    - `openReview`: calls `host.reviews.open(target, in:, caller:)` and replies `.text(["Opened review for '\(label)'.", ReviewsAPI.jsonLine(["session_id": …])])`.
  - `extension AlasHost { public func serveCLI() }`. It sets `core.harness.socketServer.onCLIRequest` to `{ [weak self] in await AlasCLICommandRouter.headless(host: self).handle($0) }`. The `[weak self]` mirrors `AppState`.
  - The default `createDelegatedWorktree`: `WorktreesAPI(core: core).prepareCreate(..., caller: .cli)`, then `recordDestination(prepared.request.destination)`, then `WorktreesAPI(core: core).create(prepared.request, caller: .cli)`. It uses the peer creation path, so startup scripts follow the non-prompting policy. Errors map to `.init(message:)` the way `AppState.createDelegatedWorktree` maps them.

- [ ] **Step 1: Write the failing tests.**
```swift
@MainActor struct HeadlessCLIRouterTests {
    static let screenBound: [AlasCLIRequest.Command] = [
        .open(paths: ["/srv/a"]), .openAt(path: "/srv/a", line: 1, endLine: nil),
        .preview(.init(action: .list)), .worktree(.switch(target: "main")),
        .workspace(.list), .workspace(.show(checkoutID: UUID())),
        .review(.localChanges(worktree: nil)),
        .review(.commentAdd(path: "a", startLine: 1, endLine: nil, side: nil, body: "b", sessionID: nil)),
        .review(.finish(sessionID: nil, verdict: .comment, summary: "")),
    ]
    /// Agents and anonymous shell callers (cwd only) get the same refusal.
    @Test(arguments: screenBound, [String?.none, "acp-1"])
    func screenBoundCommandsAreRefusedOnAHeadlessHost(command: AlasCLIRequest.Command, session: String?) async {
        let router = AlasCLICommandRouter.headless(host: AlasHost(core: AlasCoreContext(
            projects: ProjectsManager(persistedProjects: []), runHistoryStore: nil, attentionStore: .scratch())))
        let response = await router.handle(.init(version: 1, sessionId: session, cwd: "/srv/a", command: command))
        #expect(response == .error("Not available on a headless host."))
    }
}
```
  Add to `AlasHostTests`: `aHeadlessHostCreatesADelegatedSessionsWorktree`. Use a `GitTemplate.repository(at:)` repo added with `core.addProject`, set up as in `HostSocketServerTests:13-33`. Call `core.environment.createDelegatedWorktree(projectID:branch: "child", base: nil, recordDestination: { recorded = $0 }, in: core)`. Then `#expect` all of:
  - it returns `.success(let wt)`;
  - `wt.branch == "child"`;
  - `recorded?.standardizedFileURL == wt.path.standardizedFileURL`;
  - `host.worktrees.list().contains { $0.worktree.id == wt.id }`.
- [ ] **Step 2:** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter 'HeadlessCLIRouterTests|AlasHostTests'`. Expected: FAIL. `headless(host:)` is undefined, and the delegated worktree is refused.
- [ ] **Step 3:** Implement the interfaces above. In `handle`, put `if isHeadless, Self.isScreenBound(request.command) { return Self.headlessRefusal }` before any origin resolution.
- [ ] **Step 4:** Run the same command. Expected: PASS. Check the output for the `Test run with N tests` line.
- [ ] **Step 5:** Commit: `git commit -am "feat(alas-host): serve the alas CLI with screen-bound commands refused"`.

### Task 4: Ship and find the CLI, and give host agents the `alas` MCP server and CLI env

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Console/HostShellLaunch.swift:98-118`. Generalize `zmxBinary` and add `cliBinary`.
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/TerminalCLIInjection.swift:15-24`. Extract `public static var archDirectory: String` (`macos-aarch64` or `macos-x86_64`).
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/BuiltInAlasMCP.swift:233-296`. Add the `headless` parameter.
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/HeadlessAlasTools.swift`.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext.swift:400-417` (`sessionManagerFactory`).
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Boot.swift:55-94`. Add a `cliBinDir` parameter and create `HarnessService()` before the core so the tools can read its socket.
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift:181-197`. Look up and install the CLI, pass it to boot, and log when it is missing.
- Modify: `scripts/package-alas-host.sh`.
- Modify: `docs/headless-host.md:213-219`. Replace the "does not do yet" CLI bullet with a `## The alas CLI and MCP tools` section, placed after `## Terminals`.
- Test: replace `HostConsolesTests.zmxIsFoundBesideTheLinkedExecutableElseInTheApp` (`:42-69`) with one parameterized test.

**Interfaces:**
- Produces:
  - `HostShellLaunch.bundledBinary(_ relativePaths: [String], overrideKey: String, executable: URL?, fallback: URL, environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> URL?`. Its rules are today's zmx rules: a set override that isn't executable gives nil. Each relative path is tried beside `executable.resolvingSymlinksInPath()/../..`, then `fallback`. `zmxBinary(...)` becomes a call to it with `["zmx/zmx"]` and `ALAS_ZMX_BINARY`.
  - `HostShellLaunch.cliBinary(executable: URL?, fallback: URL = /Applications/Alas.app/Contents/Resources/alas-cli/<archDirectory>/alas, environment:, fileManager:) -> URL?`. It tries `["alas-cli/alas", "alas-cli/\(TerminalCLIInjection.archDirectory)/alas"]` with `ALAS_CLI_BINARY`. The second path is the layout inside the app bundle.
  - `BuiltInAlasMCP.injection(…, headless: Bool = false)`. When true, the stdio env gets `.init(name: "ALAS_MCP_HEADLESS", value: "1")`.
  - `@MainActor public struct HeadlessAlasTools` with:
    - `public init(binDir: URL, socketServer: AgentHookSocketServer, config: @escaping @MainActor () -> AppConfig, core: @escaping @MainActor () -> AlasCoreContext?)`;
    - `func socketPath(sessionId: String) -> String?`, which returns `socketServer.linkSession(leafId: AgentHookSocketServer.acpSessionLinkKey(sessionId)) ?? socketServer.socketPath`;
    - `func projectContext(for worktree: Worktree) -> MCPProjectContext?`, which uses the project's `mcpServers` plus `RepoConfigStore().config(worktreeRoot:)` for local projects, as `AppState:12440-455` does;
    - `func attachment(_ context: BuiltInMCPAttachmentContext, worktree: Worktree) async -> BuiltInMCPAttachment`. It returns `.omitted` unless `context.location` is `.local`. It is stdio only. It records the delegated parent through `core.rememberDelegatedSessionParent`, suppresses the built-in server by name via `RepoMCPResolver.merge`, and returns `.local(BuiltInAlasMCP.injection(enabled: config().harness.exposeAlasMCP, …, headless: true))`;
    - `func environment(worktreePath: String, sessionId: String) async -> [String: String]?`, which is `AlasCLIEnvInjection.environment(…, basePATH: ACPProcessEnvironment.augmented()["PATH"])`.
  - `AlasCoreContext.sessionManagerFactory(config:onChipsObserved:alasTools: HeadlessAlasTools? = nil)`. When tools are set, it passes `mcpProjectContextProvider` and `builtInMCPProvider` to `ACPSessionManager(...)` and sets `manager.alasCLIEnvProvider`.
  - `AlasHost.boot(in:cliBinDir: URL? = nil)`. A non-nil dir builds `HeadlessAlasTools`. The core is captured through a `weak var` set right after `AlasCoreContext(...)` is built.
  - `main.swift`: compute `let cliBinDir = HostShellLaunch.cliBinary(executable: Bundle.main.executableURL).flatMap { try? TerminalCLIInjection.installExecutables(sourceBinary: $0) }`. This installs into `<appSupport>/bin`, which also holds `ao`. When it is nil, write to stderr: `alas-host: alas CLI not found beside alas-host or in /Applications/Alas.app; agents get no alas tools here`.

- [ ] **Step 1: Write the failing test.** `@Test(arguments: [Tool.zmx, .cli]) func bundledBinariesAreFoundBesideTheLinkedExecutableElseInTheApp(_ tool: Tool)`. `Tool` is a local enum with `relative` (`"zmx/zmx"` or `"alas-cli/alas"`), `overrideKey`, and `lookup(executable:fallback:environment:)`, which calls `zmxBinary` or `cliBinary`. Reuse today's body with `tool.relative`, and keep all five `#expect`s:
  - linked: the binary under `pkg/` is found;
  - bare: the fallback is found;
  - missing fallback: nil;
  - an executable override wins;
  - an override that isn't executable gives nil (Review Focus 5).

  For `.cli`, add one more: under `bare/`, a binary at `alas-cli/<archDirectory>/alas` (the app layout) is found before the fallback.
- [ ] **Step 2:** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter HostConsolesTests`. Expected: FAIL, because `cliBinary` is undefined.
- [ ] **Step 3:** Implement the interfaces above. Leave out the HTTP transport, `onRebind` relinking and MCP registration status rows. The headless host has no UI for them. Add `// ponytail: no relink after a socket rebind; agents reattach on their next session`.
- [ ] **Step 4:** Package. In `scripts/package-alas-host.sh`:
  - derive `cli_arch` from the prefix suffix (`*-arm64` gives `macos-aarch64`, `*-x86_64` gives `macos-x86_64`, anything else is an error);
  - require `"$resources/alas-cli/$cli_arch/alas"` to be executable;
  - `ditto` it to `"$stage_dir/alas-cli/alas"`;
  - update the header comment.

  Then check it: `bash -n scripts/package-alas-host.sh` should print nothing.
- [ ] **Step 5:** Docs. Write the new section in `docs/headless-host.md`. It should list:
  - the tools host agents get, and the hidden ones (`open`, `preview_*`, `computer_*`, `worktree_switch`, `workspace_*`, local-changes review), refused with "Not available on a headless host.";
  - that the CLI ships in the zip at `alas-cli/alas`, with the `ALAS_CLI_BINARY` override;
  - that host shells find the host by the CLI's socket scan only on the standard profile, not on an `ALAS_APP_SUPPORT_DIR` profile.
- [ ] **Step 6:** Run `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter 'HostConsolesTests|AlasHostExecutableTests'`. Expected: PASS. Then commit:
```bash
git add -A Packages/AlasCore scripts/package-alas-host.sh docs/headless-host.md
git commit -m "feat(alas-host): ship the alas CLI and give host agents its MCP server"
```

### Task 5: Host shells get the CLI's context

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Console/HostConsoles.swift`:
  - `init` `:63-92`: add `cliBinDir: URL? = nil`;
  - `install` `:116-128`: add `cliBinDir:`;
  - the two `HostShellLaunch.make` calls at `:191-193` (shells) and `:374-377` (run consoles).
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift:197`. Pass `cliBinDir` to `HostConsoles.install`.
- Test: extend `HostConsolesTests.aShellLaunchesInTheWorktreeWithTheAgentsPath` (`:16-40`).

**Interfaces:**
- Consumes: Task 4's `cliBinDir`.
- Produces: `static func shellContext(worktree: Worktree, repoName: String?, cliBinDir: URL?, basePATH: String?) -> [String: String]`. It returns:
  - `ALAS_WORKTREE` (`worktree.path.path`);
  - `ALAS_REPO` (the project name, when known);
  - `PATH`, which is `TerminalCLIInjection.pathValue(prepending: cliBinDir.path, to: basePATH)`, only when there is a bin dir.

  It is merged into `environmentOverrides` at both call sites. A run console's `plan.envOverrides` win over it.

- [ ] **Step 1: Write the failing test.** In the existing test, add one more launch with `environmentOverrides: HostConsoles.shellContext(worktree: feature, repoName: "repo", cliBinDir: URL(fileURLWithPath: "/profile/bin"), basePATH: base["PATH"])`, then:
```swift
#expect(withContext.environment["ALAS_WORKTREE"] == "/srv/feature")
#expect(withContext.environment["ALAS_REPO"] == "repo")
#expect(withContext.environment["PATH"] == "/profile/bin:/login/bin:/usr/bin")
#expect(withContext.environment["ALAS_SOCKET_PATH"] == nil && withContext.environment["ALAS_SESSION_ID"] == nil)
```
  Add `"ALAS_SOCKET_PATH": "/stale", "ALAS_SESSION_ID": "old"` to `base`, so the test proves inherited identity is still stripped.
- [ ] **Step 2:** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter HostConsolesTests`. Expected: FAIL, because `shellContext` is undefined.
- [ ] **Step 3:** Implement it. Read the repo name from `core.projects.projects.first { $0.id == worktree.projectId }?.name`. Read the base PATH from the `baseEnvironment()` the call already uses.
- [ ] **Step 4:** Run the same command. Expected: PASS.
- [ ] **Step 5:** Commit: `git commit -am "feat(alas-host): give host shells the alas CLI and their worktree"`.

### Task 6: `notify` reaches paired Macs

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHostEnvironment.swift`. Add a `var relaysNotices: Bool { get }` requirement (`:17-108`). The default is `false` in the extension, and `HeadlessHostEnvironment` (`:227`) returns `true`.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Attention.swift:9-59`.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Events.swift`:
  - add `case notice(HostNotice)` to `HostEvent` (`:26-47`), with a coding-key enum `NoticeCodingKeys { case _0 = "notice" }` following the existing pattern (`:50-54`);
  - add a key `.notice(UUID)` (`:56-87`);
  - make `optInKind` (`:503-510`) return `"notice"` for it.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift`:
  - add internal `func noteAttention(_ events: [HostEvent])` next to `subscribe()` (`:74-94`). It runs `eventSource?.log.publish(events)` and then `eventSource?.refreshInMemoryState()`;
  - change `SessionsAPI.summary(of:in:parent:)` (`:451-467`) to `summary(of:in:core:)`. It reads the parent from `core` and applies `core.reportedStreamingState`. Update both callers: `AlasHost.swift:448` and `AlasHost+Sessions.swift:107`.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/AlasCoreContext+RemoteSessionList.swift:32-35`. Compute the status from `reportedStreamingState`.
- Modify every exhaustive `HostEvent` switch the compiler flags. These include `RemoteSessionGateway.swift:445-455` (make `.notice` a no-op) and `PeerHostChannel.State.apply` (`PeerHostChannel.swift:54-56`).
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/PeerHostChannel.swift:96-107,128-149`.
- Modify (app, mechanical): `Alas/Sources/Remote/Native/NativePeerHosts.swift:24-36,149-158` and `Alas/Sources/App/AppState+PeerHosts.swift:7-16`.
- Modify: `docs/headless-host.md`. Add one paragraph on `notify` to Task 4's section.
- Test: add to `HostSessionsTests.swift` (the `Fixture` already uses `HeadlessHostEnvironment` and a mock agent). Extend `PeerHostChannelTests.swift:50-102`.

**Interfaces:**
- Produces:
  - `public struct HostNotice: Codable, Equatable, Sendable { id: UUID; owner: SessionOwnerID; sessionID: String; agent: AgentKind; title: String?; body: String }`.
  - `AttentionAPI.notify` with `relaysNotices` true:
    - it calls no `harness.notifications.notifyAlas`;
    - with a session, it publishes `.notice(HostNotice)` through `noteAttention`; the owner falls back to `.worktree(worktree.id)`;
    - with no session, it only logs with `caller.log`;
    - with `needsInput` and a live session, it also keeps a one-shot observer of `session.transcript.$streamingState.signal` in `core.noticeAwaitingClears[sessionID]`. On the first change, the observer calls `harness.forgetSession(sessionID)` and drops itself.

    With `relaysNotices` false, today's behaviour is unchanged. Build `AttentionAPI(core:, changed: { [weak self] in self?.noteAttention($0) })` in `AlasHost.attention`.
  - `AlasCoreContext.noticeAwaitingClears: [String: ChangeSubscription]`, internal.
  - `func reportedStreamingState(of sessionID: String, live: ACPSession.StreamingState?) -> ACPSession.StreamingState?`, internal on `AlasCoreContext`. It returns `.awaitingInput` when `environment.relaysNotices`, the harness activity is `.awaitingInput` with `requiresUserInput`, and `live != .awaitingPermission`. Otherwise it returns `live`.
  - `PeerHostChannel.onNotice: (@MainActor (HostNotice) -> Void)?`. `connect()` subscribes with `.subscribeAccepting(after: snapshot.cursor, events: ["notice"])`. Channels exist only for `host.events.v1` peers, which serve it. `receive` calls `onNotice` for each `.notice` before applying the batch. A notice never changes `state`.
  - `NativePeerHosts.init(…, notice: @escaping @MainActor (HostNotice) -> Void = { _ in })`, wired as `channel.onNotice` in `makeChannel`. `AppState.makeNativePeerHosts` passes `{ [weak self] in self?.harness.notifications.notifyAlas(body: $0.body, title: $0.title, agent: $0.agent, sessionId: $0.sessionID, owner: $0.owner) }`.

- [ ] **Step 1: Write the failing tests.** In `HostSessionsTests`, `aNoticeOnAHeadlessHostReachesSubscribersAndHoldsTheSessionWaitingUntilItsNextPrompt`:
```swift
let fixture = try Fixture(); defer { fixture.tearDown() }
fixture.core.harness.notifications.notificationAdder = { _ in Issue.record("no system banner on a host") }
let sessions = fixture.host.sessions
let id = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
try await eventually { await sessions.list().first { $0.id == id }?.isWriter == true }
let subscription = fixture.host.subscribe(); let received = Collected(subscription)
try fixture.host.attention.notify("Pick one", title: "Q", needsInput: true,
    from: .worktree(fixture.worktree, sessionID: id, owner: .worktree(fixture.worktree.id)), caller: .session(id: id))
try await eventually { await received.events.contains { if case .notice(let n) = $0 { n.sessionID == id && n.body == "Pick one" } else { false } } }
#expect(HostEvent.notice(HostNotice(id: UUID(), owner: .worktree("w"), sessionID: id, agent: .codex, title: nil, body: "")).optInKind == "notice")
#expect(sessions.list().first { $0.id == id }?.streamingState == .awaitingInput)
try await sessions.send(id, prompt: "a", caller: .app)   // Review Focus 2
try await eventually { await sessions.list().first { $0.id == id }?.streamingState != .awaitingInput }
// A shell's notify, with no session, is not relayed.
try fixture.host.attention.notify("hi", title: nil, needsInput: false, from: .worktree(fixture.worktree, sessionID: nil, owner: nil), caller: .cli)
```
  `Collected` may not expose raw events yet. If it doesn't, add an `events` accessor beside its `states(of:)` instead of a new helper.

  In `PeerHostChannelTests`:
  - in `connectTakesASnapshotThenSubscribesAfterItsCursor`, change the expectation at `:61` to `.subscribeAccepting(after: cursor, events: ["notice"])`;
  - in `eventsApplyOnlyWhileSubscribedAndResyncTakesANewSnapshot`, set `channel.onNotice = { got.append($0) }`, receive `.events(events: [.notice(n)], cursor: cursor)`, and `#expect(got == [n])` with the state unchanged.
- [ ] **Step 2:** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter 'HostSessionsTests|PeerHostChannelTests'`. Expected: FAIL, because `HostNotice` is undefined.
- [ ] **Step 3:** Implement the core interfaces. Add `// ponytail: a notice for a session with no live agent is never cleared; it can't happen from MCP, which needs one`.
- [ ] **Step 4:** Run the same command. Expected: PASS. Then run the wider core suites that switch over `HostEvent`: `--filter 'AlasHostTests|HostProtocolServerTests|HostProtocolTests|HeadlessSessionPresenterTests'`. Expected: PASS.
- [ ] **Step 5:** Make the app wiring changes (`NativePeerHosts` and `AppState+PeerHosts`). They are mechanical and first compile in CI, so say so in the PR description. Update the docs paragraph. No new files, so no `xcodegen` run.
- [ ] **Step 6:** Commit:
```bash
git add -A Packages/AlasCore Alas/Sources/Remote/Native/NativePeerHosts.swift Alas/Sources/App/AppState+PeerHosts.swift docs/headless-host.md
git commit -m "feat(remote): relay a host's notify to paired Macs and report it waiting"
```

After merge, verify on the mini as the spec lists:
- an agent delegates a child;
- `visual_show` shows on the laptop;
- `notify` shows on the laptop;
- `alas wt list` works from a host shell.
