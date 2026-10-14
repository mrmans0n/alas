# PR Shepherd Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an ACP session open its PR/MR through a new `pr_create` MCP tool, then have Alas watch that PR in the background, send CI failures, trusted review threads and merge conflicts back to the same session as fix turns, and optionally merge once the gate passes.

**Architecture:** A `ReviewShepherd` service in AlasCore follows the `RunScheduler` pattern: it owns persisted `ShepherdRecord`s, polls each bound PR through a headless `ReviewLoopState`, and asks a pure `ShepherdPolicy` what to do. Prompts are built by a pure `ShepherdPromptBuilder` and queued into the owning session through the delegated-prompt path, so they render with an "Alas PR shepherd" caption. The app installs effects (delivery, session state, notifications, archive), exposes `pr_create`/`pr_status` over the existing MCP socket path, and adds a toolbar button, a Changes drawer block and settings.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing, AlasCore SwiftPM package, Rust (`AlasCLI` crates `alas`, `alas-client`), `gh` / `glab` CLIs.

**Spec:** `docs/superpowers/specs/2026-10-13-pr-shepherd-design.md`

## Global Constraints

- Code, comments, logs and UI strings are in English.
- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test("sentence")`, `#expect`), never XCTest. Parameterize with `@Test(arguments:)`.
- Follow the AGENTS.md testing policy: no tests for defaults, views, wiring or persistence round trips.
- No agent attribution anywhere: no `Co-Authored-By` trailer, no "Generated with" footer, no robot emoji.
- AlasCore must not import SwiftUI, AppKit or WebKit. `swift test --package-path Packages/AlasCore` must keep working without the app build.
- Every new `.swift` file in the `Alas` or `AlasTests` targets requires `xcodegen` and committing `Alas.xcodeproj/project.pbxproj` in the same commit. AlasCore files do not.
- Run only the focused suites named in each task. Judge a run by `** TEST SUCCEEDED **` / `** BUILD SUCCEEDED **` and the `Test run with N tests in M suites` line; a suite name that matches nothing is skipped silently.
- In a fresh worktree, initialize submodules with `git -c protocol.file.allow=always submodule update --init --recursive` before the first app build.
- Commits use Conventional Commits.
- Fix attempts per PR before escalation: 3. Polls without progress after a fix turn: 3. Stable polls on one head before merge or ready: 2.
- Poll intervals: 30 s (checks pending, fixing, awaitingPush, merging, queued), 120 s (watching, checks complete), 300 s (escalated, paused), none (merged, closed). One 30 s tick. At most 2 provider fetches in flight. Error backoff 30 s doubling, capped at 600 s.
- Fix prompts carry at most 3 failed-check logs, each the existing 8,000-character tail; other failing checks are listed by name, workflow and link.
- Trusted reviewers: GitHub `OWNER`, `MEMBER`, `COLLABORATOR` or a `Bot` actor, never the viewer. GitLab access level >= 30 or a bot, never the authenticated user. Anything else is untrusted or unknown, and only trusted thread heads trigger fixes.
- Merge goes only through `ReviewLoopState.merge(snapshot:)` (squash, head-pinned, merge-queue aware). Never force-push.
- Rules precedence: `.alas/shepherd.local.md`, then `.alas/shepherd.md`, then `ProjectConfig.shepherd`, else none. The first source found wins completely.
- Settings defaults: auto-fix new PRs on, auto-merge new PRs off, archive after merge off.
- Terminal records are kept 7 days after `finishedAt`.
- Shepherd prompts start with the header `Alas PR shepherd`; the transcript caption is "Alas PR shepherd".
- Toolbar control: icon button `arrow.triangle.pull` with a 6 pt dot badge, styled like `ACPSessionsButton`, placed directly before the minimap toggle. Badge tones: working `warn`, ready `add`, attention `del`, merged `.systemPurple`, none hides the badge.

## Review Focus

1. **A head with no checks registered yet.** Right after the agent pushes, GitHub can report zero checks for a short time. The shepherd must not treat that as green on the first poll. Pinned in Task 5 ("a new head with no checks registered yet does not merge"). Two stable polls at the 2-minute watching interval are the only guard; if a repository's CI routinely takes longer than that to register, raise it in review.
2. **Mergeability still computing.** GitHub reports `UNKNOWN` merge state right after a push. That must neither dispatch a conflict fix nor merge. Pinned in Task 5 ("unknown mergeability neither dispatches a conflict fix nor merges").
3. **A run cancelled by a newer push.** `cancel` checks must not send the agent to fix anything and must still block the merge. Pinned in Task 5 ("a cancelled run neither dispatches nor merges").
4. **Reviewer login spelling.** A user who types `ChatGPT-Codex-Connector` in project settings expects it to match the bot. Pinned in Task 5 ("required reviewers match case-insensitively"); the resolver also lowercases in Task 4.
5. **Outdated threads.** A trusted reviewer's thread that the provider marks outdated after a push must not trigger another fix turn. Pinned in Task 5 ("an outdated trusted thread is ignored").

## Decisions made while planning

These refine the spec; the spec was updated to match where they change documented behavior.

- `ShepherdRecordID` has no owner field: v1 excludes Workspace checkouts, so the owner is always `SessionOwnerID.worktree(worktreeID)`.
- GitLab member access levels and bot flags are cached inside `GitLabCLIProvider` (process-wide, one hour), not on the record. GitLab notes carry no `bot` flag, so `glab api users/:id` is called only when the member lookup returns 404 or a level below 30.
- `RightPaneState` keeps its own local-state assembly; the new `ReviewLoopLocalProbe` serves the shepherd only.
- Delivery uses `enqueueDelegatedPrompt` plus `reattach(to:)`, because `sendPrompt` needs a writer lease that unattached sessions lack.
- Required-reviewer evidence comes from a new `CodeHostProvider.reviewersOnHead`, called only when rules require reviewers.
- Persistence decode failures reuse `PersistenceStore`'s existing `.broken-<timestamp>` recovery.
- `pr_create` also refuses a branch whose upstream is the base branch.
- No `alas pr` terminal command; MCP only.
- `cliPRCreate` / `cliPRStatus` live in `AppState+PRShepherdCLI.swift`, separate from `AppState+Shepherd.swift`.

Each task group below starts with notes from the planning pass. Read them before the group's tasks.

---

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdModels.swift` | Record identity, phase, escalation, fingerprint, record, session state, defaults. |
| `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdRules.swift` | Project settings model, rules value, resolver with frontmatter parsing. |
| `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdPolicy.swift` | Pure decision function for rules 1-10 and merge-outcome bookkeeping. |
| `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdPromptBuilder.swift` | Fix, bind and Create PR prompt text. |
| `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdSchedule.swift` | Poll intervals and error backoff. |
| `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdPresentation.swift` | Badge tone, tooltip and phase line, without SwiftUI. |
| `Packages/AlasCore/Sources/AlasCore/Shepherd/ReviewLoopLocalProbe.swift` | Headless local git facts for a worktree. |
| `Packages/AlasCore/Sources/AlasCore/Shepherd/ReviewShepherd.swift` | Service: persistence, timer, wake, evaluation, actions, public API, retention. |
| `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/*.swift` | Fixtures plus rules, policy, prompt, schedule, presentation and retention suites. |
| `Alas/Sources/App/AppState+Shepherd.swift` | Effects installation, delivery, session state, UI-facing helpers. |
| `Alas/Sources/App/AppState+PRShepherdCLI.swift` | `pr_create` and `pr_status` handlers. |
| `Alas/Sources/App/PRShepherdWireDTO.swift` | Agent-facing JSON for both tools. |
| `Alas/Sources/ACP/UI/ACPShepherdButton.swift` | Toolbar button, badge and popover. |
| `Alas/Sources/Integrations/CodeHost/ReviewShepherdBlock.swift` | Drawer model and shepherd block view. |

**Modify:** `CodeHostModels.swift`, `CodeHostProvider.swift`, `GitHubCLIProvider.swift`, `GitLabCLIProvider.swift`, `ReviewThreadMutations.swift` (Tasks 1-3); `AppConfig.swift`, `ProjectConfig.swift` (Task 4); `ACPDelegatedPromptSource.swift` (Task 9); `AlasCoreContext.swift`, `AppState.swift`, `RootView.swift`, `PlatformServices.swift` (Task 10); `AlasCLIRequest.swift`, `AlasCLICommandRouter.swift` (Task 11); `alas-client/src/lib.rs`, `alas/src/mcp.rs`, `ACPMCPPromptPreamble.swift` (Task 12); `ChangesPane.swift`, `ProjectsManager.swift`, `NewProjectDialog.swift` (Task 13); `ACPToolbar.swift` (Task 14); `ReviewLoopDrawer.swift`, `ChangesTabView.swift` (Task 15); `CHANGELOG.md`, `docs/manual-test.md` (Task 16).

## Task order

Tasks 1-3 (provider data) and 4-7 (pure core) are independent of each other. Task 8 needs 1-7. Task 9 is independent. Task 10 needs 8 and 9. Task 11 needs 10. Task 12 needs 11's wire names only. Tasks 13-15 need 10. Task 16 runs last.

---

## Group A: Provider data (Tasks 1-3)

#### Planning notes for this group

1. `reviewersOnHead(remote:request:cwd:)` is a `CodeHostProvider` protocol requirement **plus** a default in `extension CodeHostProvider` that throws `CodeHostProviderError.unsupportedProvider(remote.kind)`. Every optional provider capability in `CodeHostProvider.swift` follows this pattern (`mergedReviewRequests` at lines 484-493 throws for the same reason: an empty result would read as "nobody reviewed"). So the 10 test fakes compile without edits. Task 3 lists them and checks them with `git grep`. A later task that needs a scripted head-reviewer set overrides the method in its own fake.
2. GitLab member access is cached in a new public `GitLabAuthorStandingCache`. `GitLabCLIProvider.init` gains `authorStandingCache: GitLabAuthorStandingCache = .shared` (defaulted, so every existing `GitLabCLIProvider()` / `GitLabCLIProvider(runner:)` call compiles). The default is process-wide, not per instance, because `CodeHostProviderRegistry.live()` builds new provider instances at every call site (`AppState.swift:11680,11877,12114`, `ReviewTabView.swift:247,285`, `ReviewLoopState.swift:45`, `ReviewSessionLoader.swift:112`). A per-instance cache would rarely get a second hit. Entries expire after one hour, so a role change takes effect without restarting the app. The cache still lives inside the GitLab provider's file and is keyed by host + project + user id, which matches deviation 2.
3. GitLab note payloads do not carry `author.bot`. Notes use `API::Entities::UserBasic` (= `UserSafe` id/username/public_email/name + state/locked/avatar_url/web_url, checked against `lib/api/entities/user_basic.rb` and `user_safe.rb` on gitlab master). `bot` is only on `API::Entities::User` (`GET /users/:id`, `expose :bot?, as: :bot`). So Task 2 calls `glab api users/<id>` only when the member lookup returned 404 or an access level below 30. Lookups are limited to the head-comment authors of unresolved discussions. `ReviewThread.headAuthorTrust` is the only consumer, and limiting the lookups keeps the drawer's first refresh cheap. A reply comment whose author heads no thread stays `.unknown`.
4. `GitLabCLIProvider.parseDiscussions` gains a trailing `authorStandings: [Int: GitLabAuthorStanding] = [:]` parameter. New public `GitLabAuthorStanding` enum (`privileged`, `unprivileged`).
5. Viewer-authored comments map to `.untrusted` on both providers (GitHub `viewerDidAuthor == true`; GitLab username equals the `glab api user` username, case-insensitive). If the viewer is unknown (GitLab user lookup failed, or GitHub `viewerDidAuthor` missing on a non-bot), the comment is `.unknown`.
6. Head-reviewer selection is a public static pure function on each provider: `GitHubCLIProvider.parseReviewersOnHead(_ json: String, headSHA: String) throws -> Set<String>` and `GitLabCLIProvider.parseReviewersOnHead(approvalsJSON:notesJSON:headCommitJSON:) throws -> Set<String>`.
7. Two refinements of the assignment, both aimed at the spec's "reviewed the current head":
   - The GitHub `reviews` connection filters `states: [APPROVED, CHANGES_REQUESTED, COMMENTED]`, which drops the viewer's PENDING drafts and DISMISSED reviews.
   - A GitLab approval whose `approved_at` (exposed by `API::Entities::Approvals`) is older than the head commit does not count. Approvals without `approved_at` (older GitLab) still count.
   - The GitHub comment cutoff uses `commits(last: 1)`. If that commit's oid is not `request.headSHA` (the head moved after the request was fetched), comments count for nobody. Reviews still match by oid.
8. `reviewersOnHead` throws `CodeHostProviderError.malformedOutput` when `request.headSHA` is nil or empty, so the caller maps it to `headReviewers == nil` and the gate fails closed.
9. Tests use `@Test("sentence", arguments:)` as the contract requires. The existing provider suites use bare `@Test func`, and both forms run under the same `-only-testing AlasTests/<Suite>` selector.

Line numbers below were read from the tree before Task 1. Within a task, edit bottom-up or locate each edit by the quoted anchor text, because earlier edits in the same file shift later lines.

---

### Task 1: Review author trust model and GitHub classification

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/CodeHostModels.swift:302-322` (`ReviewComment`), `:438-439` (`ReviewThread.author` / `body`)
- Modify: `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/GitHubCLIProvider.swift:94-97` (`reviewThreadsQuery` comment fields), `:1763-1774` (comment mapping in `parseReviewThreadsPage`), `:1799` (insert after the end of `parseReviewThreadsPage`), `:2709-2727` (`ReviewThreadCommentNode`), `:2757-2763` (`ReviewThreadAuthor`)
- Modify: `Alas/Sources/Center/Review/ReviewThreadMutations.swift:36-45` (preserve trust on optimistic edit)
- Test: `AlasTests/Integrations/GitHubCLIProviderTests.swift` (insert before `@Test func githubPublishReviewUsesGraphQLPayloadAndRefreshesPR()` at line 522)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public enum ReviewAuthorTrust: String, Codable, Equatable, Sendable { case trusted, untrusted, unknown }`
  - `ReviewComment.authorTrust: ReviewAuthorTrust` (`public let`), init gains last parameter `authorTrust: ReviewAuthorTrust = .unknown`
  - `ReviewThread.headAuthorTrust: ReviewAuthorTrust` (`public var`, `headComment?.authorTrust ?? .unknown`)
  - GitHub review threads fetched by `currentReviewRequest` / `reviewRequest(remote:number:cwd:)` / `parseReviewThreads(_:)` carry `authorTrust` on each comment.

- [ ] **Step 1: Write the failing test**

In `AlasTests/Integrations/GitHubCLIProviderTests.swift`, insert immediately before the line `    @Test func githubPublishReviewUsesGraphQLPayloadAndRefreshesPR() async throws {`:

```swift
    struct GitHubAuthorTrustCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let headCommentFields: String
        let expected: ReviewAuthorTrust
    }

    @Test(
        "Review thread comments map author association, bot type and viewer to author trust",
        arguments: [
            GitHubAuthorTrustCase(
                testDescription: "owner",
                headCommentFields: #""author": {"__typename": "User", "login": "owner"}, "authorAssociation": "OWNER", "viewerDidAuthor": false"#,
                expected: .trusted
            ),
            GitHubAuthorTrustCase(
                testDescription: "organization member",
                headCommentFields: #""author": {"__typename": "User", "login": "maintainer"}, "authorAssociation": "MEMBER", "viewerDidAuthor": false"#,
                expected: .trusted
            ),
            GitHubAuthorTrustCase(
                testDescription: "collaborator",
                headCommentFields: #""author": {"__typename": "User", "login": "collab"}, "authorAssociation": "COLLABORATOR", "viewerDidAuthor": false"#,
                expected: .trusted
            ),
            GitHubAuthorTrustCase(
                testDescription: "contributor",
                headCommentFields: #""author": {"__typename": "User", "login": "drive-by"}, "authorAssociation": "CONTRIBUTOR", "viewerDidAuthor": false"#,
                expected: .untrusted
            ),
            GitHubAuthorTrustCase(
                testDescription: "first timer",
                headCommentFields: #""author": {"__typename": "User", "login": "newcomer"}, "authorAssociation": "FIRST_TIMER", "viewerDidAuthor": false"#,
                expected: .untrusted
            ),
            GitHubAuthorTrustCase(
                testDescription: "no association",
                headCommentFields: #""author": {"__typename": "User", "login": "stranger"}, "authorAssociation": "NONE", "viewerDidAuthor": false"#,
                expected: .untrusted
            ),
            GitHubAuthorTrustCase(
                testDescription: "GitHub App bot without association",
                headCommentFields: #""author": {"__typename": "Bot", "login": "chatgpt-codex-connector"}, "authorAssociation": "NONE", "viewerDidAuthor": false"#,
                expected: .trusted
            ),
            GitHubAuthorTrustCase(
                testDescription: "viewer who is a member",
                headCommentFields: #""author": {"__typename": "User", "login": "viewer"}, "authorAssociation": "MEMBER", "viewerDidAuthor": true"#,
                expected: .untrusted
            ),
            GitHubAuthorTrustCase(
                testDescription: "missing association",
                headCommentFields: #""author": {"__typename": "User", "login": "maintainer"}, "viewerDidAuthor": false"#,
                expected: .unknown
            ),
            GitHubAuthorTrustCase(
                testDescription: "missing viewerDidAuthor",
                headCommentFields: #""author": {"__typename": "User", "login": "maintainer"}, "authorAssociation": "MEMBER""#,
                expected: .unknown
            ),
        ]
    )
    func reviewThreadCommentAuthorTrust(_ testCase: GitHubAuthorTrustCase) throws {
        let threads = try GitHubCLIProvider.parseReviewThreads(
            Self.authorTrustReviewThreadOutput(headCommentFields: testCase.headCommentFields)
        )

        let thread = try #require(threads.first)
        #expect(thread.comments.first?.authorTrust == testCase.expected)
        #expect(thread.comments.last?.authorTrust == .untrusted)
        #expect(thread.headAuthorTrust == testCase.expected)
    }

    private static func authorTrustReviewThreadOutput(headCommentFields: String) -> String {
        """
        {
          "data": {
            "repository": {
              "pullRequest": {
                "reviewThreads": {
                  "nodes": [
                    {
                      "id": "PRRT_trust",
                      "isResolved": false,
                      "isOutdated": false,
                      "comments": {
                        "nodes": [
                          {
                            "id": "PRRC_head",
                            "body": "Please rename this.",
                            \(headCommentFields)
                          },
                          {
                            "id": "PRRC_reply",
                            "body": "Done.",
                            "author": { "__typename": "User", "login": "viewer" },
                            "authorAssociation": "OWNER",
                            "viewerDidAuthor": true
                          }
                        ]
                      }
                    }
                  ],
                  "pageInfo": { "hasNextPage": false, "endCursor": null }
                }
              }
            }
          }
        }
        """
    }

```

The second comment is the viewer's own reply. It is always `.untrusted`, so the trusted cases also prove that `headAuthorTrust` reads the head comment and not the last one.

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/GitHubCLIProviderTests test > /tmp/alas-test.log 2>&1; grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log
```
Expected: `** TEST FAILED **`. `grep -E 'error:' /tmp/alas-test.log` shows `cannot find type 'ReviewAuthorTrust' in scope` and `value of type 'ReviewThread' has no member 'headAuthorTrust'`.

- [ ] **Step 3: Add the trust model**

In `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/CodeHostModels.swift`, replace lines 302-322 (the whole `public struct ReviewComment` declaration) with:

```swift
/// Whether a review comment's author may steer the PR shepherd. Only
/// `trusted` comments trigger automatic fixes; `unknown` means the provider
/// could not classify the author and is treated like `untrusted`.
public enum ReviewAuthorTrust: String, Codable, Equatable, Sendable {
    case trusted
    case untrusted
    case unknown
}

public struct ReviewComment: Identifiable, Equatable, Sendable {
    public let id: String
    public let author: String?
    public let body: String
    public let url: URL?
    public let createdAt: Date?
    public let viewerCanUpdate: Bool
    public let viewerCanDelete: Bool
    public let isPending: Bool
    public let authorTrust: ReviewAuthorTrust

    public init(
        id: String,
        author: String?,
        body: String,
        url: URL?,
        createdAt: Date?,
        viewerCanUpdate: Bool,
        viewerCanDelete: Bool,
        isPending: Bool,
        authorTrust: ReviewAuthorTrust = .unknown
    ) {
        self.id = id
        self.author = author
        self.body = body
        self.url = url
        self.createdAt = createdAt
        self.viewerCanUpdate = viewerCanUpdate
        self.viewerCanDelete = viewerCanDelete
        self.isPending = isPending
        self.authorTrust = authorTrust
    }
}
```

In the same file, inside `ReviewThread`, right after the existing line 439 `    public var body: String { headComment?.body ?? "" }`, insert:

```swift
    public var headAuthorTrust: ReviewAuthorTrust { headComment?.authorTrust ?? .unknown }
```

- [ ] **Step 4: Keep trust on optimistic comment edits**

In `Alas/Sources/Center/Review/ReviewThreadMutations.swift`, replace lines 36-45:

```swift
            let updated = ReviewComment(
                id: comment.id,
                author: comment.author,
                body: newBody,
                url: comment.url,
                createdAt: comment.createdAt,
                viewerCanUpdate: comment.viewerCanUpdate,
                viewerCanDelete: comment.viewerCanDelete,
                isPending: comment.isPending
            )
```

with:

```swift
            let updated = ReviewComment(
                id: comment.id,
                author: comment.author,
                body: newBody,
                url: comment.url,
                createdAt: comment.createdAt,
                viewerCanUpdate: comment.viewerCanUpdate,
                viewerCanDelete: comment.viewerCanDelete,
                isPending: comment.isPending,
                authorTrust: comment.authorTrust
            )
```

- [ ] **Step 5: Request the author fields in the GitHub thread query**

In `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/GitHubCLIProvider.swift`, inside `reviewThreadsQuery`, replace lines 94-97:

```
                  author {
                    login
                  }
                  viewerDidAuthor
```

with:

```
                  author {
                    __typename
                    login
                  }
                  authorAssociation
                  viewerDidAuthor
```

Change only `reviewThreadsQuery`. The reply and update mutations (`addPullRequestReviewThreadReplyMutation`, `updatePullRequestReviewCommentMutation`) keep their selections. Their results are the viewer's own comments, which stay `.unknown` until the next refresh.

- [ ] **Step 6: Decode the new fields**

In the same file, replace `ReviewThreadCommentNode` (lines 2709-2727) with:

```swift
private struct ReviewThreadCommentNode: Decodable {
    let id: String?
    let body: String
    let url: String?
    let createdAt: String?
    let diffHunk: String?
    let author: ReviewThreadAuthor?
    let authorAssociation: String?
    let viewerDidAuthor: Bool?

    public init(
        id: String?,
        body: String,
        url: String?,
        createdAt: String?,
        diffHunk: String?,
        author: ReviewThreadAuthor?,
        authorAssociation: String? = nil,
        viewerDidAuthor: Bool?
    ) {
        self.id = id
        self.body = body
        self.url = url
        self.createdAt = createdAt
        self.diffHunk = diffHunk
        self.author = author
        self.authorAssociation = authorAssociation
        self.viewerDidAuthor = viewerDidAuthor
    }
}
```

Replace `ReviewThreadAuthor` (lines 2757-2763) with:

```swift
private struct ReviewThreadAuthor: Decodable {
    let login: String
    /// GraphQL `Actor` concrete type: `User`, `Bot`, `Mannequin`, ...
    let typename: String?

    private enum CodingKeys: String, CodingKey {
        case login
        case typename = "__typename"
    }

    public init(login: String, typename: String? = nil) {
        self.login = login
        self.typename = typename
    }
}
```

- [ ] **Step 7: Map the fields to trust**

In `parseReviewThreadsPage`, replace lines 1764-1773 (the `ReviewComment(...)` initializer inside the `allComments` map):

```swift
                ReviewComment(
                    id: c.id ?? "\(node.id)-\(index)",
                    author: c.author?.login,
                    body: c.body,
                    url: try parseOptionalHTTPURL(c.url, context: "gh review threads returned an invalid URL"),
                    createdAt: try? parseOptionalDate(c.createdAt),
                    viewerCanUpdate: c.viewerDidAuthor ?? false,
                    viewerCanDelete: c.viewerDidAuthor ?? false,
                    isPending: false
                )
```

with:

```swift
                ReviewComment(
                    id: c.id ?? "\(node.id)-\(index)",
                    author: c.author?.login,
                    body: c.body,
                    url: try parseOptionalHTTPURL(c.url, context: "gh review threads returned an invalid URL"),
                    createdAt: try? parseOptionalDate(c.createdAt),
                    viewerCanUpdate: c.viewerDidAuthor ?? false,
                    viewerCanDelete: c.viewerDidAuthor ?? false,
                    isPending: false,
                    authorTrust: authorTrust(
                        viewerDidAuthor: c.viewerDidAuthor,
                        authorAssociation: c.authorAssociation,
                        authorTypename: c.author?.typename
                    )
                )
```

Right after the closing `}` of `parseReviewThreadsPage` (line 1799, the line before `    private static func parseAddThreadReplyResponse(_ json: String) throws -> ReviewComment {`), insert:

```swift

    /// Repository owners, organization members, collaborators and GitHub Apps
    /// (`Bot`) are trusted. The viewer's own comments never are: the shepherd
    /// must not act on its own replies. Without the viewer flag or the
    /// association (for a non-bot) the author can't be classified.
    private static func authorTrust(
        viewerDidAuthor: Bool?,
        authorAssociation: String?,
        authorTypename: String?
    ) -> ReviewAuthorTrust {
        if viewerDidAuthor == true { return .untrusted }
        if authorTypename == "Bot" { return .trusted }
        guard viewerDidAuthor == false,
              let association = authorAssociation?.uppercased(),
              !association.isEmpty
        else { return .unknown }
        switch association {
        case "OWNER", "MEMBER", "COLLABORATOR":
            return .trusted
        default:
            return .untrusted
        }
    }
```

- [ ] **Step 8: Run the test to verify it passes**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/GitHubCLIProviderTests test > /tmp/alas-test.log 2>&1; grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log
```
Expected: `** TEST SUCCEEDED **`, no `✘` lines. The `Test run with N tests` line includes the 10 `reviewThreadCommentAuthorTrust` cases. The existing `reviewThreadsJSONParsesActionableSummaries` and `reviewThreadsJSONIgnoresMalformedLocationMetadata` still pass, because their fixtures lack the new optional fields.

- [ ] **Step 9: Commit**

```bash
git add Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/CodeHostModels.swift \
  Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/GitHubCLIProvider.swift \
  Alas/Sources/Center/Review/ReviewThreadMutations.swift \
  AlasTests/Integrations/GitHubCLIProviderTests.swift
git commit -m "feat(codehost): classify GitHub review comment author trust"
```

---

### Task 2: GitLab review comment author trust

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/GitLabCLIProvider.swift:9-18` (stored properties and `init`), `:1070` (insert after `currentUserUsername(remote:cwd:)`), `:1349-1350` (end of `unresolvedDiscussions`), `:1468-1532` (`parseDiscussions`), `:2029` (insert after `parseCurrentUserUsername`), `:2140` (insert after `GitLabPendingComments`), `:2650-2656` (`GitLabDiscussionAuthor`)
- Test: `AlasTests/Integrations/GitLabCLIProviderTests.swift` (insert before `@Test func noteIDRequiresNumericCommentID()` at line 2048)

**Interfaces:**
- Consumes (Task 1): `ReviewAuthorTrust`; `ReviewComment.init(..., isPending:, authorTrust: ReviewAuthorTrust = .unknown)`; `ReviewThread.headAuthorTrust`.
- Produces:
  - `public enum GitLabAuthorStanding: Equatable, Sendable { case privileged, unprivileged }` with `public static let minimumTrustedAccessLevel = 30` and `public init(accessLevel: Int?, isBot: Bool)`
  - `public final class GitLabAuthorStandingCache: @unchecked Sendable` with `public static let shared` and `public init()`
  - `GitLabCLIProvider.init(runner: any CodeHostCommandRunning = ProcessCodeHostCommandRunner(), authorStandingCache: GitLabAuthorStandingCache = .shared)`
  - `GitLabCLIProvider.parseDiscussions(_ json: String, requestURL: URL, currentUserUsername: String? = nil, authorStandings: [Int: GitLabAuthorStanding] = [:]) throws -> [ReviewThread]`
  - GitLab threads from `currentReviewRequest` / `reviewRequest(remote:number:cwd:)` carry `authorTrust`.

Concurrency choice: `GitLabAuthorStandingCache` is an `NSLock`-guarded `@unchecked Sendable` class, the same shape as `GitLabPendingComments` (lines 2101-2140). The provider is a `Sendable` struct that can be reached from several tasks. Cache reads and writes are single dictionary operations, so a lock gives synchronous hits with no `await`, and the network calls run outside the critical section either way. An actor would add hops and change nothing. Two refreshes that miss on the same id at the same time both fetch it and store the same answer, so the race costs one redundant call.

- [ ] **Step 1: Write the failing tests**

In `AlasTests/Integrations/GitLabCLIProviderTests.swift`, insert immediately before the line `    @Test func noteIDRequiresNumericCommentID() throws {`:

```swift
    struct DiscussionTrustCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let author: String
        let currentUserUsername: String?
        let standings: [Int: GitLabAuthorStanding]
        let expected: ReviewAuthorTrust
    }

    @Test(
        "Discussion comments map viewer and project standing to author trust",
        arguments: [
            DiscussionTrustCase(
                testDescription: "privileged author",
                author: #"{ "id": 7, "username": "maintainer" }"#,
                currentUserUsername: "viewer",
                standings: [7: .privileged],
                expected: .trusted
            ),
            DiscussionTrustCase(
                testDescription: "unprivileged author",
                author: #"{ "id": 7, "username": "maintainer" }"#,
                currentUserUsername: "viewer",
                standings: [7: .unprivileged],
                expected: .untrusted
            ),
            DiscussionTrustCase(
                testDescription: "viewer, matched case-insensitively, even when privileged",
                author: #"{ "id": 1, "username": "Viewer" }"#,
                currentUserUsername: "viewer",
                standings: [1: .privileged],
                expected: .untrusted
            ),
            DiscussionTrustCase(
                testDescription: "standing not resolved",
                author: #"{ "id": 7, "username": "maintainer" }"#,
                currentUserUsername: "viewer",
                standings: [:],
                expected: .unknown
            ),
            DiscussionTrustCase(
                testDescription: "author without id",
                author: #"{ "username": "maintainer" }"#,
                currentUserUsername: "viewer",
                standings: [7: .privileged],
                expected: .unknown
            ),
            DiscussionTrustCase(
                testDescription: "viewer unknown",
                author: #"{ "id": 7, "username": "maintainer" }"#,
                currentUserUsername: nil,
                standings: [7: .privileged],
                expected: .unknown
            ),
        ]
    )
    func discussionCommentAuthorTrust(_ testCase: DiscussionTrustCase) throws {
        let threads = try GitLabCLIProvider.parseDiscussions(
            Self.singleNoteDiscussionsOutput(author: testCase.author),
            requestURL: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42")!,
            currentUserUsername: testCase.currentUserUsername,
            authorStandings: testCase.standings
        )

        let thread = try #require(threads.first)
        #expect(thread.comments.first?.authorTrust == testCase.expected)
        #expect(thread.headAuthorTrust == testCase.expected)
    }

    @Test("Author standing comes from member and user lookups and is cached across refreshes")
    func authorStandingLookupsAreCachedAcrossRefreshes() async throws {
        let members = "projects/platform%2Fmobile%2Falas/members/all"
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.trustDiscussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"username":"viewer"}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"id":7,"username":"maintainer","access_level":30}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"id":8,"username":"reporter","access_level":20}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"id":8,"username":"reporter","bot":false}"#, stderr: ""),
            ProcessResult(exitCode: 1, stdout: #"{"message":"404 Not found"}"#, stderr: "glab: 404 Not Found (HTTP 404)"),
            ProcessResult(exitCode: 0, stdout: #"{"id":9,"username":"review-bot","bot":true}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineWithJobsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.trustDiscussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"username":"viewer"}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineWithJobsOutput, stderr: ""),
        ])
        let provider = GitLabCLIProvider(runner: runner, authorStandingCache: GitLabAuthorStandingCache())
        let expected: [String: ReviewAuthorTrust] = [
            "by-maintainer": .trusted,
            "by-reporter": .untrusted,
            "by-bot": .trusted,
            "by-viewer": .untrusted,
        ]

        let first = try await provider.reviewRequest(remote: Self.remote, number: 42, cwd: Self.cwd)
        let second = try await provider.reviewRequest(remote: Self.remote, number: 42, cwd: Self.cwd)

        #expect(Dictionary(uniqueKeysWithValues: first.threads.map { ($0.id, $0.headAuthorTrust) }) == expected)
        #expect(Dictionary(uniqueKeysWithValues: second.threads.map { ($0.id, $0.headAuthorTrust) }) == expected)
        let userLookup = ["api", "user", "--hostname", "gitlab.example.com", "--output", "json"]
        let standingLookups = await runner.commands.map(\.args).filter { $0.first == "api" && $0 != userLookup }
        #expect(standingLookups == [
            ["api", "\(members)/7", "--hostname", "gitlab.example.com", "--output", "json"],
            ["api", "\(members)/8", "--hostname", "gitlab.example.com", "--output", "json"],
            ["api", "users/8", "--hostname", "gitlab.example.com", "--output", "json"],
            ["api", "\(members)/9", "--hostname", "gitlab.example.com", "--output", "json"],
            ["api", "users/9", "--hostname", "gitlab.example.com", "--output", "json"],
        ])
    }

    private static func singleNoteDiscussionsOutput(author: String) -> String {
        """
        [
          {
            "id": "discussion-trust",
            "notes": [
              {
                "id": 801,
                "body": "Please rename this.",
                "system": false,
                "resolvable": true,
                "resolved": false,
                "author": \(author)
              }
            ]
          }
        ]
        """
    }

    private static let trustDiscussionsOutput = """
    [
      {
        "id": "by-maintainer",
        "notes": [
          { "id": 701, "body": "Rename this.", "system": false, "resolvable": true, "resolved": false,
            "author": { "id": 7, "username": "maintainer" } }
        ]
      },
      {
        "id": "by-reporter",
        "notes": [
          { "id": 702, "body": "Maybe split this.", "system": false, "resolvable": true, "resolved": false,
            "author": { "id": 8, "username": "reporter" } }
        ]
      },
      {
        "id": "by-bot",
        "notes": [
          { "id": 703, "body": "Possible nil dereference.", "system": false, "resolvable": true, "resolved": false,
            "author": { "id": 9, "username": "review-bot" } }
        ]
      },
      {
        "id": "by-viewer",
        "notes": [
          { "id": 704, "body": "Note to self.", "system": false, "resolvable": true, "resolved": false,
            "author": { "id": 1, "username": "viewer" } }
        ]
      }
    ]
    """

```

The second test pins four things:
- Access level 30 is trusted with no users call.
- Level 20 asks the users API and stays untrusted when not a bot.
- A 404 membership plus `bot: true` is trusted.
- The viewer is never looked up, and the second refresh makes no lookups at all.

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/GitLabCLIProviderTests test > /tmp/alas-test.log 2>&1; grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log
```
Expected: `** TEST FAILED **`. `grep -E 'error:' /tmp/alas-test.log` shows `cannot find type 'GitLabAuthorStanding' in scope` and `cannot find 'GitLabAuthorStandingCache' in scope`.

- [ ] **Step 3: Add the standing type and cache**

In `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/GitLabCLIProvider.swift`, right after the closing `}` of `GitLabPendingComments` (line 2140, the `}` after `    public init() {}`), insert:

```swift

/// A GitLab comment author's standing in the project, which decides trust
/// for anyone other than the viewer.
public enum GitLabAuthorStanding: Equatable, Sendable {
    /// A bot, or a member with Developer (30) access or higher.
    case privileged
    /// Not a member, or a member below Developer, and not a bot.
    case unprivileged

    public static let minimumTrustedAccessLevel = 30

    public init(accessLevel: Int?, isBot: Bool) {
        self = isBot || (accessLevel ?? 0) >= Self.minimumTrustedAccessLevel ? .privileged : .unprivileged
    }
}

/// Author standings keyed by host, project and user id.
///
/// `@unchecked Sendable` for the same reason as `GitLabPendingComments`: the
/// only mutable state is `entries`, and every access goes through `lock`.
/// `shared` is the provider default because registries create provider
/// instances per call site. Entries expire after an hour so a role change
/// is picked up without restarting Alas.
public final class GitLabAuthorStandingCache: @unchecked Sendable {
    public static let shared = GitLabAuthorStandingCache()
    static let timeToLive: TimeInterval = 60 * 60

    private struct Entry {
        let standing: GitLabAuthorStanding
        let storedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    func standing(host: String, projectPath: String, userID: Int, now: Date = Date()) -> GitLabAuthorStanding? {
        let key = Self.key(host: host, projectPath: projectPath, userID: userID)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], now.timeIntervalSince(entry.storedAt) < Self.timeToLive else { return nil }
        return entry.standing
    }

    func store(_ standing: GitLabAuthorStanding, host: String, projectPath: String, userID: Int, now: Date = Date()) {
        let key = Self.key(host: host, projectPath: projectPath, userID: userID)
        lock.lock()
        defer { lock.unlock() }
        entries[key] = Entry(standing: standing, storedAt: now)
    }

    private static func key(host: String, projectPath: String, userID: Int) -> String {
        "\(host.lowercased())|\(projectPath.lowercased())|\(userID)"
    }
}
```

- [ ] **Step 4: Decode author ids and the lookup payloads**

Replace `GitLabDiscussionAuthor` (lines 2650-2656) with the following. The two new response types follow it:

```swift
private struct GitLabDiscussionAuthor: Decodable {
    let id: Int?
    let username: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Lenient: an unexpected id shape must not drop the whole note.
        self.id = try? container.decodeIfPresent(Int.self, forKey: .id)
        self.username = try container.decodeIfPresent(String.self, forKey: .username)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case username
    }

    public init(id: Int? = nil, username: String?) {
        self.id = id
        self.username = username
    }
}

private struct GitLabMemberResponse: Decodable {
    let accessLevel: Int?

    private enum CodingKeys: String, CodingKey {
        case accessLevel = "access_level"
    }
}

private struct GitLabUserResponse: Decodable {
    let bot: Bool?
}
```

Right after the closing `}` of `public static func parseCurrentUserUsername(_ json: String) throws -> String` (line 2029), insert:

```swift

    static func parseMemberAccessLevel(_ json: String) throws -> Int {
        let member: GitLabMemberResponse
        do {
            member = try JSONDecoder().decode(GitLabMemberResponse.self, from: Data(json.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab api member output")
        }
        guard let accessLevel = member.accessLevel else {
            throw CodeHostProviderError.malformedOutput("glab api member output is missing access_level")
        }
        return accessLevel
    }

    /// `bot` is missing on GitLab versions that predate it; that reads as a human.
    static func parseUserIsBot(_ json: String) throws -> Bool {
        let user: GitLabUserResponse
        do {
            user = try JSONDecoder().decode(GitLabUserResponse.self, from: Data(json.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab api users output")
        }
        return user.bot ?? false
    }
```

- [ ] **Step 5: Split `parseDiscussions` and add trust mapping**

Replace the whole `public static func parseDiscussions(...)` (lines 1468-1532) with:

```swift
    public static func parseDiscussions(
        _ json: String,
        requestURL: URL,
        currentUserUsername: String? = nil,
        authorStandings: [Int: GitLabAuthorStanding] = [:]
    ) throws -> [ReviewThread] {
        try threads(
            from: decodeDiscussions(json),
            requestURL: requestURL,
            currentUserUsername: currentUserUsername,
            authorStandings: authorStandings
        )
    }

    private static func decodeDiscussions(_ json: String) throws -> [GitLabDiscussion] {
        do {
            return try JSONDecoder().decode([GitLabDiscussion].self, from: Data(json.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab mr note list output")
        }
    }

    /// Non-system notes with a non-empty body: the notes that become comments.
    private static func actionableNotes(in discussion: GitLabDiscussion) -> [GitLabDiscussionNote] {
        discussion.notes.filter { note in
            !note.isSystem && !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Ids of thread-head authors whose standing must be looked up, sorted for
    /// a stable request order. Only head comments decide `headAuthorTrust`,
    /// so reply authors are not looked up. Empty when the viewer is unknown:
    /// every comment is then `.unknown`, so lookups would be wasted.
    private static func standingLookupAuthorIDs(
        in discussions: [GitLabDiscussion],
        currentUserUsername: String?
    ) -> [Int] {
        guard let viewer = normalizedOptionalString(currentUserUsername)?.lowercased() else { return [] }
        var ids = Set<Int>()
        for discussion in discussions {
            guard let author = actionableNotes(in: discussion).first?.author,
                  let id = author.id,
                  let username = normalizedOptionalString(author.username),
                  username.lowercased() != viewer
            else { continue }
            ids.insert(id)
        }
        return ids.sorted()
    }

    /// Trusted when the author is not the viewer and is a bot or has
    /// Developer access or higher.
    private static func authorTrust(
        of author: GitLabDiscussionAuthor?,
        currentUserUsername: String?,
        authorStandings: [Int: GitLabAuthorStanding]
    ) -> ReviewAuthorTrust {
        guard let username = normalizedOptionalString(author?.username),
              let viewer = normalizedOptionalString(currentUserUsername)
        else { return .unknown }
        if username.lowercased() == viewer.lowercased() { return .untrusted }
        guard let id = author?.id, let standing = authorStandings[id] else { return .unknown }
        return standing == .privileged ? .trusted : .untrusted
    }

    private static func threads(
        from discussions: [GitLabDiscussion],
        requestURL: URL,
        currentUserUsername: String?,
        authorStandings: [Int: GitLabAuthorStanding]
    ) throws -> [ReviewThread] {
        try discussions.compactMap { discussion in
            let notes = Self.actionableNotes(in: discussion)
            guard let firstNote = notes.first else {
                return nil
            }

            // Use the first note's position for the thread-level anchor fields.
            // Assumed GitLab note position keys: new_path, new_line, old_line, old_path
            // (from glab mr note list --output json).
            let position = firstNote.position
            let comments: [ReviewComment] = try notes.enumerated().map { index, note in
                let commentURL = try discussionURL(note: note, requestURL: requestURL)
                let isViewer = note.author?.username.map { currentUserUsername == $0 } ?? false
                return ReviewComment(
                    id: note.id.map(String.init) ?? "\(discussion.id)-\(index)",
                    author: note.author?.username,
                    body: note.body,
                    url: commentURL,
                    createdAt: try? parseOptionalGitLabDate(note.createdAt),
                    viewerCanUpdate: isViewer,
                    viewerCanDelete: isViewer,
                    isPending: false,
                    authorTrust: authorTrust(
                        of: note.author,
                        currentUserUsername: currentUserUsername,
                        authorStandings: authorStandings
                    )
                )
            }

            let firstURL = try discussionURL(note: firstNote, requestURL: requestURL)
            let isOldSide = position?.newLine == nil && position?.oldLine != nil
            return ReviewThread(
                id: discussion.id,
                path: position?.newPath ?? position?.oldPath,
                line: position?.newLine,
                startLine: position?.newLine == nil ? nil : position?.lineRange?.start.newLine,
                originalLine: position?.oldLine,
                originalStartLine: isOldSide ? position?.lineRange?.start.oldLine : nil,
                diffHunk: nil,
                diffSide: isOldSide ? "LEFT" : nil,
                isResolved: discussion.isResolved,
                isOutdated: false,
                // File-level only when there is no line anchor on either side
                isFileLevel: position == nil || (position?.newLine == nil && position?.oldLine == nil),
                comments: comments,
                // glab does not report per-thread viewer capabilities; assume true (real availability is gated by provider capabilities).
                viewerCanResolve: true,
                viewerCanUnresolve: true,
                viewerCanReply: true,
                url: firstURL
            )
        }
    }
```

This keeps every pre-existing behavior of `parseDiscussions`: the same note filter, error message, position mapping and `isViewer` editability.

- [ ] **Step 6: Inject the cache**

Replace lines 9-18 (from `    private let runner: any CodeHostCommandRunning` through the closing `}` of `init`) with:

```swift
    private let runner: any CodeHostCommandRunning

    // Reference-type buffer so the struct doesn't need to be mutating. The
    // buffer serialises its own access with a lock, which is what lets this
    // `Sendable` struct hold it (see `GitLabPendingComments`).
    private let pendingComments = GitLabPendingComments()

    // Process-wide by default (see `GitLabAuthorStandingCache`); tests pass
    // their own so cases stay independent.
    private let authorStandingCache: GitLabAuthorStandingCache

    public init(
        runner: any CodeHostCommandRunning = ProcessCodeHostCommandRunner(),
        authorStandingCache: GitLabAuthorStandingCache = .shared
    ) {
        self.runner = runner
        self.authorStandingCache = authorStandingCache
    }
```

- [ ] **Step 7: Look up standings while loading discussions**

Right after the closing `}` of `private func currentUserUsername(remote:cwd:)` (line 1070), insert:

```swift

    /// Standing of each author id in this project, from the cache or the
    /// members/users APIs. Ids whose lookup fails are left out, so their
    /// comments stay `.unknown` and nothing is cached for them.
    private func authorStandings(
        for authorIDs: [Int],
        remote: CodeHostRemote,
        cwd: URL
    ) async -> [Int: GitLabAuthorStanding] {
        var standings: [Int: GitLabAuthorStanding] = [:]
        for userID in authorIDs {
            if let cached = authorStandingCache.standing(
                host: remote.host,
                projectPath: remote.repositorySlug,
                userID: userID
            ) {
                standings[userID] = cached
                continue
            }
            guard let standing = await fetchAuthorStanding(userID: userID, remote: remote, cwd: cwd) else { continue }
            authorStandingCache.store(standing, host: remote.host, projectPath: remote.repositorySlug, userID: userID)
            standings[userID] = standing
        }
        return standings
    }

    /// `members/all` includes access inherited from groups; a 404 means "not a
    /// member". Note payloads carry no `bot` flag, so the users API is asked
    /// only when membership alone doesn't already make the author trusted.
    private func fetchAuthorStanding(userID: Int, remote: CodeHostRemote, cwd: URL) async -> GitLabAuthorStanding? {
        guard let member = try? await runner.run(
            "glab",
            args: [
                "api", "projects/\(Self.encodedProjectPath(remote.repositorySlug))/members/all/\(userID)",
                "--hostname", remote.host, "--output", "json",
            ],
            cwd: cwd
        ) else { return nil }

        let accessLevel: Int?
        if member.exitCode == 0 {
            guard let level = try? Self.parseMemberAccessLevel(member.stdout) else { return nil }
            accessLevel = level
        } else if case .notFound? = CodeHostIssueProviderError.classification(
            // `number` only feeds the error message, which is discarded here.
            provider: kind, remote: remote, number: userID, result: member
        ) {
            accessLevel = nil
        } else {
            return nil
        }
        if let accessLevel, accessLevel >= GitLabAuthorStanding.minimumTrustedAccessLevel {
            return .privileged
        }

        guard let user = try? await runner.run(
            "glab",
            args: ["api", "users/\(userID)", "--hostname", remote.host, "--output", "json"],
            cwd: cwd
        ), user.exitCode == 0,
            let isBot = try? Self.parseUserIsBot(user.stdout)
        else { return nil }
        return GitLabAuthorStanding(accessLevel: accessLevel, isBot: isBot)
    }
```

In `unresolvedDiscussions`, replace lines 1349-1350:

```swift
        let currentUserUsername = await currentUserUsername(remote: remote, cwd: cwd)
        return try Self.parseDiscussions(result.stdout, requestURL: request.url, currentUserUsername: currentUserUsername)
```

with:

```swift
        let currentUserUsername = await currentUserUsername(remote: remote, cwd: cwd)
        let discussions = try Self.decodeDiscussions(result.stdout)
        let standings = await authorStandings(
            for: Self.standingLookupAuthorIDs(in: discussions, currentUserUsername: currentUserUsername),
            remote: remote,
            cwd: cwd
        )
        return try Self.threads(
            from: discussions,
            requestURL: request.url,
            currentUserUsername: currentUserUsername,
            authorStandings: standings
        )
```

The `glab api user` call stays where it was, so the command order asserted by `currentReviewRequestUsesExpectedMRListCommand` and the publish/mutation tests (`["mr", "note"], ["api", "user"], ["ci", "get"]`) does not change. Their fixtures have no `author.id`, so they trigger no lookups.

- [ ] **Step 8: Run the tests to verify they pass**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/GitLabCLIProviderTests test > /tmp/alas-test.log 2>&1; grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log
```
Expected: `** TEST SUCCEEDED **`, no `✘` lines. The run includes the 6 `discussionCommentAuthorTrust` cases and `authorStandingLookupsAreCachedAcrossRefreshes`.

- [ ] **Step 9: Commit**

```bash
git add Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/GitLabCLIProvider.swift \
  AlasTests/Integrations/GitLabCLIProviderTests.swift
git commit -m "feat(codehost): classify GitLab review comment author trust"
```

---

### Task 3: Reviewers on the current head

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/CodeHostProvider.swift:283` (insert after the `repositoryParent` requirement), `:502` (insert after the default `repositoryParent` in `extension CodeHostProvider`)
- Modify: `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/GitHubCLIProvider.swift`. Anchors, with line numbers from before Task 1:
  - after `reviewThreadsQuery` (ends line 109)
  - after `reviewThreadsPage(remote:request:cursor:cwd:)` (ends line 784)
  - after `parseReviewThreadsPage` (ends line 1799; Task 1 adds `authorTrust(viewerDidAuthor:authorAssociation:authorTypename:)` there, so insert after that)
  - after `ReviewThreadAuthor` (ends line 2763)
- Modify: `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/GitLabCLIProvider.swift`. Anchors, with line numbers from before Task 2:
  - after `unresolvedDiscussions(remote:request:cwd:)` (ends line 1351)
  - after `parseCurrentUserUsername` (ends line 2029; Task 2 adds `parseMemberAccessLevel` / `parseUserIsBot` there, so insert after `parseUserIsBot`)
  - after `GitLabCurrentUser` (ends line 2648)
- Test: `AlasTests/Integrations/GitHubCLIProviderTests.swift` (insert before `@Test func githubPublishReviewUsesGraphQLPayloadAndRefreshesPR()`), `AlasTests/Integrations/GitLabCLIProviderTests.swift` (insert before `@Test func noteIDRequiresNumericCommentID()`)
- Unchanged, compile through the protocol default (verified in Step 7). `git grep` lists 10 test conformers:
  - `AlasTests/ACP/UpstreamReferenceTestSupport.swift:11` `StubReferenceProvider`
  - `AlasTests/Center/CommitPublishLiveOperationsTests.swift:638` `CapturedPublishProvider`
  - `AlasTests/Integrations/CodeHostProviderTests.swift:261` `FakeCodeHostProvider`
  - `AlasTests/Integrations/MergedReviewRequestTests.swift:310` `MergeQueryUnsupportedProvider`
  - `AlasTests/Integrations/ReviewLoopStateTests.swift:1459` `FakeCodeHostProvider`
  - `AlasTests/Integrations/ReviewRequestDiffLoaderTests.swift:510` `FakeDiffProvider`, `:522` `FakeHostedImageProvider`
  - `AlasTests/ReviewSessionLoaderTests.swift:307` `FakeReviewRequestProvider`
  - `AlasTests/ReviewSessionTabViewTests.swift:1342` `FakeProviderReviewMutator`, `:1407` `RecordingProviderReviewMutator`

**Interfaces:**
- Consumes: `ReviewRequest.headSHA: String?`, `ReviewRequest.number`, `CodeHostRemote.host/owner/repository/repositorySlug` (existing). From Task 2 (only if already landed): `GitLabDiscussionAuthor` with optional `id`. This task reads only `username`, so it works either way.
- Produces:
  - `CodeHostProvider.reviewersOnHead(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> Set<String>`, default throws `CodeHostProviderError.unsupportedProvider(remote.kind)`
  - `GitHubCLIProvider.reviewersOnHeadQuery: String` (public static)
  - `GitHubCLIProvider.parseReviewersOnHead(_ json: String, headSHA: String) throws -> Set<String>`
  - `GitLabCLIProvider.parseReviewersOnHead(approvalsJSON: String, notesJSON: String, headCommitJSON: String) throws -> Set<String>`
  - All returned logins are lowercased. A nil or empty `request.headSHA` throws `CodeHostProviderError.malformedOutput`.

- [ ] **Step 1: Write the failing GitHub test**

In `AlasTests/Integrations/GitHubCLIProviderTests.swift`, insert immediately before `    @Test func githubPublishReviewUsesGraphQLPayloadAndRefreshesPR() async throws {`:

```swift
    struct ReviewersOnHeadCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let lastCommitOID: String
        let reviews: String
        let comments: String
        let expected: Set<String>
    }

    @Test(
        "Reviewers on head keep head-commit reviews and comments posted after the head commit",
        arguments: [
            ReviewersOnHeadCase(
                testDescription: "review on head counts, lowercased",
                lastCommitOID: "head-sha-42",
                reviews: #"{"author": {"login": "Codex-Connector"}, "commit": {"oid": "head-sha-42"}}"#,
                comments: "",
                expected: ["codex-connector"]
            ),
            ReviewersOnHeadCase(
                testDescription: "review on an older commit does not count",
                lastCommitOID: "head-sha-42",
                reviews: #"{"author": {"login": "maintainer"}, "commit": {"oid": "old-sha"}}"#,
                comments: "",
                expected: []
            ),
            ReviewersOnHeadCase(
                testDescription: "comment after the head commit counts",
                lastCommitOID: "head-sha-42",
                reviews: "",
                comments: #"{"author": {"login": "Maintainer"}, "createdAt": "2026-10-13T10:05:00Z"}"#,
                expected: ["maintainer"]
            ),
            ReviewersOnHeadCase(
                testDescription: "comment before the head commit does not count",
                lastCommitOID: "head-sha-42",
                reviews: "",
                comments: #"{"author": {"login": "maintainer"}, "createdAt": "2026-10-13T09:55:00Z"}"#,
                expected: []
            ),
            ReviewersOnHeadCase(
                testDescription: "moved head ignores comments",
                lastCommitOID: "newer-sha",
                reviews: "",
                comments: #"{"author": {"login": "maintainer"}, "createdAt": "2026-10-13T10:05:00Z"}"#,
                expected: []
            ),
            ReviewersOnHeadCase(
                testDescription: "deleted author is skipped",
                lastCommitOID: "head-sha-42",
                reviews: #"{"author": null, "commit": {"oid": "head-sha-42"}}"#,
                comments: "",
                expected: []
            ),
        ]
    )
    func reviewersOnHeadSelection(_ testCase: ReviewersOnHeadCase) throws {
        let output = Self.reviewersOnHeadOutput(
            lastCommitOID: testCase.lastCommitOID,
            reviews: testCase.reviews,
            comments: testCase.comments
        )

        #expect(try GitHubCLIProvider.parseReviewersOnHead(output, headSHA: "head-sha-42") == testCase.expected)
    }

    private static func reviewersOnHeadOutput(lastCommitOID: String, reviews: String, comments: String) -> String {
        """
        {
          "data": {
            "repository": {
              "pullRequest": {
                "commits": {
                  "nodes": [
                    { "commit": { "oid": "\(lastCommitOID)", "committedDate": "2026-10-13T10:00:00Z" } }
                  ]
                },
                "reviews": { "nodes": [\(reviews)] },
                "comments": { "nodes": [\(comments)] }
              }
            }
          }
        }
        """
    }

```

- [ ] **Step 2: Write the failing GitLab test**

In `AlasTests/Integrations/GitLabCLIProviderTests.swift`, insert immediately before `    @Test func noteIDRequiresNumericCommentID() throws {`:

```swift
    struct GitLabReviewersOnHeadCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let approvals: String
        let notes: String
        let expected: Set<String>
    }

    @Test(
        "Reviewers on head keep current approvals and human notes posted after the head commit",
        arguments: [
            GitLabReviewersOnHeadCase(
                testDescription: "approval without approved_at counts, lowercased",
                approvals: #"{"user": {"id": 7, "username": "Maintainer"}}"#,
                notes: "",
                expected: ["maintainer"]
            ),
            GitLabReviewersOnHeadCase(
                testDescription: "approval after the head commit counts",
                approvals: #"{"user": {"username": "maintainer"}, "approved_at": "2026-10-13T10:05:00.000Z"}"#,
                notes: "",
                expected: ["maintainer"]
            ),
            GitLabReviewersOnHeadCase(
                testDescription: "approval before the head commit does not count",
                approvals: #"{"user": {"username": "maintainer"}, "approved_at": "2026-10-13T09:55:00.000Z"}"#,
                notes: "",
                expected: []
            ),
            GitLabReviewersOnHeadCase(
                testDescription: "note after the head commit counts",
                approvals: "",
                notes: #"{"id": 1, "body": "Looks good.", "system": false, "author": {"username": "Codex"}, "created_at": "2026-10-13T10:05:00.000Z"}"#,
                expected: ["codex"]
            ),
            GitLabReviewersOnHeadCase(
                testDescription: "note before the head commit does not count",
                approvals: "",
                notes: #"{"id": 1, "body": "Looks good.", "system": false, "author": {"username": "codex"}, "created_at": "2026-10-13T09:55:00.000Z"}"#,
                expected: []
            ),
            GitLabReviewersOnHeadCase(
                testDescription: "system note after the head commit does not count",
                approvals: "",
                notes: #"{"id": 1, "body": "approved this merge request", "system": true, "author": {"username": "maintainer"}, "created_at": "2026-10-13T10:05:00.000Z"}"#,
                expected: []
            ),
        ]
    )
    func reviewersOnHeadSelection(_ testCase: GitLabReviewersOnHeadCase) throws {
        let reviewers = try GitLabCLIProvider.parseReviewersOnHead(
            approvalsJSON: "{\"approved_by\": [\(testCase.approvals)]}",
            notesJSON: "[\(testCase.notes)]",
            headCommitJSON: #"{"id": "head123", "created_at": "2026-10-13T10:00:00.000Z"}"#
        )

        #expect(reviewers == testCase.expected)
    }

```

- [ ] **Step 3: Run both suites to verify they fail**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/GitHubCLIProviderTests -only-testing AlasTests/GitLabCLIProviderTests test > /tmp/alas-test.log 2>&1; grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log
```
Expected: `** TEST FAILED **`. `grep -E 'error:' /tmp/alas-test.log` shows `type 'GitHubCLIProvider' has no member 'parseReviewersOnHead'` and the same for `GitLabCLIProvider`.

- [ ] **Step 4: Add the protocol requirement and default**

In `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/CodeHostProvider.swift`, right after line 283 `    func repositoryParent(remote: CodeHostRemote, cwd: URL) async throws -> CodeHostRemote?` (inside `public protocol CodeHostProvider`), insert:

```swift

    /// Lowercased logins that reviewed the request's current head: a review
    /// or approval on `request.headSHA`, or a top-level comment posted after
    /// the head commit. Throws when the provider can't tell, so callers fail
    /// closed instead of reading an empty set as "nobody reviewed".
    func reviewersOnHead(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> Set<String>
```

In the same file, inside `extension CodeHostProvider`, right after the default `repositoryParent` (the `    }` on line 502, before the extension's closing `}` on line 503), insert:

```swift

    // Throwing for the same reason as `mergedReviewRequests`: an empty set
    // would read as "nobody reviewed" rather than "can't tell".
    public func reviewersOnHead(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> Set<String> {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }
```

- [ ] **Step 5: Implement the GitHub side**

In `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/GitHubCLIProvider.swift`, right after the closing `"""` of `reviewThreadsQuery` (the line before `    public static let mergeQueueMetadataQuery = """`), insert:

```swift

    public static let reviewersOnHeadQuery = """
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          commits(last: 1) {
            nodes {
              commit {
                oid
                committedDate
              }
            }
          }
          reviews(last: 100, states: [APPROVED, CHANGES_REQUESTED, COMMENTED]) {
            nodes {
              author {
                login
              }
              commit {
                oid
              }
            }
          }
          comments(last: 100) {
            nodes {
              author {
                login
              }
              createdAt
            }
          }
        }
      }
    }
    """
```

Right after the closing `}` of `private func reviewThreadsPage(remote:request:cursor:cwd:)` (the line before `    private func fetchPRNodeID(`), insert:

```swift

    public func reviewersOnHead(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> Set<String> {
        guard let headSHA = request.headSHA, !headSHA.isEmpty else {
            throw CodeHostProviderError.malformedOutput("GitHub reviewers on head require the pull request head SHA.")
        }
        let result = try await runner.run(
            "gh",
            args: [
                "api", "graphql",
                "--hostname", remote.host,
                "-f", "query=\(Self.reviewersOnHeadQuery)",
                "-F", "owner=\(remote.owner)",
                "-F", "repo=\(remote.repository)",
                "-F", "number=\(request.number)",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }
        return try Self.parseReviewersOnHead(result.stdout, headSHA: headSHA)
    }
```

Right after the closing `}` of the private static `authorTrust(viewerDidAuthor:authorAssociation:authorTypename:)` that Task 1 added after `parseReviewThreadsPage` (the line before `    private static func parseAddThreadReplyResponse(_ json: String) throws -> ReviewComment {`), insert:

```swift

    /// Lowercased logins with a submitted review on `headSHA`, plus authors of
    /// top-level comments created after the head commit. The comment cutoff
    /// only applies while the newest PR commit is `headSHA`; if the head moved
    /// since the request was fetched, comments count for nobody.
    public static func parseReviewersOnHead(_ json: String, headSHA: String) throws -> Set<String> {
        let response: ReviewersOnHeadResponse
        do {
            response = try JSONDecoder().decode(ReviewersOnHeadResponse.self, from: Data(json.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh reviewers output")
        }
        let pullRequest = response.data.repository.pullRequest
        let head = headSHA.lowercased()

        var reviewers = Set<String>()
        for review in pullRequest.reviews.nodes {
            guard review.commit?.oid.lowercased() == head, let login = review.author?.login else { continue }
            reviewers.insert(login.lowercased())
        }
        guard let lastCommit = pullRequest.commits.nodes.last?.commit,
              lastCommit.oid.lowercased() == head,
              let headCommittedAt = try? parseOptionalDate(lastCommit.committedDate)
        else { return reviewers }
        for comment in pullRequest.comments.nodes {
            guard let login = comment.author?.login,
                  let createdAt = try? parseOptionalDate(comment.createdAt),
                  createdAt > headCommittedAt
            else { continue }
            reviewers.insert(login.lowercased())
        }
        return reviewers
    }
```

Right after the closing `}` of `private struct ReviewThreadAuthor` (the line before `private struct AddPullRequestReviewThreadReplyResponse: Decodable {`), insert:

```swift

private struct ReviewersOnHeadResponse: Decodable {
    struct Nodes<Node: Decodable>: Decodable {
        let nodes: [Node]
    }

    struct Login: Decodable {
        let login: String
    }

    struct CommitOID: Decodable {
        let oid: String
    }

    struct HeadCommit: Decodable {
        let oid: String
        let committedDate: String?
    }

    struct CommitNode: Decodable {
        let commit: HeadCommit
    }

    struct Review: Decodable {
        let author: Login?
        let commit: CommitOID?
    }

    struct Comment: Decodable {
        let author: Login?
        let createdAt: String?
    }

    struct PullRequest: Decodable {
        let commits: Nodes<CommitNode>
        let reviews: Nodes<Review>
        let comments: Nodes<Comment>
    }

    struct Repository: Decodable {
        let pullRequest: PullRequest
    }

    struct ResponseData: Decodable {
        let repository: Repository
    }

    let data: ResponseData
}
```

- [ ] **Step 6: Implement the GitLab side**

In `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/GitLabCLIProvider.swift`, right after the closing `}` of `private func unresolvedDiscussions(remote:request:cwd:)` (the line before `    public static func normalizedBaseBranch(_ baseBranch: String, remoteName: String) -> String {`), insert:

```swift

    public func reviewersOnHead(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> Set<String> {
        guard let headSHA = Self.normalizedOptionalString(request.headSHA) else {
            throw CodeHostProviderError.malformedOutput("GitLab reviewers on head require the merge request head SHA.")
        }
        let approvals = try await apiJSON(
            Self.mergeRequestAPIPath(remote: remote, request: request, suffix: "approvals"),
            remote: remote,
            cwd: cwd
        )
        let notes = try await apiJSON(
            Self.mergeRequestAPIPath(remote: remote, request: request, suffix: "notes"),
            query: ["sort=desc", "order_by=created_at", "per_page=100"],
            remote: remote,
            cwd: cwd
        )
        let headCommit = try await apiJSON(
            "projects/\(Self.encodedProjectPath(remote.repositorySlug))/repository/commits/\(headSHA)",
            remote: remote,
            cwd: cwd
        )
        return try Self.parseReviewersOnHead(approvalsJSON: approvals, notesJSON: notes, headCommitJSON: headCommit)
    }

    /// `glab api <path>` as JSON. Query fields switch the call to an explicit
    /// GET, as `openIssues` does, so `-f` becomes query parameters.
    private func apiJSON(_ path: String, query: [String] = [], remote: CodeHostRemote, cwd: URL) async throws -> String {
        var args = ["api", path, "--hostname", remote.host, "--output", "json"]
        if !query.isEmpty {
            args += ["--method", "GET"]
            for field in query {
                args += ["-f", field]
            }
        }
        let result = try await runner.run("glab", args: args, cwd: cwd)
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "glab api \(path)", stderr: result.stderr)
        }
        return result.stdout
    }
```

Right after the closing `}` of `static func parseUserIsBot(_ json: String) throws -> Bool` (added by Task 2 after `parseCurrentUserUsername`), insert:

```swift

    /// Lowercased usernames that approved or commented on the head commit.
    /// An approval counts unless its `approved_at` (newer GitLab) is older
    /// than the head commit. Notes count when posted after the head commit.
    /// System notes ("added 1 commit", "approved this merge request") never
    /// count.
    public static func parseReviewersOnHead(
        approvalsJSON: String,
        notesJSON: String,
        headCommitJSON: String
    ) throws -> Set<String> {
        let decoder = JSONDecoder()
        let approvals: GitLabApprovalsResponse
        let notes: [GitLabDiscussionNote]
        let headCommit: GitLabCommitResponse
        do {
            approvals = try decoder.decode(GitLabApprovalsResponse.self, from: Data(approvalsJSON.utf8))
            notes = try decoder.decode([GitLabDiscussionNote].self, from: Data(notesJSON.utf8))
            headCommit = try decoder.decode(GitLabCommitResponse.self, from: Data(headCommitJSON.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse glab reviewers output")
        }
        guard let headCreatedAt = try? parseOptionalGitLabDate(headCommit.createdAt) else {
            throw CodeHostProviderError.malformedOutput("glab commit output is missing created_at")
        }

        var reviewers = Set<String>()
        for approval in approvals.approvedBy ?? [] {
            guard let username = normalizedOptionalString(approval.user?.username) else { continue }
            if let approvedAt = try? parseOptionalGitLabDate(approval.approvedAt), approvedAt < headCreatedAt {
                continue
            }
            reviewers.insert(username.lowercased())
        }
        for note in notes where !note.isSystem {
            guard let username = normalizedOptionalString(note.author?.username),
                  let createdAt = try? parseOptionalGitLabDate(note.createdAt),
                  createdAt > headCreatedAt
            else { continue }
            reviewers.insert(username.lowercased())
        }
        return reviewers
    }
```

If Task 2 has not landed, insert it right after the closing `}` of `public static func parseCurrentUserUsername(_ json: String) throws -> String` instead.

Right after the closing `}` of `private struct GitLabCurrentUser` (the line before `private struct GitLabDiscussionAuthor: Decodable {`), insert:

```swift

private struct GitLabApprovalsResponse: Decodable {
    struct Approval: Decodable {
        let user: GitLabDiscussionAuthor?
        let approvedAt: String?

        private enum CodingKeys: String, CodingKey {
            case user
            case approvedAt = "approved_at"
        }
    }

    let approvedBy: [Approval]?

    private enum CodingKeys: String, CodingKey {
        case approvedBy = "approved_by"
    }
}

private struct GitLabCommitResponse: Decodable {
    let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
    }
}
```

- [ ] **Step 7: Confirm the test fakes need no change**

Run:
```bash
git grep -nE '(struct|class|actor) [A-Za-z]+: ([A-Za-z]+, )*CodeHostProvider([ ,{]|$)' -- AlasTests Packages/AlasCore/Tests Alas/Sources Packages/AlasCore/Sources
```
Expected: exactly 12 lines. That is the 10 test conformers listed under **Files** plus `GitHubCLIProvider.swift:3` and `GitLabCLIProvider.swift:4` (line numbers may shift by the lines earlier tasks added above them in those two files). None of the 10 fakes declares `reviewersOnHead`; they inherit the throwing default from `extension CodeHostProvider`. If the count differs, a new conformer was added: it also inherits the default, so list it here and move on.

- [ ] **Step 8: Run both suites to verify they pass**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/GitHubCLIProviderTests -only-testing AlasTests/GitLabCLIProviderTests test > /tmp/alas-test.log 2>&1; grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log
```
Expected: `** TEST SUCCEEDED **`, no `✘` lines. Both suites start, and the run includes 6 `reviewersOnHeadSelection` cases per suite. Building the test target also compiles all 10 fakes against the new requirement.

- [ ] **Step 9: Commit**

```bash
git add Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/CodeHostProvider.swift \
  Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/GitHubCLIProvider.swift \
  Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/GitLabCLIProvider.swift \
  AlasTests/Integrations/GitHubCLIProviderTests.swift \
  AlasTests/Integrations/GitLabCLIProviderTests.swift
git commit -m "feat(codehost): report reviewers on the current head"
```

---

## Group B: Shepherd core (Tasks 4-7)

#### Planning notes for this group

For the integrator. Every item below either adds something the contract leaves out or pins down a case the spec leaves open. Contract names and signatures stay as written.

1. Public initializers the contract doesn't list (a public struct's memberwise init is internal, and tests or the app need these):
   - `ShepherdFixRequest.init(hasConflict:failingChecks:threads:)`
   - `ShepherdCheckLog.init(checkID:body:isTruncated:url:)` (PlanService builds it from `ReviewShepherd.swift`; the labels match)
   - `ShepherdDecision.init(record:action:)`
   - `ShepherdPresentation.init(tone:tooltip:phaseLine:)`
   - `ShepherdDefaults.init(autoFix:autoMerge:archiveAfterMerge:)`, with defaults `true/false/false`, plus a tolerant `init(from:)`
   - `ProjectShepherdSettings` gets a tolerant `init(from:)`.
2. `ProjectConfig.shepherd` is a stored `var` with no `ProjectConfig.init` parameter. It is encoded only when it is non-nil and `!isEmpty`. `ProjectUpdate` and dialog plumbing belong to the UI task (PlanUi Task 13).
3. Policy clarifications. The spec text taken literally either loops or never fires in these cases:
   - (a) `fixAttempts` resets only when there are no problems **and** no check is pending. Rule 7 hides failed checks while CI runs, so a literal reset would zero the counter on every push, and the attempt cap could never fire for check failures. The spec's own test list says "reset on green".
   - (b) In `awaitingPush`, progress also counts in two more cases. One: the current problem set is empty, for example after a flake rerun or an outside fix. Two: a thread that was dispatched now ends with a comment that is not from a trusted reviewer, which means the agent replied. The spec says "(the agent replied or resolved)", but thread ids alone can't show a reply.
   - (c) An `escalated(.ownerGone)` record with auto-fix on stays escalated while the session is still archived or missing, even when there are no problems. Otherwise rule 4 would re-escalate on every 5 min poll and send a notification each time.
   - (d) Phase `merging` seen by `decide` (app quit mid-merge) becomes `watching`. Phase `queued` waits while `request.isInMergeQueue`. Otherwise it returns to `watching`, because the provider dequeued it.
   - (e) A snapshot without a review request, or with a different request number, gives `.wait` and leaves the record unchanged.
   - (f) `stableHeadPolls` is capped at `requiredStablePolls`, so a stable record stays `==` across polls. `updatedAt` is bumped only when another field changed. The service can then persist only when `decision.record != record`.
   - (g) If auto-fix is off while the phase is `fixing` or `awaitingPush`, the phase returns to `watching`.
   - (h) `mergeGatePasses` also requires `record.lastSeenHeadSHA == request.headSHA`, so a stored record can't vouch for a head it hasn't polled. This matters when the UI calls the gate with the stored record and a fresh snapshot.
   - (i) "Failing bucket" means `ReviewCheckBucket.fail` only. Cancelled checks still block the merge gate through `worstCheckBucket`, but they don't trigger a fix.
4. Requirements this policy puts on the service task (sent to PlanService):
   - `sessionState` must return `.busy` while a shepherd prompt is queued but its turn hasn't started. Otherwise rule 6 moves `fixing` to `awaitingPush` early.
   - bind/rebind must clear `lastDispatchedFingerprint` and reset `fixAttempts`, so the new owner gets a fix prompt on the next poll.
5. Task 5 adds a shared test helper, `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdFixtures.swift` (internal `enum ShepherdFixtures`). Tasks 6 and 7 use it instead of writing private copies, as AGENTS.md requires.
6. Presentation gaps in the spec's badge table:
   - A `watching` record with nothing failing and the gate not passing (waiting on review, a required reviewer, or stability) maps to `.working` with "watching".
   - A `watching` record with problems and auto-fix on (a dispatch is pending or deduped) maps to `.working` with "needs a fix: …".
   - `phaseLine` never includes the attempt count; the UI shows `record.fixAttempts` separately.
7. `ShepherdPromptBuilder` uses `request.displayIdentity` ("GitHub #7"). `checkTitle` renders "name (workflow)", because `ReviewCheck` has no workflow file name (the spec example shows "CI / build.yml"). Thread headers carry the trust label per comment ("@maintainer (trusted):"), because `ReviewAuthorTrust` has no association text like "MEMBER".

### Task 4: Shepherd models, project rules and persisted settings

**Files:**
- Create: `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdModels.swift`
- Create: `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdRules.swift`
- Modify: `Packages/AlasCore/Sources/AlasCore/Persistence/AppConfig.swift`
  - lines 520-528: `stackedDiffsEnabled` property and `Changes.CodingKeys`
  - lines 1013-1014: `changes.stackedDiffsEnabled` decode inside `AppConfig.init(from:)`
- Modify: `Packages/AlasCore/Sources/AlasCore/Persistence/ProjectConfig.swift`
  - lines 198-211: `legacyWorktreeIDs` and `CodingKeys`
  - line 309: `legacyWorktreeIDs` decode
  - lines 433-435: `legacyWorktreeIDs` encode
- Test: `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdRulesResolverTests.swift` (new suite for a new type)

The test target is `AlasCoreTests` (`Packages/AlasCore/Package.swift`: `.testTarget(name: "AlasCoreTests", dependencies: ["AlasCore"])`). It has no explicit `path`, so SwiftPM compiles every `.swift` file under `Packages/AlasCore/Tests/AlasCoreTests/`, including subdirectories. The existing `JSONRPC/` and `SQLiteKit/` folders already rely on this. AlasCore files need no `xcodegen`.

**Interfaces:**
- Consumes (existing, `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/CodeHostModels.swift`):
  - `CodeHostKind` (`String`, `Codable`; `reviewRequestLabel`, `reviewRequestNumberPrefix`, `displayName`)
  - `CodeHostRemote` (`Codable`; `host`, `repositorySlug`)
  - `ReviewRequest` (`provider`, `remote`, `number`)
- Consumes (existing): `SessionOwnerID.worktree(String)` from `Packages/AlasCore/Sources/AlasCore/Workspace/SessionOwnerID.swift`.
- Produces: everything in `ShepherdModels.swift` and `ShepherdRules.swift`, exactly as in the contract, plus:
  - `AppConfig.Changes.shepherd: ShepherdDefaults`
  - `ProjectConfig.shepherd: ProjectShepherdSettings?`

- [ ] **Step 1: Create the models file**

Create `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdModels.swift`:

```swift
import Foundation

/// Identity of one shepherded review request. v1 excludes Workspace
/// checkouts, so the owner is always the worktree (`SessionOwnerID` is not
/// Codable, which is why it isn't stored here).
public struct ShepherdRecordID: Hashable, Codable, Sendable {
    public let worktreeID: String
    public let providerKind: CodeHostKind
    public let host: String
    public let repositorySlug: String
    public let requestNumber: Int

    public init(worktreeID: String, providerKind: CodeHostKind, host: String, repositorySlug: String, requestNumber: Int) {
        self.worktreeID = worktreeID
        self.providerKind = providerKind
        self.host = host
        self.repositorySlug = repositorySlug
        self.requestNumber = requestNumber
    }

    public init(worktreeID: String, request: ReviewRequest) {
        self.init(
            worktreeID: worktreeID,
            providerKind: request.provider,
            host: request.remote.host,
            repositorySlug: request.remote.repositorySlug,
            requestNumber: request.number
        )
    }

    public var storageKey: String {
        "\(worktreeID)|\(providerKind.rawValue)|\(host)|\(repositorySlug)|\(requestNumber)"
    }
}

public enum ShepherdEscalation: String, Codable, Equatable, Sendable {
    case attemptsExhausted, noProgress, deliveryFailed, ownerGone, authFailed
}

public enum ShepherdOutcome: String, Codable, Equatable, Sendable {
    case merged, closed
}

public enum ShepherdPhase: Codable, Equatable, Sendable {
    case watching
    /// Prompt delivered; the turn is queued or running.
    case fixing(dispatchedAt: Date)
    case awaitingPush(turnEndedAt: Date, pollsWithoutProgress: Int)
    case merging
    /// In a merge queue; polling continues until the provider reports merged.
    case queued
    case escalated(ShepherdEscalation)
    /// Provider auth failed; resumes on the next successful fetch.
    case paused
    case merged
    case closed

    public var isTerminal: Bool {
        switch self {
        case .merged, .closed: true
        default: false
        }
    }
}

public struct ShepherdFingerprint: Codable, Equatable, Sendable {
    public let headSHA: String
    public let hasConflict: Bool
    /// Sorted.
    public let failingCheckIDs: [String]
    /// Sorted; actionable threads from trusted reviewers only.
    public let threadIDs: [String]

    public init(headSHA: String, hasConflict: Bool, failingCheckIDs: [String], threadIDs: [String]) {
        self.headSHA = headSHA
        self.hasConflict = hasConflict
        self.failingCheckIDs = failingCheckIDs
        self.threadIDs = threadIDs
    }
}

public struct ShepherdRecord: Codable, Equatable, Sendable {
    public let id: ShepherdRecordID
    public var sessionID: String
    public var remote: CodeHostRemote
    public var branch: String
    public var baseBranch: String
    public var autoFix: Bool
    public var autoMerge: Bool
    public var phase: ShepherdPhase
    public var lastDispatchedFingerprint: ShepherdFingerprint?
    public var fixAttempts: Int
    public var lastSeenHeadSHA: String?
    /// Consecutive polls that saw `lastSeenHeadSHA` with no pending check,
    /// capped at `ShepherdPolicy.requiredStablePolls`.
    public var stableHeadPolls: Int
    public var notifiedReadyHeadSHA: String?
    public var finishedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ShepherdRecordID,
        sessionID: String,
        remote: CodeHostRemote,
        branch: String,
        baseBranch: String,
        autoFix: Bool,
        autoMerge: Bool,
        now: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.remote = remote
        self.branch = branch
        self.baseBranch = baseBranch
        self.autoFix = autoFix
        self.autoMerge = autoMerge
        self.phase = .watching
        self.lastDispatchedFingerprint = nil
        self.fixAttempts = 0
        self.lastSeenHeadSHA = nil
        self.stableHeadPolls = 0
        self.notifiedReadyHeadSHA = nil
        self.finishedAt = nil
        self.createdAt = now
        self.updatedAt = now
    }

    public var owner: SessionOwnerID { .worktree(id.worktreeID) }
}

public enum ShepherdSessionState: Equatable, Sendable {
    case idle, busy, archived, missing
}

/// Global defaults for newly bound PRs (`AppConfig.Changes.shepherd`).
public struct ShepherdDefaults: Codable, Equatable, Sendable {
    public var autoFix: Bool = true
    public var autoMerge: Bool = false
    public var archiveAfterMerge: Bool = false

    private enum CodingKeys: String, CodingKey {
        case autoFix, autoMerge, archiveAfterMerge
    }

    public init(autoFix: Bool = true, autoMerge: Bool = false, archiveAfterMerge: Bool = false) {
        self.autoFix = autoFix
        self.autoMerge = autoMerge
        self.archiveAfterMerge = archiveAfterMerge
    }

    /// Tolerant, like the rest of `AppConfig`: a missing or mistyped key keeps
    /// its default instead of failing the whole config.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoFix = (try? c.decode(Bool.self, forKey: .autoFix)) ?? true
        autoMerge = (try? c.decode(Bool.self, forKey: .autoMerge)) ?? false
        archiveAfterMerge = (try? c.decode(Bool.self, forKey: .archiveAfterMerge)) ?? false
    }
}
```

- [ ] **Step 2: Write the failing resolver tests**

Create `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdRulesResolverTests.swift`:

```swift
import Foundation
import Testing
@testable import AlasCore

struct ShepherdRulesResolveCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let localFile: String?
    let repoFile: String?
    let settings: ProjectShepherdSettings?
    let source: ShepherdRules.Source
    let instructions: String
    let reviewers: [String]
}

struct ShepherdRulesParseCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let contents: String
    let instructions: String
    let reviewers: [String]
}

private let sampleSettings = ProjectShepherdSettings(
    instructions: "  Settings rules\n",
    requiredReviewers: ["@Codex-Bot", "codex-bot", " "]
)
private let repoFileContents = "---\nrequired_reviewers: [maintainer]\n---\nRepo rules"

private let resolveCases: [ShepherdRulesResolveCase] = [
    .init(testDescription: "local file beats repo file and settings",
          localFile: "Local rules", repoFile: repoFileContents, settings: sampleSettings,
          source: .localFile, instructions: "Local rules", reviewers: []),
    .init(testDescription: "repo file beats settings",
          localFile: nil, repoFile: repoFileContents, settings: sampleSettings,
          source: .repoFile, instructions: "Repo rules", reviewers: ["maintainer"]),
    .init(testDescription: "settings apply when no file exists",
          localFile: nil, repoFile: nil, settings: sampleSettings,
          source: .projectSettings, instructions: "Settings rules", reviewers: ["codex-bot"]),
    .init(testDescription: "empty settings resolve to none",
          localFile: nil, repoFile: nil, settings: ProjectShepherdSettings(),
          source: .none, instructions: "", reviewers: []),
    .init(testDescription: "no source resolves to none",
          localFile: nil, repoFile: nil, settings: nil,
          source: .none, instructions: "", reviewers: []),
    .init(testDescription: "an empty local file still wins",
          localFile: "", repoFile: repoFileContents, settings: sampleSettings,
          source: .localFile, instructions: "", reviewers: []),
]

private let parseCases: [ShepherdRulesParseCase] = [
    .init(testDescription: "flow list",
          contents: "---\nrequired_reviewers: [chatgpt-codex-connector, \"Maintainer\"]\n---\nBatch fixes.\n",
          instructions: "Batch fixes.", reviewers: ["chatgpt-codex-connector", "maintainer"]),
    .init(testDescription: "block list",
          contents: "---\nrequired_reviewers:\n  - chatgpt-codex-connector\n  - '@maintainer'\n---\n\nBatch fixes.",
          instructions: "Batch fixes.", reviewers: ["chatgpt-codex-connector", "maintainer"]),
    .init(testDescription: "no frontmatter",
          contents: "Batch fixes.\n",
          instructions: "Batch fixes.", reviewers: []),
    .init(testDescription: "unterminated frontmatter is plain text",
          contents: "---\nrequired_reviewers: [a]\nBatch fixes.",
          instructions: "---\nrequired_reviewers: [a]\nBatch fixes.", reviewers: []),
    .init(testDescription: "unclosed flow list is ignored",
          contents: "---\nrequired_reviewers: [a, b\n---\nBatch fixes.",
          instructions: "Batch fixes.", reviewers: []),
    .init(testDescription: "unknown keys only",
          contents: "---\nowner: me\n---\n",
          instructions: "", reviewers: []),
    .init(testDescription: "empty file",
          contents: "",
          instructions: "", reviewers: []),
    .init(testDescription: "CRLF line endings",
          contents: "---\r\nrequired_reviewers: [a]\r\n---\r\nBatch fixes.\r\n",
          instructions: "Batch fixes.", reviewers: ["a"]),
]

@Suite struct ShepherdRulesResolverTests {
    @Test("first available source wins completely", arguments: resolveCases)
    func resolve(_ c: ShepherdRulesResolveCase) {
        let rules = ShepherdRulesResolver.resolve(
            localFile: c.localFile, repoFile: c.repoFile, projectSettings: c.settings
        )
        #expect(rules.source == c.source)
        #expect(rules.instructions == c.instructions)
        #expect(rules.requiredReviewers == c.reviewers)
    }

    @Test("frontmatter yields instructions and normalized reviewers", arguments: parseCases)
    func parse(_ c: ShepherdRulesParseCase) {
        let parsed = ShepherdRulesResolver.parse(fileContents: c.contents)
        #expect(parsed.instructions == c.instructions)
        #expect(parsed.requiredReviewers == c.reviewers)
    }
}
```

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `swift test --package-path Packages/AlasCore --filter ShepherdRulesResolverTests`
Expected: the build fails with `cannot find type 'ProjectShepherdSettings' in scope` and `cannot find 'ShepherdRulesResolver' in scope`.

- [ ] **Step 4: Implement the rules file**

Create `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdRules.swift`:

```swift
import Foundation

/// Per-project shepherd rules stored in `ProjectConfig.shepherd`.
public struct ProjectShepherdSettings: Codable, Equatable, Sendable {
    public var instructions: String
    public var requiredReviewers: [String]

    private enum CodingKeys: String, CodingKey {
        case instructions, requiredReviewers
    }

    public init(instructions: String = "", requiredReviewers: [String] = []) {
        self.instructions = instructions
        self.requiredReviewers = requiredReviewers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instructions = (try? c.decode(String.self, forKey: .instructions)) ?? ""
        requiredReviewers = (try? c.decode([String].self, forKey: .requiredReviewers)) ?? []
    }

    public var isEmpty: Bool {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ShepherdRulesResolver.normalizedReviewers(requiredReviewers).isEmpty
    }
}

public struct ShepherdRules: Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        case localFile, repoFile, projectSettings, none
    }

    public let source: Source
    public let instructions: String
    /// Lowercased logins without a leading `@`, deduplicated in file order.
    public let requiredReviewers: [String]

    public init(source: Source, instructions: String, requiredReviewers: [String]) {
        self.source = source
        self.instructions = instructions
        self.requiredReviewers = requiredReviewers
    }

    public static let none = ShepherdRules(source: .none, instructions: "", requiredReviewers: [])

    public var sourceLabel: String? {
        switch source {
        case .localFile: ShepherdRulesResolver.localFilePath
        case .repoFile: ShepherdRulesResolver.repoFilePath
        case .projectSettings: "Project settings"
        case .none: nil
        }
    }
}

public enum ShepherdRulesResolver {
    public static let localFilePath = ".alas/shepherd.local.md"
    public static let repoFilePath = ".alas/shepherd.md"

    private static let reviewersKey = "required_reviewers:"

    /// Pure. First non-nil source wins completely; sources are never merged.
    /// A file that exists but is empty still wins, so a local file can switch
    /// off the repo or project rules.
    public static func resolve(
        localFile: String?,
        repoFile: String?,
        projectSettings: ProjectShepherdSettings?
    ) -> ShepherdRules {
        if let localFile { return rules(fromFile: localFile, source: .localFile) }
        if let repoFile { return rules(fromFile: repoFile, source: .repoFile) }
        if let projectSettings, !projectSettings.isEmpty {
            return ShepherdRules(
                source: .projectSettings,
                instructions: projectSettings.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                requiredReviewers: normalizedReviewers(projectSettings.requiredReviewers)
            )
        }
        return .none
    }

    /// Parses optional `---` YAML frontmatter whose only key is
    /// `required_reviewers`, as a flow list (`[a, b]`) or a block list
    /// (`- a`). An unterminated frontmatter block is treated as plain text;
    /// an unclosed flow list yields no reviewers.
    public static func parse(fileContents: String) -> (instructions: String, requiredReviewers: [String]) {
        let text = fileContents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let frontmatter = Array(lines[1..<closing])
        let body = lines[(closing + 1)...].joined(separator: "\n")
        return (
            body.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedReviewers(reviewers(inFrontmatter: frontmatter))
        )
    }

    /// Reads the two files under `worktreePath` (a missing or unreadable file
    /// is nil), then `resolve`.
    public static func load(worktreePath: URL, projectSettings: ProjectShepherdSettings?) -> ShepherdRules {
        func read(_ relativePath: String) -> String? {
            try? String(contentsOf: worktreePath.appendingPathComponent(relativePath), encoding: .utf8)
        }
        return resolve(
            localFile: read(localFilePath),
            repoFile: read(repoFilePath),
            projectSettings: projectSettings
        )
    }

    static func normalizedReviewers(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in raw {
            var login = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if login.hasPrefix("@") { login.removeFirst() }
            guard !login.isEmpty, seen.insert(login).inserted else { continue }
            result.append(login)
        }
        return result
    }

    private static func rules(fromFile contents: String, source: ShepherdRules.Source) -> ShepherdRules {
        let parsed = parse(fileContents: contents)
        return ShepherdRules(
            source: source,
            instructions: parsed.instructions,
            requiredReviewers: parsed.requiredReviewers
        )
    }

    private static func reviewers(inFrontmatter lines: [String]) -> [String] {
        guard let keyIndex = lines.firstIndex(where: { $0.hasPrefix(reviewersKey) }) else { return [] }
        let value = lines[keyIndex].dropFirst(reviewersKey.count).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("[") {
            guard value.hasSuffix("]") else { return [] }
            return value.dropFirst().dropLast().split(separator: ",").map { unquoted(String($0)) }
        }
        if !value.isEmpty { return [unquoted(value)] }
        var items: [String] = []
        for line in lines[(keyIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") else { break }
            items.append(unquoted(String(trimmed.dropFirst())))
        }
        return items
    }

    private static func unquoted(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let first = value.first, first == value.last,
              first == "\"" || first == "'"
        else { return value }
        return String(value.dropFirst().dropLast())
    }
}
```

- [ ] **Step 5: Add `AppConfig.Changes.shepherd`**

In `Packages/AlasCore/Sources/AlasCore/Persistence/AppConfig.swift`, after line 522 (`public var stackedDiffsEnabled: Bool = true`), insert:

```swift
        /// Defaults for newly bound PR shepherd records (Settings > Changes).
        public var shepherd: ShepherdDefaults = .init()
```

Replace lines 524-528 (the `Changes.CodingKeys` enum) with:

```swift
        public enum CodingKeys: String, CodingKey, Sendable {
            case aiToolId, prompt, reviewRequestPrompt, mergeBulkResolvePrompt,
                 mergeSingleResolvePrompt, comparisonMode,
                 diffLayoutMode, diffShowWhitespace, stackedDiffsEnabled, shepherd
        }
```

In `AppConfig.init(from:)`, after lines 1013-1014:

```swift
            changes.stackedDiffsEnabled =
                (try? changesContainer.decode(Bool.self, forKey: .stackedDiffsEnabled)) ?? true
```

insert:

```swift
            changes.shepherd =
                (try? changesContainer.decode(ShepherdDefaults.self, forKey: .shepherd)) ?? .init()
```

The `else` branch (lines 1015-1026) needs no change: `Changes(...)` already starts from the `= .init()` default. `Changes` keeps its synthesized `encode(to:)`, which picks up the new key.

- [ ] **Step 6: Add `ProjectConfig.shepherd`**

In `Packages/AlasCore/Sources/AlasCore/Persistence/ProjectConfig.swift`, after line 203 (`public var legacyWorktreeIDs: [String: String] = [:]`), insert:

```swift
    /// Project-level PR shepherd rules. A `.alas/shepherd.local.md` or
    /// `.alas/shepherd.md` file in the worktree overrides them completely.
    public var shepherd: ProjectShepherdSettings?
```

Replace lines 205-211 (`CodingKeys`) with:

```swift
    public enum CodingKeys: String, CodingKey, Sendable {
        case id, name, path, color, icon, addedAt, hiddenWorktreePaths, worktreeOrder,
             cachedWorktrees, worktreeOrderIsManual, startupScripts,
             mcpServers, worktreeOpenAfterCreate, worktreeDefaultLauncherMode, worktreeLaunchPreference, worktreeBranchTemplate, host, kind, ggMode,
             ggWorktreeModes, issueAttachments, pendingAutoBranchNames, fileBookmarks,
             repoMCPTrust, disabledRepoMCPServers, approvedRepoHookHashes, pendingLegacyWorktreeIDs,
             shepherd
    }
```

In `init(from:)`, after line 309 (`legacyWorktreeIDs = (try? c.decode([String: String].self, forKey: .pendingLegacyWorktreeIDs)) ?? [:]`), insert:

```swift
        shepherd = try? c.decodeIfPresent(ProjectShepherdSettings.self, forKey: .shepherd)
```

In `encode(to:)`, after lines 433-435 (the `legacyWorktreeIDs` block), insert:

```swift
        if let shepherd, !shepherd.isEmpty {
            try c.encode(shepherd, forKey: .shepherd)
        }
```

Do not add a `shepherd` parameter to `ProjectConfig.init`; the UI task sets the property directly.

- [ ] **Step 7: Run the tests and confirm they pass**

Run: `swift test --package-path Packages/AlasCore --filter ShepherdRulesResolverTests`
Expected: `Test run with 2 tests in 1 suite passed` (14 argument cases), no build errors.

- [ ] **Step 8: Commit**

```bash
git add Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdModels.swift \
  Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdRules.swift \
  Packages/AlasCore/Sources/AlasCore/Persistence/AppConfig.swift \
  Packages/AlasCore/Sources/AlasCore/Persistence/ProjectConfig.swift \
  Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdRulesResolverTests.swift
git commit -m "feat(shepherd): add shepherd models, project rules and settings fields"
```

### Task 5: Shepherd policy

**Files:**
- Create: `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdPolicy.swift`
- Create: `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdFixtures.swift` (test helper shared with Tasks 6 and 7)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdPolicyTests.swift` (new suite for a new type)

Verified signatures this task calls:
- `ReviewReadinessModel.canMergeReviewRequest(snapshot:)` (`Integrations/CodeHost/ReviewReadinessModel.swift:297-336`). It covers: `errorMessage == nil`, provider available and authenticated, push state not diverged or stale, no `needsPush`, a clean tree, `request.headSHA == local.headSHA`, mergeState `.clean` (or `.blocked` with a merge queue), not draft, not in a queue, `reviewDecision != .reviewRequired`, threads complete, no actionable feedback, and worst check `nil` or `.pass`.
- `ReviewMergeOutcome` `{ merged, queued }` (`ReviewLoopState.swift:14-17`). `ReviewLoopState.merge(snapshot:)` returns `nil` when the gate stops passing or the merge throws (`ReviewLoopState.swift:488-539`).
- Inits from `CodeHostModels.swift`:
  - `ReviewCheck(id:name:workflow:bucket:detailURL:completedAt:)` (254)
  - `ReviewThread(id:path:line:startLine:originalLine:originalStartLine:diffHunk:diffSide:isResolved:isOutdated:isFileLevel:comments:viewerCanResolve:viewerCanUnresolve:viewerCanReply:url:)` (398-432)
  - `ReviewRequest(remote:number:title:url:state:isDraft:headRefName:baseRefName:baseSHA:headSHA:headRepositoryOwner:headRepositoryName:reviewDecision:mergeState:checks:threads:areThreadsComplete:isMergeQueueEnabled:isInMergeQueue:)` (538-578)
  - `ReviewLoopLocalState(branchName:headSHA:baseBranch:hasWorkingTreeChanges:hasStagedChanges:aheadCommitCount:hasUpstream:upstreamRemoteName:upstreamBranchName:headRemoteName:headRemoteOwner:needsPush:)` (725-754)
  - `ReviewLoopSnapshot(local:remote:reviewRequest:providerAvailable:providerAuthenticated:providerCapabilities:errorMessage:)` (812-820)
  - `CodeHostProviderCapabilities.githubCLI` (150, `canMerge: true`)

**Interfaces:**
- Consumes (Task 1):
  - `ReviewAuthorTrust` (`trusted`, `untrusted`, `unknown`)
  - `ReviewComment.authorTrust`, with init param `authorTrust: ReviewAuthorTrust = .unknown` as the last param
  - `ReviewThread.headAuthorTrust`
- Consumes (Task 4): `ShepherdRecord`, `ShepherdPhase`, `ShepherdFingerprint`, `ShepherdEscalation`, `ShepherdOutcome`, `ShepherdSessionState`, `ShepherdRules`, `ShepherdRecordID`.
- Produces:
  ```swift
  public struct ShepherdFixRequest: Equatable, Sendable {
      public let hasConflict: Bool; public let failingChecks: [ReviewCheck]; public let threads: [ReviewThread]
      public init(hasConflict: Bool, failingChecks: [ReviewCheck], threads: [ReviewThread])
      public var isEmpty: Bool
      public func fingerprint(headSHA: String) -> ShepherdFingerprint
  }
  public enum ShepherdAction: Equatable, Sendable { case wait, dispatchFix(ShepherdFixRequest), merge, notifyReady, finish(ShepherdOutcome), escalate(ShepherdEscalation) }
  public struct ShepherdObservation: Equatable, Sendable {
      public init(snapshot: ReviewLoopSnapshot, headReviewers: Set<String>?, session: ShepherdSessionState, rules: ShepherdRules, now: Date)
  }
  public struct ShepherdDecision: Equatable, Sendable { public let record: ShepherdRecord; public let action: ShepherdAction; public init(record:action:) }
  public enum ShepherdPolicy {
      public static let maxFixAttempts = 3
      public static let noProgressPollLimit = 3
      public static let requiredStablePolls = 2
      public static func decide(_ record: ShepherdRecord, _ observation: ShepherdObservation) -> ShepherdDecision
      public static func problems(in request: ReviewRequest) -> ShepherdFixRequest
      public static func mergeGatePasses(_ record: ShepherdRecord, _ observation: ShepherdObservation) -> Bool
      public static func applyMergeOutcome(_ outcome: ReviewMergeOutcome?, to record: ShepherdRecord, now: Date) -> ShepherdRecord
  }
  ```
- Produces (tests): an internal `enum ShepherdFixtures` with these members:
  - `now`, `earlier`, `head`, `newHead`, `failing`, `pending`, `trustedThread`
  - `remote(_:)`, `check(_:_:)`, `comment(_:author:body:trust:)`, `thread(_:trust:comments:)`, `request(...)`, `snapshot(_:localHead:dirty:)`, `record(...)`, `observation(_:session:rules:headReviewers:)`, `fingerprint(_:head:)`

How `decide` runs. `decide` is called only after a successful provider fetch. Steps in order:

0. Guards. A terminal record, a missing request, or a request number other than `record.id.requestNumber` gives `.wait` with the record unchanged.
1. Terminal. `request.state == .merged` gives phase `merged`, `finishedAt = now` and `finish(.merged)`. `.closed` works the same with `closed`.
2. Head stability. Runs on every open-request fetch.
   - Provider head is nil: `lastSeenHeadSHA = nil`, `stableHeadPolls = 0`.
   - Head equals `lastSeenHeadSHA`: no pending check gives `min(stableHeadPolls + 1, requiredStablePolls)`; a pending check gives 0.
   - New head: set `lastSeenHeadSHA` to it. `stableHeadPolls` becomes 1 if no check is pending, else 0.
3. Carry-over. `merging` becomes `watching`. `queued` waits while `isInMergeQueue`, else becomes `watching`.
4. Rule 2.
   - `paused` becomes `watching`.
   - `escalated` becomes `watching` only when there are no problems. It also needs the owner to be present when the reason is `.ownerGone` and auto-fix is on. Otherwise `.wait`.
5. Rules 3 to 7, only when `autoFix` is on.
   - Rule 4: archived or missing gives escalate `ownerGone`.
   - Rule 5: busy gives `.wait`.
   - Rule 6: `fixing` becomes `awaitingPush(now, 0)`, then falls through. In `awaitingPush`, progress gives `watching`. No progress increments the counter; reaching 3 escalates `noProgress`, otherwise `.wait`.
   - Rule 7: no problems resets attempts (only when no check is pending) and continues. Problems equal to `lastDispatchedFingerprint` give `.wait`. Attempts at or above 3 escalate `attemptsExhausted`. Otherwise `dispatchFix`.
   - With auto-fix off, `fixing` and `awaitingPush` become `watching` and rules 4 to 7 are skipped.
6. Rules 8 and 9. The gate passes and `autoMerge` is on: `merge`, phase `merging`. The gate passes and the head isn't `notifiedReadyHeadSHA`: `notifyReady`, and the head is recorded.
7. Rule 10: `.wait`.

`updatedAt = now` is applied only when some other field changed.

- [ ] **Step 1: Create the shared test fixtures**

Create `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdFixtures.swift`:

```swift
import Foundation
@testable import AlasCore

/// Builders shared by the shepherd suites. Values go through the real
/// initializers so the fixtures break loudly when a model changes.
enum ShepherdFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let earlier = now.addingTimeInterval(-600)
    static let head = "a3f9c1e5b2d4f6a8c0e2"
    static let newHead = "b7c2d90e11aa33cc55ee"
    static let failing = check("unit-tests", .fail)
    static let pending = check("lint", .pending)
    static let trustedThread = thread("PRRT_1")

    static func remote(_ kind: CodeHostKind = .github) -> CodeHostRemote {
        switch kind {
        case .github:
            CodeHostRemote(kind: .github, host: "github.com", owner: "acme", repository: "app",
                           remoteName: "origin", webURL: URL(string: "https://github.com/acme/app")!)
        case .gitlab:
            CodeHostRemote(kind: .gitlab, host: "gitlab.com", owner: "acme", repository: "app",
                           remoteName: "origin", webURL: URL(string: "https://gitlab.com/acme/app")!)
        }
    }

    static func check(_ id: String, _ bucket: ReviewCheckBucket) -> ReviewCheck {
        ReviewCheck(id: id, name: id, workflow: "CI", bucket: bucket,
                    detailURL: URL(string: "https://ci.example/\(id)"), completedAt: nil)
    }

    static func comment(_ id: String, author: String, body: String, trust: ReviewAuthorTrust) -> ReviewComment {
        ReviewComment(id: id, author: author, body: body, url: nil, createdAt: nil,
                      viewerCanUpdate: false, viewerCanDelete: false, isPending: false,
                      authorTrust: trust)
    }

    static func thread(
        _ id: String,
        trust: ReviewAuthorTrust = .trusted,
        comments: [ReviewComment]? = nil
    ) -> ReviewThread {
        ReviewThread(
            id: id, path: "Sources/App.swift", line: 12, startLine: nil, originalLine: nil,
            diffHunk: nil, isResolved: false, isOutdated: false, isFileLevel: false,
            comments: comments ?? [comment("\(id)-c1", author: "maintainer", body: "Please fix \(id).", trust: trust)],
            viewerCanResolve: true, viewerCanReply: true,
            url: URL(string: "https://github.com/acme/app/pull/7#\(id)")
        )
    }

    static func request(
        kind: CodeHostKind = .github,
        state: ReviewRequestState = .open,
        head: String? = ShepherdFixtures.head,
        mergeState: ReviewMergeState = .clean,
        checks: [ReviewCheck] = [ShepherdFixtures.check("build", .pass)],
        threads: [ReviewThread] = [],
        isMergeQueueEnabled: Bool = false,
        isInMergeQueue: Bool = false
    ) -> ReviewRequest {
        let host = remote(kind)
        return ReviewRequest(
            remote: host, number: 7, title: "Fix login", url: host.reviewRequestURL(number: 7),
            state: state, isDraft: false, headRefName: "fix-login", baseRefName: "main",
            headSHA: head, reviewDecision: .approved, mergeState: mergeState,
            checks: checks, threads: threads,
            isMergeQueueEnabled: isMergeQueueEnabled, isInMergeQueue: isInMergeQueue
        )
    }

    static func snapshot(
        _ request: ReviewRequest?,
        localHead: String = ShepherdFixtures.head,
        dirty: Bool = false
    ) -> ReviewLoopSnapshot {
        let local = ReviewLoopLocalState(
            branchName: "fix-login", headSHA: localHead, baseBranch: "main",
            hasWorkingTreeChanges: dirty, hasStagedChanges: false, aheadCommitCount: 1,
            hasUpstream: true, upstreamRemoteName: "origin", upstreamBranchName: "fix-login",
            needsPush: false
        )
        return ReviewLoopSnapshot(
            local: local, remote: request?.remote ?? remote(), reviewRequest: request,
            providerAvailable: true, providerAuthenticated: true,
            providerCapabilities: .githubCLI, errorMessage: nil
        )
    }

    static func record(
        kind: CodeHostKind = .github,
        phase: ShepherdPhase = .watching,
        autoFix: Bool = true,
        autoMerge: Bool = false,
        fixAttempts: Int = 0,
        lastDispatched: ShepherdFingerprint? = nil,
        lastSeenHead: String? = nil,
        stablePolls: Int = 0,
        notifiedReady: String? = nil
    ) -> ShepherdRecord {
        let host = remote(kind)
        var record = ShepherdRecord(
            id: ShepherdRecordID(worktreeID: "wt-1", providerKind: kind, host: host.host,
                                 repositorySlug: host.repositorySlug, requestNumber: 7),
            sessionID: "session-1", remote: host, branch: "fix-login", baseBranch: "main",
            autoFix: autoFix, autoMerge: autoMerge, now: earlier
        )
        record.phase = phase
        record.fixAttempts = fixAttempts
        record.lastDispatchedFingerprint = lastDispatched
        record.lastSeenHeadSHA = lastSeenHead
        record.stableHeadPolls = stablePolls
        record.notifiedReadyHeadSHA = notifiedReady
        return record
    }

    static func observation(
        _ snapshot: ReviewLoopSnapshot,
        session: ShepherdSessionState = .idle,
        rules: ShepherdRules = .none,
        headReviewers: Set<String>? = nil
    ) -> ShepherdObservation {
        ShepherdObservation(snapshot: snapshot, headReviewers: headReviewers,
                            session: session, rules: rules, now: now)
    }

    static func fingerprint(_ fix: ShepherdFixRequest, head: String = ShepherdFixtures.head) -> ShepherdFingerprint {
        fix.fingerprint(headSHA: head)
    }
}
```

- [ ] **Step 2: Write the failing policy tests**

Create `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdPolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import AlasCore

private typealias F = ShepherdFixtures

struct ShepherdPolicyCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let record: ShepherdRecord
    let observation: ShepherdObservation
    let action: ShepherdAction
    let phase: ShepherdPhase
}

struct ShepherdStabilityCase: Sendable, CustomTestStringConvertible {
    let lastSeen: String
    let polls: Int
    let bucket: ReviewCheckBucket
    let expected: Int
    var testDescription: String {
        "\(lastSeen == ShepherdFixtures.head ? "same" : "new") head, \(polls) polls, \(bucket)"
    }
}

private let stabilityCases: [ShepherdStabilityCase] = [
    .init(lastSeen: F.head, polls: 1, bucket: .pass, expected: 2),
    .init(lastSeen: F.head, polls: 2, bucket: .pass, expected: 2),
    .init(lastSeen: F.head, polls: 1, bucket: .pending, expected: 0),
    .init(lastSeen: "0ld", polls: 1, bucket: .pass, expected: 1),
    .init(lastSeen: "0ld", polls: 1, bucket: .pending, expected: 0),
]

private let failingOnly = ShepherdFixRequest(hasConflict: false, failingChecks: [F.failing], threads: [])
private let threadOnly = ShepherdFixRequest(hasConflict: false, failingChecks: [], threads: [F.trustedThread])
private let repliedThread = F.thread("PRRT_1", comments: [
    F.comment("c1", author: "maintainer", body: "Please back off.", trust: .trusted),
    F.comment("c2", author: "me", body: "Backoff already lives in RetryPolicy.", trust: .untrusted),
])
private let codexRules = ShepherdRules(source: .repoFile, instructions: "", requiredReviewers: ["chatgpt-codex-connector"])
private let mixedCaseRules = ShepherdRules(source: .projectSettings, instructions: "", requiredReviewers: ["ChatGPT-Codex-Connector"])
private let outdatedThread = ReviewThread(
    id: "PRRT_9", path: "Sources/App.swift", line: 12, startLine: nil, originalLine: nil,
    diffHunk: nil, isResolved: false, isOutdated: true, isFileLevel: false,
    comments: [F.comment("c9", author: "maintainer", body: "Old note.", trust: .trusted)],
    viewerCanResolve: true, viewerCanReply: true, url: nil
)
/// Same head already seen once with complete checks: this poll makes it stable.
private func stable(autoFix: Bool = true, autoMerge: Bool = false, phase: ShepherdPhase = .watching) -> ShepherdRecord {
    F.record(phase: phase, autoFix: autoFix, autoMerge: autoMerge, lastSeenHead: F.head, stablePolls: 1)
}

private let policyCases: [ShepherdPolicyCase] = [
    // Rule 1
    .init(testDescription: "merged request finishes",
          record: F.record(), observation: F.observation(F.snapshot(F.request(state: .merged))),
          action: .finish(.merged), phase: .merged),
    .init(testDescription: "closed request finishes",
          record: F.record(), observation: F.observation(F.snapshot(F.request(state: .closed))),
          action: .finish(.closed), phase: .closed),
    // Rule 2
    .init(testDescription: "escalated record waits while problems remain",
          record: F.record(phase: .escalated(.attemptsExhausted), fixAttempts: 3),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .wait, phase: .escalated(.attemptsExhausted)),
    .init(testDescription: "escalated record returns to watching when problems clear",
          record: F.record(phase: .escalated(.noProgress)),
          observation: F.observation(F.snapshot(F.request(checks: [F.pending]))),
          action: .wait, phase: .watching),
    .init(testDescription: "owner-gone escalation holds while the owner is gone",
          record: F.record(phase: .escalated(.ownerGone)),
          observation: F.observation(F.snapshot(F.request()), session: .archived),
          action: .wait, phase: .escalated(.ownerGone)),
    .init(testDescription: "paused record resumes on a successful fetch",
          record: stable(autoMerge: true, phase: .paused),
          observation: F.observation(F.snapshot(F.request())),
          action: .merge, phase: .merging),
    // Rule 3
    .init(testDescription: "auto-fix off never dispatches or escalates",
          record: F.record(autoFix: false),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing])), session: .missing),
          action: .wait, phase: .watching),
    .init(testDescription: "auto-fix off still notifies ready while the owner is busy",
          record: stable(autoFix: false),
          observation: F.observation(F.snapshot(F.request()), session: .busy),
          action: .notifyReady, phase: .watching),
    // Rules 4 and 5
    .init(testDescription: "archived owner escalates",
          record: F.record(), observation: F.observation(F.snapshot(F.request(checks: [F.failing])), session: .archived),
          action: .escalate(.ownerGone), phase: .escalated(.ownerGone)),
    .init(testDescription: "missing owner escalates",
          record: F.record(), observation: F.observation(F.snapshot(F.request()), session: .missing),
          action: .escalate(.ownerGone), phase: .escalated(.ownerGone)),
    .init(testDescription: "busy owner waits",
          record: F.record(), observation: F.observation(F.snapshot(F.request(checks: [F.failing])), session: .busy),
          action: .wait, phase: .watching),
    // Rule 6
    .init(testDescription: "fixing with an idle owner moves to awaitingPush",
          record: F.record(phase: .fixing(dispatchedAt: F.earlier), fixAttempts: 1, lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .wait, phase: .awaitingPush(turnEndedAt: F.now, pollsWithoutProgress: 1)),
    .init(testDescription: "third poll without progress escalates",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 2), fixAttempts: 1,
                           lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .escalate(.noProgress), phase: .escalated(.noProgress)),
    .init(testDescription: "a new head is progress and redispatches remaining failures",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0), fixAttempts: 1,
                           lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(head: F.newHead, checks: [F.failing]), localHead: F.newHead)),
          action: .dispatchFix(failingOnly), phase: .fixing(dispatchedAt: F.now)),
    .init(testDescription: "a reply on a dispatched thread is progress",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0), fixAttempts: 1,
                           lastDispatched: F.fingerprint(threadOnly)),
          observation: F.observation(F.snapshot(F.request(threads: [repliedThread]))),
          action: .wait, phase: .watching),
    // Rule 7
    .init(testDescription: "problems already dispatched wait",
          record: F.record(fixAttempts: 1, lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .wait, phase: .watching),
    .init(testDescription: "trusted thread dispatches while checks are pending",
          record: F.record(), observation: F.observation(F.snapshot(F.request(checks: [F.pending], threads: [F.trustedThread]))),
          action: .dispatchFix(threadOnly), phase: .fixing(dispatchedAt: F.now)),
    .init(testDescription: "failed check waits for pending checks",
          record: F.record(), observation: F.observation(F.snapshot(F.request(checks: [F.failing, F.pending]))),
          action: .wait, phase: .watching),
    .init(testDescription: "untrusted thread is ignored",
          record: F.record(), observation: F.observation(F.snapshot(F.request(threads: [F.thread("PRRT_2", trust: .untrusted)]))),
          action: .wait, phase: .watching),
    .init(testDescription: "conflict, checks and threads dispatch together",
          record: F.record(),
          observation: F.observation(F.snapshot(F.request(mergeState: .dirty, checks: [F.failing], threads: [F.trustedThread]))),
          action: .dispatchFix(ShepherdFixRequest(hasConflict: true, failingChecks: [F.failing], threads: [F.trustedThread])),
          phase: .fixing(dispatchedAt: F.now)),
    .init(testDescription: "attempt cap escalates",
          record: F.record(fixAttempts: 3), observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .escalate(.attemptsExhausted), phase: .escalated(.attemptsExhausted)),
    // Rule 8
    .init(testDescription: "merges when the gate passes",
          record: stable(autoMerge: true), observation: F.observation(F.snapshot(F.request())),
          action: .merge, phase: .merging),
    .init(testDescription: "required reviewer missing on the head blocks merge",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request()), rules: codexRules, headReviewers: ["maintainer"]),
          action: .wait, phase: .watching),
    .init(testDescription: "required reviewer on the head allows merge",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request()), rules: codexRules, headReviewers: ["chatgpt-codex-connector"]),
          action: .merge, phase: .merging),
    .init(testDescription: "unknown head reviewers block merge when rules require one",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request()), rules: codexRules, headReviewers: nil),
          action: .wait, phase: .watching),
    .init(testDescription: "one stable poll is not enough",
          record: F.record(autoMerge: true), observation: F.observation(F.snapshot(F.request())),
          action: .wait, phase: .watching),
    .init(testDescription: "dirty local tree blocks merge",
          record: stable(autoMerge: true), observation: F.observation(F.snapshot(F.request(), dirty: true)),
          action: .wait, phase: .watching),
    .init(testDescription: "local head behind the provider blocks merge",
          record: stable(autoMerge: true), observation: F.observation(F.snapshot(F.request(), localHead: F.newHead)),
          action: .wait, phase: .watching),
    .init(testDescription: "merge queue accepts a blocked merge state",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request(mergeState: .blocked, isMergeQueueEnabled: true))),
          action: .merge, phase: .merging),
    .init(testDescription: "queued record waits while in the queue",
          record: F.record(phase: .queued, autoMerge: true),
          observation: F.observation(F.snapshot(F.request(isMergeQueueEnabled: true, isInMergeQueue: true))),
          action: .wait, phase: .queued),
    // Review focus: inputs right after a push and reviewer-name spelling
    .init(testDescription: "a new head with no checks registered yet does not merge",
          record: F.record(autoMerge: true, lastSeenHead: "0ld", stablePolls: 2),
          observation: F.observation(F.snapshot(F.request(checks: []))),
          action: .wait, phase: .watching),
    .init(testDescription: "unknown mergeability neither dispatches a conflict fix nor merges",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request(mergeState: .unknown))),
          action: .wait, phase: .watching),
    .init(testDescription: "a cancelled run neither dispatches nor merges",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request(checks: [F.check("build", .cancel)]))),
          action: .wait, phase: .watching),
    .init(testDescription: "required reviewers match case-insensitively",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request()), rules: mixedCaseRules, headReviewers: ["chatgpt-codex-connector"]),
          action: .merge, phase: .merging),
    .init(testDescription: "an outdated trusted thread is ignored",
          record: F.record(),
          observation: F.observation(F.snapshot(F.request(threads: [outdatedThread]))),
          action: .wait, phase: .watching),
]

@Suite struct ShepherdPolicyTests {
    @Test("decides the action and next phase", arguments: policyCases)
    func decide(_ c: ShepherdPolicyCase) {
        let decision = ShepherdPolicy.decide(c.record, c.observation)
        #expect(decision.action == c.action)
        #expect(decision.record.phase == c.phase)
    }

    @Test("dispatch counts the attempt and stores the fingerprint")
    func dispatchUpdatesRecord() {
        let decision = ShepherdPolicy.decide(
            F.record(fixAttempts: 1),
            F.observation(F.snapshot(F.request(checks: [F.failing])))
        )
        #expect(decision.record.fixAttempts == 2)
        #expect(decision.record.lastDispatchedFingerprint == ShepherdFingerprint(
            headSHA: F.head, hasConflict: false, failingCheckIDs: ["unit-tests"], threadIDs: []
        ))
        #expect(decision.record.updatedAt == F.now)
    }

    @Test("fix attempts reset only once checks are green", arguments: [
        (ReviewCheckBucket.pass, 0),
        (.pending, 2),
    ] as [(ReviewCheckBucket, Int)])
    func attemptsReset(bucket: ReviewCheckBucket, expected: Int) {
        let decision = ShepherdPolicy.decide(
            F.record(fixAttempts: 2),
            F.observation(F.snapshot(F.request(checks: [F.check("build", bucket)])))
        )
        #expect(decision.record.fixAttempts == expected)
    }

    @Test("head stability counts consecutive complete polls on one head", arguments: stabilityCases)
    func headStability(_ c: ShepherdStabilityCase) {
        let decision = ShepherdPolicy.decide(
            F.record(autoFix: false, lastSeenHead: c.lastSeen, stablePolls: c.polls),
            F.observation(F.snapshot(F.request(checks: [F.check("build", c.bucket)])))
        )
        #expect(decision.record.stableHeadPolls == c.expected)
        #expect(decision.record.lastSeenHeadSHA == F.head)
    }

    @Test("ready notification fires once per head")
    func readyOncePerHead() {
        let observation = F.observation(F.snapshot(F.request()))
        let first = ShepherdPolicy.decide(stable(), observation)
        let second = ShepherdPolicy.decide(first.record, observation)
        #expect(first.action == .notifyReady)
        #expect(first.record.notifiedReadyHeadSHA == F.head)
        #expect(second.action == .wait)

        let moved = F.observation(F.snapshot(F.request(head: F.newHead), localHead: F.newHead))
        let third = ShepherdPolicy.decide(second.record, moved)
        let fourth = ShepherdPolicy.decide(third.record, moved)
        #expect(third.action == .wait)
        #expect(fourth.action == .notifyReady)
        #expect(fourth.record.notifiedReadyHeadSHA == F.newHead)
    }

    @Test("merge outcome sets the next phase", arguments: [
        (ReviewMergeOutcome?.some(.merged), ShepherdPhase.merged),
        (.some(.queued), .queued),
        (nil, .watching),
    ] as [(ReviewMergeOutcome?, ShepherdPhase)])
    func mergeOutcome(outcome: ReviewMergeOutcome?, phase: ShepherdPhase) {
        let record = F.record(phase: .merging, autoMerge: true, lastSeenHead: F.head, stablePolls: 2)
        let next = ShepherdPolicy.applyMergeOutcome(outcome, to: record, now: F.now)
        #expect(next.phase == phase)
        #expect(next.finishedAt == (outcome == .merged ? F.now : nil))
        #expect(next.stableHeadPolls == (outcome == nil ? 0 : 2))
        #expect(next.updatedAt == F.now)
    }
}
```

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `swift test --package-path Packages/AlasCore --filter ShepherdPolicyTests`
Expected: the build fails with `cannot find 'ShepherdPolicy' in scope`, `cannot find type 'ShepherdFixRequest' in scope` and `cannot find type 'ShepherdObservation' in scope`.

- [ ] **Step 4: Implement the policy**

Create `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdPolicy.swift`:

```swift
import Foundation

/// The problems one fix turn is asked to address, ordered conflict, checks,
/// threads.
public struct ShepherdFixRequest: Equatable, Sendable {
    public let hasConflict: Bool
    public let failingChecks: [ReviewCheck]
    /// Actionable threads whose head comment is from a trusted reviewer.
    public let threads: [ReviewThread]

    public init(hasConflict: Bool, failingChecks: [ReviewCheck], threads: [ReviewThread]) {
        self.hasConflict = hasConflict
        self.failingChecks = failingChecks
        self.threads = threads
    }

    public var isEmpty: Bool { !hasConflict && failingChecks.isEmpty && threads.isEmpty }

    public func fingerprint(headSHA: String) -> ShepherdFingerprint {
        ShepherdFingerprint(
            headSHA: headSHA,
            hasConflict: hasConflict,
            failingCheckIDs: failingChecks.map(\.id).sorted(),
            threadIDs: threads.map(\.id).sorted()
        )
    }
}

public enum ShepherdAction: Equatable, Sendable {
    case wait
    case dispatchFix(ShepherdFixRequest)
    case merge
    case notifyReady
    case finish(ShepherdOutcome)
    case escalate(ShepherdEscalation)
}

public struct ShepherdObservation: Equatable, Sendable {
    /// Has `local` and `reviewRequest`.
    public let snapshot: ReviewLoopSnapshot
    /// Nil when not fetched or the fetch failed; the gate then fails closed
    /// whenever the rules require reviewers.
    public let headReviewers: Set<String>?
    public let session: ShepherdSessionState
    public let rules: ShepherdRules
    public let now: Date

    public init(
        snapshot: ReviewLoopSnapshot,
        headReviewers: Set<String>?,
        session: ShepherdSessionState,
        rules: ShepherdRules,
        now: Date
    ) {
        self.snapshot = snapshot
        self.headReviewers = headReviewers
        self.session = session
        self.rules = rules
        self.now = now
    }
}

public struct ShepherdDecision: Equatable, Sendable {
    public let record: ShepherdRecord
    public let action: ShepherdAction

    public init(record: ShepherdRecord, action: ShepherdAction) {
        self.record = record
        self.action = action
    }
}

/// Pure decision logic for one shepherd poll. Runs only after a successful
/// provider fetch; fetch errors are the poller's business.
public enum ShepherdPolicy {
    public static let maxFixAttempts = 3
    public static let noProgressPollLimit = 3
    public static let requiredStablePolls = 2

    public static func decide(_ record: ShepherdRecord, _ observation: ShepherdObservation) -> ShepherdDecision {
        guard !record.phase.isTerminal,
              let request = observation.snapshot.reviewRequest,
              request.number == record.id.requestNumber
        else { return ShepherdDecision(record: record, action: .wait) }

        var next = record
        let action = evaluate(&next, request: request, observation: observation)
        if next != record { next.updatedAt = observation.now }
        return ShepherdDecision(record: next, action: action)
    }

    public static func problems(in request: ReviewRequest) -> ShepherdFixRequest {
        ShepherdFixRequest(
            hasConflict: request.mergeState == .dirty,
            // Partial CI results never trigger a fix.
            failingChecks: hasPendingChecks(request) ? [] : request.checks.filter { $0.bucket == .fail },
            threads: request.threads.filter { $0.isActionable && $0.headAuthorTrust == .trusted }
        )
    }

    /// The existing readiness gate, plus required reviewers on the current
    /// head and a head that has stayed put with complete checks for
    /// `requiredStablePolls` polls. Never bypassed.
    public static func mergeGatePasses(_ record: ShepherdRecord, _ observation: ShepherdObservation) -> Bool {
        guard ReviewReadinessModel.canMergeReviewRequest(snapshot: observation.snapshot),
              let head = observation.snapshot.reviewRequest?.headSHA,
              record.lastSeenHeadSHA == head,
              record.stableHeadPolls >= requiredStablePolls
        else { return false }
        let required = observation.rules.requiredReviewers
        guard !required.isEmpty else { return true }
        guard let reviewers = observation.headReviewers else { return false }
        return required.allSatisfy { reviewers.contains($0.lowercased()) }
    }

    /// Applied by the service after executing `.merge`. A nil outcome (head
    /// moved, gate no longer passes, provider error) returns the record to
    /// `watching` and makes it re-prove head stability.
    public static func applyMergeOutcome(
        _ outcome: ReviewMergeOutcome?,
        to record: ShepherdRecord,
        now: Date
    ) -> ShepherdRecord {
        var next = record
        switch outcome {
        case .merged:
            next.phase = .merged
            next.finishedAt = now
        case .queued:
            next.phase = .queued
        case nil:
            next.phase = .watching
            next.stableHeadPolls = 0
        }
        next.updatedAt = now
        return next
    }

    // MARK: - Rules

    private static func evaluate(
        _ record: inout ShepherdRecord,
        request: ReviewRequest,
        observation: ShepherdObservation
    ) -> ShepherdAction {
        let now = observation.now

        // Rule 1: terminal.
        switch request.state {
        case .merged:
            record.phase = .merged
            record.finishedAt = now
            return .finish(.merged)
        case .closed:
            record.phase = .closed
            record.finishedAt = now
            return .finish(.closed)
        case .open:
            break
        }

        updateHeadStability(&record, request: request)
        let problems = Self.problems(in: request)

        // A merge attempt interrupted by a quit, or a merge queue the
        // provider no longer reports, falls back to watching.
        switch record.phase {
        case .merging:
            record.phase = .watching
        case .queued:
            if request.isInMergeQueue { return .wait }
            record.phase = .watching
        default:
            break
        }

        // Rule 2: escalated or paused.
        switch record.phase {
        case .paused:
            record.phase = .watching
        case .escalated(let reason):
            let ownerStillGone = reason == .ownerGone && record.autoFix
                && (observation.session == .archived || observation.session == .missing)
            guard problems.isEmpty, !ownerStillGone else { return .wait }
            record.phase = .watching
        default:
            break
        }

        // Rule 3: auto-fix off skips straight to the merge rules.
        if record.autoFix {
            if let action = fixRules(&record, request: request, problems: problems, observation: observation) {
                return action
            }
        } else {
            switch record.phase {
            case .fixing, .awaitingPush: record.phase = .watching
            default: break
            }
        }

        return mergeRules(&record, request: request, observation: observation)
    }

    /// Rules 4 to 7. Nil means "continue to rule 8".
    private static func fixRules(
        _ record: inout ShepherdRecord,
        request: ReviewRequest,
        problems: ShepherdFixRequest,
        observation: ShepherdObservation
    ) -> ShepherdAction? {
        // Rules 4 and 5: owner.
        switch observation.session {
        case .archived, .missing:
            record.phase = .escalated(.ownerGone)
            return .escalate(.ownerGone)
        case .busy:
            return .wait
        case .idle:
            break
        }

        // Rule 6: fix turn settled. Covers a normal turn end and a turn lost
        // to an app restart.
        if case .fixing = record.phase {
            record.phase = .awaitingPush(turnEndedAt: observation.now, pollsWithoutProgress: 0)
        }
        if case .awaitingPush(let turnEndedAt, let polls) = record.phase {
            if madeProgress(since: record.lastDispatchedFingerprint, request: request, problems: problems) {
                record.phase = .watching
            } else {
                let count = polls + 1
                if count >= noProgressPollLimit {
                    record.phase = .escalated(.noProgress)
                    return .escalate(.noProgress)
                }
                record.phase = .awaitingPush(turnEndedAt: turnEndedAt, pollsWithoutProgress: count)
                return .wait
            }
        }

        // Rule 7: problems.
        if problems.isEmpty {
            if !hasPendingChecks(request) { record.fixAttempts = 0 }
            return nil
        }
        let fingerprint = problems.fingerprint(headSHA: request.headSHA ?? "")
        if fingerprint == record.lastDispatchedFingerprint { return .wait }
        if record.fixAttempts >= maxFixAttempts {
            record.phase = .escalated(.attemptsExhausted)
            return .escalate(.attemptsExhausted)
        }
        record.phase = .fixing(dispatchedAt: observation.now)
        record.fixAttempts += 1
        record.lastDispatchedFingerprint = fingerprint
        return .dispatchFix(problems)
    }

    /// Rules 8 to 10.
    private static func mergeRules(
        _ record: inout ShepherdRecord,
        request: ReviewRequest,
        observation: ShepherdObservation
    ) -> ShepherdAction {
        guard mergeGatePasses(record, observation) else { return .wait }
        if record.autoMerge {
            record.phase = .merging
            return .merge
        }
        guard record.notifiedReadyHeadSHA != request.headSHA else { return .wait }
        record.notifiedReadyHeadSHA = request.headSHA
        return .notifyReady
    }

    // MARK: - Helpers

    private static func hasPendingChecks(_ request: ReviewRequest) -> Bool {
        request.checks.contains { $0.bucket == .pending }
    }

    /// Same head with no pending check counts up; a pending check or a new
    /// head starts over. Capped so a stable record stays equal across polls.
    private static func updateHeadStability(_ record: inout ShepherdRecord, request: ReviewRequest) {
        let checksComplete = !hasPendingChecks(request)
        guard let head = request.headSHA else {
            record.lastSeenHeadSHA = nil
            record.stableHeadPolls = 0
            return
        }
        if head == record.lastSeenHeadSHA {
            record.stableHeadPolls = checksComplete
                ? min(record.stableHeadPolls + 1, requiredStablePolls)
                : 0
        } else {
            record.lastSeenHeadSHA = head
            record.stableHeadPolls = checksComplete ? 1 : 0
        }
    }

    /// Progress after a fix turn: a new provider head, a changed set of
    /// trusted threads, nothing left to fix, or a reply on a dispatched thread
    /// from someone other than a trusted reviewer (the agent answering).
    private static func madeProgress(
        since dispatched: ShepherdFingerprint?,
        request: ReviewRequest,
        problems: ShepherdFixRequest
    ) -> Bool {
        guard let dispatched else { return true }
        if problems.isEmpty { return true }
        if (request.headSHA ?? "") != dispatched.headSHA { return true }
        if problems.threads.map(\.id).sorted() != dispatched.threadIDs { return true }
        return problems.threads.contains { thread in
            dispatched.threadIDs.contains(thread.id)
                && (thread.comments.last?.authorTrust ?? .unknown) != .trusted
        }
    }
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `swift test --package-path Packages/AlasCore --filter ShepherdPolicyTests`
Expected: `Test run with 6 tests in 1 suite passed` (30 policy cases plus the parameterized reset, stability and outcome cases).

- [ ] **Step 6: Commit**

```bash
git add Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdPolicy.swift \
  Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdFixtures.swift \
  Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdPolicyTests.swift
git commit -m "feat(shepherd): add pure shepherd decision policy"
```

### Task 6: Shepherd prompt builder

**Files:**
- Create: `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdPromptBuilder.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdPromptBuilderTests.swift` (new suite for a new type)

Verified fields used:
- `ReviewRequest`: `displayIdentity` ("GitHub #7", `CodeHostModels.swift:527`), `title`, `headRefName`, `baseRefName`, `headSHA`, `remote.remoteName`, `provider`.
- `ReviewCheck`: `id`, `name`, `workflow`, `detailURL`.
- `ReviewThread`: `id`, `path`, `line`, `originalLine`, `isFileLevel`, `comments`, `url`, `author`.
- `CodeHostKind.reviewRequestLabel` ("PR"/"MR", lines 14-19).

**Interfaces:**
- Consumes (Task 1): `ReviewComment.authorTrust: ReviewAuthorTrust`. Its `rawValue` (`trusted`/`untrusted`/`unknown`) is the trust label.
- Consumes (Task 4): `ShepherdRules` (`instructions`).
- Consumes (Task 5): `ShepherdFixRequest`, `ShepherdPolicy.problems(in:)`, and the test helper `ShepherdFixtures`:
  - `request(kind:state:head:mergeState:checks:threads:isMergeQueueEnabled:isInMergeQueue:)` (number 7, title "Fix login", head branch `fix-login`, base `main`, head `a3f9c1e5b2d4f6a8c0e2`, remote name `origin`)
  - `check(_:_:)` (workflow "CI", url `https://ci.example/<id>`)
  - `thread(_:trust:comments:)` (path `Sources/App.swift`, line 12, url `https://github.com/acme/app/pull/7#<id>`)
  - `comment(_:author:body:trust:)`
- Produces:
  ```swift
  public struct ShepherdCheckLog: Equatable, Sendable {
      public let checkID: String; public let body: String; public let isTruncated: Bool; public let url: URL?
      public init(checkID: String, body: String, isTruncated: Bool, url: URL?)
  }
  public enum ShepherdPromptBuilder {
      public static let header = "Alas PR shepherd"
      public static let maxCheckLogs = 3
      public static func fixPrompt(request: ReviewRequest, fix: ShepherdFixRequest, logs: [ShepherdCheckLog], rules: ShepherdRules) -> String
      public static func bindPrompt(request: ReviewRequest, fix: ShepherdFixRequest, rules: ShepherdRules) -> String
      public static func createPrompt(kind: CodeHostKind) -> String
  }
  ```
  The caller (service task) fetches at most `maxCheckLogs` logs with `checkEvidenceDetail`, which already keeps the last 8,000 characters. The builder never prints more than `maxCheckLogs` logs, whatever it is given.

- [ ] **Step 1: Write the failing prompt tests**

Create `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdPromptBuilderTests.swift`:

```swift
import Foundation
import Testing
@testable import AlasCore

private typealias F = ShepherdFixtures

@Suite struct ShepherdPromptBuilderTests {
    @Test("fix prompt orders conflict, checks, threads, then how to work")
    func sectionOrder() {
        let request = F.request(mergeState: .dirty, checks: [F.failing], threads: [F.trustedThread])
        let prompt = ShepherdPromptBuilder.fixPrompt(
            request: request, fix: ShepherdPolicy.problems(in: request), logs: [], rules: .none
        )
        let headings = prompt.split(separator: "\n").filter { $0.hasPrefix("## ") }.map(String.init)
        #expect(headings == [
            "## Merge conflict with main",
            "## Failing checks (1)",
            "## Review threads (1)",
            "## How to work",
        ])
        #expect(prompt.hasPrefix(
            "Alas PR shepherd · GitHub #7 \"Fix login\"\nBranch fix-login → main · head a3f9c1e\n\n"
                + "The PR needs attention. Fix what's below, commit, and push to fix-login.\n"
        ))
        #expect(prompt.contains("Merge origin/main into fix-login"))
    }

    @Test("fix prompt includes at most three logs and lists the rest")
    func logCap() {
        let checks = (1...5).map { F.check("check-\($0)", .fail) }
        let request = F.request(checks: checks)
        let logs = checks.map {
            ShepherdCheckLog(checkID: $0.id, body: "log of \($0.id)", isTruncated: false, url: nil)
        }
        let prompt = ShepherdPromptBuilder.fixPrompt(
            request: request, fix: ShepherdPolicy.problems(in: request), logs: logs, rules: .none
        )
        #expect(prompt.contains("## Failing checks (5)"))
        for index in 1...3 {
            #expect(prompt.contains("log of check-\(index)"))
            #expect(prompt.contains("Full log: https://ci.example/check-\(index)"))
        }
        for index in 4...5 {
            #expect(!prompt.contains("log of check-\(index)"))
            #expect(prompt.contains("- check-\(index) (CI): https://ci.example/check-\(index)"))
        }
    }

    @Test("fix prompt quotes every comment in a thread with author and trust")
    func fullThreadChain() {
        let thread = F.thread("PRRT_1", comments: [
            F.comment("c1", author: "maintainer", body: "This retry should back off.", trust: .trusted),
            F.comment("c2", author: "dev", body: "Which policy?\nExponential?", trust: .untrusted),
            F.comment("c3", author: "maintainer", body: "Exponential, capped.", trust: .trusted),
        ])
        let request = F.request(threads: [thread])
        let prompt = ShepherdPromptBuilder.fixPrompt(
            request: request, fix: ShepherdPolicy.problems(in: request), logs: [], rules: .none
        )
        #expect(prompt.contains("""
        ### Sources/App.swift:12
        @maintainer (trusted):
        > This retry should back off.
        @dev (untrusted):
        > Which policy?
        > Exponential?
        @maintainer (trusted):
        > Exponential, capped.
        Thread: https://github.com/acme/app/pull/7#PRRT_1 (id: PRRT_1)
        """))
    }

    @Test("fix prompt appends project rules only when present", arguments: [
        ("Batch fixes into one push.\n", true),
        ("  \n", false),
    ])
    func projectRules(instructions: String, included: Bool) {
        let request = F.request(checks: [F.failing])
        let prompt = ShepherdPromptBuilder.fixPrompt(
            request: request,
            fix: ShepherdPolicy.problems(in: request),
            logs: [],
            rules: ShepherdRules(source: .repoFile, instructions: instructions, requiredReviewers: [])
        )
        #expect(prompt.contains("## Project rules") == included)
        #expect(prompt.hasSuffix("## Project rules\nBatch fixes into one push.") == included)
    }

    @Test("create prompt names the provider's request", arguments: [
        (CodeHostKind.github, "Open a PR for the work on this branch."),
        (.gitlab, "Open an MR for the work on this branch."),
    ] as [(CodeHostKind, String)])
    func createPrompt(kind: CodeHostKind, opening: String) {
        let prompt = ShepherdPromptBuilder.createPrompt(kind: kind)
        #expect(prompt.hasPrefix(opening))
        #expect(prompt.hasSuffix("then call pr_create."))
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `swift test --package-path Packages/AlasCore --filter ShepherdPromptBuilderTests`
Expected: the build fails with `cannot find 'ShepherdPromptBuilder' in scope` and `cannot find 'ShepherdCheckLog' in scope`.

- [ ] **Step 3: Implement the prompt builder**

Create `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdPromptBuilder.swift`:

```swift
import Foundation

/// The tail of one failed check's log, as returned by `checkEvidenceDetail`.
public struct ShepherdCheckLog: Equatable, Sendable {
    public let checkID: String
    public let body: String
    public let isTruncated: Bool
    public let url: URL?

    public init(checkID: String, body: String, isTruncated: Bool, url: URL?) {
        self.checkID = checkID
        self.body = body
        self.isTruncated = isTruncated
        self.url = url
    }
}

/// Pure text for the turns the shepherd sends to the owning session.
public enum ShepherdPromptBuilder {
    public static let header = "Alas PR shepherd"
    public static let maxCheckLogs = 3

    /// Built at runtime so the fence never closes a Markdown code block that
    /// quotes this file.
    private static let fence = String(repeating: "`", count: 3)

    public static func fixPrompt(
        request: ReviewRequest,
        fix: ShepherdFixRequest,
        logs: [ShepherdCheckLog],
        rules: ShepherdRules
    ) -> String {
        var sections = [
            identity(request),
            """
            The \(request.provider.reviewRequestLabel) needs attention. Fix what's below, commit, and push to \(request.headRefName).
            Never force-push or rewrite published history. When done, call pr_status to confirm.
            """,
        ]
        if fix.hasConflict { sections.append(conflictSection(request)) }
        if !fix.failingChecks.isEmpty { sections.append(checksSection(fix.failingChecks, logs: logs)) }
        if !fix.threads.isEmpty { sections.append(threadsSection(fix.threads)) }
        sections.append(howToWork(request.provider))
        if let rulesSection = projectRulesSection(rules) { sections.append(rulesSection) }
        return sections.joined(separator: "\n\n")
    }

    /// Context for a session that just became the owner (bind, adopt, or
    /// rebind). Lists current problems by name only; the next fix turn
    /// carries logs and full threads.
    public static func bindPrompt(request: ReviewRequest, fix: ShepherdFixRequest, rules: ShepherdRules) -> String {
        let label = request.provider.reviewRequestLabel
        var sections = [
            identity(request),
            """
            Alas is now watching this \(label) and will send problems to this session as new turns: failing checks, review threads from trusted reviewers, and merge conflicts with \(request.baseRefName).
            Never force-push or rewrite published history. Call pr_status any time to see the current state.
            """,
        ]
        if fix.isEmpty {
            sections.append("Nothing needs attention right now.")
        } else {
            var lines = ["## Current problems"]
            if fix.hasConflict { lines.append("- Merge conflict with \(request.baseRefName)") }
            lines += fix.failingChecks.map { "- Failing check: \(checkTitle($0))" }
            lines += fix.threads.map { "- Review thread at \(threadLocation($0)) from @\($0.author ?? "unknown")" }
            lines.append("Alas sends the details and logs in a follow-up turn when it asks for a fix.")
            sections.append(lines.joined(separator: "\n"))
        }
        if let rulesSection = projectRulesSection(rules) { sections.append(rulesSection) }
        return sections.joined(separator: "\n\n")
    }

    /// Sent by the toolbar's Create PR / Create MR button.
    public static func createPrompt(kind: CodeHostKind) -> String {
        let article = kind == .gitlab ? "an" : "a"
        return "Open \(article) \(kind.reviewRequestLabel) for the work on this branch. "
            + "If there are uncommitted changes that belong to this work, commit them first. "
            + "Write the title and description from the actual diff and this conversation, then call pr_create."
    }

    // MARK: - Sections

    private static func identity(_ request: ReviewRequest) -> String {
        var branchLine = "Branch \(request.headRefName) → \(request.baseRefName)"
        if let head = request.headSHA, !head.isEmpty { branchLine += " · head \(head.prefix(7))" }
        return "\(header) · \(request.displayIdentity) \"\(request.title)\"\n\(branchLine)"
    }

    private static func conflictSection(_ request: ReviewRequest) -> String {
        """
        ## Merge conflict with \(request.baseRefName)
        Merge \(request.remote.remoteName)/\(request.baseRefName) into \(request.headRefName), resolve each conflict from the intended behavior, commit, push.
        """
    }

    private static func checksSection(_ checks: [ReviewCheck], logs: [ShepherdCheckLog]) -> String {
        let logsByID = Dictionary(logs.map { ($0.checkID, $0) }, uniquingKeysWith: { first, _ in first })
        var lines = ["## Failing checks (\(checks.count))"]
        for check in checks.prefix(maxCheckLogs) {
            lines.append("### \(checkTitle(check))")
            let log = logsByID[check.id]
            let body = log?.body.trimmingCharacters(in: .newlines) ?? ""
            if body.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("Log unavailable.")
            } else {
                if log?.isTruncated == true { lines.append("(last part of the log)") }
                lines.append(fence + "text")
                lines.append(body)
                lines.append(fence)
            }
            if let url = log?.url ?? check.detailURL { lines.append("Full log: \(url.absoluteString)") }
        }
        let rest = checks.dropFirst(maxCheckLogs)
        if !rest.isEmpty {
            lines.append("### Other failing checks (logs not included)")
            for check in rest {
                lines.append("- \(checkTitle(check))" + (check.detailURL.map { ": \($0.absoluteString)" } ?? ""))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func threadsSection(_ threads: [ReviewThread]) -> String {
        let blocks = threads.map { thread -> String in
            var lines = ["### \(threadLocation(thread))"]
            for comment in thread.comments {
                let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                lines.append("@\(comment.author ?? "unknown") (\(comment.authorTrust.rawValue)):")
                lines += body.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }
            }
            if let url = thread.url {
                lines.append("Thread: \(url.absoluteString) (id: \(thread.id))")
            } else {
                lines.append("Thread id: \(thread.id)")
            }
            return lines.joined(separator: "\n")
        }
        return "## Review threads (\(threads.count))\n" + blocks.joined(separator: "\n\n")
    }

    private static func howToWork(_ kind: CodeHostKind) -> String {
        let cli = kind == .github ? "gh" : "glab"
        return """
        ## How to work
        - Classify each finding: fix it, show it is already fixed, or reply with evidence that it is wrong. Never change code only to silence wrong feedback.
        - Batch every fix you can make now into one push.
        - Run the tests your repository instructions require for the files you touch.
        - If a check failure is unrelated to your change and the log shows a flake or infrastructure error, rerun it with \(cli) and say why.
        - Reply on threads you decline. Resolve threads you fixed.
        - If you can't make progress, say so plainly. Alas will notify the user.
        """
    }

    private static func projectRulesSection(_ rules: ShepherdRules) -> String? {
        let text = rules.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return "## Project rules\n\(text)"
    }

    // MARK: - Labels

    private static func checkTitle(_ check: ReviewCheck) -> String {
        guard let workflow = check.workflow, !workflow.isEmpty, workflow != check.name else { return check.name }
        return "\(check.name) (\(workflow))"
    }

    private static func threadLocation(_ thread: ReviewThread) -> String {
        guard let path = thread.path, !path.isEmpty else { return "General comment" }
        guard !thread.isFileLevel, let line = thread.line ?? thread.originalLine else { return path }
        return "\(path):\(line)"
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --package-path Packages/AlasCore --filter ShepherdPromptBuilderTests`
Expected: `Test run with 5 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdPromptBuilder.swift \
  Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdPromptBuilderTests.swift
git commit -m "feat(shepherd): build fix, bind and create prompts"
```

### Task 7: Shepherd schedule and presentation

**Files:**
- Create: `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdSchedule.swift`
- Create: `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdPresentation.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdScheduleTests.swift` (new suite)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdPresentationTests.swift` (new suite)

Both files are pure Foundation (no SwiftUI). The UI maps tones to colors: `working` maps to `warn`, `ready` to `add`, `attention` to `del`, `merged` to `.systemPurple`, `none` to no badge.

**Interfaces:**
- Consumes (Task 4): `ShepherdRecord`, `ShepherdPhase`, `ShepherdEscalation`, `ShepherdFingerprint`.
- Consumes (Task 5):
  - `ShepherdPolicy.problems(in:)`
  - test helper `ShepherdFixtures`: `record(kind:phase:autoFix:autoMerge:fixAttempts:lastDispatched:lastSeenHead:stablePolls:notifiedReady:)` (request number 7), `request(...)`, `check(_:_:)`, `failing` (id/name "unit-tests", `.fail`), `pending`, `now`, `earlier`, `fingerprint(_:head:)`
- Consumes (existing): `CodeHostKind.reviewRequestNumberPrefix` ("#"/"!", `CodeHostModels.swift:21-26`).
- Produces:
  ```swift
  public enum ShepherdSchedule {
      public static let tick: TimeInterval = 30
      public static let maxConcurrentFetches = 2
      public static func interval(for record: ShepherdRecord, checksPending: Bool) -> TimeInterval?
      public static func backoff(afterFailures count: Int) -> TimeInterval
  }
  public enum ShepherdBadgeTone: Equatable, Sendable { case none, working, ready, attention, merged }
  public struct ShepherdPresentation: Equatable, Sendable {
      public let tone: ShepherdBadgeTone; public let tooltip: String; public let phaseLine: String
      public init(tone: ShepherdBadgeTone, tooltip: String, phaseLine: String)
      public static func make(record: ShepherdRecord?, request: ReviewRequest?, mergeGatePasses: Bool) -> ShepherdPresentation
  }
  ```
  Callers pass `mergeGatePasses` as `ShepherdPolicy.mergeGatePasses(record, observation)` when they have a record, so the badge matches the policy.

Presentation mapping (first match wins):

| Input | Tone | phaseLine |
| --- | --- | --- |
| no record, request present | `none` | `not shepherded` (tooltip `#7 · not shepherded`) |
| no record, no request | `none` | `not shepherded` (tooltip `Not shepherded`) |
| `merged` | `merged` | `merged` |
| `closed` | `none` | `closed` |
| `escalated(e)` | `attention` | `needs attention: <reason>` |
| `paused` | `attention` | `paused: provider sign-in failed` |
| `fixing` | `working` | `fixing <conflict, check names, N review threads>`, from `lastDispatchedFingerprint` |
| `awaitingPush` | `working` | `waiting for a push` |
| `merging` | `working` | `merging` |
| `queued` | `working` | `in merge queue` |
| watching, gate passes | `ready` | `ready to merge` |
| watching, no request | `working` | `watching` |
| watching, a check pending | `working` | `checks running` |
| watching, problems, auto-fix off | `attention` | `auto-fix off: <summary>` |
| watching, problems, auto-fix on | `working` | `needs a fix: <summary>` |
| watching, otherwise | `working` | `watching` |

Tooltip = `"\(prefix)\(number) · \(phaseLine)"`, for example `#7 · fixing unit-tests` or `!7 · merged`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdScheduleTests.swift`:

```swift
import Foundation
import Testing
@testable import AlasCore

private typealias F = ShepherdFixtures

struct ShepherdIntervalCase: Sendable, CustomTestStringConvertible {
    let phase: ShepherdPhase
    let checksPending: Bool
    let expected: TimeInterval?
    var testDescription: String { "\(phase), checks pending: \(checksPending)" }
}

private let intervalCases: [ShepherdIntervalCase] = [
    .init(phase: .watching, checksPending: false, expected: 120),
    .init(phase: .watching, checksPending: true, expected: 30),
    .init(phase: .fixing(dispatchedAt: F.earlier), checksPending: false, expected: 30),
    .init(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 1), checksPending: false, expected: 30),
    .init(phase: .merging, checksPending: false, expected: 30),
    .init(phase: .queued, checksPending: false, expected: 30),
    .init(phase: .escalated(.noProgress), checksPending: true, expected: 300),
    .init(phase: .paused, checksPending: false, expected: 300),
    .init(phase: .merged, checksPending: false, expected: nil),
    .init(phase: .closed, checksPending: true, expected: nil),
]

@Suite struct ShepherdScheduleTests {
    @Test("poll interval follows the record phase", arguments: intervalCases)
    func interval(_ c: ShepherdIntervalCase) {
        #expect(ShepherdSchedule.interval(for: F.record(phase: c.phase), checksPending: c.checksPending) == c.expected)
    }

    @Test("provider failures back off exponentially up to ten minutes", arguments: [
        (0, 0.0), (1, 30.0), (2, 60.0), (3, 120.0), (5, 480.0), (6, 600.0), (40, 600.0),
    ] as [(Int, TimeInterval)])
    func backoff(failures: Int, expected: TimeInterval) {
        #expect(ShepherdSchedule.backoff(afterFailures: failures) == expected)
    }
}
```

Create `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdPresentationTests.swift`:

```swift
import Foundation
import Testing
@testable import AlasCore

private typealias F = ShepherdFixtures

struct ShepherdPresentationCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let record: ShepherdRecord?
    let request: ReviewRequest?
    let gate: Bool
    let tone: ShepherdBadgeTone
    let tooltip: String
}

private let fixingUnitTests = F.fingerprint(
    ShepherdFixRequest(hasConflict: false, failingChecks: [F.failing], threads: [])
)

private let presentationCases: [ShepherdPresentationCase] = [
    .init(testDescription: "unbound request has no badge",
          record: nil, request: F.request(), gate: false, tone: .none, tooltip: "#7 · not shepherded"),
    .init(testDescription: "nothing to show",
          record: nil, request: nil, gate: false, tone: .none, tooltip: "Not shepherded"),
    .init(testDescription: "checks pending",
          record: F.record(), request: F.request(checks: [F.pending]), gate: false,
          tone: .working, tooltip: "#7 · checks running"),
    .init(testDescription: "fixing names the dispatched checks",
          record: F.record(phase: .fixing(dispatchedAt: F.earlier), lastDispatched: fixingUnitTests),
          request: F.request(checks: [F.failing]), gate: false,
          tone: .working, tooltip: "#7 · fixing unit-tests"),
    .init(testDescription: "awaiting push",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0)),
          request: F.request(checks: [F.failing]), gate: false,
          tone: .working, tooltip: "#7 · waiting for a push"),
    .init(testDescription: "merging",
          record: F.record(phase: .merging), request: F.request(), gate: false,
          tone: .working, tooltip: "#7 · merging"),
    .init(testDescription: "queued",
          record: F.record(phase: .queued), request: F.request(isInMergeQueue: true), gate: false,
          tone: .working, tooltip: "#7 · in merge queue"),
    .init(testDescription: "gate passes",
          record: F.record(), request: F.request(), gate: true,
          tone: .ready, tooltip: "#7 · ready to merge"),
    .init(testDescription: "failing with auto-fix off",
          record: F.record(autoFix: false), request: F.request(checks: [F.failing]), gate: false,
          tone: .attention, tooltip: "#7 · auto-fix off: unit-tests"),
    .init(testDescription: "failing with auto-fix on",
          record: F.record(), request: F.request(checks: [F.failing]), gate: false,
          tone: .working, tooltip: "#7 · needs a fix: unit-tests"),
    .init(testDescription: "escalated",
          record: F.record(phase: .escalated(.attemptsExhausted)), request: F.request(checks: [F.failing]), gate: false,
          tone: .attention, tooltip: "#7 · needs attention: fix attempts used up"),
    .init(testDescription: "paused",
          record: F.record(phase: .paused), request: nil, gate: false,
          tone: .attention, tooltip: "#7 · paused: provider sign-in failed"),
    .init(testDescription: "merged on GitLab",
          record: F.record(kind: .gitlab, phase: .merged), request: nil, gate: false,
          tone: .merged, tooltip: "!7 · merged"),
    .init(testDescription: "closed",
          record: F.record(phase: .closed), request: nil, gate: false,
          tone: .none, tooltip: "#7 · closed"),
]

@Suite struct ShepherdPresentationTests {
    @Test("badge tone and tooltip follow the record and request", arguments: presentationCases)
    func presentation(_ c: ShepherdPresentationCase) {
        let presentation = ShepherdPresentation.make(record: c.record, request: c.request, mergeGatePasses: c.gate)
        #expect(presentation.tone == c.tone)
        #expect(presentation.tooltip == c.tooltip)
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `swift test --package-path Packages/AlasCore --filter 'ShepherdScheduleTests|ShepherdPresentationTests'`
Expected: the build fails with `cannot find 'ShepherdSchedule' in scope`, `cannot find 'ShepherdPresentation' in scope` and `cannot find type 'ShepherdBadgeTone' in scope`.

- [ ] **Step 3: Implement the schedule**

Create `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdSchedule.swift`:

```swift
import Foundation

/// Polling cadence for shepherd records.
public enum ShepherdSchedule {
    /// One timer evaluates which records are due.
    public static let tick: TimeInterval = 30
    public static let maxConcurrentFetches = 2

    private static let activeInterval: TimeInterval = 30
    private static let watchingInterval: TimeInterval = 120
    private static let stalledInterval: TimeInterval = 300
    private static let maxBackoff: TimeInterval = 600

    /// 30 s while CI runs or a fix or merge is in flight, 2 min while
    /// watching a settled PR, 5 min when escalated or paused, nil for
    /// terminal records (not polled).
    public static func interval(for record: ShepherdRecord, checksPending: Bool) -> TimeInterval? {
        switch record.phase {
        case .merged, .closed:
            nil
        case .escalated, .paused:
            stalledInterval
        case .fixing, .awaitingPush, .merging, .queued:
            activeInterval
        case .watching:
            checksPending ? activeInterval : watchingInterval
        }
    }

    /// Delay after `count` consecutive provider errors: 30 s * 2^(count-1),
    /// capped at 10 min. Zero failures means no delay.
    public static func backoff(afterFailures count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        let exponent = min(count - 1, 5)
        return min(tick * Double(1 << exponent), maxBackoff)
    }
}
```

- [ ] **Step 4: Implement the presentation**

Create `Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdPresentation.swift`:

```swift
import Foundation

/// Badge state shared by the ACP toolbar button and the Changes drawer. The
/// app maps tones to colors (working: warn, ready: add, attention: del,
/// merged: purple, none: no badge).
public enum ShepherdBadgeTone: Equatable, Sendable {
    case none, working, ready, attention, merged
}

public struct ShepherdPresentation: Equatable, Sendable {
    public let tone: ShepherdBadgeTone
    /// "#2041 · fixing unit-tests"
    public let tooltip: String
    /// The phase part of the tooltip, without the number.
    public let phaseLine: String

    public init(tone: ShepherdBadgeTone, tooltip: String, phaseLine: String) {
        self.tone = tone
        self.tooltip = tooltip
        self.phaseLine = phaseLine
    }

    /// `mergeGatePasses` should come from `ShepherdPolicy.mergeGatePasses`
    /// so the badge agrees with what the policy would do.
    public static func make(record: ShepherdRecord?, request: ReviewRequest?, mergeGatePasses: Bool) -> ShepherdPresentation {
        guard let record else {
            let line = "not shepherded"
            let tooltip = request.map { "\($0.provider.reviewRequestNumberPrefix)\($0.number) · \(line)" }
                ?? "Not shepherded"
            return ShepherdPresentation(tone: .none, tooltip: tooltip, phaseLine: line)
        }
        let (tone, line) = state(record: record, request: request, mergeGatePasses: mergeGatePasses)
        let number = "\(record.id.providerKind.reviewRequestNumberPrefix)\(record.id.requestNumber)"
        return ShepherdPresentation(tone: tone, tooltip: "\(number) · \(line)", phaseLine: line)
    }

    private static func state(
        record: ShepherdRecord,
        request: ReviewRequest?,
        mergeGatePasses: Bool
    ) -> (ShepherdBadgeTone, String) {
        switch record.phase {
        case .merged: return (.merged, "merged")
        case .closed: return (.none, "closed")
        case .escalated(let reason): return (.attention, "needs attention: \(text(for: reason))")
        case .paused: return (.attention, "paused: provider sign-in failed")
        case .fixing: return (.working, fixingLine(record: record, request: request))
        case .awaitingPush: return (.working, "waiting for a push")
        case .merging: return (.working, "merging")
        case .queued: return (.working, "in merge queue")
        case .watching: break
        }
        if mergeGatePasses { return (.ready, "ready to merge") }
        guard let request else { return (.working, "watching") }
        if request.checks.contains(where: { $0.bucket == .pending }) { return (.working, "checks running") }
        let problems = ShepherdPolicy.problems(in: request)
        guard !problems.isEmpty else { return (.working, "watching") }
        let what = summary(
            hasConflict: problems.hasConflict,
            checkNames: problems.failingChecks.map(\.name),
            threadCount: problems.threads.count
        )
        return record.autoFix ? (.working, "needs a fix: \(what)") : (.attention, "auto-fix off: \(what)")
    }

    private static func fixingLine(record: ShepherdRecord, request: ReviewRequest?) -> String {
        guard let fingerprint = record.lastDispatchedFingerprint else { return "fixing" }
        let names = fingerprint.failingCheckIDs.map { id in
            request?.checks.first(where: { $0.id == id })?.name ?? id
        }
        let what = summary(
            hasConflict: fingerprint.hasConflict,
            checkNames: names,
            threadCount: fingerprint.threadIDs.count
        )
        return what.isEmpty ? "fixing" : "fixing \(what)"
    }

    private static func summary(hasConflict: Bool, checkNames: [String], threadCount: Int) -> String {
        var parts: [String] = []
        if hasConflict { parts.append("merge conflict") }
        parts += checkNames
        if threadCount > 0 { parts.append(threadCount == 1 ? "1 review thread" : "\(threadCount) review threads") }
        return parts.joined(separator: ", ")
    }

    private static func text(for escalation: ShepherdEscalation) -> String {
        switch escalation {
        case .attemptsExhausted: "fix attempts used up"
        case .noProgress: "no progress after a fix turn"
        case .deliveryFailed: "couldn't reach the session"
        case .ownerGone: "session is gone"
        case .authFailed: "provider sign-in failed"
        }
    }
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `swift test --package-path Packages/AlasCore --filter 'ShepherdScheduleTests|ShepherdPresentationTests'`
Expected: `Test run with 3 tests in 2 suites passed`.

- [ ] **Step 6: Run every shepherd suite together**

Run: `swift test --package-path Packages/AlasCore --filter Shepherd`
Expected: `Test run with 16 tests in 5 suites passed` (`ShepherdRulesResolverTests`, `ShepherdPolicyTests`, `ShepherdPromptBuilderTests`, `ShepherdScheduleTests`, `ShepherdPresentationTests`).

- [ ] **Step 7: Commit**

```bash
git add Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdSchedule.swift \
  Packages/AlasCore/Sources/AlasCore/Shepherd/ShepherdPresentation.swift \
  Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdScheduleTests.swift \
  Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdPresentationTests.swift
git commit -m "feat(shepherd): add poll schedule and badge presentation"
```

---

## Group C: Service and app wiring (Tasks 8-10)

#### Planning notes for this group

Reconcile these with the other parts before assembling.

1. `ReviewShepherd.init` gains `fileURL: URL = Paths.reviewShepherdsFile` right after `store`, exactly like `RunScheduler.init(store:fileURL:...)` (`Packages/AlasCore/Sources/AlasCore/Schedules/RunScheduler.swift`). Callers that use the contract labels compile unchanged.
2. `ReviewShepherdsFile`, `Paths.reviewShepherdsFile` and a small pure `ShepherdRecordRetention.prune(_:now:)` (7-day pruning) live in `ReviewShepherd.swift` (Task 8). PlanCore confirmed its tasks define none of them. The dispatch brief called the pruning helper `ShepherdRecordStore.prune(records:now:)`; it is named `ShepherdRecordRetention` because it does no I/O.
3. Decode failure: no separate `.bad` rename. `PersistenceStore.readIfExistsReportingRecovery` (`Packages/AlasCore/Sources/AlasCore/Persistence/PersistenceStore.swift:65-86`) already moves an unreadable file to `review-shepherds.json.broken-<timestamp>` and returns the error; the shepherd logs it and starts empty. Records also decode one by one, as `RunSchedulesFile` does, so one bad record does not drop the rest.
4. `bind(...)` is `@discardableResult`. Bind and `resume` both reset `fixAttempts` to 0 and clear `lastDispatchedFingerprint` (agreed with PlanCore: the policy then dispatches the current problems to the new owner on the next idle poll).
5. A session owns at most one non-terminal record. `bind` deletes the session's other non-terminal records (their requests are untouched) and never moves another session's record.
6. The branch lookup in `ReviewLoopState.refresh` only lists OPEN requests (`gh pr list --state open`, `GitHubCLIProvider.swift:413-428`). When it returns no request or another request, the shepherd reads the record's request by number (`CodeHostProvider.reviewRequest(remote:number:cwd:)`, `CodeHostProvider.swift:141`). Merged or closed there goes to `ShepherdPolicy.decide` (rule 1 finishes it). Still open means the worktree is on another branch, or the request was retargeted: the shepherd decides nothing that poll, and for a retarget adopts the request's new base so the next lookup finds it.
7. Spec "Session integration" step 3 (`sendPrompt(normalUserTurn: false)`) cannot reach a session this instance has not attached: `sendPrompt` first calls `confirmedWriterLease(for:)` (`ACPSessionManager.swift:456-459, 512-531`), which is false without a lease. `deliverShepherdPrompt` therefore uses `enqueueDelegatedPrompt` (default `requiringWriter: false`) plus `reattach(to:)`, the same "queue before attach" route the orchestration coordinator uses for a child's first prompt (`ACPSessionOrchestrationCoordinator.swift:1171-1187`). This matches contract deviation 4.
8. `ShepherdSessionState.busy` also covers a queued prompt that has not started yet on a spawning or ready agent (PlanCore's policy relies on this so `fixing` does not move to `awaitingPush` early). A prompt stuck behind a failed, disconnected or unattached agent is not busy, so it ends in a no-progress escalation instead of waiting forever.
9. Owner-gone attention: `AttentionProducer.review` has no body parameter and only reports CI, feedback and sync states, so it does not fit. The app appends an `AttentionHistoryEvent` (kind `.actionableFeedback`, `requiresAction: false`, jump target `.reviewRequest(number:)`) through `attentionStore.appendHistory`, the same API `AttentionProducer.finished` events use (`Alas/Sources/Attention/AppState+Attention.swift:842-846`). No new `AttentionKind`.
10. `shepherdBaseBranch(for:)` prefers the cached pane's `reviewLoop.currentBaseBranch` (it carries a per-worktree base override) and falls back to `config.worktrees.baseBranch`. Binds pass `request.baseRefName` instead, because the branch lookup filters by base (`gh pr list --base`).
11. `requestShepherdCreatePR(sessionID:worktree:)` has no provider kind in its signature, so it detects one from `git remote -v` with `CodeHostRemoteDetector.detect(from:)` and reports an in-app error when there is no GitHub or GitLab remote.
12. Extra internal app helpers beyond the contract, for later tasks to reuse: `isShepherdEligible(_ worktree: Worktree) -> Bool` and `shepherdRules(worktreeID: String) -> ShepherdRules` in `AppState+Shepherd.swift`. `cliPRCreate`/`cliPRStatus` from the contract are not written here; the MCP task adds them to `AppState+Shepherd.swift`.
13. Escalated records are not flipped to `paused` by an auth failure (they stay escalated until Resume). A failed delivery restores the pre-dispatch `fixAttempts` and `lastDispatchedFingerprint`, so the undelivered prompt is not counted and is sent again after Resume.
14. `WorktreeContext.baseBranch` is informational. Evaluation uses `record.baseBranch`, the request's own base captured at bind.

### Task 8: Review shepherd service and headless local probe

**Files:**
- Create: `Packages/AlasCore/Sources/AlasCore/Shepherd/ReviewLoopLocalProbe.swift`
- Create: `Packages/AlasCore/Sources/AlasCore/Shepherd/ReviewShepherd.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdRecordRetentionTests.swift` (new suite for a new type; test target `AlasCoreTests` from `Packages/AlasCore/Package.swift:20`, subfolders are picked up by SwiftPM)
- Read only (patterns this task mirrors):
  - `Packages/AlasCore/Sources/AlasCore/Schedules/RunScheduler.swift:76-112` (timer, wake observer, start/stop) and `:422-451` (load/persist)
  - `Packages/AlasCore/Sources/AlasCore/Schedules/RunSchedule.swift:450-507` (`RunSchedulesFile` lenient decoding, `Paths.runSchedulesFile`)
  - `Alas/Sources/Right/RightPaneState.swift:1515-1532, 1567-1568, 1671-1673` (git probes) and `:2918-2949` (`ReviewLoopLocalState` assembly), `:1380-1385` (ahead count)
  - `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/ReviewLoopState.swift:42-50` (init), `:185-343` (refresh, error and auth snapshots), `:488-539` (`merge(snapshot:)`)
  - `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/CodeHostProvider.swift:141` (`reviewRequest(remote:number:cwd:)`), `:172-178` (`failedCheckEvidence`, `checkEvidenceDetail`)
  - `Packages/AlasCore/Sources/AlasCore/Integrations/CodeHost/ReviewEvidence.swift:135-141` (CI evidence item id equals `ReviewCheck.id`)

**Interfaces:**
- Consumes (from the other shepherd tasks, all in `Packages/AlasCore/Sources/AlasCore/Shepherd/`):
  - `ShepherdModels.swift`: `ShepherdRecordID` (`init(worktreeID:request:)`, `worktreeID`, `providerKind`, `requestNumber`, `storageKey`), `ShepherdRecord` (`init(id:sessionID:remote:branch:baseBranch:autoFix:autoMerge:now:)`, vars `sessionID`, `remote`, `branch`, `baseBranch`, `autoFix`, `autoMerge`, `phase`, `lastDispatchedFingerprint`, `fixAttempts`, `finishedAt`, `createdAt`, `updatedAt`), `ShepherdPhase` (`isTerminal`, cases incl. `.fixing(dispatchedAt:)`, `.awaitingPush(turnEndedAt:pollsWithoutProgress:)`, `.paused`, `.escalated(_)`, `.merged`, `.queued`), `ShepherdEscalation`, `ShepherdSessionState`.
  - `ShepherdRules.swift`: `ShepherdRules` (`.none`, `requiredReviewers`).
  - `ShepherdPolicy.swift`: `ShepherdPolicy.decide(_:_:) -> ShepherdDecision`, `ShepherdPolicy.problems(in:) -> ShepherdFixRequest`, `ShepherdPolicy.applyMergeOutcome(_:to:now:) -> ShepherdRecord`, `ShepherdObservation(snapshot:headReviewers:session:rules:now:)`, `ShepherdAction`, `ShepherdOutcome`, `ShepherdFixRequest.failingChecks: [ReviewCheck]`.
  - `ShepherdPromptBuilder.swift`: `ShepherdPromptBuilder.fixPrompt(request:fix:logs:rules:)`, `bindPrompt(request:fix:rules:)`, `maxCheckLogs`, `ShepherdCheckLog(checkID:body:isTruncated:url:)`.
  - `ShepherdSchedule.swift`: `ShepherdSchedule.tick`, `maxConcurrentFetches`, `interval(for:checksPending:) -> TimeInterval?`, `backoff(afterFailures:) -> TimeInterval`.
  - Provider task: `CodeHostProvider.reviewersOnHead(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> Set<String>`.
  - Existing: `ReviewLoopState`, `CodeHostProviderRegistry`, `PersistenceStoreProtocol`, `Paths.appSupportRoot`, `GitService`.
- Produces:
  - `public struct ReviewLoopLocalProbe: Sendable { public var probe: @Sendable (_ worktreePath: URL, _ baseBranch: String) async throws -> (local: ReviewLoopLocalState, remotes: [GitRemote]); public init(probe:); public static let live: ReviewLoopLocalProbe }`
  - `public struct ReviewShepherdsFile: Codable, Equatable, Sendable { var version: Int = 1; var records: [ShepherdRecord]; init(records:) }`
  - `extension Paths { public static var reviewShepherdsFile: URL }` (`review-shepherds.json`)
  - `public enum ShepherdRecordRetention { static let finishedLifetime: TimeInterval; static func prune(_ records: [ShepherdRecord], now: Date) -> [ShepherdRecord] }`
  - `@MainActor @Observable public final class ReviewShepherd` with exactly the contract API: `WorktreeContext` (with public memberwise init), `Event`, `Effects` (public init with labels `worktreeContext:sessionState:deliverPrompt:rules:notify:refreshPaneIfCached:archiveWorktreeIfAllowed:`), `static var wakeNotification`, `effects`, `records`, `snapshots`, `init(store:fileURL:providerRegistry:localProbe:now:)`, `start()`, `stop()`, `record(forSession:)`, `record(forWorktree:)`, `bind(sessionID:worktreeID:request:baseBranch:autoFix:autoMerge:sendContext:)`, `setAutoFix(_:for:)`, `setAutoMerge(_:for:)`, `resume(_:)`, `stopShepherding(_:)`, `turnCompleted(sessionID:)`, `evaluateNow(_:)`, `fetchSnapshot(worktreePath:baseBranch:)`, `headReviewers(for:worktreePath:)`.

**Decisions this task implements (keep them; later tasks rely on them):**
- Every evaluation: worktree context (missing or ineligible drops the record) → local probe → headless `ReviewLoopState.refresh(local:remotes:)` → classify the snapshot → make sure it carries this record's request (by-number fallback, see below) → required reviewers only when the rules list some and the request is open → owner state → `ShepherdPolicy.decide` → persist → act → schedule → `refreshPaneIfCached`.
- Snapshot classification: `errorMessage != nil` or no code-host remote is a fetch failure (per-record exponential backoff via `ShepherdSchedule.backoff`). A remote with `providerAvailable == false` or `providerAuthenticated == false` is an auth failure: phase `.paused` and one `.escalated(_, .authFailed, _)` event on the transition; an escalated record stays escalated. The policy only runs on a successful fetch and moves `.paused` back to `.watching`.
- Request matching: the branch lookup only finds open requests on the current branch. If it returns nothing or another request, read the record's request by number. Merged or closed: decide on a snapshot that carries it (policy rule 1 finishes). Open: no decision this poll; if `baseRefName` changed, adopt it and evaluate again right away, otherwise wait one regular interval.
- Due times, failure counts and the in-flight set are in memory. `start()` and wake make every non-terminal record due. The 30 s timer starts due records, earliest first, while fewer than `ShepherdSchedule.maxConcurrentFetches` (2) are in flight. `evaluateNow` bypasses due times and the cap (one user-initiated fetch) but counts as in flight. Each evaluation first sets a 30 s floor due time so no early exit can make it spin.
- `.dispatchFix`: fetch `failedCheckEvidence`, then `checkEvidenceDetail` for up to `ShepherdPromptBuilder.maxCheckLogs` failing checks, build `fixPrompt`, `deliverPrompt`. `false` escalates `.deliveryFailed` and restores the pre-decision `fixAttempts` and `lastDispatchedFingerprint`.
- `.merge`: re-probe local state right before merging (same final check as `RightPaneState.performMerge`: branch unchanged, HEAD equals the reviewed head, clean tree, nothing to push), then `ReviewLoopState.merge(snapshot:)`, then `ShepherdPolicy.applyMergeOutcome`. `.merged` notifies and calls `archiveWorktreeIfAllowed`; `.queued` notifies; anything else is logged (the policy put it back to watching).
- `.notifyReady`, `.finish`, `.escalate` call `effects.notify`; `.finish(.merged)` also calls `archiveWorktreeIfAllowed`.
- `bind`: one live record per session (see Contract notes 4 and 5). With `sendContext`, sends `ShepherdPromptBuilder.bindPrompt` with the request's current problems; a failed delivery escalates `.deliveryFailed`.
- `turnCompleted(sessionID:)`: every `.fixing` record of that session moves to `.awaitingPush(turnEndedAt: now, pollsWithoutProgress: 0)` and becomes due now.
- Tests: one parameterized test for `ShepherdRecordRetention.prune`. It is pure retention logic whose regression would silently delete active records or keep finished ones forever. The service itself is wiring around already-tested pure types (policy, schedule, prompt builder), so it gets no tests (AGENTS.md: no tests for wiring or persistence round trips).

- [ ] **Step 1: Write the failing retention test**

Create `Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdRecordRetentionTests.swift`:

```swift
import Foundation
import Testing
@testable import AlasCore

@Suite("Shepherd record retention")
struct ShepherdRecordRetentionTests {
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    static let cases: [(phase: ShepherdPhase, finishedDaysAgo: Double?, updatedDaysAgo: Double, kept: Bool)] = [
        (.merged, 8, 8, false),
        (.closed, 6, 6, true),
        // Finished without a finishedAt: counted from updatedAt.
        (.merged, nil, 8, false),
        (.watching, nil, 30, true),
        (.escalated(.noProgress), nil, 30, true),
    ]

    @Test("finished records are dropped after seven days and active ones never are", arguments: cases)
    func prune(phase: ShepherdPhase, finishedDaysAgo: Double?, updatedDaysAgo: Double, kept: Bool) {
        var record = ShepherdRecord(
            id: ShepherdRecordID(
                worktreeID: "/tmp/wt",
                providerKind: .github,
                host: "github.com",
                repositorySlug: "o/r",
                requestNumber: 7
            ),
            sessionID: "session",
            remote: CodeHostRemote(
                kind: .github,
                host: "github.com",
                owner: "o",
                repository: "r",
                remoteName: "origin",
                webURL: URL(string: "https://github.com/o/r")!
            ),
            branch: "feature",
            baseBranch: "main",
            autoFix: true,
            autoMerge: false,
            now: Self.now.addingTimeInterval(-40 * Self.day)
        )
        record.phase = phase
        record.finishedAt = finishedDaysAgo.map { Self.now.addingTimeInterval(-$0 * Self.day) }
        record.updatedAt = Self.now.addingTimeInterval(-updatedDaysAgo * Self.day)

        #expect(ShepherdRecordRetention.prune([record], now: Self.now).count == (kept ? 1 : 0))
    }
}
```

- [ ] **Step 2: Run the test to see it fail**

Run: `swift test --package-path Packages/AlasCore --filter ShepherdRecordRetentionTests`
Expected: the build fails with `cannot find 'ShepherdRecordRetention' in scope`.

- [ ] **Step 3: Add the headless local probe**

Create `Packages/AlasCore/Sources/AlasCore/Shepherd/ReviewLoopLocalProbe.swift`:

```swift
import Foundation

/// Builds the `ReviewLoopLocalState` the review loop needs, for callers that
/// have no Changes pane: the PR shepherd and `pr_status`. `RightPaneState`
/// keeps its own assembly because it shares these probes with the file tree
/// refresh.
public struct ReviewLoopLocalProbe: Sendable {
    public var probe: @Sendable (_ worktreePath: URL, _ baseBranch: String) async throws -> (local: ReviewLoopLocalState, remotes: [GitRemote])

    public init(
        probe: @escaping @Sendable (_ worktreePath: URL, _ baseBranch: String) async throws -> (local: ReviewLoopLocalState, remotes: [GitRemote])
    ) {
        self.probe = probe
    }

    /// The fields `RightPaneState.refreshReviewLoop` fills, from the same
    /// `GitService` probes, without the file tree and stash work the pane
    /// also does. The ahead count uses the review-loop base resolution
    /// (`origin/<base>` first). Unlike the pane, a status or HEAD read that
    /// fails throws, so a broken worktree backs off instead of reading as a
    /// clean, unborn branch. The other probes keep the pane's fallbacks:
    /// `needsPush` true, upstream-ahead 0, no upstream, no remotes.
    public static let live = ReviewLoopLocalProbe { worktreePath, baseBranch in
        let git = GitService()
        async let status = git.status(worktreePath: worktreePath)
        async let head = git.revParseHEAD(worktreePath: worktreePath)
        async let branch = git.currentBranch(worktreePath: worktreePath)
        async let ahead = git.commitsAhead(at: worktreePath, baseBranch: baseBranch, resolution: .baseOriginFirst)
        async let upstream = git.resolveUpstreamRef(worktreePath: worktreePath)
        async let remotes = git.remotes(worktreePath: worktreePath)
        async let needsPush = git.needsPush(worktreePath: worktreePath)
        async let upstreamAhead = git.upstreamAheadCommitCount(worktreePath: worktreePath)
        let changes = try await status
        let headSHA = try await head
        let resolvedUpstream = try? await upstream
        let local = ReviewLoopLocalState(
            branchName: (try? await branch) ?? "",
            headSHA: headSHA,
            baseBranch: baseBranch,
            hasWorkingTreeChanges: !changes.isEmpty,
            hasStagedChanges: changes.contains { $0.stage == .staged },
            aheadCommitCount: (try? await ahead)?.commits.count ?? 0,
            hasUpstream: resolvedUpstream != nil,
            upstreamRemoteName: resolvedUpstream?.remote,
            upstreamBranchName: resolvedUpstream.map { String($0.ref.dropFirst($0.remote.count + 1)) },
            upstreamAheadCommitCount: (try? await upstreamAhead) ?? 0,
            needsPush: (try? await needsPush) ?? true
        )
        return (local: local, remotes: (try? await remotes) ?? [])
    }
}
```

- [ ] **Step 4: Add the service, its file type and retention**

Create `Packages/AlasCore/Sources/AlasCore/Shepherd/ReviewShepherd.swift`:

```swift
import Foundation
import Observation
import os

private let shepherdLogger = Logger(subsystem: "io.nlopez.alas", category: "ReviewShepherd")

/// The shepherd's records on disk, at `Paths.reviewShepherdsFile`. Decoded
/// per record, like `RunSchedulesFile`: one record written by a newer build
/// (an unknown phase, say) must not read as "no records" and then be
/// persisted over the ones that still decode.
public struct ReviewShepherdsFile: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var records: [ShepherdRecord] = []

    public enum CodingKeys: String, CodingKey, Sendable {
        case version, records
    }

    public init(records: [ShepherdRecord] = []) {
        self.records = records
    }

    private struct LenientRecord: Decodable {
        let record: ShepherdRecord?

        init(from decoder: Decoder) throws {
            record = try? ShepherdRecord(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        records = ((try? c.decode([LenientRecord].self, forKey: .records)) ?? []).compactMap(\.record)
    }
}

extension Paths {
    public static var reviewShepherdsFile: URL {
        appSupportRoot.appendingPathComponent("review-shepherds.json")
    }
}

/// How long merged and closed records stay, so the toolbar button and the
/// Changes drawer can still show the outcome.
public enum ShepherdRecordRetention {
    public static let finishedLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Drops finished records older than `finishedLifetime`, counted from
    /// `finishedAt` (`updatedAt` for one finished without it). Records still
    /// being shepherded are kept however old they are.
    public static func prune(_ records: [ShepherdRecord], now: Date) -> [ShepherdRecord] {
        records.filter { record in
            guard record.phase.isTerminal else { return true }
            return now.timeIntervalSince(record.finishedAt ?? record.updatedAt) < finishedLifetime
        }
    }
}

/// Watches every bound pull or merge request while Alas runs. It owns the
/// records, their timing and the provider fetches; `ShepherdPolicy` decides
/// what each fetch means, and `effects` (installed by AppState) reach the
/// sessions, notifications, panes and the archive path. Same split as
/// `RunScheduler`, and like it nothing here runs while the app is quit.
///
/// One 30 s timer starts whichever records are due, at most
/// `ShepherdSchedule.maxConcurrentFetches` at a time. `start()` and waking
/// the machine make every active record due at once. Due times and failure
/// counts live in memory only.
@MainActor
@Observable
public final class ReviewShepherd {
    public struct WorktreeContext: Equatable, Sendable {
        public let worktreeID: String
        public let projectID: String
        public let path: URL
        /// The base the Changes pane reviews against. Informational: each
        /// record keeps the base of its own request, which the branch lookup
        /// filters on.
        public let baseBranch: String
        /// A local worktree outside every Workspace checkout.
        public let isEligible: Bool

        public init(worktreeID: String, projectID: String, path: URL, baseBranch: String, isEligible: Bool) {
            self.worktreeID = worktreeID
            self.projectID = projectID
            self.path = path
            self.baseBranch = baseBranch
            self.isEligible = isEligible
        }
    }

    /// What the app turns into notifications and attention.
    public enum Event: Equatable, Sendable {
        case ready(ShepherdRecord, title: String)
        case merged(ShepherdRecord, title: String)
        case queued(ShepherdRecord, title: String)
        case closed(ShepherdRecord, title: String)
        case escalated(ShepherdRecord, ShepherdEscalation, title: String?)
    }

    public struct Effects {
        /// Nil when the worktree is gone or archived; its records are dropped.
        public var worktreeContext: @MainActor (_ worktreeID: String) -> WorktreeContext?
        public var sessionState: @MainActor (_ sessionID: String, _ worktreeID: String) async -> ShepherdSessionState
        /// Queues `text` on the session. False when it could not be queued.
        public var deliverPrompt: @MainActor (_ sessionID: String, _ worktreeID: String, _ text: String) async -> Bool
        public var rules: @MainActor (_ worktreeID: String) -> ShepherdRules
        public var notify: @MainActor (Event) -> Void
        public var refreshPaneIfCached: @MainActor (_ worktreeID: String) -> Void
        /// Checks the archive-after-merge setting and the owner's state itself.
        public var archiveWorktreeIfAllowed: @MainActor (_ worktreeID: String) async -> Void

        public init(
            worktreeContext: @escaping @MainActor (_ worktreeID: String) -> WorktreeContext?,
            sessionState: @escaping @MainActor (_ sessionID: String, _ worktreeID: String) async -> ShepherdSessionState,
            deliverPrompt: @escaping @MainActor (_ sessionID: String, _ worktreeID: String, _ text: String) async -> Bool,
            rules: @escaping @MainActor (_ worktreeID: String) -> ShepherdRules,
            notify: @escaping @MainActor (Event) -> Void,
            refreshPaneIfCached: @escaping @MainActor (_ worktreeID: String) -> Void,
            archiveWorktreeIfAllowed: @escaping @MainActor (_ worktreeID: String) async -> Void
        ) {
            self.worktreeContext = worktreeContext
            self.sessionState = sessionState
            self.deliverPrompt = deliverPrompt
            self.rules = rules
            self.notify = notify
            self.refreshPaneIfCached = refreshPaneIfCached
            self.archiveWorktreeIfAllowed = archiveWorktreeIfAllowed
        }
    }

    /// Posted when the machine wakes, so every active record is evaluated at
    /// once. Nil leaves wake-ups to the next timer tick.
    public static var wakeNotification: (center: NotificationCenter, name: Notification.Name)?

    @ObservationIgnored public var effects: Effects?
    public private(set) var records: [ShepherdRecordID: ShepherdRecord] = [:]
    /// The latest successful fetch per record, for the toolbar and drawer.
    public private(set) var snapshots: [ShepherdRecordID: ReviewLoopSnapshot] = [:]

    @ObservationIgnored private let store: any PersistenceStoreProtocol
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let providerRegistry: CodeHostProviderRegistry
    @ObservationIgnored private let localProbe: ReviewLoopLocalProbe
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// One headless review loop per record, reused across polls.
    @ObservationIgnored private var loops: [ShepherdRecordID: ReviewLoopState] = [:]
    @ObservationIgnored private var dueAt: [ShepherdRecordID: Date] = [:]
    @ObservationIgnored private var failureCounts: [ShepherdRecordID: Int] = [:]
    @ObservationIgnored private var inFlight: Set<ShepherdRecordID> = []

    public init(
        store: any PersistenceStoreProtocol,
        fileURL: URL = Paths.reviewShepherdsFile,
        providerRegistry: CodeHostProviderRegistry = .live(),
        localProbe: ReviewLoopLocalProbe = .live,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.store = store
        self.fileURL = fileURL
        self.providerRegistry = providerRegistry
        self.localProbe = localProbe
        self.now = now
        load()
    }

    // MARK: - Lifecycle

    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: ShepherdSchedule.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pump()
            }
        }
        timer.tolerance = ShepherdSchedule.tick / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        makeAllDue()
        guard let wake = Self.wakeNotification else { return }
        wakeObserver = wake.center.addObserver(
            forName: wake.name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.makeAllDue()
            }
        }
    }

    /// Stops the clock. Evaluations in flight finish; records are persisted
    /// on every change, so there is nothing to flush.
    public func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver, let wake = Self.wakeNotification {
            wake.center.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - Queries

    /// The session's newest record still being shepherded, else its newest
    /// finished one.
    public func record(forSession sessionID: String) -> ShepherdRecord? {
        Self.preferred(records.values.filter { $0.sessionID == sessionID })
    }

    public func record(forWorktree worktreeID: String) -> ShepherdRecord? {
        Self.preferred(records.values.filter { $0.id.worktreeID == worktreeID })
    }

    private static func preferred(_ candidates: [ShepherdRecord]) -> ShepherdRecord? {
        let newestFirst = candidates.sorted { $0.updatedAt > $1.updatedAt }
        return newestFirst.first { !$0.phase.isTerminal } ?? newestFirst.first
    }

    // MARK: - Binding and controls

    /// Binds `request` to `sessionID`, creating the record or moving an
    /// existing one. The owner starts fresh: phase `watching`, no attempts,
    /// no dispatched fingerprint, so its current problems are dispatched to
    /// it on the next idle poll. A session works on the branch its worktree
    /// has checked out, so it owns at most one live record: its others are
    /// deleted (their requests are untouched). No other session's record moves.
    @discardableResult
    public func bind(
        sessionID: String,
        worktreeID: String,
        request: ReviewRequest,
        baseBranch: String,
        autoFix: Bool,
        autoMerge: Bool,
        sendContext: Bool
    ) async -> ShepherdRecord {
        let id = ShepherdRecordID(worktreeID: worktreeID, request: request)
        let now = self.now()
        for other in records.values where other.id != id && other.sessionID == sessionID && !other.phase.isTerminal {
            remove(other.id)
        }
        var record = records[id].flatMap { $0.phase.isTerminal ? nil : $0 }
            ?? ShepherdRecord(
                id: id,
                sessionID: sessionID,
                remote: request.remote,
                branch: request.headRefName,
                baseBranch: baseBranch,
                autoFix: autoFix,
                autoMerge: autoMerge,
                now: now
            )
        record.sessionID = sessionID
        record.remote = request.remote
        record.branch = request.headRefName
        record.baseBranch = baseBranch
        record.autoFix = autoFix
        record.autoMerge = autoMerge
        record.phase = .watching
        record.fixAttempts = 0
        record.lastDispatchedFingerprint = nil
        record.updatedAt = now
        put(record)
        failureCounts[id] = nil
        dueAt[id] = now
        if sendContext, let effects {
            let prompt = ShepherdPromptBuilder.bindPrompt(
                request: request,
                fix: ShepherdPolicy.problems(in: request),
                rules: effects.rules(worktreeID)
            )
            let delivered = await effects.deliverPrompt(sessionID, worktreeID, prompt)
            if !delivered {
                escalate(id, .deliveryFailed, title: request.title)
            }
        }
        pump()
        return records[id] ?? record
    }

    public func setAutoFix(_ on: Bool, for id: ShepherdRecordID) {
        update(id) { $0.autoFix = on }
    }

    public func setAutoMerge(_ on: Bool, for id: ShepherdRecordID) {
        update(id) { $0.autoMerge = on }
    }

    /// Escalated or paused back to watching with a full attempt budget. The
    /// dispatched fingerprint is cleared too: a no-progress escalation leaves
    /// the same problems as the last prompt, which the policy would otherwise
    /// keep waiting on.
    public func resume(_ id: ShepherdRecordID) {
        guard let record = records[id] else { return }
        switch record.phase {
        case .escalated, .paused:
            break
        default:
            return
        }
        failureCounts[id] = nil
        update(id) {
            $0.phase = .watching
            $0.fixAttempts = 0
            $0.lastDispatchedFingerprint = nil
        }
    }

    /// Deletes the record. The request itself is left alone.
    public func stopShepherding(_ id: ShepherdRecordID) {
        guard records[id] != nil else { return }
        remove(id)
    }

    /// A turn of `sessionID` ended. Any fix it was working on now waits for
    /// the push to show up on the provider, starting with the next poll.
    public func turnCompleted(sessionID: String) {
        let now = self.now()
        for record in records.values where record.sessionID == sessionID {
            guard case .fixing = record.phase else { continue }
            var next = record
            next.phase = .awaitingPush(turnEndedAt: now, pollsWithoutProgress: 0)
            next.updatedAt = now
            put(next)
            dueAt[record.id] = now
        }
        pump()
    }

    // MARK: - Fetching

    /// Fetches, decides and acts for one record now, ignoring its due time
    /// and the concurrency cap. A record already being evaluated is skipped;
    /// that evaluation is just as fresh.
    public func evaluateNow(_ id: ShepherdRecordID) async {
        guard records[id] != nil, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        await evaluate(id)
        inFlight.remove(id)
        pump()
    }

    /// A fresh provider fetch for any worktree, bypassing every throttle.
    /// Nil when the worktree's git state cannot be read.
    public func fetchSnapshot(worktreePath: URL, baseBranch: String) async -> ReviewLoopSnapshot? {
        guard let probed = try? await localProbe.probe(worktreePath, baseBranch) else { return nil }
        let loop = ReviewLoopState(worktreePath: worktreePath, baseBranch: baseBranch, providerRegistry: providerRegistry)
        await loop.refresh(local: probed.local, remotes: probed.remotes)
        return loop.snapshot
    }

    /// Lowercased logins that reviewed the request's current head. Nil when
    /// the provider could not say, which keeps a required-reviewer gate closed.
    public func headReviewers(for snapshot: ReviewLoopSnapshot, worktreePath: URL) async -> Set<String>? {
        guard let remote = snapshot.remote,
              let request = snapshot.reviewRequest,
              let provider = providerRegistry.provider(for: remote.kind)
        else { return nil }
        return try? await provider.reviewersOnHead(remote: remote, request: request, cwd: worktreePath)
    }

    // MARK: - Scheduling

    private func makeAllDue() {
        let now = self.now()
        for record in records.values where !record.phase.isTerminal {
            dueAt[record.id] = now
        }
        pump()
    }

    /// Starts due evaluations, earliest due first, while fewer than
    /// `ShepherdSchedule.maxConcurrentFetches` are in flight.
    private func pump() {
        guard timer != nil, effects != nil else { return }
        let now = self.now()
        let due = records.values
            .filter { !$0.phase.isTerminal && !inFlight.contains($0.id) && (dueAt[$0.id] ?? now) <= now }
            .sorted { (dueAt[$0.id] ?? now) < (dueAt[$1.id] ?? now) }
        for record in due.prefix(max(0, ShepherdSchedule.maxConcurrentFetches - inFlight.count)) {
            let id = record.id
            inFlight.insert(id)
            Task { @MainActor [weak self] in
                await self?.evaluate(id)
                self?.inFlight.remove(id)
                self?.pump()
            }
        }
    }

    private func scheduleNext(_ record: ShepherdRecord, checksPending: Bool) {
        dueAt[record.id] = ShepherdSchedule.interval(for: record, checksPending: checksPending)
            .map { now().addingTimeInterval($0) }
    }

    private func noteFailure(_ id: ShepherdRecordID, _ message: String) {
        let count = (failureCounts[id] ?? 0) + 1
        failureCounts[id] = count
        dueAt[id] = now().addingTimeInterval(ShepherdSchedule.backoff(afterFailures: count))
        shepherdLogger.notice(
            "PR shepherd fetch for \(id.storageKey, privacy: .private) failed (\(count, privacy: .public) in a row): \(message, privacy: .public)"
        )
    }

    // MARK: - Evaluation

    private func evaluate(_ id: ShepherdRecordID) async {
        guard let effects, let record = records[id], !record.phase.isTerminal else { return }
        // A floor, so no early exit below can make the record due again at once.
        dueAt[id] = now().addingTimeInterval(ShepherdSchedule.tick)
        guard let context = effects.worktreeContext(id.worktreeID), context.isEligible else {
            shepherdLogger.notice("Dropping PR shepherd record \(id.storageKey, privacy: .private): its worktree is gone or not eligible")
            remove(id)
            return
        }
        let probed: (local: ReviewLoopLocalState, remotes: [GitRemote])
        do {
            probed = try await localProbe.probe(context.path, record.baseBranch)
        } catch {
            noteFailure(id, String(describing: error))
            return
        }
        let loop = reviewLoop(for: record, path: context.path)
        await loop.refresh(local: probed.local, remotes: probed.remotes)
        guard records[id] != nil else { return }
        guard let snapshot = loop.snapshot else {
            noteFailure(id, "The review loop produced no snapshot.")
            return
        }
        if let message = snapshot.errorMessage {
            noteFailure(id, message)
            return
        }
        guard snapshot.remote != nil else {
            noteFailure(id, "The worktree has no GitHub or GitLab remote.")
            return
        }
        guard snapshot.providerAvailable, snapshot.providerAuthenticated else {
            pauseForAuth(id)
            return
        }
        guard let observed = await snapshotCarryingRequest(id, from: snapshot, worktreePath: context.path) else { return }
        let rules = effects.rules(id.worktreeID)
        let reviewers: Set<String>?
        if rules.requiredReviewers.isEmpty || observed.reviewRequest?.state != .open {
            reviewers = nil
        } else {
            reviewers = await headReviewers(for: observed, worktreePath: context.path)
        }
        guard let owner = records[id]?.sessionID else { return }
        let session = await effects.sessionState(owner, id.worktreeID)
        // Toggles, a rebind or a finished turn may have changed the record
        // while this evaluation waited: decide on the current one, and not at
        // all when it now belongs to another session.
        guard let current = records[id], current.sessionID == owner, !current.phase.isTerminal else { return }
        failureCounts[id] = nil
        snapshots[id] = observed
        let decision = ShepherdPolicy.decide(current, ShepherdObservation(
            snapshot: observed,
            headReviewers: reviewers,
            session: session,
            rules: rules,
            now: now()
        ))
        var next = decision.record
        if next.phase.isTerminal, next.finishedAt == nil {
            next.finishedAt = now()
        }
        if next != current {
            next.updatedAt = now()
            put(next)
        }
        await execute(decision.action, for: id, before: current, snapshot: observed, rules: rules, context: context)
        if let latest = records[id] {
            scheduleNext(latest, checksPending: observed.reviewRequest?.checks.contains { $0.bucket == .pending } ?? false)
        }
        effects.refreshPaneIfCached(id.worktreeID)
    }

    /// The snapshot to decide on, carrying this record's request. The branch
    /// lookup only finds open requests on the worktree's current branch, so
    /// when it returns another request or none, the request is read by
    /// number. Merged or closed there is decided on (the policy finishes the
    /// record). Still open means the worktree moved to another branch or the
    /// request was retargeted: nothing is decided until the branch lookup
    /// finds it again, and a new base is adopted so it can.
    private func snapshotCarryingRequest(
        _ id: ShepherdRecordID,
        from snapshot: ReviewLoopSnapshot,
        worktreePath: URL
    ) async -> ReviewLoopSnapshot? {
        if let request = snapshot.reviewRequest,
           ShepherdRecordID(worktreeID: id.worktreeID, request: request) == id {
            return snapshot
        }
        guard let record = records[id], let provider = providerRegistry.provider(for: id.providerKind) else { return nil }
        let request: ReviewRequest
        do {
            request = try await provider.reviewRequest(remote: record.remote, number: id.requestNumber, cwd: worktreePath)
        } catch {
            noteFailure(id, String(describing: error))
            return nil
        }
        guard request.state == .open else {
            return ReviewLoopSnapshot(
                local: snapshot.local,
                remote: snapshot.remote,
                reviewRequest: request,
                providerAvailable: true,
                providerAuthenticated: true,
                providerCapabilities: snapshot.providerCapabilities,
                errorMessage: nil
            )
        }
        guard var current = records[id] else { return nil }
        failureCounts[id] = nil
        if request.baseRefName != current.baseBranch {
            current.baseBranch = request.baseRefName
            current.updatedAt = now()
            put(current)
            dueAt[id] = now()
        } else {
            scheduleNext(current, checksPending: false)
        }
        return nil
    }

    private func execute(
        _ action: ShepherdAction,
        for id: ShepherdRecordID,
        before: ShepherdRecord,
        snapshot: ReviewLoopSnapshot,
        rules: ShepherdRules,
        context: WorktreeContext
    ) async {
        guard let effects, let record = records[id], let request = snapshot.reviewRequest else { return }
        switch action {
        case .wait:
            return
        case .dispatchFix(let fix):
            let logs = await checkLogs(for: fix, request: request, remote: record.remote, worktreePath: context.path)
            let prompt = ShepherdPromptBuilder.fixPrompt(request: request, fix: fix, logs: logs, rules: rules)
            let delivered = await effects.deliverPrompt(record.sessionID, id.worktreeID, prompt)
            guard !delivered, var failed = records[id] else { return }
            // The prompt never reached the session, so it is not an attempt:
            // after Resume the same problems are dispatched again.
            failed.fixAttempts = before.fixAttempts
            failed.lastDispatchedFingerprint = before.lastDispatchedFingerprint
            put(failed)
            escalate(id, .deliveryFailed, title: request.title)
        case .merge:
            let outcome = await merge(id, snapshot: snapshot, worktreePath: context.path)
            guard let latest = records[id] else { return }
            var next = ShepherdPolicy.applyMergeOutcome(outcome, to: latest, now: now())
            if next.phase.isTerminal, next.finishedAt == nil {
                next.finishedAt = now()
            }
            next.updatedAt = now()
            put(next)
            switch next.phase {
            case .merged:
                effects.notify(.merged(next, title: request.title))
                loops[id] = nil
                await effects.archiveWorktreeIfAllowed(id.worktreeID)
            case .queued:
                effects.notify(.queued(next, title: request.title))
            default:
                let reason = loops[id]?.lastError ?? "the merge gate closed before merging"
                shepherdLogger.notice("PR shepherd did not merge \(id.storageKey, privacy: .private): \(reason, privacy: .public)")
            }
        case .notifyReady:
            effects.notify(.ready(record, title: request.title))
        case .finish(let outcome):
            loops[id] = nil
            switch outcome {
            case .merged:
                effects.notify(.merged(record, title: request.title))
                await effects.archiveWorktreeIfAllowed(id.worktreeID)
            case .closed:
                effects.notify(.closed(record, title: request.title))
            }
        case .escalate(let reason):
            effects.notify(.escalated(record, reason, title: request.title))
        }
    }

    /// Reads git again right before merging, as `RightPaneState.performMerge`
    /// does, so a commit or edit made since the probe can't slip through.
    /// `ReviewLoopState.merge` then re-reads the provider and re-runs the gate.
    private func merge(_ id: ShepherdRecordID, snapshot: ReviewLoopSnapshot, worktreePath: URL) async -> ReviewMergeOutcome? {
        guard let loop = loops[id], let reviewedHead = snapshot.reviewRequest?.headSHA else { return nil }
        guard let fresh = try? await localProbe.probe(worktreePath, snapshot.local.baseBranch),
              fresh.local.branchName == snapshot.local.branchName,
              fresh.local.headSHA == reviewedHead,
              !fresh.local.hasWorkingTreeChanges,
              !fresh.local.hasStagedChanges,
              !fresh.local.needsPush
        else { return nil }
        return await loop.merge(snapshot: snapshot)
    }

    /// Logs for at most `ShepherdPromptBuilder.maxCheckLogs` failing checks.
    /// A check whose log can't be read is left to the prompt's list of names.
    private func checkLogs(
        for fix: ShepherdFixRequest,
        request: ReviewRequest,
        remote: CodeHostRemote,
        worktreePath: URL
    ) async -> [ShepherdCheckLog] {
        guard !fix.failingChecks.isEmpty,
              let provider = providerRegistry.provider(for: remote.kind),
              let items = try? await provider.failedCheckEvidence(remote: remote, request: request, cwd: worktreePath)
        else { return [] }
        var logs: [ShepherdCheckLog] = []
        for check in fix.failingChecks.prefix(ShepherdPromptBuilder.maxCheckLogs) {
            // CI evidence items carry their check's id.
            guard let item = items.first(where: { $0.id == check.id }),
                  let detail = try? await provider.checkEvidenceDetail(
                      remote: remote, request: request, item: item, cwd: worktreePath
                  )
            else { continue }
            logs.append(ShepherdCheckLog(
                checkID: check.id,
                body: detail.body,
                isTruncated: detail.isTruncated,
                url: check.detailURL ?? item.providerURL
            ))
        }
        return logs
    }

    // MARK: - Transitions outside the policy

    private func escalate(_ id: ShepherdRecordID, _ reason: ShepherdEscalation, title: String?) {
        guard var record = records[id] else { return }
        record.phase = .escalated(reason)
        record.updatedAt = now()
        put(record)
        effects?.notify(.escalated(record, reason, title: title))
    }

    /// The provider CLI is missing or signed out. Pauses once, with one
    /// escalation; the policy resumes the record on the next good fetch. An
    /// escalated record keeps waiting for Resume instead.
    private func pauseForAuth(_ id: ShepherdRecordID) {
        guard var record = records[id] else { return }
        failureCounts[id] = nil
        if case .escalated = record.phase {
            scheduleNext(record, checksPending: false)
            return
        }
        if record.phase != .paused {
            record.phase = .paused
            record.updatedAt = now()
            put(record)
            effects?.notify(.escalated(record, .authFailed, title: snapshots[id]?.reviewRequest?.title))
        }
        scheduleNext(record, checksPending: false)
    }

    private func update(_ id: ShepherdRecordID, _ change: (inout ShepherdRecord) -> Void) {
        guard var record = records[id], !record.phase.isTerminal else { return }
        change(&record)
        guard record != records[id] else { return }
        record.updatedAt = now()
        put(record)
        dueAt[id] = now()
        pump()
    }

    // MARK: - Storage

    private func reviewLoop(for record: ShepherdRecord, path: URL) -> ReviewLoopState {
        if let loop = loops[record.id], loop.currentBaseBranch == record.baseBranch {
            return loop
        }
        let loop = ReviewLoopState(worktreePath: path, baseBranch: record.baseBranch, providerRegistry: providerRegistry)
        loops[record.id] = loop
        return loop
    }

    private func put(_ record: ShepherdRecord) {
        records[record.id] = record
        persist()
    }

    private func remove(_ id: ShepherdRecordID) {
        records[id] = nil
        snapshots[id] = nil
        loops[id] = nil
        dueAt[id] = nil
        failureCounts[id] = nil
        persist()
    }

    private func load() {
        do {
            let result = try store.readIfExistsReportingRecovery(ReviewShepherdsFile.self, from: fileURL)
            if let recoveryError = result.recoveryError {
                // The store has already moved the unreadable file aside
                // (`review-shepherds.json.broken-<time>`) so it can be inspected.
                shepherdLogger.error(
                    "PR shepherd records were unreadable and were set aside: \(String(describing: recoveryError), privacy: .public)"
                )
            }
            guard let file = result.value else { return }
            let kept = ShepherdRecordRetention.prune(file.records, now: now())
            records = Dictionary(kept.map { ($0.id, $0) }) { lhs, rhs in lhs.updatedAt >= rhs.updatedAt ? lhs : rhs }
            if kept.count != file.records.count {
                persist()
            }
        } catch {
            shepherdLogger.error("Could not read PR shepherd records: \(String(describing: error), privacy: .public)")
        }
    }

    private func persist() {
        let file = ReviewShepherdsFile(records: records.values.sorted { $0.createdAt < $1.createdAt })
        do {
            try store.write(file, to: fileURL)
        } catch {
            shepherdLogger.error("Could not save PR shepherd records: \(String(describing: error), privacy: .public)")
        }
    }
}
```

- [ ] **Step 5: Run the test and build the package**

Run: `swift test --package-path Packages/AlasCore --filter ShepherdRecordRetentionTests`
Expected: `Test run with 1 test in 1 suite passed` (the test reports 5 argument cases).

Run: `swift test --package-path Packages/AlasCore`
Expected: every AlasCore suite passes (this also compiles `ReviewShepherd.swift` and `ReviewLoopLocalProbe.swift` under Swift 6 strict concurrency).

- [ ] **Step 6: Commit**

```bash
git add Packages/AlasCore/Sources/AlasCore/Shepherd/ReviewLoopLocalProbe.swift \
        Packages/AlasCore/Sources/AlasCore/Shepherd/ReviewShepherd.swift \
        Packages/AlasCore/Tests/AlasCoreTests/Shepherd/ShepherdRecordRetentionTests.swift
git commit -m "feat(shepherd): add the review shepherd service"
```

### Task 9: Caption PR shepherd prompts in the transcript

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasCore/ACP/Orchestration/ACPDelegatedPromptSource.swift:6-11` (doc comment), `:34-36` (insert after), `:78-89` (label)
- Test: `AlasTests/ACP/Orchestration/ACPDelegatedOutcomeTextTests.swift:154-169` (extend `persistedSourceDecodes`, the existing parameterized label test for `ACPDelegatedPromptSource`)
- Read only (verified, no change needed):
  - `Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift:209-279`: `DelegatedPromptRow` renders `label` at 11 pt in `fg-faint` beside an icon, above an incoming slate bubble that folds long prompts. `isFromChild` only picks the icon: `arrow.turn.down.left` for a child's report, `arrow.turn.down.right` for everything else. Shepherd sources are not from a child, so they get `arrow.turn.down.right`.
  - `Alas/Sources/ACP/UI/ACPTranscriptRowContent.swift:219-227` passes `delegatedLabel ?? ACPDelegatedPromptSource.transcriptLabel(...)`, and `Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift:779-780` computes `delegatedLabel` with `transcriptLabel` too, so the label change covers both paths.
  - Delegated sources already keep shepherd prompts out of branch auto-naming and local titles (`ACPSessionRunner.swift:3916, 4410-4421`), next-prompt suggestions (`:4645`), the visible queue (`QueuedPrompt.swift:80-82`), and child-report batching (`ACPSessionManager.swift:8740`).

**Interfaces:**
- Consumes: nothing new.
- Produces (on `ACPDelegatedPromptSource`):
  - `public static let shepherdRelationship = "alas-shepherd"`
  - `public var isFromShepherd: Bool`
  - `public static func shepherd(recordKey: String, messageID: UUID) -> ACPDelegatedPromptSource` (`sessionId` `"shepherd:\(recordKey)"`, `messageId` `messageID.uuidString`, `senderRelationship` `shepherdRelationship`)
  - `transcriptLabel(for:agentDisplayName:)` returns `"Alas PR shepherd"` for shepherd sources.

- [ ] **Step 1: Add the failing label case**

In `AlasTests/ACP/Orchestration/ACPDelegatedOutcomeTextTests.swift`, add one argument row to `persistedSourceDecodes`. Insert after line 163 (`"Alas · child parent"),`), before the closing `])` on line 164:

```swift
        // A PR shepherd prompt, as stored in a transcript, is Alas's own.
        (#"{"sessionId":"parent","messageId":"m1","senderRelationship":"alas-shepherd"}"#,
         "Alas PR shepherd"),
```

This pins the persisted relationship string that reloaded transcripts carry. The factory is a one-line constructor and gets no test of its own.

- [ ] **Step 2: Run the test to see it fail**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/ACPDelegatedOutcomeTextTests test > /tmp/alas-test.log 2>&1; grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log`
Expected: `** TEST FAILED **`, with a `✘` line for `persistedSourceDecodes` showing `"Delegated prompt" == "Alas PR shepherd"`.

- [ ] **Step 3: Add the shepherd source and its label**

In `Packages/AlasCore/Sources/AlasCore/ACP/Orchestration/ACPDelegatedPromptSource.swift`, replace the doc comment on lines 6-10 (keep line 11, `public var senderRelationship: String? = nil`) with:

```swift
    /// How the sender relates to the session the prompt was delivered to.
    /// `"child"` when a delegated child wrote to its parent, `"alas-shepherd"`
    /// for a prompt from Alas's PR shepherd; nil for a parent→child prompt, a
    /// mission prompt, and every source persisted before this field existed.
    /// A plain string so an unknown future value still decodes (and falls
    /// back to the generic label).
```

Insert after line 36 (`public var isFromChild: Bool { senderRelationship == Self.childRelationship }`):

```swift

    public static let shepherdRelationship = "alas-shepherd"

    /// Queued by Alas's PR shepherd rather than by another session.
    public var isFromShepherd: Bool { senderRelationship == Self.shepherdRelationship }

    /// A prompt the PR shepherd queues for the session that owns a pull or
    /// merge request. `recordKey` (the shepherd record's storage key) names
    /// the sender; every prompt gets its own `messageID`, so two prompts are
    /// never deduplicated as one delivery.
    public static func shepherd(recordKey: String, messageID: UUID) -> ACPDelegatedPromptSource {
        ACPDelegatedPromptSource(
            sessionId: "shepherd:\(recordKey)",
            messageId: messageID.uuidString,
            senderRelationship: shepherdRelationship
        )
    }
```

Replace lines 78-80 (the `transcriptLabel` doc comment) with:

```swift
    /// The caption above a delivered prompt in the receiving transcript:
    /// a child's own report, Alas's notice about a child, a PR shepherd
    /// prompt, or a generic delegated prompt.
```

In `transcriptLabel(for:agentDisplayName:)`, insert immediately before `guard source.isFromChild else { return "Delegated prompt" }` (line 89 before the edits above):

```swift
        if source.isFromShepherd { return "Alas PR shepherd" }
```

- [ ] **Step 4: Run the test to see it pass**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/ACPDelegatedOutcomeTextTests test > /tmp/alas-test.log 2>&1; grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log`
Expected: `◇ Suite "ACP delegated outcome text" started`, a `Test run with ... tests in 1 suite passed` line, and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore/Sources/AlasCore/ACP/Orchestration/ACPDelegatedPromptSource.swift \
        AlasTests/ACP/Orchestration/ACPDelegatedOutcomeTextTests.swift
git commit -m "feat(acp): caption PR shepherd prompts in the transcript"
```

### Task 10: Run the review shepherd from the app

**Files:**
- Create: `Alas/Sources/App/AppState+Shepherd.swift`
- Modify: `Packages/AlasCore/Sources/AlasCore/Core/AlasCoreContext.swift:23-24` (property), `:88` (init parameter), `:97` (assignment)
- Modify: `Alas/Sources/App/AppState.swift:1733` (install effects), `:1737` (stop at termination), `:13170-13175` (turn completion fan-out)
- Modify: `Alas/Sources/App/RootView.swift:163-165` (start after topology load)
- Modify: `Alas/Sources/App/PlatformServices.swift:32` (wake notification)
- Modify: `Alas.xcodeproj/project.pbxproj` (regenerated by `xcodegen` for the new app file)
- Read only (patterns used, verified):
  - `Alas/Sources/App/AppState+RunSchedules.swift:9-22` (install and start pattern)
  - `Packages/AlasCore/Sources/AlasCore/ACP/Orchestration/ACPSessionOrchestrationCoordinator.swift:1403-1431` (`resolveDeliveryTarget`: row, archived check, `placeholderSession`, `hydrateIfNeeded`) and `:1171-1187` (queue before attach)
  - `Packages/AlasCore/Sources/AlasCore/ACP/Session/ACPSessionManager.swift:8148-8165` (`reattach(to:)` is a no-op for `.spawning`/`.ready`, attaches for `.idle`/`.disconnected`/`.failed`), `:8699-8781` (`enqueueDelegatedPrompt`), `:512-531` (`sendPrompt` needs this instance's writer lease), `:2651-2663` (`persistedSessionRow`), `:3223-3226` (archive updates the cached row)
  - `Packages/AlasCore/Sources/AlasCore/ACP/Session/ACPSession.swift:538-544` (`AgentState`: `idle`, `spawning`, `ready`, `disconnected`, `failed(String)`), `:677` (`StreamingState`)
  - `Alas/Sources/App/AppState.swift:7699-7725` (`cliNotify`: `notifyAlas` + `setExternalActivity(.awaitingInput, requiresUserInput: true)`), `:6725-6751` (`archiveWorktree`, which prompts for dirty editor buffers), `:5358-5400` (`launchWorktreeSurface`), `:5513-5536` (`defaultAgentID`), `:11437-11466` (Workspace checkout membership by path)
  - `Alas/Sources/Plugins/AppState+Plugins.swift:247-301` (prepared prompt launch and post-launch check)
  - `Alas/Sources/Right/RightPaneStore.swift:351-354` (`refresh(worktreeId:forceReviewLoopRemote:)`, no-op when not cached), `:498-500` (`activeState(worktreeId:)`)

**Interfaces:**
- Consumes:
  - Task 8: `ReviewShepherd` (all of it), `ReviewShepherd.WorktreeContext`, `ReviewShepherd.Event`, `ReviewShepherd.Effects`.
  - Task 9: `ACPDelegatedPromptSource.shepherd(recordKey:messageID:)`.
  - Shepherd core: `ShepherdRecordID(worktreeID:request:)`, `ShepherdRecord.owner`, `ShepherdSessionState`, `ShepherdEscalation`, `ShepherdRules.none`, `ShepherdRulesResolver.load(worktreePath:projectSettings:)`, `ShepherdPolicy.problems(in:)`, `ShepherdPolicy.maxFixAttempts`, `ShepherdPromptBuilder.bindPrompt(request:fix:rules:)`, `ShepherdPromptBuilder.createPrompt(kind:)`.
  - Settings tasks: `AppConfig.Changes.shepherd: ShepherdDefaults` (`autoFix`, `autoMerge`, `archiveAfterMerge`) and `ProjectConfig.shepherd: ProjectShepherdSettings?`.
- Produces (internal, `extension AppState` in `AppState+Shepherd.swift`):
  - `var reviewShepherd: ReviewShepherd`
  - `func installReviewShepherdEffects()`
  - `func startReviewShepherd()`
  - `func deliverShepherdPrompt(sessionID: String, worktreeID: String, text: String) async -> Bool`
  - `func shepherdSessionState(sessionID: String, worktreeID: String) async -> ShepherdSessionState`
  - `func requestShepherdCreatePR(sessionID: String, worktree: Worktree)`
  - `func shepherdWithSession(_ sessionID: String, worktree: Worktree, request: ReviewRequest) async`
  - `func shepherdWithNewSession(worktree: Worktree, request: ReviewRequest) async`
  - `func shepherdSessionCandidates(worktree: Worktree) -> [ACPSessionRow]`
  - `func shepherdBaseBranch(for worktree: Worktree) -> String`
  - `func isShepherdEligible(_ worktree: Worktree) -> Bool`
  - `func shepherdRules(worktreeID: String) -> ShepherdRules`
  - `AlasCoreContext.reviewShepherd: ReviewShepherd` (public, AlasCore)
- Not here: `cliPRCreate` and `cliPRStatus` (contract) are added to `AppState+Shepherd.swift` by the MCP task.

**Decisions:**
- Delivery is `enqueueDelegatedPrompt` + `reattach(to:)` (see Contract note 7), so the prompt shows the "Alas PR shepherd" caption and reaches sessions with no open tab.
- Busy: the transcript is not idle (running, or waiting on permission or input), the agent is spawning, or a ready agent has a queued prompt (no error, not scheduled for later) that has not started. A prompt held behind a failed, disconnected or unattached agent is not busy. An unloaded session uses the stored `directTurnInFlight`.
- Notifications: every event posts `notifyAlas`. Escalations also flag the owning session with `setExternalActivity(.awaitingInput, requiresUserInput: true)`, like MCP `notify` at attention level; owner-gone escalations append an attention history event instead (Contract note 9).
- Auto-archive (Settings default off) uses `archiveWorktree`. It is skipped for the main worktree, for an already hidden worktree, while the owning session is busy (the shepherd does not retry; an in-app message says why), and while an editor has unsaved changes, because `archiveWorktree` would open a modal prompt.
- "New session" launches the project's default ACP agent with the bind prompt as its first message, through `PreparedWorktreeACPPrompt` and `launchWorktreeSurface`, then binds with `sendContext: false`. The first message also gives the session its title.
- A rebind keeps the existing record's toggles; a new binding takes the Settings defaults.

- [ ] **Step 1: Let `AlasCoreContext` own the shepherd**

In `Packages/AlasCore/Sources/AlasCore/Core/AlasCoreContext.swift`, insert after line 24 (`public let runScheduler: RunScheduler`):

```swift
    /// Watches bound pull and merge requests; AppState installs its effects.
    public let reviewShepherd: ReviewShepherd
```

Insert after line 88 (`runScheduler: RunScheduler? = nil,`):

```swift
        reviewShepherd: ReviewShepherd? = nil,
```

Insert after line 97 (`self.runScheduler = runScheduler ?? RunScheduler(store: store)`):

```swift
        self.reviewShepherd = reviewShepherd ?? ReviewShepherd(store: store)
```

- [ ] **Step 2: Add the AppState wiring**

Create `Alas/Sources/App/AppState+Shepherd.swift`:

```swift
import Foundation

extension AppState {
    /// Watches bound pull and merge requests. It decides when and what; the
    /// effects installed here reach sessions, notifications and panes.
    var reviewShepherd: ReviewShepherd { core.reviewShepherd }

    // MARK: - Wiring

    func installReviewShepherdEffects() {
        reviewShepherd.effects = ReviewShepherd.Effects(
            worktreeContext: { [weak self] worktreeID in
                self?.shepherdWorktreeContext(worktreeID)
            },
            sessionState: { [weak self] sessionID, worktreeID in
                await self?.shepherdSessionState(sessionID: sessionID, worktreeID: worktreeID) ?? .missing
            },
            deliverPrompt: { [weak self] sessionID, worktreeID, text in
                await self?.deliverShepherdPrompt(sessionID: sessionID, worktreeID: worktreeID, text: text) ?? false
            },
            rules: { [weak self] worktreeID in
                self?.shepherdRules(worktreeID: worktreeID) ?? ShepherdRules.none
            },
            notify: { [weak self] event in
                self?.notifyShepherdEvent(event)
            },
            refreshPaneIfCached: { [weak self] worktreeID in
                guard let self else { return }
                Task { await self.rightPaneStore.refresh(worktreeId: worktreeID, forceReviewLoopRemote: true) }
            },
            archiveWorktreeIfAllowed: { [weak self] worktreeID in
                await self?.archiveShepherdWorktreeIfAllowed(worktreeID)
            }
        )
    }

    /// Called once the worktree topology is loaded, because records resolve
    /// their worktrees against it.
    func startReviewShepherd() {
        reviewShepherd.start()
    }

    // MARK: - Eligibility, rules and base

    /// Local git worktrees outside Workspace checkouts. Remote (SSH)
    /// projects, folders and checkout members are out of scope for v1.
    func isShepherdEligible(_ worktree: Worktree) -> Bool {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else { return false }
        return project.host == nil && !project.isFolder && !isWorkspaceCheckoutMember(worktree)
    }

    func shepherdRules(worktreeID: String) -> ShepherdRules {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeID) else { return ShepherdRules.none }
        return ShepherdRulesResolver.load(
            worktreePath: resolved.worktree.path,
            projectSettings: resolved.project.shepherd
        )
    }

    /// The base the Changes pane reviews against: its per-worktree override
    /// when the pane is cached, else the global default.
    func shepherdBaseBranch(for worktree: Worktree) -> String {
        rightPaneStore.activeState(worktreeId: worktree.id)?.reviewLoop.currentBaseBranch
            ?? config.worktrees.baseBranch
    }

    // MARK: - Sessions

    /// Sessions that can own a request in this worktree: not archived, most
    /// recently active first (the sessions popover sorts by last opened).
    /// Reads the manager's recent rows; a menu calls `refreshRecent()` on the
    /// manager as it opens, as `ACPSessionsButton` does.
    func shepherdSessionCandidates(worktree: Worktree) -> [ACPSessionRow] {
        guard let manager = acpManager(for: worktree) else { return [] }
        return manager.sessionRows
            .filter { !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Queues `text` on the session as a shepherd prompt, captioned "Alas PR
    /// shepherd". Hydrates a session with no open tab, like the orchestration
    /// coordinator's delivery, then brings its agent up the way the composer
    /// does, so the prompt runs after any turn in progress. False when the
    /// session is missing or archived, or the queue could not be saved.
    func deliverShepherdPrompt(sessionID: String, worktreeID: String, text: String) async -> Bool {
        guard let worktree = worktree(withId: worktreeID),
              let manager = acpManager(for: worktree),
              let row = await manager.persistedSessionRow(id: sessionID),
              !row.archived,
              manager.placeholderSession(id: sessionID) != nil
        else { return false }
        await manager.hydrateIfNeeded(id: sessionID)
        guard manager.liveSession(for: sessionID)?.hydrationState == .ready else { return false }
        let recordKey = reviewShepherd.record(forSession: sessionID)?.id.storageKey ?? worktreeID
        let source = ACPDelegatedPromptSource.shepherd(recordKey: recordKey, messageID: UUID())
        guard await manager.enqueueDelegatedPrompt(text: text, source: source, into: sessionID) else { return false }
        // Attaches an idle, disconnected or failed agent; a no-op while it is
        // spawning or ready, where the enqueue already flushed the queue.
        await manager.reattach(to: sessionID)
        return true
    }

    func shepherdSessionState(sessionID: String, worktreeID: String) async -> ShepherdSessionState {
        guard let worktree = worktree(withId: worktreeID),
              let manager = acpManager(for: worktree),
              let row = await manager.persistedSessionRow(id: sessionID)
        else { return .missing }
        if row.archived { return .archived }
        if let session = manager.liveSession(for: sessionID) {
            return Self.shepherdSessionIsBusy(session, now: Date()) ? .busy : .idle
        }
        return row.directTurnInFlight ? .busy : .idle
    }

    /// The popover's Create PR/MR button: asks the session, as a normal user
    /// turn, to commit what belongs to the work and call `pr_create`.
    func requestShepherdCreatePR(sessionID: String, worktree: Worktree) {
        guard let manager = acpManager(for: worktree) else { return }
        Task { @MainActor [weak self] in
            let remotes = (try? await GitService().remotes(worktreePath: worktree.path)) ?? []
            guard let kind = CodeHostRemoteDetector.detect(from: remotes)?.kind else {
                self?.inAppNotifications.post(
                    "No GitHub or GitLab remote for \(worktree.branch).",
                    severity: .error,
                    worktreeID: worktree.id
                )
                return
            }
            await manager.sendPrompt(
                for: sessionID,
                text: ShepherdPromptBuilder.createPrompt(kind: kind),
                attachments: []
            ) { [weak self] sent in
                guard !sent else { return }
                self?.inAppNotifications.post(
                    "Could not send the Create \(kind.reviewRequestLabel) prompt to this session.",
                    severity: .error,
                    worktreeID: worktree.id
                )
            }
        }
    }

    /// Binds `request` to an existing session and sends it the context
    /// prompt. A rebind keeps the record's toggles; a new binding starts from
    /// the Settings defaults.
    func shepherdWithSession(_ sessionID: String, worktree: Worktree, request: ReviewRequest) async {
        let toggles = shepherdToggles(worktree: worktree, request: request)
        await reviewShepherd.bind(
            sessionID: sessionID,
            worktreeID: worktree.id,
            request: request,
            baseBranch: request.baseRefName,
            autoFix: toggles.autoFix,
            autoMerge: toggles.autoMerge,
            sendContext: true
        )
    }

    /// "New session" in the Changes drawer: launches the project's default
    /// chat agent with the context prompt as its first message (which also
    /// titles the session), then binds the request to that session.
    func shepherdWithNewSession(worktree: Worktree, request: ReviewRequest) async {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else { return }
        guard let agentID = defaultAgentID(projectId: project.id, worktreeRoot: worktree.path),
              ACPLaunchCatalog.spec(for: agentID) != nil
        else {
            inAppNotifications.post(
                "No chat agent is set up for \(project.name).",
                severity: .error,
                worktreeID: worktree.id
            )
            return
        }
        let prompt = ShepherdPromptBuilder.bindPrompt(
            request: request,
            fix: ShepherdPolicy.problems(in: request),
            rules: shepherdRules(worktreeID: worktree.id)
        )
        let prepared = PreparedWorktreeACPPrompt(sessionID: UUID().uuidString, promptID: UUID(), text: prompt)
        do {
            try await launchWorktreeSurface(
                .acp(agentId: agentID, preparedPrompt: prepared),
                worktree: worktree,
                project: project
            )
        } catch {
            inAppNotifications.post(
                "Could not start \(agentID): \(error.localizedDescription)",
                severity: .error,
                worktreeID: worktree.id
            )
            return
        }
        // The launch returns normally when the session could not be opened,
        // so check what it left behind, as plugin tasks do.
        guard acpManager(for: worktree)?.liveSession(for: prepared.sessionID) != nil else {
            inAppNotifications.post(
                "Could not open a chat session for \(agentID) in \(worktree.branch).",
                severity: .error,
                worktreeID: worktree.id
            )
            return
        }
        let toggles = shepherdToggles(worktree: worktree, request: request)
        await reviewShepherd.bind(
            sessionID: prepared.sessionID,
            worktreeID: worktree.id,
            request: request,
            baseBranch: request.baseRefName,
            autoFix: toggles.autoFix,
            autoMerge: toggles.autoMerge,
            sendContext: false
        )
    }

    // MARK: - Effects

    private func shepherdToggles(worktree: Worktree, request: ReviewRequest) -> (autoFix: Bool, autoMerge: Bool) {
        let id = ShepherdRecordID(worktreeID: worktree.id, request: request)
        if let record = reviewShepherd.records[id], !record.phase.isTerminal {
            return (record.autoFix, record.autoMerge)
        }
        let defaults = config.changes.shepherd
        return (defaults.autoFix, defaults.autoMerge)
    }

    private func shepherdWorktreeContext(_ worktreeID: String) -> ReviewShepherd.WorktreeContext? {
        guard let resolved = projectAndWorktree(withWorktreeId: worktreeID),
              !projectsManager.isWorktreeHidden(projectId: resolved.project.id, path: resolved.worktree.path)
        else { return nil }
        return ReviewShepherd.WorktreeContext(
            worktreeID: resolved.worktree.id,
            projectID: resolved.project.id,
            path: resolved.worktree.path,
            baseBranch: shepherdBaseBranch(for: resolved.worktree),
            isEligible: isShepherdEligible(resolved.worktree)
        )
    }

    /// Same membership test the worktree cleanup scanner uses: a checkout
    /// lists a member of this project at this path.
    private func isWorkspaceCheckoutMember(_ worktree: Worktree) -> Bool {
        let path = worktree.path.standardizedFileURL.path
        return workspacesManager.checkouts.contains { checkout in
            checkout.members.contains { member in
                member.projectID == worktree.projectId
                    && URL(fileURLWithPath: checkout.inAppWorktreePath(member.worktreePath)).standardizedFileURL.path == path
            }
        }
    }

    /// Busy while a turn runs or waits on the user, while the agent starts,
    /// or while a ready agent has a queued prompt (a shepherd prompt
    /// included) that has not started. A prompt held behind an agent that
    /// failed, disconnected or never attached is not busy, so a stuck fix
    /// ends in a no-progress escalation instead of waiting forever.
    private static func shepherdSessionIsBusy(_ session: ACPSession, now: Date) -> Bool {
        if session.transcript.streamingState != .idle { return true }
        switch session.agentState {
        case .spawning:
            return true
        case .ready:
            return session.queue.contains { $0.lastError == nil && ($0.scheduledAt ?? .distantPast) <= now }
        case .idle, .disconnected, .failed:
            return false
        }
    }

    private func notifyShepherdEvent(_ event: ReviewShepherd.Event) {
        let message = Self.shepherdNotification(for: event)
        let record = message.record
        guard let resolved = projectAndWorktree(withWorktreeId: record.id.worktreeID) else { return }
        let agent = shepherdAgentKind(sessionID: record.sessionID, worktreeID: record.id.worktreeID)
        harness.notifications.notifyAlas(
            body: message.body,
            title: message.title,
            agent: agent,
            projectId: resolved.project.id,
            worktreeId: resolved.worktree.id,
            sessionId: record.sessionID,
            owner: record.owner
        )
        guard let escalation = message.escalation else { return }
        if escalation == .ownerGone {
            // No session left to flag: keep it in the worktree's attention history.
            guard let context = attentionContext(for: resolved.worktree) else { return }
            attentionStore.appendHistory(AttentionHistoryEvent(
                sourceKey: AttentionSourceKey(rawValue: "shepherd:\(record.id.storageKey):owner-gone"),
                fingerprint: "\(record.id.storageKey)|owner-gone|\(record.sessionID)",
                owner: context.owner,
                kind: .actionableFeedback,
                title: message.title,
                body: message.body,
                jumpTarget: .reviewRequest(number: record.id.requestNumber),
                display: context.display
            ))
        } else {
            // Same as MCP `notify` at attention level.
            harness.setExternalActivity(
                sessionId: record.sessionID,
                owner: record.owner,
                agent: agent,
                state: .awaitingInput,
                body: message.body,
                requiresUserInput: true
            )
        }
    }

    private func shepherdAgentKind(sessionID: String, worktreeID: String) -> AgentKind {
        let manager = acpManager(forWorktreeId: worktreeID)
        let agentID = manager?.liveSession(for: sessionID)?.agentId
            ?? manager?.cachedPersistedSessionRow(id: sessionID)?.agentId
        return agentID.map { ACPHarnessBridge.agentKind(for: $0) } ?? .codex
    }

    private static func shepherdNotification(
        for event: ReviewShepherd.Event
    ) -> (record: ShepherdRecord, escalation: ShepherdEscalation?, title: String, body: String) {
        switch event {
        case .ready(let record, let title):
            return (record, nil, "Ready to merge", "\(shepherdReference(record)) \"\(title)\" passes every check and can be merged.")
        case .merged(let record, let title):
            return (record, nil, "Merged", "\(shepherdReference(record)) \"\(title)\" was merged.")
        case .queued(let record, let title):
            return (record, nil, "Added to merge queue", "\(shepherdReference(record)) \"\(title)\" is in the merge queue.")
        case .closed(let record, let title):
            return (record, nil, "Closed", "\(shepherdReference(record)) \"\(title)\" was closed without merging.")
        case .escalated(let record, let reason, let title):
            let subject = title.map { "\(shepherdReference(record)) \"\($0)\"" } ?? shepherdReference(record)
            let cli = record.id.providerKind == .github ? "gh" : "glab"
            let detail: String = switch reason {
            case .attemptsExhausted: "still has problems after \(ShepherdPolicy.maxFixAttempts) fix attempts."
            case .noProgress: "has not moved since the last fix prompt."
            case .deliveryFailed: "could not reach its chat session."
            case .ownerGone: "lost its chat session. Pick another one in Changes."
            case .authFailed: "can't be checked: \(cli) is missing or signed out. Run \(cli) auth login."
            }
            return (record, reason, "PR shepherd needs you", "\(subject) \(detail)")
        }
    }

    private static func shepherdReference(_ record: ShepherdRecord) -> String {
        let kind = record.id.providerKind
        return "\(kind.displayName) \(kind.reviewRequestNumberPrefix)\(record.id.requestNumber)"
    }

    /// Settings > Changes > "Archive worktree after its PR merges": the
    /// normal archive path, which hides the worktree and stops its tabs
    /// without touching disk.
    private func archiveShepherdWorktreeIfAllowed(_ worktreeID: String) async {
        guard config.changes.shepherd.archiveAfterMerge,
              let resolved = projectAndWorktree(withWorktreeId: worktreeID),
              resolved.worktree.isMainWorktree != true,
              !projectsManager.isWorktreeHidden(projectId: resolved.project.id, path: resolved.worktree.path)
        else { return }
        let worktree = resolved.worktree
        if let record = reviewShepherd.record(forWorktree: worktreeID),
           await shepherdSessionState(sessionID: record.sessionID, worktreeID: worktreeID) == .busy {
            inAppNotifications.post(
                "Kept \(worktree.branch): its chat session is still working.",
                severity: .information,
                worktreeID: worktreeID
            )
            return
        }
        // `archiveWorktree` would ask about unsaved edits in a modal prompt.
        guard tabs.tabIdsWithUnsavedChanges(forWorktree: worktreeID).isEmpty else {
            inAppNotifications.post(
                "Kept \(worktree.branch): it has unsaved editor changes.",
                severity: .information,
                worktreeID: worktreeID
            )
            return
        }
        archiveWorktree(worktree)
    }
}
```

- [ ] **Step 3: Install, stop and fan out turn completions in `AppState`**

In `Alas/Sources/App/AppState.swift`, insert after line 1733 (`installRunScheduleRunner()`):

```swift
        installReviewShepherdEffects()
```

Insert after line 1737 (`self?.runScheduler.stop()`, inside `AlasTerminationCoordinator.shared.flush`):

```swift
            self?.reviewShepherd.stop()
```

Replace lines 13170-13175 (the worktree manager's `onTurnCompleted:` closure) with:

```swift
            onTurnCompleted: { [weak self] completion in
                Task { @MainActor [weak self] in
                    self?.scheduledAgentTurns.deliver(completion)
                    self?.reviewShepherd.turnCompleted(sessionID: completion.sessionId)
                    await self?.acpOrchestration.childTurnCompleted(completion)
                }
            },
```

Only the worktree manager (built in `acpManager(for worktree:)`) gets this; the Workspace checkout manager at `AppState.swift:13649` is left alone because shepherd records are always worktree-owned.

- [ ] **Step 4: Start after topology load and evaluate on wake**

In `Alas/Sources/App/RootView.swift`, replace lines 163-165 with:

```swift
                // Schedules and shepherded requests need reconciled worktrees
                // to resolve their targets, so both clocks start only once
                // topology is loaded.
                state.startRunScheduler()
                state.startReviewShepherd()
```

In `Alas/Sources/App/PlatformServices.swift`, insert after line 32 (`RunScheduler.wakeNotification = ...`):

```swift
        ReviewShepherd.wakeNotification = (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
```

- [ ] **Step 5: Regenerate the Xcode project**

Run: `xcodegen`
Expected: `Created project at .../Alas.xcodeproj`, and `git status --short Alas.xcodeproj` shows `project.pbxproj` modified with `AppState+Shepherd.swift` added.

- [ ] **Step 6: Run the AlasCore tests and build the app**

Run: `swift test --package-path Packages/AlasCore`
Expected: every AlasCore suite passes.

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build`
Expected: exits 0 with no `error:` lines.

- [ ] **Step 7: Manual smoke test (no UI binds yet, so seed one record)**

Use a throwaway GitHub repository you can push to, already added to Alas, with a local worktree Alas lists. Run Alas from Xcode (Alas scheme, Product > Run) without `ALAS_APP_SUPPORT_DIR` set, so its support folder is `~/Library/Application Support/Alas`.

1. In the worktree, open a PR that conflicts with its base (no CI needed; a conflict is a shepherd problem):

```bash
BASE="main"
git switch -c shepherd-smoke
printf 'branch side\n' > shepherd-smoke.txt
git add shepherd-smoke.txt && git commit -m "smoke: branch side" && git push -u origin HEAD
gh pr create --base "$BASE" --title "Shepherd smoke" --body "Throwaway"
SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
gh api -X PUT "repos/$SLUG/contents/shepherd-smoke.txt" \
  -f message="smoke: base side" -f branch="$BASE" \
  -f content="$(printf 'base side\n' | base64)"
```

2. In Alas, open a chat session in this worktree, send "Say hi", wait for the reply, then close the session's tab (this exercises delivery to a session with no tab).
3. Quit Alas (Cmd-Q), then seed the record from the worktree directory (the path Alas shows for the worktree):

```bash
WT="$(pwd)"
SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
PR="$(gh pr view --json number -q .number)"
BASE="$(gh pr view --json baseRefName -q .baseRefName)"
BRANCH="$(git branch --show-current)"
SESSION="$(sqlite3 "$HOME/Library/Application Support/Alas/acp-sessions${WT}.sqlite" \
  "select id from sessions where archived = 0 order by last_opened_at desc limit 1;")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "session=$SESSION pr=$PR"
cat > "$HOME/Library/Application Support/Alas/review-shepherds.json" <<EOF
{
  "records" : [
    {
      "autoFix" : true,
      "autoMerge" : false,
      "baseBranch" : "$BASE",
      "branch" : "$BRANCH",
      "createdAt" : "$NOW",
      "fixAttempts" : 0,
      "id" : {
        "host" : "github.com",
        "providerKind" : "github",
        "repositorySlug" : "$SLUG",
        "requestNumber" : $PR,
        "worktreeID" : "$WT"
      },
      "phase" : { "watching" : { } },
      "remote" : {
        "host" : "github.com",
        "kind" : "github",
        "owner" : "${SLUG%%/*}",
        "remoteName" : "origin",
        "repository" : "${SLUG#*/}",
        "webURL" : "https://github.com/$SLUG"
      },
      "sessionID" : "$SESSION",
      "stableHeadPolls" : 0,
      "updatedAt" : "$NOW"
    }
  ],
  "version" : 1
}
EOF
```

   Expected: `echo` prints a non-empty session id and the PR number.

4. In a terminal, run `log stream --level info --predicate 'subsystem == "io.nlopez.alas" AND category == "ReviewShepherd"'`, then launch Alas again from Xcode.
   Expected within 3 minutes (GitHub may report the conflict a little after the first poll):
   - `review-shepherds.json` is rewritten with `"fixing"` in `phase` and `"fixAttempts" : 1`.
   - Reopening the session from the sessions popover shows a new incoming bubble captioned "Alas PR shepherd" (icon `arrow.turn.down.right`) whose text starts with "Alas PR shepherd" and has a merge-conflict section, and the agent is running a turn.
   - The log stream shows no "failed" or "Dropping" lines.
5. Stop the agent's turn (Esc) and archive the session from the sessions popover.
   Expected within about a minute: a macOS notification "PR shepherd needs you" whose body ends with "lost its chat session. Pick another one in Changes.", and the worktree's attention history lists the same entry.
6. Clean up: `gh pr close "$PR"`. Expected within 5 minutes (escalated records poll every 5 minutes): a "Closed" notification, and the record's `phase` becomes `"closed"` with a `finishedAt` date. Quit Alas and delete `~/Library/Application Support/Alas/review-shepherds.json`, or leave it for the 7-day pruning.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/App/AppState+Shepherd.swift \
        Alas/Sources/App/AppState.swift \
        Alas/Sources/App/RootView.swift \
        Alas/Sources/App/PlatformServices.swift \
        Packages/AlasCore/Sources/AlasCore/Core/AlasCoreContext.swift \
        Alas.xcodeproj/project.pbxproj
git commit -m "feat(shepherd): run the review shepherd from the app"
```

---

## Group D: MCP tools (Tasks 11-12)

#### Planning notes for this group

1. `PRCreateParams` is a public top-level struct in `Packages/AlasCore/Sources/AlasCore/Harness/AlasCLIRequest.swift` (AlasCore, next to `AlasCLINotifyLevel`), because `AlasCLIRequest.Command` lives in AlasCore. Fields are `let`; it adds `Equatable, Sendable` and `init(title:body:draft:base:)`.
2. `cliPRCreate` / `cliPRStatus` live in a new file `Alas/Sources/App/AppState+PRShepherdCLI.swift` instead of `AppState+Shepherd.swift`, so Task 10 owns `AppState+Shepherd.swift` alone. Signatures are exactly the contract's.
3. The CLI handlers read the worktree path, base branch and eligibility from `reviewShepherd.effects?.worktreeContext(worktreeID)`, and the project rules from `effects.rules(worktreeID)`. They need no other Task 10 helper. If effects are not installed yet, the tools return a plain "not running yet" error.
4. Router contract: `AlasCLICommandRouter` gains `prCreate: (String, String, PRCreateParams) async -> AlasCLIResponse` (sessionID, worktreeID, params) and `prStatus: (String, String) async -> AlasCLIResponse`. Both tools also require the caller to be an ACP session (`resolveACPSessionOrigin`, like `visual_show`), because the shepherd delivers fixes to ACP sessions. A terminal session id gets a plain error.
5. Extra `pr_create` precondition: when the branch's upstream is the base branch (for example, `feature` tracking `origin/main`), the call is rejected. Otherwise the reused `CommitPublishOperations.push` would push to `upstreamBranch`, which would land on base and break the spec's `git push -u <remote> <sha>:refs/heads/<branch>` rule.
6. A bind from `pr_create` uses `request.baseRefName` as the record's base branch. If this session already shepherds the PR, the bind keeps that record's toggles; otherwise it uses `config.changes.shepherd` defaults. It always passes `sendContext: false`.
7. `pr_status` check counts: each check is counted exactly once. `fail` and `cancel` count as `failed` and appear in `failing`. `pending` and `unknown` count as `pending`. `skipping` counts as `skipped`, and `pass` counts as `passed`. Optional wire fields are encoded as explicit `null`. `ReviewCommentWireDTO.jsonLine` is reused, so slashes are escaped (`https:\/\/…`), as in `review_comments`.
8. No `runs_on_worker` change: `pr_create` runs inline on the stdio loop, like `review`. It is bounded by alas-client's 30 s `READ_TIMEOUT` (`AlasCLI/crates/alas-client/src/lib.rs:950`). If a slow push or create times out on the agent side, the app still finishes, and calling `pr_create` again binds the PR and returns `created: false`.

### Task 11: App-side `pr_create` and `pr_status`

Adds the Swift wire commands, router cases, wire DTOs, and the AppState handlers behind the two MCP tools. Rust and the agent preamble come in Task 12. This task is testable on its own through the decode and encoding tests.

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasCore/Harness/AlasCLIRequest.swift`. Insert `PRCreateParams` after line 36 (end of `AlasCLINotifyLevel`). Insert command cases after line 61 (`case sessionAction(...)`). Insert the private `PRCreateWireParams` after line 288 (end of `NotifyParams`). Insert decode cases after line 624 (end of the `"review_finish"` case, before `case "agent_list":`).
- Create: `Alas/Sources/App/PRShepherdWireDTO.swift`
- Create: `Alas/Sources/App/AppState+PRShepherdCLI.swift`
- Modify: `Alas/Sources/App/AlasCLICommandRouter.swift`. Add properties after line 65 (end of `showVisualAid`). Add a Workspace checkout guard after line 185 (end of the `notify` checkout block). Add switch cases after line 282 (`.visualShow` precondition case).
- Modify: `Alas/Sources/App/AppState.swift:7636-7645`, the `showVisualAid:` argument and the closing `)` of `makeCLICommandRouter`.
- Test: `AlasTests/AlasCLIRequestTests.swift`. Insert after line 427 (end of `visualShowOutsideTheContractIsMalformed`, before `private struct ProbeParams`).
- Regenerate: `Alas.xcodeproj/project.pbxproj` (two new app files).

**Interfaces:**
- Consumes (Task 10 and earlier, contract signatures):
  - `AppState.reviewShepherd: ReviewShepherd`
  - `ReviewShepherd.effects: ReviewShepherd.Effects?` with `worktreeContext: @MainActor (String) -> WorktreeContext?` and `rules: @MainActor (String) -> ShepherdRules`
  - `ReviewShepherd.WorktreeContext { worktreeID, projectID, path: URL, baseBranch: String, isEligible: Bool }`
  - `ReviewShepherd.fetchSnapshot(worktreePath: URL, baseBranch: String) async -> ReviewLoopSnapshot?`
  - `ReviewShepherd.evaluateNow(_ id: ShepherdRecordID) async`
  - `ReviewShepherd.headReviewers(for: ReviewLoopSnapshot, worktreePath: URL) async -> Set<String>?`
  - `ReviewShepherd.record(forSession: String) -> ShepherdRecord?`, `records`, `snapshots`
  - `ReviewShepherd.bind(sessionID:worktreeID:request:baseBranch:autoFix:autoMerge:sendContext:) async -> ShepherdRecord`
  - `ShepherdRecordID(worktreeID: String, request: ReviewRequest)`, `ShepherdRecord`, `ShepherdPhase`, `ShepherdRules`, `ShepherdRules.Source`
  - `AppConfig.Changes.shepherd: ShepherdDefaults` (`autoFix`, `autoMerge`)
  - `ReviewThread.headAuthorTrust: ReviewAuthorTrust`
  - Existing: `CommitPublishOperations.live(worktreePath:reviewLoop:comparisonBase:syncGG:refreshAfterCompletion:runGit:...)` (`Alas/Sources/Center/Commit/CommitPublishWorkflow.swift:130-255`), `CommitPublishReviewTarget.capture(snapshot:createAsDraft:runGit:)` (`Alas/Sources/Center/Commit/CommitPublishModels.swift:247-291`), `ReviewLoopState.init(worktreePath:baseBranch:providerRegistry:)` (`ReviewLoopState.swift:42-50`), `ReviewCommentWireDTO.jsonLine(_:)` (`Alas/Sources/App/ReviewCommentWireDTO.swift:90-99`), `Process.git(_:cwd:)`.
- Produces:
  - `public struct PRCreateParams: Equatable, Sendable { title, body, draft, base }`
  - `AlasCLIRequest.Command.prCreate(PRCreateParams)`, `.prStatus`; wire `command: "pr_create"` params `{title, body, draft?, base?}`, `command: "pr_status"`
  - `AppState.cliPRCreate(sessionID:worktreeID:title:body:draft:base:) async -> AlasCLIResponse`
  - `AppState.cliPRStatus(sessionID:worktreeID:) async -> AlasCLIResponse`
  - `PRCreateResultWire`, `PRStatusWire` (spec JSON, snake_case)

Push reuse decision: no extraction. `CommitPublishOperations.live(...)` already provides the three operations `pr_create` needs as plain closures:
- `remoteBranchContainsCommit` skips a push when every captured destination already has the SHA.
- `push` re-checks the exact push-URL set, then runs `git push -u <remote> <sha>:refs/heads/<branch>` with no force.
- `configureUpstreamTracking` sets up tracking when the branch had none.

`CommitPublishReviewTarget.capture` does the destination checks: branch and HEAD match the snapshot, every push URL is recognized, and the code host owner and repository match. `pr_create` builds the operations value with no-op `syncGG` and `refreshAfterCompletion`, and calls those closures plus `createReviewRequest` in the same order as `CommitPublishWorkflow.continueResuming` (`CommitPublishWorkflow.swift:393-447`).

- [ ] **Step 1: Write the failing decode and wire tests**

Insert in `AlasTests/AlasCLIRequestTests.swift` after line 427:

```swift
    @Test(arguments: [
        (#"{"title":"fix: retry","body":"Why.","draft":true,"base":"release"}"#,
         PRCreateParams?.some(PRCreateParams(title: "fix: retry", body: "Why.", draft: true, base: "release"))),
        (#"{"title":" fix: retry ","body":"Why."}"#,
         PRCreateParams(title: "fix: retry", body: "Why.", draft: false, base: nil)),
        (#"{"title":"fix: retry","body":"Why.","base":"  "}"#,
         PRCreateParams(title: "fix: retry", body: "Why.", draft: false, base: nil)),
        (#"{"body":"Why."}"#, nil),
        (#"{"title":"   ","body":"Why."}"#, nil),
        (#"{"title":"fix: retry"}"#, nil),
        (#"{"title":"fix: retry","body":"Why.","draft":"yes"}"#, nil),
    ])
    func decodesPRCreate(params: String, expected: PRCreateParams?) throws {
        let json = #"{"v":1,"kind":"cli","command":"pr_create","session_id":"acp-1","cwd":"/wt","params":\#(params)}"#
        if let expected {
            #expect(try AlasCLIRequest.decode(from: Data(json.utf8)).command == .prCreate(expected))
        } else {
            #expect(throws: AlasCLIRequestError.malformed) {
                try AlasCLIRequest.decode(from: Data(json.utf8))
            }
        }
    }

    @Test func decodesPRStatus() throws {
        let json = #"{"v":1,"kind":"cli","command":"pr_status","session_id":"acp-1","cwd":"/wt","params":{}}"#
        #expect(try AlasCLIRequest.decode(from: Data(json.utf8)).command == .prStatus)
    }

    /// Pins the agent-facing `pr_status` keys from the spec, including the
    /// explicit nulls agents rely on.
    @Test(arguments: [
        (PRStatusWire(pullRequest: nil, shepherd: nil), #"{"pull_request":null,"shepherd":null}"#),
        (
            PRStatusWire(
                pullRequest: .init(
                    number: 2041,
                    url: "https://example.com/pr/2041",
                    state: "open",
                    draft: false,
                    headSha: "a3f9c1e",
                    mergeState: "blocked",
                    checks: .init(
                        passed: 10, failed: 1, pending: 1, skipped: 0,
                        failing: [.init(name: "unit-tests", workflow: "CI", url: nil)]
                    ),
                    threads: [.init(
                        id: "PRRT_1", path: "Auth/TokenRefresher.swift", line: 88, author: "maintainer",
                        trust: "trusted", body: "Back off.", url: nil
                    )],
                    missingRequiredReviewers: ["chatgpt-codex-connector"]
                ),
                shepherd: .init(phase: "fixing", autoFix: true, autoMerge: false, fixAttempts: 1, rulesSource: "repo_file")
            ),
            #"{"pull_request":{"checks":{"failed":1,"failing":[{"name":"unit-tests","url":null,"workflow":"CI"}],"passed":10,"pending":1,"skipped":0},"draft":false,"head_sha":"a3f9c1e","merge_state":"blocked","missing_required_reviewers":["chatgpt-codex-connector"],"number":2041,"state":"open","threads":[{"author":"maintainer","body":"Back off.","id":"PRRT_1","line":88,"path":"Auth\/TokenRefresher.swift","trust":"trusted","url":null}],"url":"https:\/\/example.com\/pr\/2041"},"shepherd":{"auto_fix":true,"auto_merge":false,"fix_attempts":1,"phase":"fixing","rules_source":"repo_file"}}"#
        ),
    ])
    func prStatusWireMatchesTheSpecKeys(status: PRStatusWire, expected: String) {
        #expect(ReviewCommentWireDTO.jsonLine(status) == expected)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/AlasCLIRequestTests test > /tmp/alas-test.log 2>&1; grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log; grep -m5 'error:' /tmp/alas-test.log
```
Expected: `** TEST FAILED **`, with compile errors such as `cannot find type 'PRCreateParams' in scope` and `cannot find 'PRStatusWire' in scope`.

- [ ] **Step 3: Add the wire command to `AlasCLIRequest`**

In `Packages/AlasCore/Sources/AlasCore/Harness/AlasCLIRequest.swift`, insert after line 36 (the closing `}` of `AlasCLINotifyLevel`):

```swift

/// `pr_create` arguments after validation: title and body trimmed and
/// non-empty, `base` nil when omitted or blank (the worktree's base branch).
public struct PRCreateParams: Equatable, Sendable {
    public let title: String
    public let body: String
    public let draft: Bool
    public let base: String?

    public init(title: String, body: String, draft: Bool = false, base: String? = nil) {
        self.title = title
        self.body = body
        self.draft = draft
        self.base = base
    }
}
```

Insert after line 61 (`case sessionAction(ACPDelegatedSessionAction)`):

```swift
        /// MCP-only: push this worktree's branch, open its PR/MR (or adopt the
        /// open one) and bind the PR shepherd to the calling session.
        case prCreate(PRCreateParams)
        /// MCP-only: fresh status of the calling session's PR/MR.
        case prStatus
```

Insert after line 288 (the closing `}` of `NotifyParams`):

```swift

    private struct PRCreateWireParams: Decodable {
        var title: String?
        var body: String?
        var draft: Bool?
        var base: String?
    }
```

Insert after line 624 (the closing `))` of the `"review_finish"` case, before `case "agent_list":`):

```swift
        case "pr_create":
            let params = try Self.decodeParams(PRCreateWireParams.self, from: data)
            command = .prCreate(PRCreateParams(
                title: try requiredNonEmpty(params.title),
                body: try requiredNonEmpty(params.body),
                draft: params.draft ?? false,
                base: params.base?.nilIfBlank
            ))
        case "pr_status":
            command = .prStatus
```

Check the AlasCore part compiles on its own:
```bash
swift build --package-path Packages/AlasCore
```
Expected: `Build complete!`.

- [ ] **Step 4: Create the wire DTOs**

Create `Alas/Sources/App/PRShepherdWireDTO.swift`:

```swift
import Foundation

/// Agent-facing JSON of the `pr_create` MCP tool. Snake_cased on the wire by
/// `ReviewCommentWireDTO.jsonLine`'s key strategy.
struct PRCreateResultWire: Encodable, Equatable, Sendable {
    struct Shepherd: Encodable, Equatable, Sendable {
        var autoFix: Bool
        var autoMerge: Bool
    }

    var number: Int
    var url: String
    var provider: String
    var headSha: String
    var created: Bool
    var uncommittedChanges: Bool
    var shepherd: Shepherd
}

extension PRCreateResultWire {
    init(request: ReviewRequest, headSHA: String, created: Bool, uncommittedChanges: Bool, record: ShepherdRecord) {
        self.init(
            number: request.number,
            url: request.url.absoluteString,
            provider: request.provider.rawValue,
            headSha: headSHA,
            created: created,
            uncommittedChanges: uncommittedChanges,
            shepherd: Shepherd(autoFix: record.autoFix, autoMerge: record.autoMerge)
        )
    }
}

/// Agent-facing JSON of the `pr_status` MCP tool. Optional fields encode as
/// explicit `null` so agents always see the same keys.
struct PRStatusWire: Encodable, Equatable, Sendable {
    struct FailingCheck: Encodable, Equatable, Sendable {
        var name: String
        var workflow: String?
        var url: String?

        enum CodingKeys: String, CodingKey {
            case name, workflow, url
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(workflow, forKey: .workflow)
            try container.encode(url, forKey: .url)
        }
    }

    struct Checks: Encodable, Equatable, Sendable {
        var passed: Int
        var failed: Int
        var pending: Int
        var skipped: Int
        var failing: [FailingCheck]
    }

    struct ThreadEntry: Encodable, Equatable, Sendable {
        var id: String
        var path: String?
        var line: Int?
        var author: String?
        var trust: String
        var body: String
        var url: String?

        enum CodingKeys: String, CodingKey {
            case id, path, line, author, trust, body, url
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(path, forKey: .path)
            try container.encode(line, forKey: .line)
            try container.encode(author, forKey: .author)
            try container.encode(trust, forKey: .trust)
            try container.encode(body, forKey: .body)
            try container.encode(url, forKey: .url)
        }
    }

    struct PullRequest: Encodable, Equatable, Sendable {
        var number: Int
        var url: String
        var state: String
        var draft: Bool
        var headSha: String?
        var mergeState: String
        var checks: Checks
        var threads: [ThreadEntry]
        var missingRequiredReviewers: [String]

        enum CodingKeys: String, CodingKey {
            case number, url, state, draft, headSha, mergeState, checks, threads, missingRequiredReviewers
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(number, forKey: .number)
            try container.encode(url, forKey: .url)
            try container.encode(state, forKey: .state)
            try container.encode(draft, forKey: .draft)
            try container.encode(headSha, forKey: .headSha)
            try container.encode(mergeState, forKey: .mergeState)
            try container.encode(checks, forKey: .checks)
            try container.encode(threads, forKey: .threads)
            try container.encode(missingRequiredReviewers, forKey: .missingRequiredReviewers)
        }
    }

    struct Shepherd: Encodable, Equatable, Sendable {
        var phase: String
        var autoFix: Bool
        var autoMerge: Bool
        var fixAttempts: Int
        var rulesSource: String
    }

    var pullRequest: PullRequest?
    var shepherd: Shepherd?

    enum CodingKeys: String, CodingKey {
        case pullRequest, shepherd
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pullRequest, forKey: .pullRequest)
        try container.encode(shepherd, forKey: .shepherd)
    }
}

extension PRStatusWire.PullRequest {
    /// `threads` lists actionable threads whose head comment comes from a
    /// trusted reviewer, the set the shepherd acts on. Each check is counted
    /// once: cancelled counts as failed, unknown as pending. A nil
    /// `headReviewers` (not fetched, or the fetch failed) lists every required
    /// reviewer as missing, matching the merge gate's fail-closed rule.
    init(request: ReviewRequest, rules: ShepherdRules, headReviewers: Set<String>?) {
        let failing = request.checks.filter { $0.bucket == .fail || $0.bucket == .cancel }
        self.init(
            number: request.number,
            url: request.url.absoluteString,
            state: request.state.rawValue,
            draft: request.isDraft,
            headSha: request.headSHA,
            mergeState: request.mergeState.rawValue,
            checks: PRStatusWire.Checks(
                passed: request.checks.filter { $0.bucket == .pass }.count,
                failed: failing.count,
                pending: request.checks.filter { $0.bucket == .pending || $0.bucket == .unknown }.count,
                skipped: request.checks.filter { $0.bucket == .skipping }.count,
                failing: failing.map {
                    PRStatusWire.FailingCheck(name: $0.name, workflow: $0.workflow, url: $0.detailURL?.absoluteString)
                }
            ),
            threads: request.threads
                .filter { $0.isActionable && $0.headAuthorTrust == .trusted }
                .map {
                    PRStatusWire.ThreadEntry(
                        id: $0.id, path: $0.path, line: $0.line, author: $0.author,
                        trust: $0.headAuthorTrust.rawValue, body: $0.body, url: $0.url?.absoluteString
                    )
                },
            missingRequiredReviewers: rules.requiredReviewers.filter {
                !(headReviewers?.contains($0.lowercased()) ?? false)
            }
        )
    }
}

extension PRStatusWire.Shepherd {
    init(record: ShepherdRecord, rules: ShepherdRules) {
        self.init(
            phase: Self.wireName(record.phase),
            autoFix: record.autoFix,
            autoMerge: record.autoMerge,
            fixAttempts: record.fixAttempts,
            rulesSource: Self.wireName(rules.source)
        )
    }

    static func wireName(_ phase: ShepherdPhase) -> String {
        switch phase {
        case .watching: "watching"
        case .fixing: "fixing"
        case .awaitingPush: "awaiting_push"
        case .merging: "merging"
        case .queued: "queued"
        case .escalated: "escalated"
        case .paused: "paused"
        case .merged: "merged"
        case .closed: "closed"
        }
    }

    static func wireName(_ source: ShepherdRules.Source) -> String {
        switch source {
        case .localFile: "local_file"
        case .repoFile: "repo_file"
        case .projectSettings: "project_settings"
        case .none: "none"
        }
    }
}
```

- [ ] **Step 5: Add the AppState handlers**

Create `Alas/Sources/App/AppState+PRShepherdCLI.swift`:

```swift
import Foundation

/// Agent-facing failure of `pr_create` / `pr_status`; `message` is returned verbatim.
private struct PRShepherdCLIError: Error {
    let message: String
}

/// MCP `pr_create` and `pr_status`. The router has already resolved the
/// calling ACP session and its worktree, and rejected Workspace checkout owners.
extension AppState {
    /// Pushes the exact HEAD, opens the PR/MR (or adopts the open one for this
    /// branch), and binds the shepherd to the calling session.
    func cliPRCreate(
        sessionID: String,
        worktreeID: String,
        title: String,
        body: String,
        draft: Bool,
        base: String?
    ) async -> AlasCLIResponse {
        do {
            let result = try await createShepherdedPR(
                sessionID: sessionID, worktreeID: worktreeID,
                title: title, body: body, draft: draft, base: base
            )
            return .text([ReviewCommentWireDTO.jsonLine(result)])
        } catch {
            return .error(Self.prShepherdErrorMessage(error))
        }
    }

    /// Fresh status of the PR/MR bound to the calling session, else of the
    /// worktree branch's PR/MR.
    func cliPRStatus(sessionID: String, worktreeID: String) async -> AlasCLIResponse {
        do {
            let status = try await shepherdedPRStatus(sessionID: sessionID, worktreeID: worktreeID)
            return .text([ReviewCommentWireDTO.jsonLine(status)])
        } catch {
            return .error(Self.prShepherdErrorMessage(error))
        }
    }

    private func createShepherdedPR(
        sessionID: String,
        worktreeID: String,
        title: String,
        body: String,
        draft: Bool,
        base: String?
    ) async throws -> PRCreateResultWire {
        let (_, context) = try prShepherdTarget(worktreeID)
        let baseBranch = base ?? context.baseBranch
        guard let snapshot = await reviewShepherd.fetchSnapshot(worktreePath: context.path, baseBranch: baseBranch) else {
            throw PRShepherdCLIError(message: "Alas could not read this worktree's Git state.")
        }
        let local = snapshot.local
        if let blocker = Self.prCreateBranchBlocker(local, baseBranch: baseBranch) {
            throw PRShepherdCLIError(message: blocker)
        }
        guard let remote = snapshot.remote else {
            throw PRShepherdCLIError(message: "This worktree has no GitHub or GitLab remote.")
        }
        if let problem = Self.prProviderSetupProblem(snapshot) {
            throw PRShepherdCLIError(message: problem)
        }
        if let message = snapshot.errorMessage {
            throw PRShepherdCLIError(message: "Could not check for an existing pull request: \(message)")
        }
        let hasUncommittedChanges = local.hasWorkingTreeChanges || local.hasStagedChanges

        if let existing = snapshot.reviewRequest, existing.state == .open {
            let record = await bindPRShepherd(sessionID: sessionID, worktreeID: worktreeID, request: existing)
            return PRCreateResultWire(
                request: existing, headSHA: existing.headSHA ?? local.headSHA, created: false,
                uncommittedChanges: hasUncommittedChanges, record: record
            )
        }

        // Same exact-SHA publish path as Commit & publish: capture validates the
        // branch, HEAD and push destinations; push re-checks the URL set and
        // never forces; tracking is configured when the branch had none.
        let run: ([String]) async throws -> ProcessResult = { try await Process.git($0, cwd: context.path) }
        let operations = CommitPublishOperations.live(
            worktreePath: context.path,
            reviewLoop: ReviewLoopState(worktreePath: context.path, baseBranch: baseBranch),
            comparisonBase: nil,
            syncGG: { _ in },
            refreshAfterCompletion: {},
            runGit: run
        )
        let url: URL
        do {
            let target = try await CommitPublishReviewTarget.capture(snapshot: snapshot, createAsDraft: draft, runGit: run)
            if try await !operations.remoteBranchContainsCommit(target, local.headSHA) {
                try await operations.push(target, local.headSHA)
            }
            try await operations.configureUpstreamTracking(target)
            url = try await operations.createReviewRequest(target, title, body)
        } catch let error as CodeHostProviderError {
            throw PRShepherdCLIError(message: Self.prProviderErrorMessage(error, kind: remote.kind))
        }

        guard let created = await reviewShepherd.fetchSnapshot(
            worktreePath: context.path, baseBranch: baseBranch
        )?.reviewRequest else {
            throw PRShepherdCLIError(
                message: "Created \(url.absoluteString), but Alas could not load it yet. Call pr_create again to start watching it."
            )
        }
        let record = await bindPRShepherd(sessionID: sessionID, worktreeID: worktreeID, request: created)
        return PRCreateResultWire(
            request: created, headSHA: created.headSHA ?? local.headSHA, created: true,
            uncommittedChanges: hasUncommittedChanges, record: record
        )
    }

    private func shepherdedPRStatus(sessionID: String, worktreeID: String) async throws -> PRStatusWire {
        let (effects, context) = try prShepherdTarget(worktreeID)
        let bound = reviewShepherd.record(forSession: sessionID).flatMap { $0.id.worktreeID == worktreeID ? $0 : nil }
        var snapshot: ReviewLoopSnapshot?
        if let bound {
            await reviewShepherd.evaluateNow(bound.id)
            snapshot = reviewShepherd.snapshots[bound.id]
        }
        if snapshot == nil {
            snapshot = await reviewShepherd.fetchSnapshot(
                worktreePath: context.path, baseBranch: bound?.baseBranch ?? context.baseBranch
            )
        }
        guard let snapshot else {
            throw PRShepherdCLIError(message: "Alas could not read this worktree's Git state.")
        }
        let rules = effects.rules(worktreeID)
        var pullRequest: PRStatusWire.PullRequest?
        if let request = snapshot.reviewRequest {
            var headReviewers: Set<String>?
            if !rules.requiredReviewers.isEmpty {
                headReviewers = await reviewShepherd.headReviewers(for: snapshot, worktreePath: context.path)
            }
            pullRequest = PRStatusWire.PullRequest(request: request, rules: rules, headReviewers: headReviewers)
        } else if let problem = Self.prProviderSetupProblem(snapshot) {
            throw PRShepherdCLIError(message: problem)
        } else if snapshot.remote != nil, let message = snapshot.errorMessage {
            throw PRShepherdCLIError(message: "Could not load the pull request: \(message)")
        }
        // evaluateNow may have advanced or finished the record; report it as it is now.
        let shepherd = bound
            .flatMap { reviewShepherd.records[$0.id] }
            .map { PRStatusWire.Shepherd(record: $0, rules: rules) }
        return PRStatusWire(pullRequest: pullRequest, shepherd: shepherd)
    }

    private func prShepherdTarget(
        _ worktreeID: String
    ) throws -> (effects: ReviewShepherd.Effects, context: ReviewShepherd.WorktreeContext) {
        guard let effects = reviewShepherd.effects else {
            throw PRShepherdCLIError(message: "The Alas PR shepherd is not running yet. Try again in a moment.")
        }
        guard let context = effects.worktreeContext(worktreeID) else {
            throw PRShepherdCLIError(message: "Alas could not find this session's worktree.")
        }
        guard context.isEligible else {
            throw PRShepherdCLIError(
                message: "The PR shepherd works on local worktrees only. Remote worktrees and Workspace checkouts are not supported yet."
            )
        }
        return (effects, context)
    }

    /// Re-binding a PR this session already shepherds keeps its toggles; a new
    /// binding takes the Settings defaults.
    private func bindPRShepherd(sessionID: String, worktreeID: String, request: ReviewRequest) async -> ShepherdRecord {
        let current = reviewShepherd.records[ShepherdRecordID(worktreeID: worktreeID, request: request)]
        let defaults = config.changes.shepherd
        return await reviewShepherd.bind(
            sessionID: sessionID,
            worktreeID: worktreeID,
            request: request,
            baseBranch: request.baseRefName,
            autoFix: current?.autoFix ?? defaults.autoFix,
            autoMerge: current?.autoMerge ?? defaults.autoMerge,
            sendContext: false
        )
    }

    static func prCreateBranchBlocker(_ local: ReviewLoopLocalState, baseBranch: String) -> String? {
        if local.branchName.isEmpty {
            return "HEAD is detached. Check out a branch before opening a pull request."
        }
        if local.headSHA.isEmpty {
            return "\(local.branchName) has no commits yet."
        }
        if local.branchName == baseBranch {
            return "This worktree is on the base branch \(baseBranch). Open a pull request from a feature branch."
        }
        if local.upstreamBranchName == baseBranch {
            return "\(local.branchName) tracks the base branch \(baseBranch), so a push would land on \(baseBranch). "
                + "Run `git branch --unset-upstream` in this worktree, then call pr_create again."
        }
        if local.aheadCommitCount == 0 {
            return "\(local.branchName) has no commits ahead of \(baseBranch)."
        }
        return nil
    }

    static func prProviderSetupProblem(_ snapshot: ReviewLoopSnapshot) -> String? {
        guard let remote = snapshot.remote else { return nil }
        if !snapshot.providerAvailable { return prProviderSetupMessage(kind: remote.kind, isInstalled: false) }
        if !snapshot.providerAuthenticated { return prProviderSetupMessage(kind: remote.kind, isInstalled: true) }
        return nil
    }

    static func prProviderErrorMessage(_ error: CodeHostProviderError, kind: CodeHostKind) -> String {
        switch error {
        case .cliMissing: prProviderSetupMessage(kind: kind, isInstalled: false)
        case .unauthenticated: prProviderSetupMessage(kind: kind, isInstalled: true)
        default: error.localizedDescription
        }
    }

    static func prProviderSetupMessage(kind: CodeHostKind, isInstalled: Bool) -> String {
        let cli = switch kind {
        case .github: "gh"
        case .gitlab: "glab"
        }
        if isInstalled {
            return "\(kind.displayName) CLI (\(cli)) is not signed in. Run `\(cli) auth login`, then try again."
        }
        return "\(kind.displayName) CLI (\(cli)) is not installed. Install it with `brew install \(cli)`, then run `\(cli) auth login`."
    }

    static func prShepherdErrorMessage(_ error: Error) -> String {
        (error as? PRShepherdCLIError)?.message ?? error.localizedDescription
    }
}
```

- [ ] **Step 6: Route the commands**

In `Alas/Sources/App/AlasCLICommandRouter.swift`, insert after line 65 (the closing `}` of the `showVisualAid` default):

```swift
    var prCreate: (String, String, PRCreateParams) async -> AlasCLIResponse = { _, _, _ in
        .error("The PR shepherd is not available yet.")
    }
    var prStatus: (String, String) async -> AlasCLIResponse = { _, _ in
        .error("The PR shepherd is not available yet.")
    }
```

Insert after line 185 (the closing `}` of the `if case .notify(...) ... case .workspaceCheckout = owner` block):

```swift
        switch request.command {
        case .prCreate, .prStatus:
            if case .workspaceCheckout = requestOwner {
                return .error("The PR shepherd does not support Workspace checkouts yet. Use a regular worktree.")
            }
        default:
            break
        }
```

Insert after line 282 (`preconditionFailure("visual_show is handled before generic origin resolution")`):

```swift
        case .prCreate(let params):
            guard let sessionId = request.sessionId, resolveACPSessionOrigin(sessionId) != nil else {
                return .error("pr_create is only available to ACP agent sessions.")
            }
            return await prCreate(sessionId, origin.id, params)
        case .prStatus:
            guard let sessionId = request.sessionId, resolveACPSessionOrigin(sessionId) != nil else {
                return .error("pr_status is only available to ACP agent sessions.")
            }
            return await prStatus(sessionId, origin.id)
```

In `Alas/Sources/App/AppState.swift`, replace lines 7643-7645:

```swift
                return .text([#"{"visual_id":"\#(visual.id.uuidString)"}"#])
            }
        )
```

with:

```swift
                return .text([#"{"visual_id":"\#(visual.id.uuidString)"}"#])
            },
            prCreate: { [weak self] sessionID, worktreeID, params in
                guard let self else { return .error("Alas is not available.") }
                return await self.cliPRCreate(
                    sessionID: sessionID,
                    worktreeID: worktreeID,
                    title: params.title,
                    body: params.body,
                    draft: params.draft,
                    base: params.base
                )
            },
            prStatus: { [weak self] sessionID, worktreeID in
                guard let self else { return .error("Alas is not available.") }
                return await self.cliPRStatus(sessionID: sessionID, worktreeID: worktreeID)
            }
        )
```

- [ ] **Step 7: Regenerate the Xcode project**

Run:
```bash
xcodegen
```
Expected: `Created project at .../Alas.xcodeproj`. `git status --short Alas.xcodeproj/project.pbxproj` shows it modified, with both new files listed in it.

- [ ] **Step 8: Run the tests to verify they pass**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/AlasCLIRequestTests test > /tmp/alas-test.log 2>&1; grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log
```
Expected: `** TEST SUCCEEDED **` and no `✘` lines. `decodesPRCreate` runs 7 cases and `prStatusWireMatchesTheSpecKeys` runs 2.

- [ ] **Step 9: Build the app**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build
```
Expected: exit 0 with no `error:` lines.

- [ ] **Step 10: Commit**

```bash
git add Packages/AlasCore/Sources/AlasCore/Harness/AlasCLIRequest.swift \
  Alas/Sources/App/PRShepherdWireDTO.swift \
  Alas/Sources/App/AppState+PRShepherdCLI.swift \
  Alas/Sources/App/AlasCLICommandRouter.swift \
  Alas/Sources/App/AppState.swift \
  AlasTests/AlasCLIRequestTests.swift \
  Alas.xcodeproj/project.pbxproj
git commit -m "feat(shepherd): handle pr_create and pr_status requests in the app"
```

### Task 12: `pr_create` and `pr_status` MCP tools and preamble

Exposes the two tools from `alas mcp`: shared `Command` variants, socket requests, tool definitions, argument parsing, and the agent-visible preamble inventory. Workspace-only servers hide both tools, because `is_workspace_tool` (`AlasCLI/crates/alas/src/mcp.rs:726-730`) matches only `workspace_*`, `preview_*`, `session_read` and `visual_show`. Delegated children keep both, because only `CHILD_ONLY_TOOLS` (`mcp.rs:183`) is removed. Neither gate needs a code change; the tests pin both behaviors. No terminal `alas pr` subcommand is added (deviation 6).

**Files:**
- Modify: `AlasCLI/crates/alas-client/src/lib.rs`. Add variants after line 201 (end of `ReviewFinish`), `build_request` arms after line 547 (end of the `ReviewFinish` arm), and a test after line 1666 (end of `builds_review_finish_params`).
- Modify: `AlasCLI/crates/alas/src/mcp.rs`:
  - Tool definitions after line 497 (end of the `review_finish` `json!`).
  - `command_for_tool` arms after line 989 (end of the `"review_finish"` arm).
  - `success_message` arm after line 1498 (`Command::ReviewFinish { .. } => ...`).
  - Inventory test lines 2564-2566.
  - Gate test after line 2899 (end of `workspace_only_mode_exposes_preview_tools_too`).
  - Parse test after line 3654 (end of `review_finish_tool_maps_and_validates_verdict`).
- Modify: `Packages/AlasCore/Sources/AlasCore/ACP/Session/ACPMCPPromptPreamble.swift`: lines 67-68 (inventory), 173-177 (tool sentence), 192-193 (prefer sentence), 199-204 (CLI fallback sentence).
- Test: `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift`: lines 80-92 (`rootBuiltIn`), 141-151 (`toolNameInventory`), 154-166 (`cliMode`).

**Interfaces:**
- Consumes: Swift decoding of `command: "pr_create"` with params `{title, body, draft, base?}` and `command: "pr_status"` (Task 11).
- Produces:
  - `alas_client::Command::PrCreate { title: String, body: String, draft: bool, base: Option<String> }`
  - `alas_client::Command::PrStatus`
  - Socket requests `{"command":"pr_create","params":{"title","body","draft","base"?}}` and `{"command":"pr_status","params":{}}`, both carrying the MCP server's `session_id` and `cwd` through `dispatch` (`mcp.rs:1392-1403`).
  - MCP tools `pr_create` (required `title`, `body`; `draft` default false; optional `base`) and `pr_status` (no arguments).
  - `ACPMCPPromptPreamble.builtInToolNames` gains `"pr_create", "pr_status"` after `"review_finish"`.

- [ ] **Step 1: Write the failing Rust tests**

In `AlasCLI/crates/alas-client/src/lib.rs`, insert after line 1666:

```rust

    #[test]
    fn builds_pr_create_and_status_params() {
        let create = build_request(
            &Command::PrCreate {
                title: "fix: retry".into(),
                body: "Why.".into(),
                draft: false,
                base: None,
            },
            Some("acp-1".into()),
            Some("/wt".into()),
        );
        assert_eq!(create.command, "pr_create");
        assert_eq!(create.session_id.as_deref(), Some("acp-1"));
        assert_eq!(
            create.params,
            Some(serde_json::json!({ "title": "fix: retry", "body": "Why.", "draft": false }))
        );

        let with_base = build_request(
            &Command::PrCreate {
                title: "fix: retry".into(),
                body: "Why.".into(),
                draft: true,
                base: Some("release".into()),
            },
            None,
            Some("/wt".into()),
        );
        assert_eq!(
            with_base.params,
            Some(serde_json::json!({
                "title": "fix: retry",
                "body": "Why.",
                "draft": true,
                "base": "release"
            }))
        );

        let status = build_request(&Command::PrStatus, Some("acp-1".into()), Some("/wt".into()));
        assert_eq!(status.command, "pr_status");
        assert_eq!(status.params, Some(serde_json::json!({})));
    }
```

In `AlasCLI/crates/alas/src/mcp.rs`, change the inventory test so lines 2564-2566 read:

```rust
                "review_comment_add",
                "review_finish",
                "pr_create",
                "pr_status",
                "preview_list",
```

Insert after line 2899:

```rust

    #[test]
    fn pr_tools_stay_with_delegated_children_and_leave_workspace_checkouts() {
        let tool_names = |parent: Option<&str>, workspace_only: bool| -> Vec<String> {
            let list = handle_line_with_parent(
                r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                "/wt",
                parent,
                workspace_only,
                |_| unreachable!(),
            )
            .unwrap();
            list["result"]["tools"]
                .as_array()
                .unwrap()
                .iter()
                .map(|tool| tool["name"].as_str().unwrap().to_string())
                .collect()
        };
        let child = tool_names(Some("parent-session"), false);
        let checkout = tool_names(None, true);
        for tool in ["pr_create", "pr_status"] {
            assert!(child.iter().any(|name| name == tool), "child lacks {tool}");
            assert!(!checkout.iter().any(|name| name == tool), "checkout exposes {tool}");
        }

        let reply = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"pr_status","arguments":{}}}"#,
            "/checkout",
            None,
            true,
            |_| unreachable!(),
        )
        .unwrap();
        assert_eq!(reply["error"]["code"], json!(-32602));
    }
```

Insert after line 3654:

```rust

    #[test]
    fn pr_tools_map_to_commands_and_validate_arguments() {
        assert_eq!(
            command_for_tool(
                "pr_create",
                &json!({"title": "fix: retry", "body": "Why.", "draft": true, "base": "release"}),
                "/wt"
            )
            .unwrap(),
            Command::PrCreate {
                title: "fix: retry".into(),
                body: "Why.".into(),
                draft: true,
                base: Some("release".into())
            }
        );
        assert_eq!(
            command_for_tool(
                "pr_create",
                &json!({"title": " fix: retry ", "body": "Why.", "base": "  "}),
                "/wt"
            )
            .unwrap(),
            Command::PrCreate {
                title: "fix: retry".into(),
                body: "Why.".into(),
                draft: false,
                base: None
            }
        );
        for bad in [
            json!({"body": "Why."}),
            json!({"title": "   ", "body": "Why."}),
            json!({"title": "fix: retry"}),
            json!({"title": "fix: retry", "body": "Why.", "draft": "yes"}),
        ] {
            assert!(
                command_for_tool("pr_create", &bad, "/wt").is_err(),
                "accepted {bad}"
            );
        }
        assert_eq!(
            command_for_tool("pr_status", &json!({}), "/wt").unwrap(),
            Command::PrStatus
        );
    }
```

- [ ] **Step 2: Run the Rust tests to verify they fail**

Run:
```bash
cd AlasCLI && cargo test -p alas mcp::tests; cargo test -p alas-client
```
Expected: both fail to compile with `no variant or associated item named 'PrCreate' found for enum 'Command'` (and `PrStatus`).

- [ ] **Step 3: Add the shared command and its socket request**

In `AlasCLI/crates/alas-client/src/lib.rs`, insert after line 201 (the `},` closing `ReviewFinish`):

```rust
    /// MCP-only: push this worktree's branch, open its pull/merge request (or
    /// adopt the open one) and have Alas shepherd it for the calling session.
    PrCreate {
        title: String,
        body: String,
        draft: bool,
        base: Option<String>,
    },
    /// MCP-only: fresh status of the calling session's pull/merge request.
    PrStatus,
```

Insert after line 547 (the `}` closing the `Command::ReviewFinish` arm of `build_request`):

```rust
        Command::PrCreate {
            title,
            body,
            draft,
            base,
        } => {
            let mut r = Request::new("pr_create");
            let mut params = serde_json::Map::new();
            params.insert("title".into(), serde_json::Value::String(title.clone()));
            params.insert("body".into(), serde_json::Value::String(body.clone()));
            params.insert("draft".into(), serde_json::Value::Bool(*draft));
            if let Some(base) = base {
                params.insert("base".into(), serde_json::Value::String(base.clone()));
            }
            r.params = Some(serde_json::Value::Object(params));
            r
        }
        Command::PrStatus => {
            let mut r = Request::new("pr_status");
            r.params = Some(serde_json::json!({}));
            r
        }
```

- [ ] **Step 4: Add the MCP tools**

In `AlasCLI/crates/alas/src/mcp.rs`, insert after line 497 (the `}),` closing the `review_finish` definition, before `];`):

```rust
        json!({
            "name": "pr_create",
            "description": "Open a pull/merge request for this worktree's branch and have Alas watch it. Offer this when you've finished a change the user will want reviewed, and call it only after the user agrees or asks. Alas pushes the exact HEAD (never force), creates the PR/MR (or adopts the open one for this branch), and later sends this session a new turn when CI fails, a trusted reviewer leaves a thread, or the branch conflicts with base. Returns JSON with number, url, provider, head_sha, created, uncommitted_changes, and the shepherd's auto_fix/auto_merge settings.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "title": { "type": "string", "description": "PR/MR title, written from the actual diff." },
                    "body": { "type": "string", "description": "PR/MR description, Markdown." },
                    "draft": { "type": "boolean", "description": "Create as a draft. Default: false." },
                    "base": { "type": "string", "description": "Target branch. Default: the worktree's base branch." }
                },
                "required": ["title", "body"]
            }
        }),
        json!({
            "name": "pr_status",
            "description": "Show the pull/merge request Alas watches for this session, else the one for this worktree's branch, as JSON from a fresh provider fetch: state, head_sha, merge_state, check counts with failing checks, actionable threads from trusted reviewers, required reviewers still missing on the current head, and the shepherd's phase and settings. pull_request is null when there is none; shepherd is null when Alas is not watching it.",
            "inputSchema": { "type": "object", "properties": {} }
        }),
```

Insert after line 989 (the `}` closing the `"review_finish"` arm of `command_for_tool`):

```rust
        "pr_create" => Ok(Command::PrCreate {
            title: required_string(args, "title")?,
            body: required_string(args, "body")?,
            draft: optional_bool(args, "draft")?.unwrap_or(false),
            base: optional_string(args, "base"),
        }),
        "pr_status" => Ok(Command::PrStatus),
```

Insert after line 1498 (`Command::ReviewFinish { .. } => "Review finished.".into(),`):

```rust
        Command::PrCreate { .. } | Command::PrStatus => "OK".into(),
```

- [ ] **Step 5: Run the Rust tests to verify they pass**

Run:
```bash
cd AlasCLI && cargo test -p alas mcp::tests && cargo test -p alas-client
```
Expected: both report `test result: ok.`, including `tools_list_returns_all_tools`, `pr_tools_map_to_commands_and_validate_arguments`, `pr_tools_stay_with_delegated_children_and_leave_workspace_checkouts`, `delegated_child_discovery_omits_session_new_but_calls_still_reach_alas`, and `builds_pr_create_and_status_params`.

- [ ] **Step 6: Write the failing preamble tests**

In `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift`, in `rootBuiltIn` (lines 80-92), insert after line 91 (`#expect(!text.contains("Additional MCP servers"))`):

```swift
        #expect(text.contains("call it only after the user agrees or asks"))
        #expect(text.contains("pr_create and pr_status are MCP-only"))
```

Replace the inventory literal at lines 141-151 with:

```swift
        #expect(ACPMCPPromptPreamble.builtInToolNames == [
            "open", "notify",
            "agent_list", "session_list", "session_new", "session_send",
            "session_read", "session_search", "session_wait", "session_interrupt",
            "worktree_list", "worktree_switch", "worktree_new", "worktree_delete",
            "review", "review_comments", "review_reply", "review_resolve",
            "review_comment_add", "review_finish",
            "pr_create", "pr_status",
            "preview_list", "preview_open", "preview_navigate", "preview_reload", "preview_back", "preview_forward",
            "preview_inspect", "preview_capture", "preview_console", "preview_click", "preview_type", "preview_scroll",
            "preview_wait", "preview_cancel",
        ])
```

In `cliMode` (lines 154-166), insert after line 163 (`#expect(!text.contains("MCP server \"alas\""))`):

```swift
        // pr_create/pr_status have no CLI command, so CLI-mode agents aren't told about them.
        #expect(!text.contains("pr_create"))
```

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/ACPMCPPromptPreambleTests test > /tmp/alas-test.log 2>&1; grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log
```
Expected: `** TEST FAILED **`, with `✘` on `rootBuiltIn` and `toolNameInventory`. `cliMode` still passes.

- [ ] **Step 7: Update the preamble**

In `Packages/AlasCore/Sources/AlasCore/ACP/Session/ACPMCPPromptPreamble.swift`, replace lines 67-68:

```swift
        "review", "review_comments", "review_reply", "review_resolve",
        "review_comment_add", "review_finish",
```

with:

```swift
        "review", "review_comments", "review_reply", "review_resolve",
        "review_comment_add", "review_finish",
        "pr_create", "pr_status",
```

Replace lines 173-177:

```swift
            var line = "The MCP server \"alas\" (built-in) drives the Alas UI: "
                + "open (reveal files to the user), notify (macOS notification), "
                + "worktree_list/worktree_switch/worktree_new/worktree_delete, "
                + "review, review_comments/review_reply/review_resolve/"
                + "review_comment_add/review_finish, \(sessionTools)."
```

with:

```swift
            var line = "The MCP server \"alas\" (built-in) drives the Alas UI: "
                + "open (reveal files to the user), notify (macOS notification), "
                + "worktree_list/worktree_switch/worktree_new/worktree_delete, "
                + "review, review_comments/review_reply/review_resolve/"
                + "review_comment_add/review_finish, "
                + "pr_create/pr_status (open a PR/MR for this worktree's branch and have Alas watch it "
                + "until it merges; offer pr_create when you've finished a change the user will want "
                + "reviewed, and call it only after the user agrees or asks), \(sessionTools)."
```

Replace lines 192-193:

```swift
            line += " Prefer these tools when the user asks to open/show files, "
                + "manage worktrees, run or respond to reviews, or be notified."
```

with:

```swift
            line += " Prefer these tools when the user asks to open/show files, "
                + "manage worktrees, run or respond to reviews, open or check a pull request, "
                + "or be notified."
```

Replace lines 199-204:

```swift
            lines.append(
                "If these MCP tools do not appear in your inventory (some harnesses "
                + "restrict MCP servers by policy), the same actions are available via "
                + "the `alas` CLI in your shell: `alas open`, `alas notify`, "
                + "`alas wt …`, `alas review …` (comments/reply/resolve/finish), "
                + "`alas session …`, and `alas preview …`.")
```

with:

```swift
            lines.append(
                "If these MCP tools do not appear in your inventory (some harnesses "
                + "restrict MCP servers by policy), the same actions are available via "
                + "the `alas` CLI in your shell: `alas open`, `alas notify`, "
                + "`alas wt …`, `alas review …` (comments/reply/resolve/finish), "
                + "`alas session …`, and `alas preview …`. "
                + "pr_create and pr_status are MCP-only.")
```

`cliText` (lines 223-304) stays unchanged: CLI-mode agents have no `pr` command.

- [ ] **Step 8: Run the preamble tests to verify they pass**

Run:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/ACPMCPPromptPreambleTests test > /tmp/alas-test.log 2>&1; grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log
```
Expected: `** TEST SUCCEEDED **`, no `✘`. In particular, `delegated` still passes, because the new prose does not contain `session_new`, `session_wait` or `session_interrupt`.

- [ ] **Step 9: Commit**

```bash
git add AlasCLI/crates/alas-client/src/lib.rs \
  AlasCLI/crates/alas/src/mcp.rs \
  Packages/AlasCore/Sources/AlasCore/ACP/Session/ACPMCPPromptPreamble.swift \
  AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift
git commit -m "feat(mcp): expose pr_create and pr_status tools"
```

---

## Group E: Settings and UI (Tasks 13-15)

#### Planning notes for this group

1. `ProjectUpdate` gains `public var shepherd: ProjectShepherdSettings?` (nil leaves the stored value unchanged, an empty value clears it), and `AppState.updateProject(id:name:icon:startupScripts:mcpServers:worktreeBranchTemplate:)` gains a trailing `shepherd: ProjectShepherdSettings? = nil`. Task 4 adds the persisted fields `AppConfig.Changes.shepherd` and `ProjectConfig.shepherd`; Task 13 only adds the update plumbing and UI.
2. The toolbar badge and the drawer chip must render synchronously, and required reviewers need a provider call. So both pass `mergeGatePasses: ReviewReadinessModel.canMergeReviewRequest(snapshot:)` to `ShepherdPresentation.make`, the readiness-only half of the gate. Once the popover has loaded the rules and `headReviewers(for:worktreePath:)`, it uses the policy's exact gate, `ShepherdPolicy.mergeGatePasses(record, ShepherdObservation(...))` from Task 5, and lists missing required reviewers explicitly. `ShepherdPresentation` (Task 7) never includes the attempt count in `phaseLine`, so the popover shows `fixAttempts` / `ShepherdPolicy.maxFixAttempts` on its own line.
3. `ACPShepherdButton` takes `session` as a plain `let`, not `@ObservedObject`, so streaming updates do not re-render the toolbar badge. Only the popover observes `session.transcript` (for the busy check).
4. The button is hidden for Workspace checkout owners (contract), and also for remote worktrees (`worktree.path.isRemoteAlasPath`) and folder projects, which v1 excludes.
5. When the session has no record and `RightPaneStore` has no cached snapshot for the worktree, the popover calls `state.reviewShepherd.fetchSnapshot(worktreePath:baseBranch:)` with `state.shepherdBaseBranch(for:)` so it can show the ahead count, the provider state and an existing unowned PR.
6. "Open in Changes" uses the existing `RightPaneStore.revealAttentionTarget(.reviewRequest(number:), for:)` path (same as notification jumps), which switches the pane to Changes and expands the review drawer.
7. Task 14 also defines two small app-side helpers used by Task 15: `ShepherdBadgeTone.color(theme:) -> Color?` and `ShepherdPhase.isResumable`.
8. The project shepherd section only appears when editing a local git project. Add mode does not show it, because `AppState.addProject` is not part of this plumbing.

### Task 13: PR shepherd settings

Settings > Changes gets a "PR shepherd" group bound to `config.changes.shepherd`. Project Settings > Automation gets a "PR shepherd" section with instructions and a required-reviewers list stored in `ProjectConfig.shepherd`. It also shows "Overridden by .alas/shepherd.md" (or `.local.md`) when the project's main worktree has a shepherd file. No tests: this is view composition and forwarding (AGENTS.md testing policy).

**Files:**
- Modify: `Alas/Sources/Settings/ChangesPane.swift` (insert after line 58, the end of the "Review requests" `SettingsGroup`)
- Modify: `Packages/AlasCore/Sources/AlasCore/Projects/ProjectsManager.swift:4-42` (`ProjectUpdate`) and `:250-262` (`updateProject(id:update:)`)
- Modify: `Alas/Sources/App/AppState.swift:6649-6671` (`updateProject(id:name:icon:startupScripts:mcpServers:worktreeBranchTemplate:)`)
- Modify: `Alas/Sources/Dialogs/NewProjectDialog.swift`: `@State` block (after line 134), `.automation` case (lines 210-211), `.onAppear` (lines 234-238), after `startupScriptsSection` (ends line 886), `populateInitialValues()` (lines 1086-1087), `confirm()` `.edit` case (lines 1387-1395)

**Interfaces:**
- Consumes (Task 4): `AppConfig.Changes.shepherd: ShepherdDefaults` (`autoFix`, `autoMerge`, `archiveAfterMerge`); `ProjectConfig.shepherd: ProjectShepherdSettings?`; `ProjectShepherdSettings(instructions:requiredReviewers:)`, `.isEmpty`.
- Consumes (Task 2, rules): `ShepherdRulesResolver.load(worktreePath: URL, projectSettings: ProjectShepherdSettings?) -> ShepherdRules`; `ShepherdRules.source`, `ShepherdRules.sourceLabel`.
- Consumes (existing): `AppState.bind(_:)` (`Alas/Sources/Settings/SettingsBinding.swift:5`, auto-saves), `SettingsGroup`, `SettingsRow`, `ProjectStartupScriptEditor` (`NewProjectDialog.swift:1553`), `AlasField`, `AlasButton`, `MCPServerIconButton` (`ProjectMCPServerManager.swift:185`).
- Produces: `ProjectUpdate.shepherd: ProjectShepherdSettings?`, `ProjectUpdate.init(..., shepherd: ProjectShepherdSettings? = nil)` on both initializers; `AppState.updateProject(id:name:icon:startupScripts:mcpServers:worktreeBranchTemplate:shepherd:)`.

- [ ] **Step 1: Add the Settings > Changes group**

In `Alas/Sources/Settings/ChangesPane.swift`, insert after line 58 (the closing `}` of `SettingsGroup(title: "Review requests")`), before the blank line and `SettingsGroup(title: "Stacked diffs")`:

```swift

                SettingsGroup(title: "PR shepherd") {
                    SettingsRow(
                        name: "Auto-fix new PRs",
                        desc: "Send failing checks, trusted review threads and merge conflicts back to the session that owns the PR. Each PR can change this from its toolbar button or the review drawer."
                    ) {
                        Toggle("", isOn: state.bind(\.changes.shepherd.autoFix))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    SettingsRow(
                        name: "Auto-merge new PRs",
                        desc: "Squash-merge once checks pass, required reviewers have reviewed the current head, and the head has stayed the same for two polls."
                    ) {
                        Toggle("", isOn: state.bind(\.changes.shepherd.autoMerge))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    SettingsRow(
                        name: "Archive worktree after its PR merges",
                        desc: "Runs once the owning session is idle. Hides the worktree and stops its tabs; nothing on disk is deleted."
                    ) {
                        Toggle("", isOn: state.bind(\.changes.shepherd.archiveAfterMerge))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
```

`state.bind` writes `state.config` and calls `saveConfig()` on every change, the same as the "Enable stacked diffs" toggle at lines 73-79.

- [ ] **Step 2: Add `shepherd` to `ProjectUpdate`**

In `Packages/AlasCore/Sources/AlasCore/Projects/ProjectsManager.swift`, replace lines 4-42 (the whole `ProjectUpdate` struct) with:

```swift
public struct ProjectUpdate: Equatable, Sendable {
    public var name: String
    public var icon: ProjectIcon
    public var startupScripts: ProjectStartupScripts = .defaults
    /// `nil` means this update does not change the project's MCP configuration.
    public var mcpServers: [ProjectMCPServer]?
    /// Nil leaves naming unchanged; a blank string resets to the global default.
    public var worktreeBranchTemplate: String?
    /// Nil leaves the PR shepherd rules unchanged; empty settings clear them.
    public var shepherd: ProjectShepherdSettings?

    public init(
        name: String,
        icon: ProjectIcon,
        startupScripts: ProjectStartupScripts = .defaults,
        mcpServers: [ProjectMCPServer]? = nil,
        worktreeBranchTemplate: String? = nil,
        shepherd: ProjectShepherdSettings? = nil
    ) {
        self.name = name
        self.icon = icon
        self.startupScripts = startupScripts
        self.mcpServers = mcpServers
        self.worktreeBranchTemplate = worktreeBranchTemplate
        self.shepherd = shepherd
    }

    public init(
        name: String,
        color: String,
        startupScripts: ProjectStartupScripts = .defaults,
        mcpServers: [ProjectMCPServer]? = nil,
        worktreeBranchTemplate: String? = nil,
        shepherd: ProjectShepherdSettings? = nil
    ) {
        self.init(
            name: name,
            icon: ProjectIcon.default(color: color),
            startupScripts: startupScripts,
            mcpServers: mcpServers,
            worktreeBranchTemplate: worktreeBranchTemplate,
            shepherd: shepherd
        )
    }
}
```

- [ ] **Step 3: Apply it in `ProjectsManager.updateProject`**

In the same file, replace lines 259-262 (the `worktreeBranchTemplate` block and the method's closing brace):

```swift
        if let template = update.worktreeBranchTemplate {
            projects[idx].worktreeBranchTemplate = WorktreeBranchName.normalizedTemplate(template)
        }
    }
```

with:

```swift
        if let template = update.worktreeBranchTemplate {
            projects[idx].worktreeBranchTemplate = WorktreeBranchName.normalizedTemplate(template)
        }
        if let shepherd = update.shepherd {
            projects[idx].shepherd = shepherd.isEmpty ? nil : shepherd
        }
    }
```

The other `ProjectUpdate` caller (`AppState.swift:1383-1390`, agent snapping) passes no `shepherd`, so it leaves the rules alone.

- [ ] **Step 4: Thread it through `AppState.updateProject`**

In `Alas/Sources/App/AppState.swift`, replace lines 6649-6671 with:

```swift
    func updateProject(
        id: String,
        name: String,
        icon: ProjectIcon,
        startupScripts: ProjectStartupScripts,
        mcpServers: [ProjectMCPServer],
        worktreeBranchTemplate: String? = nil,
        shepherd: ProjectShepherdSettings? = nil
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        projectsManager.updateProject(
            id: id,
            update: ProjectUpdate(
                name: trimmedName,
                icon: icon,
                startupScripts: startupScripts,
                mcpServers: mcpServers,
                worktreeBranchTemplate: worktreeBranchTemplate,
                shepherd: shepherd
            )
        )
        saveProjects()
    }
```

The `color:` overload at lines 6673-6687 and the test callers in `AlasTests/AppStateRunScriptCreationTests.swift:245,253` keep compiling through the default.

- [ ] **Step 5: Add dialog state**

In `Alas/Sources/Dialogs/NewProjectDialog.swift`, insert after line 134 (`@State private var mcpServers: [ProjectMCPServer] = []`):

```swift
    @State private var shepherdInstructions: String = ""
    @State private var shepherdRequiredReviewers: [String] = []
    /// `.alas/shepherd.local.md` or `.alas/shepherd.md` when the project's
    /// main worktree has one; that file wins over these settings.
    @State private var shepherdRulesOverride: String?
```

- [ ] **Step 6: Mount the section in the Automation tab**

Replace lines 210-211:

```swift
                        case .automation:
                            startupScriptsSection
```

with:

```swift
                        case .automation:
                            startupScriptsSection
                            shepherdSection
```

- [ ] **Step 7: Load the override label on appear**

Replace lines 234-238:

```swift
        .onAppear {
            populateInitialValues()
            Task { await loadAvatarPresetIfAvailable() }
            refreshRepoHookPresentations()
        }
```

with:

```swift
        .onAppear {
            populateInitialValues()
            Task { await loadAvatarPresetIfAvailable() }
            refreshRepoHookPresentations()
            loadShepherdRulesOverride()
        }
```

- [ ] **Step 8: Add the section view and helpers**

Insert after line 886 (the closing `}` of `startupScriptsSection`), before `private func repoHookScriptMode(for:)`:

```swift

    /// Per-project PR shepherd rules. Shown only when editing a local git
    /// project: the shepherd does not run for folders or remote worktrees.
    @ViewBuilder
    private var shepherdSection: some View {
        if case .edit(let project) = mode, !project.isFolder, project.host == nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("PR shepherd")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                Text("Instructions and required reviewers Alas uses when it fixes or merges this project's pull requests.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-muted"))
                if let shepherdRulesOverride {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10.5))
                        Text("Overridden by \(shepherdRulesOverride)")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(theme.color("warn"))
                    .help("The repository file wins over these settings. Remove or rename it to use them.")
                    .accessibilityElement(children: .combine)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Instructions")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                    ProjectStartupScriptEditor(text: $shepherdInstructions, minHeight: 60)
                        .accessibilityLabel("PR shepherd instructions")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Required reviewers")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                    Text("Logins that must review the current head before auto-merge.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-muted"))
                    ForEach(shepherdRequiredReviewers.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            AlasField(
                                text: shepherdReviewerBinding(at: index),
                                placeholder: "chatgpt-codex-connector",
                                monospaced: true
                            )
                            MCPServerIconButton(icon: "trash", tooltip: "Remove reviewer") {
                                guard shepherdRequiredReviewers.indices.contains(index) else { return }
                                shepherdRequiredReviewers.remove(at: index)
                            }
                        }
                    }
                    AlasButton(title: "Add Reviewer", icon: "plus", style: .subtle) {
                        shepherdRequiredReviewers.append("")
                    }
                }
            }
        }
    }

    private func shepherdReviewerBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { shepherdRequiredReviewers.indices.contains(index) ? shepherdRequiredReviewers[index] : "" },
            set: { value in
                guard shepherdRequiredReviewers.indices.contains(index) else { return }
                shepherdRequiredReviewers[index] = value
            }
        )
    }

    /// Trimmed instructions, and reviewers without blanks, a leading `@`, or
    /// case-insensitive duplicates. Empty settings clear the stored value.
    private var draftShepherdSettings: ProjectShepherdSettings {
        var seen = Set<String>()
        let reviewers = shepherdRequiredReviewers.compactMap { raw -> String? in
            var login = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if login.hasPrefix("@") { login.removeFirst() }
            guard !login.isEmpty, seen.insert(login.lowercased()).inserted else { return nil }
            return login
        }
        return ProjectShepherdSettings(
            instructions: shepherdInstructions.trimmingCharacters(in: .whitespacesAndNewlines),
            requiredReviewers: reviewers
        )
    }

    /// Reads only the repo files (no project settings), so any non-`none`
    /// source means a file overrides this section.
    private func loadShepherdRulesOverride() {
        guard case .edit(let project) = mode, !project.isFolder, project.host == nil else { return }
        let root = URL(fileURLWithPath: project.path, isDirectory: true)
        Task {
            let rules = await Task.detached {
                ShepherdRulesResolver.load(worktreePath: root, projectSettings: nil)
            }.value
            shepherdRulesOverride = rules.source == .none ? nil : rules.sourceLabel
        }
    }
```

- [ ] **Step 9: Populate and save**

In `populateInitialValues()`, replace lines 1086-1087:

```swift
            agentSettings = project.startupScripts
            mcpServers = project.mcpServers
```

with:

```swift
            agentSettings = project.startupScripts
            mcpServers = project.mcpServers
            shepherdInstructions = project.shepherd?.instructions ?? ""
            shepherdRequiredReviewers = project.shepherd?.requiredReviewers ?? []
```

In `confirm()`, replace lines 1387-1395:

```swift
        case .edit(let project):
            state.updateProject(
                id: project.id,
                name: name,
                icon: draftIcon,
                startupScripts: draftStartupScripts,
                mcpServers: mcpServers,
                worktreeBranchTemplate: worktreeBranchTemplate
            )
```

with:

```swift
        case .edit(let project):
            state.updateProject(
                id: project.id,
                name: name,
                icon: draftIcon,
                startupScripts: draftStartupScripts,
                mcpServers: mcpServers,
                worktreeBranchTemplate: worktreeBranchTemplate,
                shepherd: draftShepherdSettings
            )
```

- [ ] **Step 10: Build**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build`
Expected: exits 0 with no errors.

Run: `swift build --package-path Packages/AlasCore`
Expected: `Build complete!`

- [ ] **Step 11: Manual check**

1. Launch the built app. Settings > Changes shows "PR shepherd" between "Review requests" and "Stacked diffs" with Auto-fix on and the other two off. Flip Auto-merge, quit, relaunch: it stays on (`config.json` has `changes.shepherd.autoMerge: true`).
2. Edit a local git project > Automation. Below "Startup scripts" there is a "PR shepherd" section. Type instructions, add reviewers `@Foo`, `foo`, and an empty row, then save. Reopen: instructions are trimmed, and the reviewers list is `Foo`.
3. Clear the instructions and remove every reviewer, save: `projects.json` no longer has a `shepherd` key for the project.
4. Create `.alas/shepherd.md` in the project root and reopen the dialog: the section shows "Overridden by .alas/shepherd.md". Add `.alas/shepherd.local.md`: it shows "Overridden by .alas/shepherd.local.md". Delete both: the line goes away.
5. Edit a folder project or an SSH project: no "PR shepherd" section.

- [ ] **Step 12: Commit**

```bash
git add Alas/Sources/Settings/ChangesPane.swift Alas/Sources/Dialogs/NewProjectDialog.swift Alas/Sources/App/AppState.swift Packages/AlasCore/Sources/AlasCore/Projects/ProjectsManager.swift
git commit -m "feat(settings): add PR shepherd defaults and project rules"
```

### Task 14: PR shepherd toolbar button

`ACPShepherdButton` sits in the ACP toolbar's right-hand group, directly left of the minimap toggle. It is built the same way as `ACPSessionsButton`, with a dot badge colored by `ShepherdPresentation` tone. Its 300 pt popover shows the bound PR (header, checks, threads, required reviewers, shepherd line, toggles, actions), or Create PR/MR or adopt-PR actions when the session shepherds nothing. No tests: view composition only.

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPShepherdButton.swift`
- Modify: `Alas/Sources/ACP/UI/ACPToolbar.swift`: insert between line 111 (end of the plugin-commands `if`) and line 112 (minimap `ToolbarBtn`); add a property after `isWorkspaceCheckoutOwner` (lines 135-138)
- Modify: `Alas.xcodeproj/project.pbxproj` (regenerated by `xcodegen`)

**Interfaces:**
- Consumes (AlasCore shepherd tasks): `ShepherdRecord` (`id`, `sessionID`, `remote`, `branch`, `baseBranch`, `autoFix`, `autoMerge`, `phase`, `fixAttempts`, `lastSeenHeadSHA`); `ShepherdRecordID` (`requestNumber`, `providerKind`); `ShepherdPhase.isTerminal`; `ShepherdBadgeTone`; `ShepherdPresentation.make(record:request:mergeGatePasses:)` (`tone`, `tooltip`, `phaseLine`); `ShepherdPolicy.maxFixAttempts`; `ShepherdRules` (`.none`, `requiredReviewers`, `sourceLabel`); `ShepherdRulesResolver.load(worktreePath:projectSettings:)`; `ReviewThread.headAuthorTrust`, `ReviewAuthorTrust.trusted`; `ProjectConfig.shepherd`.
- Consumes (`ReviewShepherd`, `@MainActor @Observable`): `records`, `snapshots`, `record(forSession:)`, `record(forWorktree:)`, `setAutoFix(_:for:)`, `setAutoMerge(_:for:)`, `resume(_:)`, `stopShepherding(_:)`, `fetchSnapshot(worktreePath:baseBranch:) async -> ReviewLoopSnapshot?`, `headReviewers(for:worktreePath:) async -> Set<String>?`.
- Consumes (`AppState+Shepherd.swift`): `var reviewShepherd: ReviewShepherd`, `requestShepherdCreatePR(sessionID:worktree:)`, `shepherdWithSession(_:worktree:request:) async`, `shepherdBaseBranch(for:) -> String`.
- Consumes (Task 5, policy): `ShepherdObservation(snapshot:headReviewers:session:rules:now:)`, `ShepherdSessionState` (`.idle`, `.busy`), `ShepherdPolicy.mergeGatePasses(_:_:) -> Bool`.
- Consumes (existing): `RightPaneStore.activeState(worktreeId:) -> RightPaneState?` (`RightPaneStore.swift:498`), `RightPaneStore.revealAttentionTarget(_:for:) async -> Bool` (`RightPaneStore.swift:38`), `AttentionJumpTarget.reviewRequest(number: Int?)`, `ReviewReadinessModel.canMergeReviewRequest(snapshot:)`, `CIStatusStrip(checks:)` (`Alas/Sources/Center/Review/CIStatusStrip.swift:3-5`), `ACPTranscript.streamingState`, `URL.isRemoteAlasPath`, `AlasButton`, `.toolbarControl`.
- Produces: `struct ACPShepherdButton: View { init(session: ACPSession, worktree: Worktree, state: AppState) }`; `@MainActor struct ShepherdSessionContext`; `extension ShepherdBadgeTone { func color(theme: Theme) -> Color? }`; `extension ShepherdPhase { var isResumable: Bool }`.

- [ ] **Step 1: Create the button, popover and shared helpers**

Create `Alas/Sources/ACP/UI/ACPShepherdButton.swift`:

```swift
import SwiftUI

/// PR shepherd control in the ACP toolbar. Built like `ACPSessionsButton`:
/// an icon-only popover button whose dot badge shows the state of the
/// pull/merge request this session shepherds.
///
/// `session` is a plain reference on purpose: the badge reads only the
/// shepherd records and the cached review snapshot, so streaming updates
/// must not re-render the toolbar. The popover observes the transcript.
struct ACPShepherdButton: View {
    let session: ACPSession
    let worktree: Worktree
    let state: AppState
    @Environment(\.theme) private var theme
    @State private var open = false
    @State private var hovering = false

    /// Lit while the pointer is over the button or its popover is up, so the
    /// trigger stays visibly tied to the surface it opened.
    private var isLit: Bool { hovering || open }

    var body: some View {
        let presentation = ShepherdSessionContext(sessionID: session.id, worktree: worktree, state: state).presentation
        let tooltip = presentation.tooltip
        Button {
            open.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color(isLit ? "fg" : "fg-muted"))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(theme.color("bg-3").opacity(isLit ? 1 : 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.color("line"), lineWidth: 0.5))
                if let badge = presentation.tone.color(theme: theme) {
                    Circle()
                        .fill(badge)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(theme.color("bg-2"), lineWidth: 1))
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.toolbarControl)
        .onHover { hovering = $0 }
        .help(tooltip)
        .accessibilityLabel("PR shepherd")
        .accessibilityValue(tooltip)
        .popover(isPresented: $open, arrowEdge: .top) {
            ShepherdPopover(
                session: session,
                transcript: session.transcript,
                worktree: worktree,
                state: state,
                onClose: { open = false }
            )
        }
    }
}

/// What the toolbar knows about one session's PR: the session's own record,
/// another session's live record for the same worktree, and the freshest
/// snapshot (the shepherd's, else the Changes pane's cached one, else a
/// fetch the popover made).
@MainActor
struct ShepherdSessionContext {
    let record: ShepherdRecord?
    /// A non-terminal record owned by a different session in this worktree.
    let otherRecord: ShepherdRecord?
    let snapshot: ReviewLoopSnapshot?

    init(sessionID: String, worktree: Worktree, state: AppState, fetched: ReviewLoopSnapshot? = nil) {
        let shepherd = state.reviewShepherd
        let own = shepherd.record(forSession: sessionID)
        let worktreeRecord = shepherd.record(forWorktree: worktree.id)
        record = own
        if own == nil, let worktreeRecord, worktreeRecord.sessionID != sessionID, !worktreeRecord.phase.isTerminal {
            otherRecord = worktreeRecord
        } else {
            otherRecord = nil
        }
        if let bound = own ?? otherRecord, let shepherdSnapshot = shepherd.snapshots[bound.id] {
            snapshot = shepherdSnapshot
        } else {
            snapshot = state.rightPaneStore.activeState(worktreeId: worktree.id)?.reviewLoop.snapshot ?? fetched
        }
    }

    /// The request this context describes. A cached pane snapshot for a
    /// different PR than the bound one is ignored.
    var request: ReviewRequest? {
        guard let request = snapshot?.reviewRequest else { return nil }
        guard let bound = record ?? otherRecord else { return request }
        return request.number == bound.id.requestNumber && request.provider == bound.id.providerKind ? request : nil
    }

    /// The readiness half of the merge gate. Required reviewers need a
    /// provider call, so the popover reports them separately.
    var mergeGatePasses: Bool {
        guard let snapshot, request != nil else { return false }
        return ReviewReadinessModel.canMergeReviewRequest(snapshot: snapshot)
    }

    var presentation: ShepherdPresentation {
        ShepherdPresentation.make(record: record, request: request, mergeGatePasses: mergeGatePasses)
    }
}

extension ShepherdBadgeTone {
    /// Badge and chip tint shared by the toolbar button and the Changes
    /// drawer. `nil` means no badge.
    func color(theme: Theme) -> Color? {
        switch self {
        case .none: nil
        case .working: theme.color("warn")
        case .ready: theme.color("add")
        case .attention: theme.color("del")
        case .merged: Color(nsColor: .systemPurple)
        }
    }
}

extension ShepherdPhase {
    /// Escalated and paused records wait for the user to press Resume.
    var isResumable: Bool {
        switch self {
        case .escalated, .paused: true
        default: false
        }
    }
}

private struct ShepherdPopover: View {
    let session: ACPSession
    @ObservedObject var transcript: ACPTranscript
    let worktree: Worktree
    let state: AppState
    let onClose: () -> Void
    @Environment(\.theme) private var theme
    @State private var fetchedSnapshot: ReviewLoopSnapshot?
    @State private var isLoading = true
    @State private var rules: ShepherdRules = .none
    @State private var headReviewers: Set<String>?
    @State private var reviewersChecked = false

    /// Narrower than the composer options popover (164 pt): the toggle
    /// titles here are long and the popover is 300 pt wide.
    private let controlWidth: CGFloat = 64

    private var isBusy: Bool { transcript.streamingState != .idle }

    var body: some View {
        let context = ShepherdSessionContext(
            sessionID: session.id, worktree: worktree, state: state, fetched: fetchedSnapshot
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let record = context.record {
                    boundContent(record: record, context: context)
                } else {
                    unboundContent(context: context)
                }
            }
        }
        .frame(width: 300)
        .frame(maxHeight: 520)
        .background(theme.color("bg-1"))
        .task(id: session.id) { await load() }
    }

    // MARK: Loading

    private func load() async {
        let settings = state.projectsManager.projects.first(where: { $0.id == worktree.projectId })?.shepherd
        let root = worktree.path
        rules = await Task.detached {
            ShepherdRulesResolver.load(worktreePath: root, projectSettings: settings)
        }.value
        let context = ShepherdSessionContext(sessionID: session.id, worktree: worktree, state: state)
        if context.snapshot == nil {
            fetchedSnapshot = await state.reviewShepherd.fetchSnapshot(
                worktreePath: worktree.path,
                baseBranch: state.shepherdBaseBranch(for: worktree)
            )
        }
        isLoading = false
        let current = ShepherdSessionContext(
            sessionID: session.id, worktree: worktree, state: state, fetched: fetchedSnapshot
        )
        guard !rules.requiredReviewers.isEmpty, let snapshot = current.snapshot, current.request != nil else { return }
        headReviewers = await state.reviewShepherd.headReviewers(for: snapshot, worktreePath: worktree.path)
        reviewersChecked = true
    }

    // MARK: Bound

    @ViewBuilder
    private func boundContent(record: ShepherdRecord, context: ShepherdSessionContext) -> some View {
        let request = context.request
        let presentation = exactPresentation(record: record, context: context)
        header(record: record, request: request)
        Divider().background(theme.color("line"))
        if let request {
            if request.checks.isEmpty {
                infoLine("No CI checks", systemImage: "checkmark.seal")
            } else {
                CIStatusStrip(checks: request.checks)
            }
            reviewLines(request: request)
        } else {
            infoLine("Waiting for the first status check.", systemImage: "hourglass")
        }
        Divider().background(theme.color("line"))
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "pawprint")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(presentation.tone.color(theme: theme) ?? theme.color("fg-muted"))
                Text(presentation.phaseLine)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Text("Attempt \(record.fixAttempts) of \(ShepherdPolicy.maxFixAttempts) · Rules: \(rules.sourceLabel ?? "none")")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.color("fg-muted"))
            toggleRow(
                "Auto-fix CI, conflicts and reviews",
                isEnabled: record.autoFix,
                icon: "wrench.and.screwdriver",
                isDisabled: record.phase.isTerminal,
                help: "Send failing checks, trusted review threads and conflicts to this session"
            ) {
                state.reviewShepherd.setAutoFix(!record.autoFix, for: record.id)
            }
            toggleRow(
                "Auto-merge when ready (squash)",
                isEnabled: record.autoMerge,
                icon: "arrow.triangle.merge",
                isDisabled: record.phase.isTerminal,
                help: "Squash-merge when the merge gate passes"
            ) {
                state.reviewShepherd.setAutoMerge(!record.autoMerge, for: record.id)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        Divider().background(theme.color("line"))
        footer(record: record)
    }

    /// Once `load()` has the rules and head reviewers, use the policy's exact
    /// merge gate (required reviewers and head stability included) instead of
    /// the readiness-only approximation the toolbar badge uses. Until the
    /// reviewers arrive, `headReviewers` is nil and the gate fails closed when
    /// the rules require any.
    private func exactPresentation(record: ShepherdRecord, context: ShepherdSessionContext) -> ShepherdPresentation {
        guard !isLoading, let snapshot = context.snapshot, context.request != nil else { return context.presentation }
        let observation = ShepherdObservation(
            snapshot: snapshot,
            headReviewers: headReviewers,
            session: isBusy ? .busy : .idle,
            rules: rules,
            now: Date()
        )
        return ShepherdPresentation.make(
            record: record,
            request: context.request,
            mergeGatePasses: ShepherdPolicy.mergeGatePasses(record, observation)
        )
    }

    private func header(record: ShepherdRecord, request: ReviewRequest?) -> some View {
        let kind = record.id.providerKind
        let number = "\(kind.reviewRequestNumberPrefix)\(record.id.requestNumber)"
        let url = request?.url ?? record.remote.reviewRequestURL(number: record.id.requestNumber)
        let shortSHA = (request?.headSHA ?? record.lastSeenHeadSHA).map { String($0.prefix(7)) }
        let parts: [String?] = ["\(record.branch) → \(record.baseBranch)", shortSHA, kind.displayName]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.color("accent"))
                Text(request?.title ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .foregroundStyle(theme.color("fg-muted"))
                .help("Open \(kind.reviewRequestLabel) \(number) in the browser")
                .accessibilityLabel("Open \(kind.reviewRequestLabel) \(number) in the browser")
            }
            Text(parts.compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func reviewLines(request: ReviewRequest) -> some View {
        let openThreads = request.threads.filter(\.isActionable)
        let trusted = openThreads.filter { $0.headAuthorTrust == .trusted }.count
        let threadText = openThreads.isEmpty
            ? "No open review threads"
            : "\(openThreads.count) open thread\(openThreads.count == 1 ? "" : "s"), \(trusted) from trusted reviewers"
        return VStack(alignment: .leading, spacing: 4) {
            Text(threadText)
            if let reviewersText = requiredReviewersText {
                Text(reviewersText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.color("fg-dim"))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var requiredReviewersText: String? {
        guard !rules.requiredReviewers.isEmpty else { return nil }
        guard reviewersChecked else { return "Checking required reviewers…" }
        guard let headReviewers else { return "Couldn't check required reviewers." }
        let missing = rules.requiredReviewers.filter { !headReviewers.contains($0.lowercased()) }
        if missing.isEmpty { return "Required reviewers have reviewed this head." }
        return "Waiting on this head: " + missing.map { "@\($0)" }.joined(separator: ", ")
    }

    private func footer(record: ShepherdRecord) -> some View {
        let label = record.id.providerKind.reviewRequestLabel
        return HStack(spacing: 8) {
            Button("Open in Changes") {
                onClose()
                Task {
                    let revealed = await state.rightPaneStore.revealAttentionTarget(
                        .reviewRequest(number: record.id.requestNumber),
                        for: worktree
                    )
                    if !revealed { state.config.rightPaneVisible = true }
                }
            }
            .help("Show this \(label) in the Changes review drawer")
            if record.phase.isResumable {
                Button("Resume") {
                    state.reviewShepherd.resume(record.id)
                }
                .help("Watch again and reset the fix attempt count")
            }
            Spacer(minLength: 0)
            Button("Stop shepherding") {
                state.reviewShepherd.stopShepherding(record.id)
            }
            .help("Stop watching. The \(label) stays open.")
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(12)
    }

    // MARK: Unbound

    @ViewBuilder
    private func unboundContent(context: ShepherdSessionContext) -> some View {
        let snapshot = context.snapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-muted"))
                Text(worktree.branch)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let local = snapshot?.local {
                    Text("\(local.aheadCommitCount) ahead of \(local.baseBranch)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.color("fg-muted"))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            if let other = context.otherRecord {
                adoptRow(
                    text: "\(other.id.providerKind.reviewRequestLabel) \(other.id.providerKind.reviewRequestNumberPrefix)\(other.id.requestNumber) is shepherded by another session.",
                    buttonTitle: "Move to this session",
                    request: context.request
                )
            } else if let request = context.request, request.state == .open {
                let number = "\(request.provider.reviewRequestNumberPrefix)\(request.number)"
                adoptRow(
                    text: "\(request.provider.reviewRequestLabel) \(number) is open: \(request.title)",
                    buttonTitle: "Shepherd \(number) from this session",
                    request: request
                )
            } else {
                createRow(kind: snapshot?.remote?.kind, reason: Self.createDisabledReason(
                    isBusy: isBusy, snapshot: snapshot, isLoading: isLoading
                ))
            }
        }
        .padding(12)
    }

    private func adoptRow(text: String, buttonTitle: String, request: ReviewRequest?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-dim"))
                .fixedSize(horizontal: false, vertical: true)
            AlasButton(title: buttonTitle, style: .primary) {
                guard let request else { return }
                onClose()
                Task { await state.shepherdWithSession(session.id, worktree: worktree, request: request) }
            }
            .disabled(request == nil)
            .opacity(request == nil ? 0.5 : 1)
            .help(request == nil ? "Waiting for the PR status" : "Bind this PR to this session and send it the current problems")
            .accessibilityLabel(buttonTitle)
        }
    }

    private func createRow(kind: CodeHostKind?, reason: String?) -> some View {
        let title = kind?.createReviewRequestTitle ?? "Create PR"
        return VStack(alignment: .leading, spacing: 6) {
            AlasButton(title: title, icon: "plus", style: .primary) {
                onClose()
                state.requestShepherdCreatePR(sessionID: session.id, worktree: worktree)
            }
            .disabled(reason != nil)
            .opacity(reason == nil ? 1 : 0.5)
            .help(reason ?? "Ask this session to open a \(kind?.reviewRequestLabel ?? "PR") and shepherd it")
            .accessibilityLabel(title)
            Text(reason ?? "The agent writes the title and description from the diff, then calls pr_create.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.color(reason == nil ? "fg-muted" : "warn"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Why Create PR/MR is unavailable, or nil when it can be pressed.
    private static func createDisabledReason(isBusy: Bool, snapshot: ReviewLoopSnapshot?, isLoading: Bool) -> String? {
        if isBusy { return "Wait for the current turn to finish." }
        guard let snapshot else {
            return isLoading ? "Checking the code host…" : "Couldn't read this branch's code host."
        }
        guard let remote = snapshot.remote else { return "This branch has no GitHub or GitLab remote." }
        let cli = remote.kind == .github ? "gh" : "glab"
        if !snapshot.providerAvailable { return "\(cli) isn't installed. Install it with brew install \(cli)." }
        if !snapshot.providerAuthenticated { return "\(cli) isn't signed in. Run \(cli) auth login." }
        return nil
    }

    // MARK: Pieces

    private func infoLine(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(theme.color("fg-dim"))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// Same construction as the ACP composer options popover's `toggleRow`
    /// (`ACPComposerShell.swift:996-1033`), with an accent "on" state.
    private func toggleRow(
        _ title: String,
        isEnabled: Bool,
        icon: String,
        isDisabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let foreground = isEnabled ? theme.color("accent") : theme.color("fg-muted")
        let background = isEnabled ? theme.color("accent").opacity(0.18) : theme.color("bg-3").opacity(0.7)
        let border = isEnabled ? theme.color("accent").opacity(0.5) : theme.color("line")
        return HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .foregroundStyle(theme.color("fg"))
            Spacer(minLength: 8)
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text(isEnabled ? "On" : "Off")
                    Spacer(minLength: 0)
                }
                .foregroundStyle(foreground)
                .padding(.horizontal, 8)
                .frame(width: controlWidth, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(background))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(isEnabled ? "On" : "Off")")
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.5 : 1)
            .help(help)
        }
        .frame(height: 24)
        .font(.system(size: 11, weight: .medium))
    }
}
```

- [ ] **Step 2: Insert the button into `ACPToolbar`**

In `Alas/Sources/ACP/UI/ACPToolbar.swift`, insert after line 111 (the closing `}` of `if !isWorkspaceCheckoutOwner { … }` around plugin commands) and before line 112 (`ToolbarBtn(`):

```swift
            if showsShepherdButton {
                ACPShepherdButton(session: session, worktree: worktree, state: state)
            }
```

Then insert after line 138 (the closing `}` of `private var isWorkspaceCheckoutOwner`):

```swift

    /// v1 shepherds local git worktrees only: no Workspace checkouts,
    /// remote worktrees, or folder projects.
    private var showsShepherdButton: Bool {
        guard !isWorkspaceCheckoutOwner, !worktree.path.isRemoteAlasPath else { return false }
        return state.projectsManager.projects.first(where: { $0.id == worktree.projectId })?.isFolder != true
    }
```

- [ ] **Step 3: Regenerate the Xcode project**

Run: `xcodegen`
Expected: `Created project at …/Alas.xcodeproj`, and `git status --short Alas.xcodeproj` shows `project.pbxproj` modified.

- [ ] **Step 4: Build**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build`
Expected: exits 0 with no errors.

- [ ] **Step 5: Manual check**

1. Open an ACP session in a local git worktree on a feature branch with one commit ahead and no PR. The toolbar shows the `arrow.triangle.pull` button directly left of the minimap toggle, with no badge. Hovering lights it and shows the presentation tooltip ("Not shepherded").
2. Open the popover: it shows the branch, "1 ahead of main", and an enabled "Create PR" (GitHub) or "Create MR" (GitLab). While the agent is mid-turn the button is disabled with "Wait for the current turn to finish." With `gh` logged out it says "gh isn't signed in. Run gh auth login."
3. Press Create PR on an idle session: the popover closes and the session receives the create prompt. After `pr_create` binds the PR, the badge turns `warn` while checks run, and the popover shows `#N title`, `branch → main · abc1234 · GitHub`, the CI strip, the thread line, "Attempt 0 of 3 · Rules: none", and both toggles.
4. Flip Auto-merge in the popover, then open the Changes drawer (Task 15) or reopen the popover: the value persists.
5. On a branch whose open PR has no record, the popover offers "Shepherd #N from this session". Pressing it binds the PR, and the session receives the context prompt.
6. Add `.alas/shepherd.md` with `required_reviewers: [someone]`, reopen the popover: "Rules: .alas/shepherd.md" and "Waiting on this head: @someone".
7. "Open in Changes" switches the right pane to Changes and expands the review drawer. "Stop shepherding" removes the badge. For an escalated record, "Resume" appears, and pressing it returns the badge to `warn`.
8. A Workspace checkout session, an SSH worktree session and a folder project session show no shepherd button.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPShepherdButton.swift Alas/Sources/ACP/UI/ACPToolbar.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): add PR shepherd toolbar button"
```

### Task 15: Shepherd block in the Changes review drawer

`ReviewLoopDrawer` gets an optional `ReviewShepherdDrawerModel` that `ChangesTabView` builds from `AppState`. The collapsed row adds a `pawprint` chip tinted by the shepherd tone. The expanded body shows a `ReviewShepherdBlock` above the actions: owning session with Jump, the phase line, both toggles, Resume/Stop, and a "Move to…" menu. An unbound open PR gets a "Shepherd with…" menu listing the worktree's sessions plus "New session". No tests: view composition and forwarding.

**Files:**
- Create: `Alas/Sources/Integrations/CodeHost/ReviewShepherdBlock.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/ReviewLoopDrawer.swift`: line 7 (inputs), lines 56-60 (chips `HStack`), insert after line 149 (end of `blockingText`), add a function after `chipView` (ends line 222, before `labelColor` at 224)
- Modify: `Alas/Sources/Right/ChangesTabView.swift`: lines 132-139 (`ReviewLoopDrawer` mount); insert after line 159 (end of `isRevealingAttentionReview`)
- Modify: `Alas.xcodeproj/project.pbxproj` (regenerated by `xcodegen`)

**Interfaces:**
- Consumes (Task 14): `extension ShepherdBadgeTone { func color(theme: Theme) -> Color? }`, `extension ShepherdPhase { var isResumable: Bool }` (both in `Alas/Sources/ACP/UI/ACPShepherdButton.swift`).
- Consumes (AlasCore shepherd tasks): `ShepherdRecord` (`id`, `sessionID`, `autoFix`, `autoMerge`, `phase`), `ShepherdRecordID` (`requestNumber`, `providerKind`), `ShepherdPhase.isTerminal`, `ShepherdPresentation.make(record:request:mergeGatePasses:)` (`tone`, `tooltip`, `phaseLine`), `ReviewShepherd.record(forWorktree:)`, `.snapshots`, `.setAutoFix(_:for:)`, `.setAutoMerge(_:for:)`, `.resume(_:)`, `.stopShepherding(_:)`.
- Consumes (`AppState+Shepherd.swift`): `reviewShepherd`, `shepherdSessionCandidates(worktree:) -> [ACPSessionRow]` (non-archived, sorted by `updatedAt` desc), `shepherdWithSession(_:worktree:request:) async`, `shepherdWithNewSession(worktree:request:) async`.
- Consumes (existing): `AppState.openExistingACPSession(sessionId:worktree:activate:storedTitle:) async` (`AppState.swift:14491-14493`), `AppState.agent(id:) -> AgentDefinition?` (`AppState.swift:1130`), `AgentDefinition.displayName`, `ACPSessionRow` (`id`, `agentId`, `title`), `RightPaneState.worktree`, `.isFolder`, `.reviewLoop`, `ReviewReadinessModel.canMergeReviewRequest(snapshot:)`, `URL.isRemoteAlasPath`.
- Produces: `struct ReviewShepherdDrawerModel` (below), `struct ReviewShepherdBlock: View { init(model:) }`, `ReviewLoopDrawer.shepherd: ReviewShepherdDrawerModel?` (default `nil`).

- [ ] **Step 1: Create the model and block view**

Create `Alas/Sources/Integrations/CodeHost/ReviewShepherdBlock.swift`:

```swift
import SwiftUI

/// What the Changes review drawer shows about the PR shepherd. Built by
/// `ChangesTabView` from `AppState` so the drawer itself does no app lookups.
struct ReviewShepherdDrawerModel {
    struct Candidate: Identifiable, Equatable {
        let id: String
        let title: String
        let agentName: String?

        var menuTitle: String {
            agentName.map { "\(title) · \($0)" } ?? title
        }
    }

    /// Nil when the open PR is not shepherded yet.
    let record: ShepherdRecord?
    let presentation: ShepherdPresentation
    /// Nil when the owning session is archived or no longer exists.
    let ownerTitle: String?
    let ownerAgent: String?
    /// Sessions that can take the PR, newest `updatedAt` first, excluding the owner.
    let candidates: [Candidate]
    let setAutoFix: @MainActor (Bool) -> Void
    let setAutoMerge: @MainActor (Bool) -> Void
    let jump: @MainActor () -> Void
    let stop: @MainActor () -> Void
    let resume: @MainActor () -> Void
    let shepherdWith: @MainActor (_ sessionID: String) -> Void
    let shepherdWithNewSession: @MainActor () -> Void
}

/// Shepherd section inside the expanded review drawer, above the actions.
struct ReviewShepherdBlock: View {
    let model: ReviewShepherdDrawerModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let record = model.record {
                bound(record)
            } else {
                unbound
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.color("bg-2").opacity(0.48))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PR shepherd")
    }

    @ViewBuilder
    private func bound(_ record: ShepherdRecord) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "pawprint")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(model.presentation.tone.color(theme: theme) ?? theme.color("fg-faint"))
            Text(model.ownerTitle ?? "Session archived or missing")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(theme.color(model.ownerTitle == nil ? "fg-dim" : "fg"))
                .lineLimit(1)
                .truncationMode(.tail)
            if let agent = model.ownerAgent {
                Text(agent)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if model.ownerTitle != nil {
                actionButton("Jump", systemImage: "arrow.up.forward.square", help: "Focus the session that owns this PR") {
                    model.jump()
                }
            }
        }

        Text(model.presentation.phaseLine)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-dim"))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

        toggle(
            "Auto-fix CI, conflicts and reviews",
            isOn: record.autoFix,
            isDisabled: record.phase.isTerminal,
            set: model.setAutoFix
        )
        toggle(
            "Auto-merge when ready (squash)",
            isOn: record.autoMerge,
            isDisabled: record.phase.isTerminal,
            set: model.setAutoMerge
        )

        HStack(spacing: 8) {
            if record.phase.isResumable {
                actionButton("Resume", systemImage: "play", help: "Watch again and reset the fix attempt count") {
                    model.resume()
                }
            }
            actionButton("Stop shepherding", systemImage: "stop", help: "Stop watching. The PR stays open.") {
                model.stop()
            }
            Spacer(minLength: 0)
            if !record.phase.isTerminal {
                sessionMenu(title: "Move to…", help: "Hand this PR to another session")
            }
        }
    }

    private var unbound: some View {
        HStack(spacing: 6) {
            Image(systemName: "pawprint")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.color("fg-faint"))
            Text("Not shepherded")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            Spacer(minLength: 6)
            sessionMenu(title: "Shepherd with…", help: "Have a session fix and merge this PR")
        }
    }

    private func toggle(
        _ title: String,
        isOn: Bool,
        isDisabled: Bool,
        set: @escaping @MainActor (Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { set($0) })) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.color("fg"))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(isDisabled)
        .help(title)
    }

    /// Sessions sorted by `updatedAt` (the history list sorts by
    /// `lastOpenedAt`, so the order here is explicit), then "New session".
    private func sessionMenu(title: String, help: String) -> some View {
        Menu {
            ForEach(model.candidates) { candidate in
                Button(candidate.menuTitle) {
                    model.shepherdWith(candidate.id)
                }
            }
            if !model.candidates.isEmpty {
                Divider()
            }
            Button("New session") {
                model.shepherdWithNewSession()
            }
        } label: {
            Label(title, systemImage: "pawprint")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help(help)
        .accessibilityLabel(title)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(theme.color("fg-muted"))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(theme.color("bg-3").opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(title)
    }
}
```

- [ ] **Step 2: Add the drawer input**

In `Alas/Sources/Integrations/CodeHost/ReviewLoopDrawer.swift`, replace line 7:

```swift
    var onRevealReviewRequest: (Int) -> Void = { _ in }
```

with:

```swift
    var onRevealReviewRequest: (Int) -> Void = { _ in }
    var shepherd: ReviewShepherdDrawerModel? = nil
```

- [ ] **Step 3: Add the collapsed-row chip**

Replace lines 56-60:

```swift
            HStack(spacing: 5) {
                ForEach(model.chips) { chip in
                    chipView(chip)
                }
            }
```

with:

```swift
            HStack(spacing: 5) {
                if let shepherd, shepherd.record != nil {
                    shepherdChip(shepherd)
                }
                ForEach(model.chips) { chip in
                    chipView(chip)
                }
            }
```

Insert after line 222 (the closing `}` of `chipView(_:)`), before `private func labelColor(for:)`:

```swift

    /// Shown only while a record exists. Same shape as `chipView`, tinted by
    /// the toolbar badge tone.
    private func shepherdChip(_ shepherd: ReviewShepherdDrawerModel) -> some View {
        let color = shepherd.presentation.tone.color(theme: theme) ?? theme.color("fg-faint")
        return Image(systemName: "pawprint")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(color.opacity(0.34), lineWidth: 0.75)
            )
            .help(shepherd.presentation.tooltip)
            .accessibilityLabel("PR shepherd")
            .accessibilityValue(shepherd.presentation.tooltip)
    }
```

- [ ] **Step 4: Mount the block above the actions**

Insert after line 149 (the closing `}` of `if let blockingText = model.blockingText { … }`), before the blank line and `if !model.actions.isEmpty {`:

```swift

            if let shepherd {
                ReviewShepherdBlock(model: shepherd)
            }
```

- [ ] **Step 5: Build the model in `ChangesTabView`**

In `Alas/Sources/Right/ChangesTabView.swift`, replace lines 132-139:

```swift
                ReviewLoopDrawer(
                    state: rps.reviewLoop,
                    canOpenAgentHandoff: rps.canOpenReviewLoopHandoff(appState: appState),
                    onAction: { action in rps.handleReviewReadinessAction(action, appState: appState) },
                    onRevealReviewRequest: { number in
                        appState.acknowledgeAttentionSurface(worktreeID: rps.worktree.id, target: .reviewRequest(number: number))
                    }
                )
```

with:

```swift
                ReviewLoopDrawer(
                    state: rps.reviewLoop,
                    canOpenAgentHandoff: rps.canOpenReviewLoopHandoff(appState: appState),
                    onAction: { action in rps.handleReviewReadinessAction(action, appState: appState) },
                    onRevealReviewRequest: { number in
                        appState.acknowledgeAttentionSurface(worktreeID: rps.worktree.id, target: .reviewRequest(number: number))
                    },
                    shepherd: shepherdDrawerModel
                )
```

Insert after line 159 (the closing `}` of `private var isRevealingAttentionReview`):

```swift

    /// The shepherd record for this worktree's PR, or an unbound open PR the
    /// user can hand to a session. Nil for folders, remote worktrees, and
    /// branches with neither. A record for a different PR than the pane's
    /// current one (an older merged PR on a reused branch) is ignored.
    private var shepherdDrawerModel: ReviewShepherdDrawerModel? {
        let worktree = rps.worktree
        guard !rps.isFolder, !worktree.path.isRemoteAlasPath else { return nil }
        let shepherd = appState.reviewShepherd
        let paneSnapshot = rps.reviewLoop.snapshot
        let paneRequest = paneSnapshot?.reviewRequest
        let record: ShepherdRecord? = shepherd.record(forWorktree: worktree.id).flatMap { bound in
            guard let paneRequest else { return bound }
            return bound.id.requestNumber == paneRequest.number && bound.id.providerKind == paneRequest.provider
                ? bound : nil
        }
        let snapshot = record.flatMap { shepherd.snapshots[$0.id] } ?? paneSnapshot
        let request = snapshot?.reviewRequest
        guard record != nil || request?.state == .open else { return nil }

        let rows = appState.shepherdSessionCandidates(worktree: worktree)
        let owner = record.flatMap { bound in rows.first { $0.id == bound.sessionID } }
        let candidates = rows
            .filter { $0.id != record?.sessionID }
            .map {
                ReviewShepherdDrawerModel.Candidate(
                    id: $0.id,
                    title: $0.title,
                    agentName: appState.agent(id: $0.agentId)?.displayName
                )
            }
        let gatePasses = snapshot.map { ReviewReadinessModel.canMergeReviewRequest(snapshot: $0) } ?? false
        let recordID = record?.id
        let ownerSessionID = record?.sessionID

        return ReviewShepherdDrawerModel(
            record: record,
            presentation: ShepherdPresentation.make(record: record, request: request, mergeGatePasses: gatePasses),
            ownerTitle: owner?.title,
            ownerAgent: owner.flatMap { appState.agent(id: $0.agentId)?.displayName },
            candidates: candidates,
            setAutoFix: { on in
                guard let recordID else { return }
                appState.reviewShepherd.setAutoFix(on, for: recordID)
            },
            setAutoMerge: { on in
                guard let recordID else { return }
                appState.reviewShepherd.setAutoMerge(on, for: recordID)
            },
            jump: {
                guard let ownerSessionID else { return }
                Task { await appState.openExistingACPSession(sessionId: ownerSessionID, worktree: worktree) }
            },
            stop: {
                guard let recordID else { return }
                appState.reviewShepherd.stopShepherding(recordID)
            },
            resume: {
                guard let recordID else { return }
                appState.reviewShepherd.resume(recordID)
            },
            shepherdWith: { sessionID in
                guard let request else { return }
                Task { await appState.shepherdWithSession(sessionID, worktree: worktree, request: request) }
            },
            shepherdWithNewSession: {
                guard let request else { return }
                Task { await appState.shepherdWithNewSession(worktree: worktree, request: request) }
            }
        )
    }
```

- [ ] **Step 6: Regenerate the Xcode project**

Run: `xcodegen`
Expected: `Created project at …/Alas.xcodeproj`, and `git status --short Alas.xcodeproj` shows `project.pbxproj` modified.

- [ ] **Step 7: Build**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build`
Expected: exits 0 with no errors.

- [ ] **Step 8: Manual check**

1. Open the Changes tab for a worktree whose branch has an open PR with no record. The collapsed drawer row has no pawprint chip. Expand it: above the actions there is "Not shepherded" and a "Shepherd with…" menu that lists the worktree's non-archived sessions, newest `updatedAt` first, with the agent name, then a divider and "New session".
2. Pick a session: the record appears, the collapsed row shows a pawprint chip tinted `warn` while checks run, and the block shows the session title, agent, Jump, the phase line and both toggles. The chosen session receives the context prompt.
3. Press Jump: the owning session's tab is focused (or reopened from history if it was closed).
4. Toggle Auto-merge in the drawer and open the toolbar popover (Task 14) for the owning session: it shows the same value.
5. Use "Move to…" > another session: the owner line changes, and the new session receives the context prompt.
6. Force an escalation (for example, three failed fix rounds). The chip turns `del`, and "Resume" appears. Press it: the chip returns to `warn`.
7. "Stop shepherding" removes the chip and returns the block to "Not shepherded".
8. "New session" opens a new ACP tab with the default agent and the context prompt, and the drawer then shows that session as owner.
9. A branch with no PR shows no shepherd block. A folder project or an SSH worktree shows no shepherd block.

- [ ] **Step 9: Commit**

```bash
git add Alas/Sources/Integrations/CodeHost/ReviewShepherdBlock.swift Alas/Sources/Integrations/CodeHost/ReviewLoopDrawer.swift Alas/Sources/Right/ChangesTabView.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(changes): show PR shepherd in the review drawer"
```

---

## Group F: Documentation and end-to-end verification

### Task 16: Changelog, manual test script and smoke runs

**Files:**
- Modify: `CHANGELOG.md:7-8` (the empty `## [Unreleased]` section)
- Modify: `docs/manual-test.md:253` (Review Loop Drawer step 7) and insert a new section after line 262 (end of `### Draft PR generation`, before `## Peer pairing by approval`)

**Interfaces:**
- Consumes: everything from Tasks 1-15.
- Produces: user-facing documentation and recorded smoke evidence.

- [ ] **Step 1: Add the changelog entry**

In `CHANGELOG.md`, replace the empty Unreleased section:

```markdown
## [Unreleased]

### ✨ Features

- Shepherd pull and merge requests from the agent session that opened them: the new `pr_create` and `pr_status` MCP tools, background watching of CI, trusted review threads and merge conflicts on GitHub and GitLab, fix turns queued into the owning session, optional auto-merge through the existing merge gate, project shepherd rules from `.alas/shepherd.md`, and a PR button in the agent toolbar.
```

- [ ] **Step 2: Update the review loop manual test**

In `docs/manual-test.md`, replace line 253:

```markdown
7. Confirm merge, comment posting, review-thread resolution, force-push, and editing-agent runs are not executed without explicit user action, unless PR shepherd auto-fix or auto-merge is turned on for that PR.
```

- [ ] **Step 3: Add the PR shepherd manual test section**

Insert after the `### Draft PR generation` list (after line 262):

```markdown
## PR shepherd

Use a disposable branch on a GitHub repository you can push to, with CI that runs on pull requests, and an ACP agent that supports MCP.

1. In an agent session, make a small change, commit it, and ask the agent to open a PR. Confirm it offers first and calls `pr_create` only after you agree.
2. Confirm the toolbar PR button shows an amber badge while checks run, and its popover lists the checks, the shepherd phase, and both toggles.
3. Push a commit that breaks a test. Confirm that once CI fails, a prompt captioned "Alas PR shepherd" appears in the same session with the failing check and its log tail, and that the agent pushes a fix.
4. Leave a review comment from a second account with write access. Confirm the session receives it as a fix turn while CI is still running.
5. Leave a comment from your own account. Confirm it does not trigger a fix turn.
6. Turn auto-fix off in the popover, break CI again, and confirm no fix turn arrives and the badge turns red.
7. Create `.alas/shepherd.md` with `required_reviewers: [some-bot]` frontmatter, turn auto-merge on, and confirm the PR does not merge while that reviewer has not reviewed the current head, and the popover lists them as missing.
8. Remove the required reviewer and confirm the PR is squash-merged after two stable polls, the badge turns purple, and a macOS notification arrives.
9. Open the Changes tab for a worktree whose PR was created from the Changes drawer. Confirm the drawer offers "Shepherd with…", binding a session sends it a context prompt, and the toolbar of that session shows the badge.
10. Archive the owning session of a shepherded PR with failing CI. Confirm a notification says the shepherd needs you and the drawer shows the escalation.
11. Quit Alas mid-fix and relaunch. Confirm the record resumes and the phase moves on once the agent's push lands.
```

- [ ] **Step 4: Run every focused suite touched by this plan**

```bash
swift test --package-path Packages/AlasCore
cd AlasCLI && cargo test -p alas mcp::tests && cargo test -p alas-client && cd ..
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing AlasTests/GitHubCLIProviderTests \
  -only-testing AlasTests/GitLabCLIProviderTests \
  -only-testing AlasTests/ACPDelegatedOutcomeTextTests \
  -only-testing AlasTests/AlasCLIRequestTests \
  -only-testing AlasTests/ACPMCPPromptPreambleTests \
  test > /tmp/alas-test.log 2>&1
grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|Test run with' /tmp/alas-test.log
```

Expected: AlasCore and both cargo runs pass; the xcodebuild log shows `** TEST SUCCEEDED **`, one `◇ Suite … started` line for each of the five suites, and no `✘`.

- [ ] **Step 5: Smoke run 1, GitHub create and fix**

Build and run the app. On a throwaway branch of `mrmans0n/alas`, follow manual test steps 1-3. Record the PR number, the head SHA after the agent's fix, and the time from CI failure to the shepherd prompt. Close the PR without merging when done.

- [ ] **Step 6: Smoke run 2, Codex required reviewer**

Still on a throwaway PR in `mrmans0n/alas`, create `.alas/shepherd.local.md`:

```markdown
---
required_reviewers: [chatgpt-codex-connector]
---
Codex reviews every push within 5 to 10 minutes. Act on its findings without waiting for CI. CI takes about 50 minutes and a push cancels the run in flight, so batch fixes into one push.
```

Turn auto-merge on. Before Codex posts on the current head, call `pr_status` from the session and confirm `missing_required_reviewers` lists `chatgpt-codex-connector`. After Codex posts, confirm it disappears. This checks the spec's open question: whether Codex leaves a formal review per head (matched by commit oid) or only a comment (matched by the comment cutoff in Task 3). Record which path matched. Turn auto-merge off and close the PR before CI finishes, so nothing is merged.

- [ ] **Step 7: Smoke run 3, GitLab**

On a GitLab test project with a pipeline, run `pr_create`, then `pr_status`, then break the pipeline and confirm one fix cycle reaches the session. Leave a thread from a Developer-level member and confirm it is classified as trusted in `pr_status`.

- [ ] **Step 8: Remove smoke artifacts**

Delete `.alas/shepherd.local.md`, close any remaining throwaway PRs/MRs, and delete their remote branches.

- [ ] **Step 9: Commit**

```bash
git add CHANGELOG.md docs/manual-test.md
git commit -m "docs: document the PR shepherd"
```

Report exactly which suites ran and passed, which smoke runs were performed and their recorded results, and whether the app build ran. Do not claim CI status.
