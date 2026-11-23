# Review Before Push Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Before Alas pushes a shipped branch, a read-only reviewer session with the chosen agent and model reviews the local commits; Alas files its findings in the review pane, sends them to the owning session, and pushes only a clean or allowed SHA.

**Architecture:**
- **Pure pieces in AlasIntegrations/ShipReview** (new folder): diff parsing, prompt building, result parsing, reviewer resolution, the ship review record and its policy. `swift test` covers them.
- **`ShipReviewer`** (new, `@MainActor @Observable`, AlasIntegrations) owns `ShipReviewRecord`s in `ship-reviews.json` and runs rounds through an injected `Effects` struct, like `ReviewShepherd`.
- **The reviewer** is an ephemeral, `readOnlyRestricted` ACP session started by a new `ACPSessionManager.runReviewTurn`, built on the `/btw` machinery.
- **AlasCoreContext** installs the effects and gates the three push paths: `pr_create`, the shepherd's fix pushes (by re-entering the same publish path), and `stack_ship`.
- **The app** adds settings, the Ship popover states, the verdict banner and the transcript card.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing, Rust (AlasCLI text only).

**Spec:** `docs/superpowers/specs/2026-11-23-review-before-push-design.md`

**API maps** (read the one your task names before coding; they quote the exact signatures this plan builds on):
`local://api-shepherd.md`, `local://api-stack.md`, `local://api-acp.md`, `local://api-review.md`, `local://api-settings.md`.

## Global Constraints

- **Package rules:** AlasCore must not import SwiftUI, AppKit, WebKit, GhosttyKit, MLX, TreeSitterPack or FffC. Anything the app or tests use from the package is `public`.
- **Persistence compatibility:** every new field on an existing persisted type decodes from old JSON. Follow the type's existing style (`(try? c.decode(...)) ?? default` for `ShepherdDefaults`, `AppConfig.Changes`, `ProjectConfig`).
- **Defaults:** `reviewBeforePush = false`, `maxReviewRounds = 3`, range `1...10`, reviewer `sameAsSession` with the agent's default model, diff cap `200_000` characters, reviewer turn timeout 20 minutes.
- **Never force-push.** Every push goes through the existing exact-SHA `CommitPublishOperations` path.
- **Repo files:** `.alas/code-review.md` and `.alas/code-review.local.md`, read from the worktree with the same local/SSH reader as shepherd rules. A read failure throws (fail closed).
- **Prompt layer order:** global prompt, `.alas/code-review.md`, project instructions, `.alas/code-review.local.md`, then the Alas section. Empty layers are skipped. Layers add up.
- **Clean:** verdict `approve`, or verdict `comment` with zero findings. `request_changes` is never clean.
- **UI copy** is the spec's, verbatim. English only, sentence case, no emoji.
- **Tests:** Swift Testing (`import Testing`). Extend the existing suite for the type before adding a file. `@Test(arguments:)` for variants. No view tests, no default-value tests, no `Task.sleep` synchronization. AlasCore `.timeLimit` only `.minutes(5)`.
- **Commits:** Conventional Commits, one per task. No agent attribution anywhere.
- **Local checks:** `swift test --package-path Packages/AlasCore --filter '<Suite>'` and read the "Test run with N tests" line. App suites run once at the end with `xcodebuild ... -only-testing AlasTests/<Suite> test`. Don't run the full test plan.
- **Concurrency during execution:** tasks in the same wave touch disjoint files and do not run `swift test` or `xcodebuild` themselves; the integrator runs checks after each wave.

## Review Focus

1. **HEAD moves while a review runs** (the owner commits, or the user does). The result must not push the new HEAD as if it were reviewed. Expected: the round is discarded, does not count, and a new round starts on the new HEAD. Pinned by Task 4 (`headMovedDuringReviewRestartsWithoutCounting`).
2. **The reviewer returns prose, two JSON blocks, a finding on a file outside the diff, or a line outside every hunk.** Expected: last block wins; outside-diff paths fold into the summary; outside-hunk lines become file comments; no block fails the round without counting. Pinned by Task 2 parser tests.
3. **The owner ends its fix turn without committing,** either because it disagreed and resolved the findings or because it stalled. Expected: all findings resolved by the owner pushes the reviewed SHA; any finding still open stops with "no progress". Pinned by Task 4 (`ownerTurnWithoutCommitPushesOnlyIfFindingsWereResolved`).
4. **Alas relaunches mid-review,** or the reviewer agent is uninstalled between rounds. Expected: a running round restarts once with a fresh reviewer session and does not count; an unavailable agent stops with a reason, nothing pushed. Pinned by Task 4 (`relaunchRestartsRunningRound`) and Task 6 (`unavailableReviewerStopsWithoutPushing`).
5. **A head reaches the PR without passing review** (shell push, "Ship without review" on an older SHA). Expected: Auto-merge never merges it; a head equal to local HEAD gets reviewed automatically. Pinned by Task 5 (`mergeGateRequiresAPassedHead`).

---

## Wave 1 (three tasks in parallel)

### Task 1: Settings models and reviewer resolution

**Files:**
- Create: `Packages/AlasCore/Sources/AlasModel/Model/CodeReviewSettings.swift`
- Modify: `Packages/AlasCore/Sources/AlasModel/Model/ShepherdDefaults.swift`
- Modify: `Packages/AlasCore/Sources/AlasModel/Persistence/AppConfig.swift` (`AppConfig.Changes` property, its `CodingKeys`, manual decode at ~968-1160, `AppConfig.defaults`)
- Modify: `Packages/AlasCore/Sources/AlasModel/Persistence/ProjectConfig.swift` (property, keys, init, tolerant decode ~284-345, encode ~408-463)
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Projects/ProjectsManager.swift` (`ProjectUpdate` and linked-project copying at ~188-204, ~356-372, mirroring `shepherd`)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/AppConfigDecodingTests.swift` (extend); `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdRulesResolverTests.swift` is NOT touched here.

Read `local://api-settings.md` sections 1 and 2 first.

**Interfaces:**
- Produces:
  ```swift
  public enum ReviewerChoice: Codable, Equatable, Hashable, Sendable {
      case sameAsSession
      case agent(id: String, modelID: String?)   // modelID nil = agent default
  }
  public struct CodeReviewSettings: Codable, Equatable, Sendable {
      public var reviewer: ReviewerChoice   // default .sameAsSession
      public var prompt: String             // default CodeReviewSettings.defaultPrompt
      public static let defaultPrompt: String
      public init(reviewer: ReviewerChoice = .sameAsSession, prompt: String = CodeReviewSettings.defaultPrompt)
  }
  public struct ProjectCodeReviewSettings: Codable, Equatable, Sendable {
      public var reviewer: ReviewerChoice?  // nil inherits global
      public var instructions: String
      public var isEmpty: Bool { reviewer == nil && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      public init(reviewer: ReviewerChoice? = nil, instructions: String = "")
  }
  public struct ResolvedReviewer: Equatable, Sendable { public let agentID: String; public let modelID: String? }
  public enum ReviewerResolver {
      /// Ship choice, else project, else global. `.sameAsSession` resolves to the owner's agent with no model.
      public static func resolve(ship: ReviewerChoice?, project: ProjectCodeReviewSettings?, global: CodeReviewSettings, ownerAgentID: String) -> ResolvedReviewer
  }
  // ShepherdDefaults gains:
  public var reviewBeforePush: Bool = false
  public var maxReviewRounds: Int = Self.defaultMaxReviewRounds
  public static let defaultMaxReviewRounds = 3
  public static let reviewRoundRange = 1...10
  public static func clampedReviewRounds(_ value: Int) -> Int
  // AppConfig.Changes gains: public var codeReview: CodeReviewSettings
  // ProjectConfig gains: public var codeReview: ProjectCodeReviewSettings?   (nil when isEmpty, like shepherd)
  ```

- [ ] **Step 1: Write the failing tests** in `AppConfigDecodingTests`:

```swift
@Test("old configs decode the review settings to their defaults", arguments: [
    #"{"changes":{}}"#,
    #"{"changes":{"shepherd":{"autoFix":true}}}"#,
    #"{"changes":{"shepherd":{"maxReviewRounds":99},"codeReview":{"reviewer":"bogus"}}}"#,
])
func reviewSettingsTolerateOldAndBadJSON(_ json: String) throws {
    let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    #expect(config.changes.shepherd.reviewBeforePush == false)
    #expect(ShepherdDefaults.reviewRoundRange.contains(config.changes.shepherd.maxReviewRounds))
    #expect(config.changes.codeReview.reviewer == .sameAsSession)
    #expect(config.changes.codeReview.prompt == CodeReviewSettings.defaultPrompt)
}

@Test("reviewer precedence: ship, then project, then global", arguments: [
    (ReviewerChoice?.some(.agent(id: "codex", modelID: "gpt-5.2")), ReviewerChoice?.some(.agent(id: "claude", modelID: nil)), ReviewerChoice.sameAsSession, ResolvedReviewer(agentID: "codex", modelID: "gpt-5.2")),
    (nil, .some(.agent(id: "claude", modelID: "opus")), .agent(id: "codex", modelID: nil), ResolvedReviewer(agentID: "claude", modelID: "opus")),
    (nil, nil, .agent(id: "codex", modelID: nil), ResolvedReviewer(agentID: "codex", modelID: nil)),
    (nil, .some(.sameAsSession), .agent(id: "codex", modelID: nil), ResolvedReviewer(agentID: "pi", modelID: nil)),
])
func reviewerPrecedence(ship: ReviewerChoice?, project: ReviewerChoice?, global: ReviewerChoice, expected: ResolvedReviewer) {
    let resolved = ReviewerResolver.resolve(
        ship: ship,
        project: project.map { ProjectCodeReviewSettings(reviewer: $0) },
        global: CodeReviewSettings(reviewer: global),
        ownerAgentID: "pi"
    )
    #expect(resolved == expected)
}
```

If `AppConfig` cannot decode from a bare `{"changes":{}}` in this suite, mirror how the existing tests in the file build their JSON input; keep the three variants.

- [ ] **Step 2:** Add the types. `CodeReviewSettings.defaultPrompt` is exactly:

```
Review the change below as a senior engineer on this codebase. Report only problems worth fixing before this ships:
- correctness bugs and regressions
- missing or swallowed error handling
- security problems
- leftover debug code, commented-out code and temporary markers
- tests that don't test what they claim

One finding per problem, each with a concrete fix. Skip style nits that a linter or formatter would catch, and don't praise the change.
```

`ReviewerChoice` Codable: synthesized is fine. Decoding failures inside `CodeReviewSettings` fall back per field (`(try? c.decode(ReviewerChoice.self, forKey: .reviewer)) ?? .sameAsSession`).

- [ ] **Step 3:** Wire `ShepherdDefaults` (keys `reviewBeforePush`, `maxReviewRounds`, clamped), `AppConfig.Changes.codeReview` (key `codeReview`), `ProjectConfig.codeReview` (key `codeReview`, encode only when non-nil, normalize empty to nil like `shepherd`), and `ProjectsManager` (`ProjectUpdate.codeReview`, copy to linked projects exactly where `shepherd` is copied).

- [ ] **Step 4:** Commit `feat(review): add review-before-push settings models`.

### Task 2: Diff, instructions, prompt builder and result parser (pure)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasIntegrations/ShipReview/CodeReviewDiff.swift`
- Create: `Packages/AlasCore/Sources/AlasIntegrations/ShipReview/CodeReviewInstructions.swift`
- Create: `Packages/AlasCore/Sources/AlasIntegrations/ShipReview/CodeReviewPromptBuilder.swift`
- Create: `Packages/AlasCore/Sources/AlasIntegrations/ShipReview/CodeReviewResultParser.swift`
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/ShepherdRules.swift` (move the private `read(_:host:)` and `remoteReadContents` into an internal `RepoTextFileReader` enum in the same module; `ShepherdRulesResolver` calls it; behavior unchanged)
- Test: Create `Packages/AlasCore/Tests/AlasCoreTests/ShipReview/CodeReviewTextTests.swift` (one suite for the diff, builder and parser; they're one pipeline). Extend `Shepherd/ShepherdRulesResolverTests.swift` for the instructions resolver.

Read `local://api-shepherd.md` "Rules resolver and file loading" first.

**Interfaces:**
- Consumes: nothing from other tasks (plain strings).
- Produces:
  ```swift
  public struct CodeReviewDiff: Equatable, Sendable {
      public struct File: Equatable, Sendable {
          public let path: String            // new path ("b/" stripped); old path for deletions
          public let patch: String           // the file's full "diff --git" block
          public let newLineRanges: [ClosedRange<Int>]   // new-side line ranges of its hunks
      }
      public let files: [File]
      public init(rawDiff: String)           // splits `git diff --no-color base...head` output
      /// Files in diff order until adding the next patch would pass `cap` characters.
      public func included(cap: Int) -> (included: [File], omitted: [String])
      public func file(at path: String) -> File?
  }
  public struct CodeReviewInstructions: Equatable, Sendable {
      public var repoFile: String?      // .alas/code-review.md
      public var project: String?
      public var localFile: String?     // .alas/code-review.local.md
      public static let repoFilePath = ".alas/code-review.md"
      public static let localFilePath = ".alas/code-review.local.md"
  }
  public enum CodeReviewInstructionsResolver {
      public static func load(worktreePath: URL, projectInstructions: String?) async throws -> CodeReviewInstructions
  }
  public struct CodeReviewEarlierFinding: Equatable, Sendable {
      public let id: String; public let path: String; public let line: Int?; public let body: String
      public let replies: [String]       // "Author: text", oldest first
  }
  public struct CodeReviewPromptInput: Equatable, Sendable {
      public var globalPrompt: String
      public var instructions: CodeReviewInstructions
      public var branch: String
      public var base: String
      public var headSHA: String
      public var round: Int
      public var maxRounds: Int
      public var diff: CodeReviewDiff
      public var earlierFindings: [CodeReviewEarlierFinding]
      public static let diffCap = 200_000
  }
  public enum CodeReviewPromptBuilder {
      public static func build(_ input: CodeReviewPromptInput) -> String
  }
  public struct CodeReviewFinding: Equatable, Sendable {
      public enum Anchor: Equatable, Sendable { case line(start: Int, end: Int), file }
      public let path: String; public let anchor: Anchor; public let body: String
  }
  public struct CodeReviewResult: Equatable, Sendable {
      public let verdict: ReviewVerdict          // AlasModel
      public let summary: String
      public let findings: [CodeReviewFinding]
      public let resolvedIDs: [String]
      public var isClean: Bool { verdict == .approve || (verdict == .comment && findings.isEmpty) }
  }
  public enum CodeReviewResultParser {
      public enum Failure: Error, Equatable { case noResult, malformed(String) }
      public static func parse(_ finalMessage: String, diff: CodeReviewDiff) -> Result<CodeReviewResult, Failure>
  }
  ```

- [ ] **Step 1: Write the failing tests** (`@Suite struct CodeReviewTextTests`):

```swift
static let twoFileDiff = """
diff --git a/Sources/A.swift b/Sources/A.swift
index 1111111..2222222 100644
--- a/Sources/A.swift
+++ b/Sources/A.swift
@@ -10,3 +10,4 @@ struct A {
     let x = 1
+    // ponytail: remove me
     let y = 2
     let z = 3
diff --git a/Sources/B.swift b/Sources/B.swift
new file mode 100644
--- /dev/null
+++ b/Sources/B.swift
@@ -0,0 +1,2 @@
+let b = 1
+let c = 2
"""

@Test func diffSplitsFilesAndHunkRanges() {
    let diff = CodeReviewDiff(rawDiff: Self.twoFileDiff)
    #expect(diff.files.map(\.path) == ["Sources/A.swift", "Sources/B.swift"])
    #expect(diff.files[0].newLineRanges == [10...13])
    #expect(diff.files[1].newLineRanges == [1...2])
}

@Test("the cap keeps whole files in order and lists the rest", arguments: [(Int.max, 2, 0), (1, 0, 2)])
func diffCap(cap: Int, included: Int, omitted: Int) {
    let split = CodeReviewDiff(rawDiff: Self.twoFileDiff).included(cap: cap)
    #expect(split.included.count == included)
    #expect(split.omitted.count == omitted)
}

@Test("prompt layers appear in order and empty ones are skipped", arguments: [
    (CodeReviewInstructions(repoFile: "REPO", project: "PROJ", localFile: "LOCAL"), ["GLOBAL", "## Repository review instructions", "REPO", "## Project review instructions", "PROJ", "## Your review instructions", "LOCAL"]),
    (CodeReviewInstructions(repoFile: nil, project: "  \n", localFile: "LOCAL"), ["GLOBAL", "## Your review instructions", "LOCAL"]),
])
func promptLayerOrder(_ instructions: CodeReviewInstructions, expectedInOrder: [String]) {
    let prompt = CodeReviewPromptBuilder.build(.init(
        globalPrompt: "GLOBAL", instructions: instructions, branch: "feat", base: "main",
        headSHA: "abc1234def", round: 1, maxRounds: 3,
        diff: CodeReviewDiff(rawDiff: Self.twoFileDiff), earlierFindings: []
    ))
    var cursor = prompt.startIndex
    for needle in expectedInOrder {
        let found = prompt.range(of: needle, range: cursor..<prompt.endIndex)
        #expect(found != nil, "missing or out of order: \(needle)")
        if let found { cursor = found.upperBound }
    }
    if instructions.project == "  \n" { #expect(!prompt.contains("## Project review instructions")) }
}

@Test func promptListsOmittedFilesAndEarlierFindings() {
    var input = CodeReviewPromptInput(
        globalPrompt: "G", instructions: .init(), branch: "feat", base: "main", headSHA: "abc1234def",
        round: 2, maxRounds: 3, diff: CodeReviewDiff(rawDiff: Self.twoFileDiff),
        earlierFindings: [.init(id: "f1", path: "Sources/A.swift", line: 11, body: "Leftover marker", replies: ["Claude Code: fixed"])]
    )
    let small = CodeReviewPromptBuilder.build(input)
    #expect(small.contains("f1") && small.contains("Leftover marker") && small.contains("Claude Code: fixed"))
    // Force the cap below the first file by building the prompt from a diff whose first patch is huge.
    input.diff = CodeReviewDiff(rawDiff: Self.twoFileDiff.replacingOccurrences(of: "let x = 1", with: String(repeating: "x", count: CodeReviewPromptInput.diffCap)))
    let capped = CodeReviewPromptBuilder.build(input)
    #expect(capped.contains("Sources/A.swift") && capped.contains("Read these files from the worktree"))
}

@Test("parser: last JSON block wins, fenced or bare", arguments: [
    "Thinking…\n```json\n{\"verdict\":\"approve\",\"summary\":\"old\",\"findings\":[]}\n```\nThen:\n```json\n{\"verdict\":\"comment\",\"summary\":\"new\",\"findings\":[]}\n```",
    "{\"verdict\":\"comment\",\"summary\":\"new\",\"findings\":[]}",
])
func parserTakesLastBlock(_ message: String) throws {
    let result = try CodeReviewResultParser.parse(message, diff: CodeReviewDiff(rawDiff: Self.twoFileDiff)).get()
    #expect(result.summary == "new")
    #expect(result.isClean)
}

@Test func parserMapsAnchors() throws {
    let message = """
    ```json
    {"verdict":"request_changes","summary":"S","findings":[
      {"path":"Sources/A.swift","line":11,"end_line":11,"body":"in hunk"},
      {"path":"Sources/A.swift","line":400,"body":"outside hunk"},
      {"path":"Docs/X.md","line":3,"body":"not in diff"}
    ],"resolved":["f1"]}
    ```
    """
    let result = try CodeReviewResultParser.parse(message, diff: CodeReviewDiff(rawDiff: Self.twoFileDiff)).get()
    #expect(result.verdict == .requestChanges)
    #expect(result.findings == [
        .init(path: "Sources/A.swift", anchor: .line(start: 11, end: 11), body: "in hunk"),
        .init(path: "Sources/A.swift", anchor: .file, body: "outside hunk"),
    ])
    #expect(result.summary.contains("Docs/X.md:3") && result.summary.contains("not in diff"))
    #expect(result.resolvedIDs == ["f1"])
    #expect(!result.isClean)
}

@Test("parser failures", arguments: [("no json here", CodeReviewResultParser.Failure.noResult)])
func parserFailures(_ message: String, expected: CodeReviewResultParser.Failure) {
    #expect(CodeReviewResultParser.parse(message, diff: CodeReviewDiff(rawDiff: "")) == .failure(expected))
}

@Test func parserRejectsAnUnknownVerdict() {
    let result = CodeReviewResultParser.parse(#"{"verdict":"lgtm","summary":"","findings":[]}"#, diff: CodeReviewDiff(rawDiff: ""))
    guard case .failure(.malformed) = result else { Issue.record("expected malformed, got \(result)"); return }
}
```

And in `ShepherdRulesResolverTests`, mirroring its existing unreadable-file test (same fixture style: a temp worktree with an unreadable `.alas/` file):

```swift
@Test("code review instructions: an unreadable repo file throws")
func unreadableCodeReviewFile() async throws { /* make .alas/code-review.md unreadable (chmod 000) in a temp dir, expect `try await CodeReviewInstructionsResolver.load(...)` to throw */ }

@Test("code review instructions read both files and keep project text")
func codeReviewInstructionsLoad() async throws { /* write both files, expect repoFile/localFile contents and project passthrough; empty project string becomes nil */ }
```

Write those two bodies using the exact helper the neighboring tests use for temp worktrees.

- [ ] **Step 2:** Implement `CodeReviewDiff` (split on lines starting with `diff --git `; path from the `+++ b/` line, or `--- a/` when `+++ /dev/null`; hunk header `@@ -a,b +c,d @@` gives `c...(c + max(d,1) - 1)`, `d` defaulting to 1 when absent; a `d` of 0 contributes no range).
- [ ] **Step 3:** Implement `CodeReviewPromptBuilder.build`. Section order: global prompt; then each non-empty instruction layer under its `##` heading; then `## What to review` with "Branch <branch> → <base>, head <first 7 of sha>, round <n> of <max>."; then `## Earlier findings` (only if any) listing `- [<id>] <path>:<line> <body>` plus indented replies, and the sentence "Check each one. Put the ids of the ones now fixed in `resolved`. Report any that still apply again as new findings."; then `## Rules` with: "You are reviewing, not editing. Don't modify files, run commands, or call Alas tools. You may read files in the worktree for context."; then `## Diff` with the included patches inside a fence from `ShepherdPromptBuilder.fence(for:)` (make `fence` `public` or move it to a shared internal helper in the same module); then, if any were omitted, "These files are part of the change but too large to include. Read these files from the worktree:" and one `- <path>` per line; then `## Output` with:

```
End your reply with exactly one JSON block in this shape and nothing after it:
```json
{"verdict": "approve" | "request_changes" | "comment",
 "summary": "<two or three sentences>",
 "findings": [{"path": "<repo-relative path>", "line": <new-side line>, "end_line": <optional>, "body": "<problem and concrete fix, Markdown>"}],
 "resolved": ["<earlier finding id>"]}
```
Use "approve" when nothing needs fixing, "request_changes" when any finding must be fixed before pushing, and "comment" for optional suggestions only.
```
(Use the computed fence for the inner block so the outer prompt fence never collides.)

- [ ] **Step 4:** Implement `CodeReviewResultParser.parse`: find the last ```` ```json ```` (or ```` ``` ````) fenced block whose content parses as a JSON object; if none, try the whole trimmed message, then the substring from the last `{` that starts a line to the end. No object → `.noResult`. Verdict strings: `approve`, `request_changes`, `comment` (map to `ReviewVerdict.approve/.requestChanges/.comment`); anything else → `.malformed`. Findings: drop entries without `path` or `body`; `line` absent → `.file`; path not in `diff` → append `"\n- <path>:<line>: <body>"` to the summary under a `Not in this diff:` line; line not inside any `newLineRanges` → `.file`. `end_line` < `line` → use `line`.
- [ ] **Step 5:** Implement `CodeReviewInstructionsResolver.load` with `RepoTextFileReader` (SSH host from `RemoteHostRegistry.shared.host(forPath:)`); trims project text and maps empty to nil; files are passed through untrimmed except an all-whitespace file becomes nil.
- [ ] **Step 6:** Commit `feat(review): parse diffs, build review prompts and parse reviewer results`.

### Task 3: Unattended read-only reviewer turn

**Files:**
- Create: `Packages/AlasCore/Sources/AlasAgents/ACP/Session/ACPSessionManager+ReviewTurn.swift`
- Modify: `Packages/AlasCore/Sources/AlasAgents/ACP/Session/ACPSessionManager.swift` (runner `onTurnCompleted` closure at ~7875; make `enterReadOnlyMode` `fileprivate`→internal so the extension can call it)
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/SideQuestion/ACPSideQuestionError.swift` (`ACPSideQuestionPermissionRule.decide(kind:unattended:)`)
- Modify: `Packages/AlasCore/Sources/AlasSessions/ACP/Permissions/ACPPermissionPolicy.swift` (pass `session.unattendedReview`)
- Modify: the `ACPSession` class file (find it with LSP; add `public var unattendedReview = false`, not persisted)
- Test: `AlasTests/ACP/Session/ACPSessionForkManagerTests.swift` (extend; it already builds managers on `ACPMockClient`), `AlasTests/ACP/Permissions/ACPPermissionPolicyTests.swift` (extend `readOnlyGate`).

Read `local://api-acp.md` fully first.

**Interfaces:**
- Produces:
  ```swift
  public struct ACPReviewTurnRequest: Sendable {
      public var parentSessionID: ACPSession.ID
      public var reuseSessionID: ACPSession.ID?   // reuse the reviewer from an earlier round when still live
      public var agentID: String
      public var modelID: String?
      public var title: String                    // "Review before push"
      public var prompt: String
      public var timeout: Duration                // .seconds(20 * 60)
  }
  public enum ACPReviewTurnFailure: Error, Equatable, Sendable {
      case attachFailed(String), cannotRunReadOnly, notAccepted, timedOut, turnFailed(String)
  }
  public enum ACPReviewTurnOutcome: Equatable, Sendable {
      case finished(sessionID: ACPSession.ID, finalText: String)
      case failed(sessionID: ACPSession.ID?, ACPReviewTurnFailure)
  }
  extension ACPSessionManager {
      public func runReviewTurn(_ request: ACPReviewTurnRequest) async -> ACPReviewTurnOutcome
      public func discardReviewSession(id: ACPSession.ID) async
  }
  // ACPSideQuestionPermissionRule:
  public static func decide(kind: String?, unattended: Bool) -> Decision   // unattended: "fetch" → .reject
  ```

- [ ] **Step 1: Failing tests.** In `ACPPermissionPolicyTests`, add `fetch` with `unattendedReview = true` to the `readOnlyGate` arguments (or a sibling parameterized test) expecting a reject option selected without parking. In `ACPSessionForkManagerTests`, add:

```swift
@Test("an unattended review turn runs read-only and returns the whole final message")
func reviewTurnReturnsFinalText() async throws {
    // Build the manager exactly like `sideQuestionReadOnlyMode` does, with a session/new response that advertises a plan mode.
    // Script session/prompt to emit two agent message chunks, then end the turn.
    // let outcome = await manager.runReviewTurn(.init(parentSessionID: parent.id, reuseSessionID: nil, agentId: "claude", ...))
    // #expect(outcome == .finished(sessionID: <id>, finalText: "<chunk1><chunk2>"))
    // #expect(manager.sessions[<id>]?.readOnlyRestricted == true)
    // #expect(!manager.recent.contains { $0.id == <id> })
    // #expect(the mock received session/set_mode with the plan mode before session/prompt)
}

@Test("an unattended review turn fails when the agent can't enter a read-only mode")
func reviewTurnRefusesUnsafeMode() async throws { /* session/new advertises only a bypass mode → .failed(_, .cannotRunReadOnly), session discarded */ }
```
Fill the bodies from the existing `sideQuestionReadOnlyMode` test's fixtures; keep the asserted outcomes as written.

- [ ] **Step 2:** Implement `runReviewTurn`:
  1. Reuse `reuseSessionID` if `liveSession(for:)` exists and is idle; otherwise `createSession(id: UUID().uuidString, agentId:, ephemeralParentID: parentSessionID, ephemeralTitle: title)`, set `unattendedReview = true`, stage `pendingModel[id] = modelID` when non-nil, `await attach(to: id, freshlyCreated: true)`.
  2. Not `.ready` → `.failed(id, .attachFailed(reason))` and discard.
  3. `await enterReadOnlyMode(session)` must return true (no fallback for unenforced agents) → else `.failed(id, .cannotRunReadOnly)` and discard.
  4. Register a one-shot waiter `reviewTurnWaiters[id]` (a new `[ACPSession.ID: CheckedContinuation<ACPTurnCompletion, Never>]` stored on the manager) and `submit(sessionId:text:attachments: [], intent: .auto, onCompleted: { _ in })`; `false` → `.notAccepted`.
  5. Race the waiter against `timeout` (`withTaskGroup`; on timeout cancel the turn with the manager's existing cancel API for a session and return `.timedOut`).
  6. On completion with a failure result → `.turnFailed(message)`; else read the full final text: reverse-scan `session.transcript.messages` after the last `.user` row, first non-empty `ACPSessionTranscriptReader.agentText`.
  7. In the runner `onTurnCompleted` closure, resume `reviewTurnWaiters.removeValue(forKey: sessionId)` **before** the `readOnlyRestricted` guard.
  8. `discardReviewSession(id:)` calls the existing private `discardSideSession(id:)` path.
- [ ] **Step 3:** Thread `unattended: session.unattendedReview` into `ACPPermissionPolicy`'s read-only branch. Unattended never reaches `awaitUserDecision`: `.ask` is impossible because `fetch` rejects.
- [ ] **Step 4:** Commit `feat(acp): run unattended read-only review turns`.

---

## Wave 2 (two tasks in parallel, after Wave 1 compiles)

### Task 4: Ship review record, policy and presentation (pure)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasIntegrations/ShipReview/ShipReviewModels.swift`
- Create: `Packages/AlasCore/Sources/AlasIntegrations/ShipReview/ShipReviewPolicy.swift`
- Create: `Packages/AlasCore/Sources/AlasIntegrations/ShipReview/ShipReviewPresentation.swift`
- Test: Create `Packages/AlasCore/Tests/AlasCoreTests/ShipReview/ShipReviewPolicyTests.swift` (includes the presentation cases as one parameterized test).

**Interfaces:**
- Consumes: `ReviewerChoice` (Task 1), `CodeReviewResult` (Task 2), `ReviewVerdict`, `ReviewSessionID`, `StackShipPlan`.
- Produces:
  ```swift
  public struct ShipReviewID: Hashable, Codable, Sendable { public let worktreeID: String; public let sessionID: String; public init(worktreeID: String, sessionID: String) }
  public struct PendingPRPush: Codable, Equatable, Sendable { public var title: String; public var body: String; public var draft: Bool; public var base: String? }
  public enum ShipReviewTarget: Codable, Equatable, Sendable {
      case pullRequest(PendingPRPush)   // first push and PR fix pushes (pr_create adopts the open PR)
      case stack(StackShipPlan)
      case pushedHead                   // a head already on the remote; clean just records it
  }
  public enum ShipReviewStop: Codable, Equatable, Sendable {
      case roundsExhausted(openFindings: Int)
      case findingsWithAutoFixOff(count: Int)
      case reviewerFailed(String)
      case instructionsUnreadable(String)
      case noProgress(openFindings: Int)
      case pushFailed(String)
  }
  public enum ShipReviewPhase: Codable, Equatable, Sendable {
      case idle
      case reviewing(headSHA: String, startedAt: Date)
      case awaitingFix(headSHA: String)     // findings sent to the owner
      case pushing(headSHA: String)
      case stopped(ShipReviewStop)
  }
  public struct ShipReviewRound: Codable, Equatable, Sendable {
      public var number: Int
      public var headSHA: String
      public var reviewSessionID: ReviewSessionID?
      public var verdict: ReviewVerdict?
      public var summary: String?
      public var openFindingIDs: [String]
      public var reviewerLabel: String       // "Codex · gpt-5.2"
      public var reviewedAt: Date?
  }
  public struct ShipReviewRecord: Codable, Equatable, Sendable {
      public let id: ShipReviewID
      public var enabled: Bool
      public var reviewer: ReviewerChoice?     // per-ship override
      public var maxRounds: Int
      public var pending: ShipReviewTarget?
      public var phase: ShipReviewPhase
      public var roundsThisPush: Int           // reviews with findings since the last push
      public var rounds: [ShipReviewRound]     // newest last, capped at 30
      public var passedSHAs: [String]          // clean or allowed; newest last, capped at 50
      public var unreviewedRemoteHead: String?
      public var reviewerSessionID: String?
      public var createdAt: Date
      public var updatedAt: Date
      public init(id: ShipReviewID, enabled: Bool, reviewer: ReviewerChoice?, maxRounds: Int, now: Date)
      public var currentRound: ShipReviewRound? { rounds.last }
  }
  public enum ShipReviewAction: Equatable, Sendable {
      case none
      case startRound(headSHA: String)
      case push(headSHA: String)
      case sendFindings(round: Int)
      case stop(ShipReviewStop)
  }
  public enum ShipReviewPolicy {
      /// A push request. Lever off or SHA already passed → .push; else start or keep a round.
      public static func requestPush(_ r: ShipReviewRecord, target: ShipReviewTarget, headSHA: String, now: Date) -> (ShipReviewRecord, ShipReviewAction)
      /// The reviewer's outcome for `reviewedSHA`, with the worktree's HEAD read after the turn.
      public static func reviewFinished(_ r: ShipReviewRecord, reviewedSHA: String, currentHeadSHA: String, outcome: Result<CodeReviewResult, ShipReviewFailure>, autoFix: Bool, now: Date) -> (ShipReviewRecord, ShipReviewAction)
      /// The owner's turn ended. `openFindings` counts the round's findings still active in the pane.
      public static func ownerTurnEnded(_ r: ShipReviewRecord, headSHA: String, openFindings: Int, now: Date) -> (ShipReviewRecord, ShipReviewAction)
      public static func pushFinished(_ r: ShipReviewRecord, headSHA: String, error: String?, now: Date) -> ShipReviewRecord
      public static func allow(_ r: ShipReviewRecord, headSHA: String, now: Date) -> (ShipReviewRecord, ShipReviewAction)   // "Ship anyway", "Ship without review", "Allow"
      public static func relaunched(_ r: ShipReviewRecord, now: Date) -> (ShipReviewRecord, ShipReviewAction)              // .reviewing → restart same SHA, no count
      public static func passed(_ r: ShipReviewRecord?, headSHA: String?) -> Bool                                          // nil record or disabled → true
  }
  public enum ShipReviewFailure: Error, Equatable, Sendable { case reviewer(String), noResult, instructions(String) }
  public struct ShipReviewLine: Equatable, Sendable {
      public enum Tone: String, Sendable { case running, clean, findings, stopped }
      public let tone: Tone; public let text: String; public let actions: [ShipReviewLineAction]
  }
  public enum ShipReviewLineAction: String, Equatable, Sendable { case openSession, openReview, retry, shipAnyway, sendToSession, allow, reviewNow }
  public enum ShipReviewPresentation {
      public static func line(_ r: ShipReviewRecord, reviewerName: String, providerName: String) -> ShipReviewLine?
      public static func stopMessage(_ stop: ShipReviewStop) -> String
  }
  ```

- [ ] **Step 1: Failing tests.** Build a `func record(_ phase: ShipReviewPhase = .idle, rounds: Int = 0, max: Int = 3, passed: [String] = []) -> ShipReviewRecord` helper and a `func result(_ verdict: ReviewVerdict, findings: Int) -> CodeReviewResult`.

```swift
@Test("a push request reviews unless the lever is off or the SHA passed", arguments: [
    (true, [String](), ShipReviewAction.startRound(headSHA: "h1")),
    (false, [], .push(headSHA: "h1")),
    (true, ["h1"], .push(headSHA: "h1")),
])
func requestPush(enabled: Bool, passed: [String], expected: ShipReviewAction)

@Test("review outcomes", arguments: [
    // verdict, findings, autoFix, roundsBefore, expected action
    (ReviewVerdict.approve, 0, true, 0, ShipReviewAction.push(headSHA: "h1")),
    (.approve, 2, true, 0, .push(headSHA: "h1")),          // approve stays clean; findings are filed, not sent
    (.comment, 0, true, 0, .push(headSHA: "h1")),
    (.comment, 1, true, 0, .sendFindings(round: 1)),
    (.requestChanges, 2, false, 0, .stop(.findingsWithAutoFixOff(count: 2))),
    (.requestChanges, 1, true, 2, .stop(.roundsExhausted(openFindings: 1))),
])
func reviewOutcomes(...)

@Test func headMovedDuringReviewRestartsWithoutCounting() // reviewFinished(reviewedSHA: "h1", currentHeadSHA: "h2") → .startRound("h2"), roundsThisPush unchanged

@Test func failedReviewStopsWithoutCounting()             // .failure(.reviewer("Codex is not signed in")) → .stop(.reviewerFailed(...)), roundsThisPush unchanged; .noResult → .stop(.reviewerFailed("the reviewer returned no result"))

@Test("owner turn ends", arguments: [
    ("h2", 1, ShipReviewAction.startRound(headSHA: "h2")),   // new commit → next round
    ("h1", 0, .push(headSHA: "h1")),                          // no commit, owner resolved everything
    ("h1", 1, .stop(.noProgress(openFindings: 1))),
])
func ownerTurnWithoutCommitPushesOnlyIfFindingsWereResolved(head: String, open: Int, expected: ShipReviewAction) // starting from .awaitingFix(headSHA: "h1")

@Test func relaunchRestartsRunningRound()   // .reviewing("h1") → .startRound("h1"), roundsThisPush unchanged
@Test func pushResetsTheRoundCountAndRecordsThePass() // pushFinished(error: nil) → .idle, roundsThisPush 0, passedSHAs contains sha; with error → .stopped(.pushFailed)

@Test("review line by state", arguments: shipReviewLineCases) // the five spec strings, e.g. "Codex is reviewing a1b2c3d…", "Codex reviewed a1b2c3d before the push", "Codex review: 2 findings on a1b2c3d, sent to this session", "3 review rounds spent, 1 finding still open. Nothing was pushed.", "a1b2c3d reached GitHub without a review"
func reviewLine(_ c: ShipReviewLineCase)
```
Write the bodies; each asserts the returned action and the record fields named in the comment.

- [ ] **Step 2:** Implement. Rules not spelled out above:
  - `requestPush` while `.reviewing` for the same SHA → `.none` (and updates `pending`); different SHA → `.startRound(new)`.
  - Round numbers increment per started round within the push; `rounds.append` happens on `startRound` with `reviewSessionID: nil` and the coordinator fills it.
  - `allow` appends to `passedSHAs`, sets `.pushing` when a push is pending (action `.push`), else `.idle` and clears `unreviewedRemoteHead` when it matches.
  - `stopMessage` strings: `roundsExhausted` → "\(n) review rounds spent, \(k) finding\(s) still open. Nothing was pushed." (n = maxRounds), `findingsWithAutoFixOff` → "\(k) finding\(s). Auto-fix is off, so nothing was pushed.", `reviewerFailed(r)` → "Review didn't finish: \(r). Nothing was pushed.", `instructionsUnreadable(r)` → "Couldn't read \(r). Nothing was pushed.", `noProgress(k)` → "The session ended its turn without a fix, \(k) finding\(s) still open. Nothing was pushed.", `pushFailed(r)` → "Push failed: \(r)".
- [ ] **Step 3:** Commit `feat(review): add the ship review record and policy`.

### Task 5: Shepherd policy, prompts and presentation for review gating

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/ShepherdPolicy.swift`
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/ShepherdPromptBuilder.swift`
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/StackShepherdPolicy.swift`
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/ShepherdPresentation.swift`
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/ReviewShepherd.swift` (only: build the observation with the new gate; new `Effects.reviewGate`)
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/StackShepherd.swift` (pass the gate into `isReady`; new `Effects.reviewGate`)
- Test: extend `Shepherd/ShepherdPolicyTests.swift`, `Shepherd/ShepherdPromptBuilderTests.swift`, `Shepherd/ShepherdPresentationTests.swift`, `Shepherd/StackShepherdTests.swift` (policy-level case only). Update `ShepherdFixtures.observation(...)` with a defaulted `reviewGate: ShepherdReviewGate? = nil`.

Read `local://api-shepherd.md` (policy, presentation, prompt sections) and `local://api-stack.md` ("Ready-to-land policy") first.

**Interfaces:**
- Produces:
  ```swift
  public struct ShepherdReviewGate: Equatable, Sendable {
      public var passedSHAs: Set<String>
      public var reviewing: Bool        // a round runs or findings wait for the owner
      public init(passedSHAs: Set<String>, reviewing: Bool)
  }
  // ShepherdObservation gains `public let reviewGate: ShepherdReviewGate?` (nil = lever off), init param defaulted to nil.
  // ShepherdPolicy.headGatePasses gains `reviewGate: ShepherdReviewGate? = nil`: non-nil requires request.headSHA ∈ passedSHAs.
  // StackShepherdPolicy.isReady gains `reviewPassed: Bool = true`, ANDed into the result.
  // ShepherdPromptBuilder.fixPrompt/bindPrompt gain `reviewBeforePush: Bool = false`.
  // ShepherdBadgeState gains `case reviewing`; ShepherdPresentation.make gains `review: ShipReviewLine? = nil`
  // ReviewShepherd.Effects gains `public var reviewGate: @MainActor (_ record: ShepherdRecord) -> ShepherdReviewGate? = { _ in nil }`
  // StackShepherd.Effects gains `public var reviewGate: @MainActor (_ record: StackShepherdRecord) -> ShepherdReviewGate? = { _ in nil }`
  ```

- [ ] **Step 1: Failing tests.**

```swift
// ShepherdPolicyTests
@Test("merge gate requires a passed head when review is on", arguments: [
    (ShepherdReviewGate?.none, true),
    (.some(.init(passedSHAs: ["head"], reviewing: false)), true),
    (.some(.init(passedSHAs: ["older"], reviewing: false)), false),
])
func mergeGateRequiresAPassedHead(gate: ShepherdReviewGate?, passes: Bool)
// Use the existing "ready to merge" fixture (stable head, green checks), only varying reviewGate.

@Test func awaitingPushWaitsWhileReviewing()
// .awaitingPush past idleGracePeriod with an unchanged failing check and reviewGate.reviewing == true → action .wait, phase unchanged (today it redispatches).

// ShepherdPromptBuilderTests
@Test("fix prompt tells the session not to push when review is on", arguments: [true, false])
func fixPromptPushInstruction(reviewBeforePush: Bool)
// true: contains "Don't push: Alas reviews the commits and pushes them." and not "commit, and push to"; false: today's text.

// ShepherdPresentationTests: add cases — record .watching + review line tone .running → badge .reviewing, phaseLine "reviewing before the push"; tone .stopped → badge .attention, phaseLine "needs attention: " + stop text (lowercased first letter).

// StackShepherdTests: isReady with reviewPassed false → false, true → unchanged.
```

- [ ] **Step 2:** Implement. Fix prompt with `reviewBeforePush` uses: "The \(label) needs attention. Fix what's below and commit. Don't push: Alas reviews the commits and pushes them." then "Never force-push or rewrite published history. When done, call pr_status to confirm." The conflict section's trailing "commit, push." becomes "commit." under the same flag. Bind prompt adds "Alas reviews your commits before it pushes them; don't push yourself." when the flag is on.
- [ ] **Step 3:** In `ReviewShepherd.evaluate`, pass `effects.reviewGate(current)` into the observation and into `mergeGatePasses`; `fixPrompt`/`bindPrompt` get `reviewBeforePush: effects.reviewGate(record) != nil`. In `ShepherdPolicy`'s `awaitingPush` branch, return `.wait` before the idle-grace check when `observation.reviewGate?.reviewing == true`. `StackShepherd` computes `reviewPassed` as `gate == nil || gate!.passedSHAs.contains(topOpenEntryHeadSHA)` where the top open entry is the highest-position entry in `record.openEntries` and its head is `requests[entry.requestNumber]?.headSHA`.
- [ ] **Step 4:** Commit `feat(shepherd): gate merges and fix prompts on review before push`.

---

## Wave 3 (one task)

### Task 6: ShipReviewer coordinator and core wiring for PRs

**Files:**
- Create: `Packages/AlasCore/Sources/AlasIntegrations/ShipReview/ShipReviewer.swift`
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/Shepherd/AlasCoreContext+ShipReview.swift`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/Shepherd/AlasCoreContext+PRShepherd.swift` (gate in `createShepherdedPR`; `pr_status` review object)
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/PRShepherdWireDTO.swift`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext.swift` (own `shipReviewer`, start/stop with `reviewShepherd`)
- Modify: `Packages/AlasCore/Sources/AlasModel/Persistence/Paths.swift` (`shipReviewsFile` = `<app support>/ship-reviews.json`)
- Test: Create `Packages/AlasCore/Tests/AlasCoreTests/ShipReview/ShipReviewerTests.swift` (fake effects, `MemoryStore` copied from `ReviewShepherdTests` into a shared `TestSupport/MemoryStore.swift` and both suites use it).

Read `local://api-shepherd.md` ("ReviewShepherd", "PR creation and publishing", "Wire DTOs"), `local://api-review.md` sections 1-4 and `local://api-acp.md` section 6.

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces:
  ```swift
  @MainActor @Observable
  public final class ShipReviewer {
      public struct Context: Sendable { public let worktreePath: URL; public let branch: String; public let baseBranch: String; public let providerName: String; public let projectSettings: ProjectCodeReviewSettings? }
      public struct ReviewerRun: Sendable { public let id: ShipReviewID; public let reviewer: ResolvedReviewer; public let reuseSessionID: String?; public let prompt: String }
      public struct Filing: Sendable {
          public let id: ShipReviewID; public let round: Int; public let baseSHA: String; public let headSHA: String
          public let reviewerLabel: String; public let result: CodeReviewResult
          public let earlierRoundSessionIDs: [ReviewSessionID]   // for resolving `resolvedIDs` and, on clean, every still-open finding of this push
      }
      public struct Effects {
          public var context: @MainActor (_ worktreeID: String) -> Context?
          public var settings: @MainActor () -> (review: CodeReviewSettings, defaults: ShepherdDefaults)
          public var ownerAgentID: @MainActor (_ id: ShipReviewID) -> String?
          public var agentLabel: @MainActor (_ reviewer: ResolvedReviewer) -> String?        // nil = agent unavailable; else "Codex · gpt-5.2" or "Codex"
          public var git: ShipReviewGit                                                       // headSHA, mergeBase, diff, localAheadOfUpstream
          public var instructions: @MainActor (_ path: URL, _ project: String?) async throws -> CodeReviewInstructions
          public var runReviewer: @MainActor (ReviewerRun) async -> ACPReviewTurnOutcome
          public var discardReviewer: @MainActor (_ id: ShipReviewID, _ sessionID: String) async -> Void
          public var earlierFindings: @MainActor (_ reviewSessionIDs: [ReviewSessionID]) -> [CodeReviewEarlierFinding]
          public var openFindingCount: @MainActor (_ reviewSessionID: ReviewSessionID) -> Int
          public var fileRound: @MainActor (Filing) throws -> ReviewSessionID
          public var deliverFindings: @MainActor (_ id: ShipReviewID, _ prompt: ShepherdPrompt) async -> ReviewShepherd.Delivery
          public var push: @MainActor (_ id: ShipReviewID, _ target: ShipReviewTarget, _ headSHA: String) async -> String?   // nil = success, else error text
          public var autoFix: @MainActor (_ id: ShipReviewID) -> Bool
          public var localCommitsToPush: @MainActor (_ id: ShipReviewID) async -> String?   // HEAD when ahead of the bound PR's remote head branch
          public var notify: @MainActor (_ id: ShipReviewID, _ stop: ShipReviewStop) -> Void
      }
      public struct ShipReviewGit: Sendable {
          public var headSHA: @Sendable (_ path: URL) async throws -> String
          public var mergeBase: @Sendable (_ path: URL, _ base: String, _ head: String) async throws -> String
          public var diff: @Sendable (_ path: URL, _ base: String, _ head: String) async throws -> String   // git diff --no-color base...head
          public static let live: ShipReviewGit
      }
      public init(store: any PersistenceStoreProtocol, fileURL: URL = Paths.shipReviewsFile, now: @escaping @MainActor () -> Date = { Date() })
      @ObservationIgnored public var effects: Effects?
      public private(set) var records: [ShipReviewID: ShipReviewRecord]
      public func start()          // load, then ShipReviewPolicy.relaunched for running rounds
      public func stop()
      public enum Gate: Equatable, Sendable { case push, reviewing(ShipReviewRecord) }
      public func requestPush(_ id: ShipReviewID, target: ShipReviewTarget, headSHA: String) -> Gate
      public func prepare(_ id: ShipReviewID, enabled: Bool, reviewer: ReviewerChoice?)   // the popover's choice before Ship
      public func setEnabled(_ on: Bool, for id: ShipReviewID)
      public func setReviewer(_ choice: ReviewerChoice?, for id: ShipReviewID)
      public func ownerTurnCompleted(sessionID: String)
      public func allow(_ id: ShipReviewID, headSHA: String)
      public func retry(_ id: ShipReviewID)
      public func cancel(_ id: ShipReviewID)           // "Stop": idle, pending cleared, reviewer discarded
      public func reviewPushedHead(_ id: ShipReviewID, headSHA: String)
      public func record(for id: ShipReviewID) -> ShipReviewRecord?
      public func reviewGate(worktreeID: String, sessionID: String) -> ShepherdReviewGate?
  }
  ```
  Wire additions:
  ```swift
  public struct ShipReviewWire: Encodable, Equatable, Sendable { public var state: String; public var round: Int; public var maxRounds: Int; public var reviewer: String; public var headSha: String?; public var openFindings: Int; public var message: String? }
  public struct PRCreateReviewingWire: Encodable, Equatable, Sendable { public var status = "reviewing"; public var review: ShipReviewWire; public var message: String }
  // PRStatusWire gains `public var review: ShipReviewWire?` (explicit null when absent, matching its encode style)
  // PRCreateResultWire.Shepherd and PRStatusWire.Shepherd gain `reviewBeforePush: Bool`
  ```

- [ ] **Step 1: Failing tests** (`@MainActor struct ShipReviewerTests`), with fake effects that record calls and return scripted values:

```swift
@Test func cleanReviewPushesTheReviewedSHA()
// requestPush(.pullRequest(...), "h1") → .reviewing; reviewer returns an approve JSON; expect push effect called once with "h1", record .idle, passedSHAs == ["h1"], fileRound called with round 1.

@Test func findingsGoToTheOwnerAndTheNextCommitStartsRoundTwo()
// request_changes with one finding → deliverFindings called with a card titled "Review before push · 1 finding"; headSHA effect now returns "h2"; ownerTurnCompleted(sessionID:) → runReviewer called again with reuseSessionID == first session id and a prompt containing the earlier finding id.

@Test func unavailableReviewerStopsWithoutPushing()
// agentLabel returns nil → .stopped(.reviewerFailed("<agent id> isn't available")), push never called, notify called.

@Test func unreadableInstructionsStopWithoutPushing()
// instructions throws ShepherdRulesReadError(file: ".alas/code-review.md", host: "local", detail: "denied") → .stopped(.instructionsUnreadable(...)).

@Test func relaunchRestartsARunningRoundOnce()
// persist a record in .reviewing via a MemoryStore, create a new ShipReviewer on the same store, start() → runReviewer called once, roundsThisPush unchanged.
```

- [ ] **Step 2:** Implement `ShipReviewer`:
  - A round (`runRound(id, headSHA)`): resolve context (nil → stop `.reviewerFailed("the worktree is gone")`), reviewer (`ReviewerResolver.resolve` with record override, project settings, global, owner agent), label (nil → stop `"\(agentID) isn't available"`), instructions (throw → `.instructionsUnreadable("\(file): \(detail)")` using `ShepherdRulesReadError` fields when present), `mergeBase(path, "origin/" + baseBranch` falling back to `baseBranch`, `headSHA)`, diff, earlier findings from this push's rounds, prompt via `CodeReviewPromptBuilder`; then `runReviewer`; parse with `CodeReviewResultParser`; read HEAD again; apply `ShipReviewPolicy.reviewFinished`; on any result (not head-moved) call `fileRound` and store the returned session id on the round; execute the action.
  - Actions: `.startRound` → new `Task` running `runRound` (one per id; a newer request cancels the older task and its reviewer turn result is ignored by comparing a per-id generation, like `ReviewShepherd.bumpGeneration`); `.push` → set `.pushing`, call `push`, then `pushFinished`; on success discard the reviewer session; `.sendFindings` → build the prompt (below) and `deliverFindings`; `.failed` delivery → stop `.reviewerFailed("couldn't reach the session")`; `.stop` → `notify`.
  - Findings prompt (`ShipReviewPromptBuilder` inside this file is fine): text starts "Alas review before push · branch <branch> → <base> · head <sha7>", then "<reviewer> reviewed your commits and found <n> problem(s). Nothing was pushed. Fix each one and commit. Resolve each finding with review_resolve and a one-line reply saying what changed, or reply with review_reply if you disagree. Don't push: when your turn ends, Alas reviews the new commits and pushes them.", then each finding as "- <path>:<line or 'file'>: <body>", then the summary. Card: `ACPPromptCard(origin: .shepherd, title: "Review before push · \(n) finding\(s)", facts: [reviewer, "round \(r) of \(max)", sha7], sections: [.init(title: nil, items: findings as items with location and bodyMarkdown and reviewCommentID)], action: .reviewSession(target))`. Look up `RemotePromptCard.Location`'s initializer in `RemotePromptCard.swift`.
  - `ownerTurnCompleted(sessionID:)`: for every record with that session in `.awaitingFix`, read HEAD and `openFindingCount(current round session)`, apply `ShipReviewPolicy.ownerTurnEnded`. For records in `.idle` with `enabled` where `localCommitsToPush(id)` returns a SHA, call `requestPush(.pullRequest(.init(title: "", body: "", draft: false, base: nil)), headSHA:)`. This is the "Alas picks up fix commits itself" path.
  - Persistence: `ShipReviewsFile { version: Int = 1; records: [ShipReviewRecord] }` with the same lenient decoding as `ReviewShepherdsFile`. Drop records idle with no pending push and `updatedAt` older than 30 days on load.
- [ ] **Step 3:** In `AlasCoreContext+ShipReview.swift` install the effects that only need core:
  - `context` from `reviewShepherd.effects?.worktreeContext` plus `projects` for `ProjectConfig.codeReview`; `settings` from `environment.configuration().changes`.
  - `ownerAgentID`: the owner session's `agentId` through `orchestrationManager(for:)?.liveSession(for:)`, else the persisted row.
  - `agentLabel`: the agent registry the host already uses for `agent_list` (find it with LSP from `AlasHost+AgentReads.swift`), `ACPLaunchCatalog.spec(for:) != nil` and enabled; label = display name, plus " · " + model name from `ACPAgentModelCatalog.models(for:)` (fallback: the model id) when a model is set.
  - `runReviewer`: `orchestrationManager(for: worktree)?.runReviewTurn(.init(parentSessionID: id.sessionID, reuseSessionID:, agentID:, modelID:, title: "Review before push", prompt:, timeout: .seconds(1200)))`; record `reviewerSessionID` from the outcome.
  - `fileRound`: build `.branch(worktreeID:, repositoryPath:, base: baseSHA, head: headSHA, title: "Review before push · round \(n)")`, persist with `ReviewSessionLauncher.openOrFocus` (no-op `open`), save each finding as `ReviewDraftComment` (line anchor `side: .new`, or the file anchor initializer for `.file`; `fileID: DiffReviewFileID(namespace:path:)` with the namespace `AlasHost+Reviews.swift` uses for branch targets), author `.agent(name: reviewerLabel)`; resolve `resolvedIDs` (and on a clean result every still-active finding in `earlierRoundSessionIDs`) by setting `state = .resolved`, `resolvedBy = .agent(name: reviewerLabel)`, `updatedAt`; store the verdict with `markedReviewed(verdict:summary:now:)`; then `reviewCommentsDidChange()` and `didChange(worktreeID:)` exactly as `ReviewsAPI` does.
  - `earlierFindings`, `openFindingCount`: read `reviewDrafts.load(sessionID:)` for each round's `draftSessionID`, active only; replies formatted "Name: text".
  - `deliverFindings`: `reviewShepherd.effects?.deliverPrompt(id.sessionID, id.worktreeID, prompt) { true }`.
  - `autoFix`: the bound PR shepherd record's `autoFix` for this owner if any, else `changes.shepherd.autoFix`.
  - `push`: `.pullRequest(p)` → `await createPR(sessionID:worktreeID:title:body:draft:base:)` (the public serialized entry); success when the response is `.text` and decodes as `PRCreateResultWire`, else the error text. `.pushedHead` → nil. `.stack(plan)` → Task 7.
  - `notify`: calls a new `public var shipReviewNotice: (@MainActor (ShipReviewID, String) -> Void)?` property on `AlasCoreContext`, which the app installs in Task 9, with `ShipReviewPresentation.stopMessage(stop)`.
  - `localCommitsToPush`: when the owner has a bound PR shepherd record, HEAD if HEAD is not contained in `<remote>/<PR head branch>` (`git merge-base --is-ancestor HEAD <ref>` exits 1), else nil.
  - `ReviewShepherd.Effects.reviewGate` = `{ shipReviewer.reviewGate(worktreeID: $0.id.worktreeID, sessionID: $0.sessionID) }` (install where AlasCoreContext already wires `reviewShepherd`; if `effects` is installed by AppState, add the closure in Task 8 instead and leave a public `reviewGate(for:)` here).
  - The unreviewed-head path: in `ReviewShepherd.evaluate`, after computing the gate, when `gate != nil && !gate.reviewing && head ∉ passedSHAs`, call a new `Effects.unreviewedHead: @MainActor (ShepherdRecord, String) -> Void = { _, _ in }`; core installs it as `shipReviewer.reviewPushedHead(...)`, which starts a `.pushedHead` round when local HEAD equals the head, else sets `unreviewedRemoteHead`.
- [ ] **Step 4:** Gate `createShepherdedPR`: right before capturing `CommitPublishReviewTarget` (after adoption decided `.publishThenBind` or no request), when `shipReviewer` has a record for `(worktreeID, sessionID)` with `enabled`, or no record and `changes.shepherd.reviewBeforePush`:
  ```swift
  let id = ShipReviewID(worktreeID: worktreeID, sessionID: sessionID)
  switch shipReviewer.requestPush(id, target: .pullRequest(.init(title: title, body: body, draft: draft, base: base)), headSHA: local.headSHA) {
  case .push: break
  case .reviewing(let record): throw ShipReviewPending(wire: PRCreateReviewingWire(record:...))
  }
  ```
  `createPR` catches `ShipReviewPending` and returns its JSON as `.text` (it is not an error). The `message` is "Alas is reviewing the commits before it pushes them. Findings come back as a new turn; once the review is clean Alas pushes and opens the pull request. Don't push yourself." (use `kind.reviewRequestLabel`). `requestPush` seeds a missing record from defaults. An `.bind` adoption (nothing to push) is never gated.
- [ ] **Step 5:** `pr_status` adds `review` from the record for `(worktreeID, sessionID)`; when no PR exists yet but a record is pending, `pr_status` returns `{"pull_request": null, "shepherd": null, "review": {...}}` instead of its current no-PR error.
- [ ] **Step 6:** Commit `feat(review): review shipped commits before Alas pushes them`.

---

## Wave 4 (two tasks in parallel)

### Task 7: Stack ship gate

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/Shepherd/AlasCoreContext+StackShepherd.swift`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/Shepherd/AlasCoreContext+ShipReview.swift` (`push` for `.stack`)
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Shepherd/StackShepherdWireDTO.swift` (`review` on the progress and status wires)
- Test: extend `Shepherd/StackShepherdTests.swift` only if a policy-level seam needs it; otherwise the gate decision is already covered by Task 4.

Read `local://api-stack.md` fully.

- [ ] **Step 1:** In `publishShepherdedStack`, after the plan is resolved (`chosen.resolved(in:)`, ~224-233) and before `effects.syncStack`, compute the top shipped entry SHA (`shipped.last?.sha` as in lines 399-410) and call `shipReviewer.requestPush(id, target: .stack(plan), headSHA: top)`. On `.reviewing`, throw `ShipReviewPending` carrying a `StackShipProgressWire` whose phase text is "reviewing before the push" and whose `review` is set. The existing `reportStackShipOutcome` must not report a pending review as a failure: catch `ShipReviewPending` in `shipStack` and return its wire as `.text`.
- [ ] **Step 2:** `push` for `.stack(plan)`: `await shipStack(sessionID: id.sessionID, worktreeID: id.worktreeID, plan: plan, replyWithin: nil)`; success when `.text`, else the error string. The outcome turn to the session goes through `reportStackShipOutcome` exactly as a late `stack_ship` does (call it with the response).
- [ ] **Step 3:** `StackShepherd.Effects.reviewGate` installed alongside the PR one, from `shipReviewer.reviewGate(worktreeID:sessionID:)`.
- [ ] **Step 4:** Commit `feat(review): review stacks before gg sync`.

### Task 8: Agent contract and docs (text)

**Files:**
- Modify: `AlasCLI/crates/alas/src/mcp.rs` (`pr_create`, `stack_ship`, `pr_status` descriptions at ~679-699)
- Modify: `AlasCLI/crates/alas/src/skills/review.md`
- Modify: `README.md` (new "### Code review" subsection after "### PR shepherd rules")
- Test: `cd AlasCLI && cargo test -p alas` if a test pins tool descriptions (grep for the current `pr_create` description text in `AlasCLI/crates/alas/tests` and `src`); update any pinned text.

- [ ] **Step 1:** Append to the `pr_create` description: " With review before push on, it may answer `{\"status\": \"reviewing\"}` instead: Alas reviews the commits first, sends findings back as a new turn, and pushes and opens the request itself once the review is clean. Never run git push yourself." Append the same idea to `stack_ship` (before gg sync), and to `pr_status`: " Includes `review` (state, round, reviewer, open findings) when review before push is on."
- [ ] **Step 2:** In `review.md` under "## Pull requests", add:
  ```
  - With review before push on, `alas pr create` and `alas stack ship` may
    answer `reviewing`: a reviewer agent checks the commits first. Findings
    arrive as a new turn. Fix them, commit, and resolve each finding with
    `alas review resolve`; don't push. Alas reviews the new commits and pushes
    them once the review is clean.
  ```
- [ ] **Step 3:** README subsection:
  ```markdown
  ### Code review

  With **Review before push** on (Settings › Changes, or the Ship button), a
  reviewer agent checks every push Ship makes before Alas pushes it.
  `.alas/code-review.md` adds the repository's review instructions to the
  global prompt from Settings, for example:

  ```markdown
  Watch out for `// ponytail` comments: keep the comment, remove the prefix.
  ```

  Project instructions from Project Settings come next, then an uncommitted
  `.alas/code-review.local.md` for you alone. Unlike the shepherd rules, these
  layers add up rather than replace each other.
  ```
  (Use a four-backtick outer fence in the README so the inner block renders.)
- [ ] **Step 4:** Commit `docs(review): describe review before push for agents and users`.

---

## Wave 5 (one task)

### Task 9: App wiring

**Files:**
- Modify: `Alas/Sources/App/AppState+Shepherd.swift` (install `reviewGate`/`unreviewedHead` if `ReviewShepherd.Effects` is installed here; call `host.core.shipReviewer.ownerTurnCompleted(sessionID:)` wherever `reviewShepherd.turnCompleted(sessionID:)` is called; `requestShepherdCreatePR` gains `review: (enabled: Bool, reviewer: ReviewerChoice?)` and calls `shipReviewer.prepare(...)` before sending the create prompt)
- Modify: `Alas/Sources/App/AppState+StackShepherd.swift` (same for the stack Ship request and `StackShepherd.Effects.reviewGate`)
- Create: `Alas/Sources/App/AppState+ShipReview.swift` (notices; `openShipReview(_ id:)` opens the latest round's review session tab via `tabs.openOrFocusReviewSession(worktreeId:record:)` and focuses the worktree; `openReviewerSession(_ id:)` via `openExistingACPSession(sessionId:worktree:)`; `shipWithoutReview`, `retryShipReview`, `stopShipReview` forwarding to `ShipReviewer`)
- Modify: `Alas/Sources/App/AppState+PromptCards.swift` only if `.reviewSession` actions need no change (they already open a review session target; verify, change nothing otherwise).

- [ ] **Step 1:** Implement the wiring. Stop notices post through the same notification path `notifyShepherdEvent` uses for escalations (macOS notification plus sidebar attention), title "Review before push", body `ShipReviewPresentation.stopMessage(stop)`.
- [ ] **Step 2:** Build the app (command in Global Constraints is for tests; here run the build):
  `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build` and fix errors.
- [ ] **Step 3:** Commit `feat(review): wire review before push into the app`.

---

## Wave 6 (three tasks in parallel)

### Task 10: Settings and project settings UI

**Files:**
- Create: `Alas/Sources/Settings/AgentModelPicker.swift` (moved out of `ScheduleChipMenu` in `Alas/Sources/Right/RunScheduleEditorView.swift:424-500,656-695`; the schedule editor switches to it)
- Create: `Alas/Sources/Settings/CodeReviewPromptEditorWindow.swift` (copy of `ReviewRequestPromptEditorWindow.swift`'s pattern; register its window id `code-review-prompt-editor` next to the others in `AlasApp.swift:85-141`)
- Modify: `Alas/Sources/Settings/ChangesPane.swift`
- Modify: `Alas/Sources/Dialogs/NewProjectDialog.swift` (draft fields, Automation tab block, load ~1365, save ~1647-1685)

Read `local://api-settings.md` sections 3-5.

**Interfaces:**
- Produces: `struct AgentModelPicker: View { @Binding var choice: ReviewerChoice?; let allowsSameAsSession: Bool; let inheritLabel: String? }` (nil choice shows `inheritLabel`, for "Use global setting · …"). Agents from `RepositoryAgentMenuPolicy.acpAgents(from: registry.enabled())`; models from `ACPAgentModelCatalog.models(for:)` with "Agent default" first.

- [ ] **Step 1:** Changes pane: new `SettingsGroup(title: "Code review")` above "PR shepherd" with the two rows from the spec (Reviewer with two menus, Prompt with `promptEditorRow(windowId: "code-review-prompt-editor", currentValue: state.config.changes.codeReview.prompt, defaultValue: CodeReviewSettings.defaultPrompt)`). In "PR shepherd" add "Review before pushing" (Toggle) and "Review rounds per push" (Stepper over `ShepherdDefaults.reviewRoundRange`) as the first two rows of the group, before "Auto-fix new PRs", matching the popover's row order. Update the Auto-merge description to: "Squash-merge once checks pass, required reviewers have reviewed the current head, the current head passed its review, and the head has stayed the same for two polls."
- [ ] **Step 2:** Project Settings › Automation: "Code review" block under "PR shepherd" with Reviewer (`AgentModelPicker` with `inheritLabel: "Use global setting · <resolved global label>"`), Instructions (`ProjectStartupScriptEditor`, caption "Added after the global prompt and .alas/code-review.md, for you alone."), and the repo file status lines ("✓ .alas/code-review.md found in the repo, added too", same for the local file), read once when the tab appears via `CodeReviewInstructionsResolver.load` on the project's primary checkout (errors show "Couldn't read <file>").
- [ ] **Step 3:** Build, fix, commit `feat(review): add code review settings`.

### Task 11: Ship popover, stack popover and review drawer

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPShepherdButton.swift`
- Modify: `Alas/Sources/ACP/UI/ACPStackShepherdPopover.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/ReviewShepherdBlock.swift`
- Modify: `Alas/Sources/Right/ChangesTabView.swift` (drawer model fields)

Read `local://api-settings.md` section 6 and `local://api-stack.md` section 6.

- [ ] **Step 1:** Badge: map `.reviewing` to symbol `"eye"` and the accent color in the `ShepherdBadgeState` extension (~189-215). Pill state: when `shipReviewer.record(for: ShipReviewID(worktreeID: worktree.id, sessionID: session.id))` is `.reviewing` or `.awaitingFix` with no PR yet, show label "Reviewing" with the `.reviewing` badge.
- [ ] **Step 2:** Unbound popover (`createContent`): popover-local `@State reviewEnabled` and `@State reviewer: ReviewerChoice?` seeded from the record or defaults. Insert, first in the step list when on, `ShipPopoverStep(symbol: "eye") { Text("\(name) reviews the commits here first. Nothing is pushed until the review is clean.") }`; a `ShepherdSwitchRow(title: "Review before push", detail: ...)` variant whose detail line hosts a compact `AgentModelPicker` menu and "up to \(max) rounds" (extend `ShepherdSwitchRow` with an optional trailing-detail view builder rather than copying it). The button passes the choice to `requestShepherdCreatePR(..., review:)`.
- [ ] **Step 3:** Reviewing content (new branch before `createContent` when the record is pending with no PR): header "Reviewing before the push" / "<branch> → <base> · nothing pushed yet", the five step rows from the spec driven by the record (committed SHA, latest round line with "Open review", "This session is fixing them" while `.awaitingFix`, next round line, "Push and open the PR"), footer buttons "Ship without review" (`allow(headSHA: current)`) and "Stop" (`cancel`). Stopped records show `ShipReviewPresentation.stopMessage` and its actions.
- [ ] **Step 4:** Bound popover: under `reviewLines`, the `ShipReviewPresentation.line` with its action links; a third switch row "Review before push" above Auto-fix (detail: picker + "every fix too"); `setEnabled`/`setReviewer` on change. The Auto-fix and Auto-merge rows keep their text.
- [ ] **Step 5:** Drawer (`ReviewShepherdBlock`): add `review: ShipReviewLine?`, `reviewEnabled: Bool?`, `setReviewEnabled` to `ReviewShepherdDrawerModel` and render the same row and line; build them in `ChangesTabView`.
- [ ] **Step 6:** Stack popover: the same unbound switch row and reviewing branch, using the stack Ship request.
- [ ] **Step 7:** Build, fix, commit `feat(review): show review before push in the Ship popover`.

### Task 12: Verdict banner in the review pane

**Files:**
- Create: `Alas/Sources/Center/ReviewWorkspace/ReviewVerdictBanner.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift` (insert under the header at ~278-327)
- Modify: `Alas/Sources/Remote/Native/NativePeerDocumentView.swift` (move its verdict label helper ~955-965 to a shared `extension ReviewVerdict { var displayLabel: String }` in AlasCore `ReviewVerdict.swift` and use it in both places)

Read `local://api-review.md` section 5.

- [ ] **Step 1:** `ReviewVerdictBanner(verdict: ReviewSessionVerdict, ship: ShipReviewRound?, roundCount: Int?, actions: ...)`: chip with `displayLabel` ("Approved", "Changes requested", "Commented"; tone colors success/warning/neutral), reviewer label and "reviewed <sha7> · round N of M · <relative time>" when `ship` is set, else just the relative time; summary as Markdown with the app's existing Markdown text view; action row: "Sent to <owner> session" status (when the record's phase is `.awaitingFix` or later for this round), "Review again" (`retry`), "Ship anyway" (only while a push is pending), and "Open reviewer session" (only while `reviewerSessionID` is live).
- [ ] **Step 2:** In `ReviewSessionTabView`, show the banner when `record.verdict != nil`. Find the ship round by scanning `shipReviewer.records` for a round whose `reviewSessionID == record.id`.
- [ ] **Step 3:** Header source line: when the target head isn't on any remote ref (`git branch -r --contains <sha>` empty, computed once on load), append " · local, not pushed".
- [ ] **Step 4:** Build, fix, commit `feat(review): show review verdicts in the review pane`.

---

## Wave 7: verification and review

### Task 13: Checks and branch review

- [ ] **Step 1:** `swift test --package-path Packages/AlasCore --filter 'AppConfigDecodingTests|CodeReviewTextTests|ShepherdRulesResolverTests|ShipReviewPolicyTests|ShipReviewerTests|ShepherdPolicyTests|ShepherdPromptBuilderTests|ShepherdPresentationTests|StackShepherdTests|ReviewShepherdTests'` and confirm the suite count in "Test run with N tests in M suites".
- [ ] **Step 2:** `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/ACPSessionForkManagerTests -only-testing AlasTests/ACPPermissionPolicyTests test`.
- [ ] **Step 3:** `cd AlasCLI && cargo test -p alas`.
- [ ] **Step 4:** One fresh reviewer on the whole branch against the spec; fix what it finds.
