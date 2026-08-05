# Provider-Neutral Mission Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any HTTP or HTTPS work-item link create a Mission while preserving rich GitHub/GitLab behavior and keeping source identity independent from repository legs.

**Architecture:** Introduce a provider-neutral Mission source model and adapter registry, with GitHub/GitLab adapters wrapping the existing CLI issue providers and a no-network manual fallback. Persist one source per Mission, resolve repository locators separately, and keep review discovery entirely leg/Git-remote based.

**Tech Stack:** Swift 5.9+, SwiftUI, Observation, Swift Testing, SQLite, existing `gh`/`glab` command providers, XcodeGen.

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Use “work item” in user-facing creation copy and “Mission source” in domain names.
- Accept only absolute HTTP or HTTPS links plus the existing selected-project short issue reference.
- Never fetch arbitrary webpage metadata.
- Require exactly one primary repository during creation; additional repositories use the existing Add Repository flow.
- Manual source URLs and stable identities are immutable after creation; manual title and context remain editable.
- Keep PR/MR identity, discovery, and readiness on Mission legs and their Git remotes.
- Do not add Jira or Linear API clients in this implementation.
- Tests use Swift Testing (`import Testing`), not XCTest.
- Run `rtk xcodegen` after adding source or test files and commit the regenerated `Alas.xcodeproj` changes.
- Do not add agent attribution to code, documentation, commits, or pull requests.

## File Responsibility Map

- `Alas/Sources/Missions/MissionModels.swift`: provider-neutral source value types, Mission aggregate/draft ownership, and temporary migration shims.
- `Alas/Sources/Missions/MissionSourceProvider.swift`: source adapter protocol, registry, GitHub/GitLab adapter bridge, and manual adapter.
- `Alas/Sources/Missions/MissionSourceResolver.swift`: source resolution plus configured-project matching.
- `Alas/Sources/Missions/MissionPromptBuilder.swift`: provider-neutral primary-leg branch and prompt defaults.
- `Alas/Sources/Missions/MissionLegPromptBuilder.swift`: provider-neutral additional-leg prompt context.
- `Alas/Sources/Missions/MissionStore.swift`: schema v6 migration, source persistence, duplicate identity, refresh replacement, and manual edits.
- `Alas/Sources/Missions/MissionPersistence.swift`: async facade for the renamed source store APIs.
- `Alas/Sources/Missions/NewMissionDialog.swift`: work-item entry, manual fallback, explicit repository selection, and confirmation UI.
- `Alas/Sources/Missions/MissionCoordinator.swift`: create/retry using `MissionDraft.source`.
- `Alas/Sources/Missions/MissionController.swift`: source refresh/edit orchestration and source-independent review matching.
- `Alas/Sources/App/AppState.swift`: live adapter wiring, code-host source refresh, and leg-based review remote selection.
- `Alas/Sources/Missions/MissionTabView.swift`: neutral source presentation and edit/refresh actions.
- `Alas/Sources/Missions/MissionSidebarSection.swift`: neutral source labels in Mission rows.
- `Alas/Sources/Missions/EditMissionSourceDialog.swift`: focused manual title/context editor.
- `AlasTests/Missions/*`: domain, resolver, migration, dialog, controller, prompt, presentation, and integration regressions.

---

### Task 1: Introduce Provider-Neutral Source Types and Text Builders

**Files:**
- Modify: `Alas/Sources/Missions/MissionModels.swift`
- Modify: `Alas/Sources/Missions/MissionPromptBuilder.swift`
- Modify: `Alas/Sources/Missions/MissionLegPromptBuilder.swift`
- Modify: `AlasTests/Missions/MissionTestFixtures.swift`
- Modify: `AlasTests/Missions/MissionPromptBuilderTests.swift`
- Modify: `AlasTests/Missions/MissionLegPromptBuilderTests.swift`

**Interfaces:**
- Produces: `MissionSourceProviderID`, `MissionSourceIdentity`, `MissionSourceContentOrigin`, `MissionSourceState`, `MissionRepositoryLocator`, and `MissionSourceSnapshot`.
- Produces: `MissionBranchName.make(displayReference:title:prefix:)`, `MissionPromptBuilder.build(source:)`, and `MissionLegPromptBuilder.build(source:existingLegs:existingProjectNames:projectName:branch:instructions:)`.
- Keeps: temporary issue-to-source conversion helpers so the project compiles before persistence and callers migrate.

- [ ] **Step 1: Write failing provider-neutral prompt and branch tests**

Add fixtures and assertions with this exact behavior:

```swift
@Test func manualSourceBranchUsesOnlyPrefixAndTitle() {
    #expect(MissionBranchName.make(
        displayReference: nil,
        title: "Fix login timeout",
        prefix: "nacho/"
    ) == "nacho/fix-login-timeout")
}

@Test func manualSourcePromptUsesWorkItemTerminology() {
    let source = MissionFixtures.manualSource(
        url: "https://jira.example.com/browse/ALAS-123?view=full",
        title: "Fix login timeout",
        body: "Sessions expire during refresh."
    )
    let prompt = MissionPromptBuilder.build(source: source)

    #expect(prompt.contains("Implement the linked work item."))
    #expect(prompt.contains("## Work item context"))
    #expect(prompt.contains("**Source:** jira.example.com"))
    #expect(prompt.contains("**URL:** https://jira.example.com/browse/ALAS-123?view=full"))
    #expect(!prompt.localizedCaseInsensitiveContains("issue #"))
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
rtk xcodebuild -derivedDataPath /private/tmp/alas-mission-source-task1 -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -only-testing:AlasTests/MissionPromptBuilderTests -only-testing:AlasTests/MissionLegPromptBuilderTests test
```

Expected: compilation fails because `MissionSourceSnapshot`, `manualSource`, and the provider-neutral builder overloads do not exist.

- [ ] **Step 3: Add the source value types and builder APIs**

Add these final shapes to `MissionModels.swift`:

```swift
struct MissionSourceProviderID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    static let github = Self(rawValue: "github")
    static let gitlab = Self(rawValue: "gitlab")
    static let manual = Self(rawValue: "manual")
}

struct MissionSourceIdentity: Codable, Hashable, Sendable {
    let providerID: MissionSourceProviderID
    let stableID: String
}

enum MissionSourceContentOrigin: String, Codable, Equatable, Sendable {
    case provider
    case manual
}

enum MissionSourceState: String, Codable, Equatable, Sendable {
    case open
    case closed
    case unknown
}

struct MissionRepositoryLocator: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let host: String
    let repositorySlug: String
}

struct MissionSourceSnapshot: Codable, Equatable, Sendable {
    let identity: MissionSourceIdentity
    let canonicalURL: URL
    let providerLabel: String
    let displayReference: String?
    let repositoryLocator: MissionRepositoryLocator?
    let title: String
    let body: String
    let state: MissionSourceState
    let labels: [String]
    let assignees: [String]
    let providerUpdatedAt: Date?
    let capturedAt: Date
    var refreshError: String?
    let contentOrigin: MissionSourceContentOrigin
    let isEditable: Bool
    let isRefreshable: Bool
}
```

Implement `MissionSourceSnapshot.init(issue:)` and `MissionIssueSnapshot.init?(source:)` as temporary migration shims. For a code-host issue, use the lowercased `host/repositorySlug#number` as `stableID`, preserve the repository locator, and use `#number` as `displayReference`.

Change branch construction so a non-empty display reference is sanitized and prepended to the title slug, while a nil reference uses only the title slug. Keep the existing `make(issueNumber:title:prefix:)` overload delegating to the new API until all callers migrate.

Build prompt headers from `providerLabel`, optional `displayReference`, canonical URL, title, and optional metadata. Provider sources may say `Implement GitHub work item #1842.`; manual sources use `Implement the linked work item.` Both use `## Work item context`.

- [ ] **Step 4: Run the focused tests and existing prompt regressions**

Run the Task 1 command again.

Expected: PASS, including existing sanitization, stable-manifest, and additional-leg ordering tests after updating their expected copy to “work item.”

- [ ] **Step 5: Commit the domain/text slice**

```bash
git add Alas/Sources/Missions/MissionModels.swift Alas/Sources/Missions/MissionPromptBuilder.swift Alas/Sources/Missions/MissionLegPromptBuilder.swift AlasTests/Missions/MissionTestFixtures.swift AlasTests/Missions/MissionPromptBuilderTests.swift AlasTests/Missions/MissionLegPromptBuilderTests.swift
git commit -m "refactor(missions): add provider-neutral source model"
```

---

### Task 2: Resolve Code-Host and Arbitrary Work-Item Links Through Adapters

**Files:**
- Create: `Alas/Sources/Missions/MissionSourceProvider.swift`
- Create: `Alas/Sources/Missions/MissionSourceResolver.swift`
- Create: `AlasTests/Missions/MissionSourceResolverTests.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/CodeHostIssueProvider.swift`
- Modify: `Alas/Sources/Missions/MissionIssueResolver.swift`
- Modify: `AlasTests/Missions/MissionIssueResolverTests.swift`

**Interfaces:**
- Consumes: Task 1 source types and `MissionSourceSnapshot.init(issue:)`.
- Produces: `MissionSourceReference`, `ResolvedMissionSource`, `MissionSourceResolutionFailure`, `MissionSourceProviding`, `MissionSourceProviderRegistry`, and `MissionSourceResolver`.
- Keeps: GitHub/GitLab structured CLI behavior behind `CodeHostMissionSourceProvider`.

- [ ] **Step 1: Write failing resolver tests for manual URLs, normalization, and fallback**

Create tests covering these exact outcomes:

```swift
@Test func arbitraryURLBecomesManualWithoutCallingCodeHostProviders() async throws {
    let recorder = SourceProviderRecorder()
    let resolver = MissionSourceResolver(environment: Self.environment(recorder: recorder))

    let result = try await resolver.resolve(
        "HTTPS://Jira.Example.com:443/browse/ALAS-123?view=full#activity"
    )

    #expect(result.source.identity == .init(
        providerID: .manual,
        stableID: "https://jira.example.com/browse/ALAS-123?view=full"
    ))
    #expect(result.source.canonicalURL.absoluteString == "https://jira.example.com/browse/ALAS-123?view=full")
    #expect(result.source.contentOrigin == .manual)
    #expect(result.repositoryLocator == nil)
    #expect(result.candidateProjectIDs == ["project-a", "project-b"])
    #expect(result.selectedProjectID == "project-b")
    #expect(recorder.resolveCount == 0)
}

@Test func recognizedProviderFailureCarriesManualFallback() async {
    let resolver = MissionSourceResolver(environment: Self.environment(
        providerError: CodeHostProviderError.unauthenticated("github.com")
    ))

    do {
        _ = try await resolver.resolve("https://github.com/acme/alas/issues/42")
        Issue.record("Expected adapter fallback")
    } catch let error as MissionSourceResolutionFailure {
        #expect(error.errorDescription == "Authentication is required for github.com.")
        #expect(error.fallback.source.contentOrigin == .manual)
        #expect(error.fallback.source.identity.providerID == .github)
        #expect(error.fallback.repositoryLocator?.repositorySlug == "acme/alas")
        #expect(error.fallback.source.isRefreshable)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
```

Also assert that fragments are removed, default ports are removed, path/query are preserved, `file:` and relative links are rejected, GitLab subgroups still parse, repository redirects still select the canonical configured clone, and `#42` still requires a selected code-host project.

- [ ] **Step 2: Run resolver tests and verify they fail**

Run:

```bash
rtk xcodebuild -derivedDataPath /private/tmp/alas-mission-source-task2 -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -only-testing:AlasTests/MissionSourceResolverTests -only-testing:AlasTests/MissionIssueResolverTests test
```

Expected: the new test target cannot compile because the adapter and resolver types are absent.

- [ ] **Step 3: Implement the adapter boundary and manual fallback**

Use these public shapes:

```swift
enum MissionSourceReference: Equatable, Sendable {
    case short(number: Int)
    case url(URL)
}

struct ResolvedMissionSource: Equatable, Sendable {
    var source: MissionSourceSnapshot
    let repositoryLocator: MissionRepositoryLocator?
    let candidateProjectIDs: [String]
    let selectedProjectID: String?
}

struct MissionSourceResolutionFailure: LocalizedError, Sendable {
    let fallback: ResolvedMissionSource
    let message: String
    var errorDescription: String? { message }
}

protocol MissionSourceProviding: Sendable {
    var id: MissionSourceProviderID { get }
    func recognizes(_ reference: MissionSourceReference) -> Bool
    func resolve(
        _ reference: MissionSourceReference,
        projects: [ProjectConfig],
        selectedProjectID: String?,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> ResolvedMissionSource
    func refresh(
        _ source: MissionSourceSnapshot,
        project: ProjectConfig,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote]
    ) async throws -> MissionSourceSnapshot
}
```

`MissionSourceProviderRegistry.resolve` tries GitHub and GitLab before manual. `ManualMissionSourceProvider` accepts only absolute HTTP/HTTPS URLs, canonicalizes them with `URLComponents`, creates an empty-title editable snapshot, returns all configured project IDs, and performs no remote/provider call. `CodeHostMissionSourceProvider` reuses current URL/short-reference matching and `CodeHostIssueProviding`, converts the issue snapshot through Task 1, and throws `MissionSourceResolutionFailure` with an adapter-derived identity/locator when fetching fails.

Retain `MissionIssueResolver` temporarily as a wrapper used by old tests/callers; route its parsing helpers through the new code rather than maintaining a second parser.

- [ ] **Step 4: Regenerate the project and run resolver tests**

```bash
rtk xcodegen
rtk xcodebuild -derivedDataPath /private/tmp/alas-mission-source-task2 -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -only-testing:AlasTests/MissionSourceResolverTests -only-testing:AlasTests/MissionIssueResolverTests test
```

Expected: PASS; the recorder proves manual resolution caused zero metadata requests.

- [ ] **Step 5: Commit adapters and resolution**

```bash
git add project.yml Alas.xcodeproj Alas/Sources/Missions/MissionSourceProvider.swift Alas/Sources/Missions/MissionSourceResolver.swift Alas/Sources/Integrations/CodeHost/CodeHostIssueProvider.swift Alas/Sources/Missions/MissionIssueResolver.swift AlasTests/Missions/MissionSourceResolverTests.swift AlasTests/Missions/MissionIssueResolverTests.swift
git commit -m "feat(missions): resolve arbitrary work item links"
```

---

### Task 3: Migrate Mission Persistence to One Provider-Neutral Source

**Files:**
- Modify: `Alas/Sources/Missions/MissionModels.swift`
- Modify: `Alas/Sources/Missions/MissionStore.swift`
- Modify: `Alas/Sources/Missions/MissionPersistence.swift`
- Modify: `AlasTests/Missions/MissionStoreTests.swift`
- Modify: `AlasTests/Missions/MissionTestFixtures.swift`

**Interfaces:**
- Consumes: `MissionSourceSnapshot` and opaque `MissionSourceIdentity` from Task 1.
- Produces: `MissionAggregate.source`, `MissionDraft.source`, `MissionStore.activeMission(sourceIdentity:)`, `replaceSourceSnapshot`, `updateSourceRefreshError`, and `updateManualSourceContent`.
- Provides: a temporary `MissionAggregate.issue` compatibility accessor only for migrated code-host fixtures; remove it in Task 7.

- [ ] **Step 1: Add failing schema-v5 migration and manual-source persistence tests**

Add a v5 fixture database, open it with the new target schema, and assert:

```swift
@Test func migratesV5IssueRowsToProviderNeutralSources() throws {
    let path = temporaryPath()
    do { _ = try MissionStoreTestDatabase.v5(path: URL(fileURLWithPath: path)) }

    let store = try MissionStore(path: path)
    let aggregate = try #require(try store.aggregate(id: .init(rawValue: "mission-1")))
    let tableNames = try store.db.query(
        "SELECT name FROM sqlite_master WHERE type = 'table'"
    ).compactMap { $0["name"] as? String }
    let missionColumns = try store.db.query("PRAGMA table_info(missions)")
        .compactMap { $0["name"] as? String }

    #expect(try store.currentSchemaVersion() == 6)
    #expect(aggregate.source.identity == .init(
        providerID: .github,
        stableID: "github.com/acme/alas#42"
    ))
    #expect(aggregate.source.repositoryLocator?.repositorySlug == "acme/alas")
    #expect(aggregate.source.displayReference == "#42")
    #expect(!missionColumns.contains("source_kind"))
    #expect(tableNames.contains("mission_sources"))
    #expect(!tableNames.contains("mission_issue_sources"))
}

@Test func manualSourceRoundTripsAndRejectsAnActiveDuplicate() throws {
    let store = try MissionStore(path: temporaryPath())
    let first = MissionFixtures.creatingMission(source: MissionFixtures.manualSource())
    let second = MissionFixtures.creatingMission(id: "mission-2", source: first.source)

    try store.insert(first)
    #expect(throws: MissionStore.Error.duplicateActiveSourceIdentity) {
        try store.insert(second)
    }
    #expect(try store.aggregate(id: first.mission.id)?.source == first.source)
}
```

Query `sqlite_master` rather than selecting removed columns/tables when asserting removal, so the test distinguishes “does not exist” from “has no rows.” Add rollback coverage by constructing a malformed v5 source row and asserting schema version/data remain at v5 after migration throws.

- [ ] **Step 2: Run store tests and verify they fail**

```bash
rtk xcodebuild -derivedDataPath /private/tmp/alas-mission-source-task3 -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -only-testing:AlasTests/MissionStoreTests test
```

Expected: FAIL because schema version 6, `mission_sources`, and source persistence APIs do not exist.

- [ ] **Step 3: Implement schema v6 and source APIs**

Set `targetSchemaVersion = 6`. In a single immediate transaction, rename the v5 `missions`, `mission_legs`, and `mission_events` tables to `_v5` staging names; recreate all three with their current v5 columns/indexes but without `missions.source_kind`; copy their rows; create and populate `mission_sources`; validate counts and relationships; then drop the staged tables and `mission_issue_sources`. Rebuilding the child tables is required so their foreign keys target the new `missions` table rather than the staged parent. Use this logical source-table shape:

```sql
CREATE TABLE mission_sources (
  mission_id TEXT PRIMARY KEY REFERENCES missions(id) ON DELETE CASCADE,
  provider_id TEXT NOT NULL,
  stable_id TEXT NOT NULL,
  canonical_url TEXT NOT NULL,
  provider_label TEXT NOT NULL,
  display_reference TEXT,
  repository_locator BLOB,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  provider_state TEXT NOT NULL,
  labels BLOB NOT NULL,
  assignees BLOB NOT NULL,
  provider_updated_at REAL,
  captured_at REAL NOT NULL,
  refresh_error TEXT,
  content_origin TEXT NOT NULL,
  is_editable INTEGER NOT NULL,
  is_refreshable INTEGER NOT NULL
);
CREATE INDEX mission_sources_identity_idx
ON mission_sources(provider_id, stable_id);
```

Use `provider_id + stable_id` for duplicate lookup. Rename store errors to `duplicateActiveSourceIdentity` and `sourceIdentityChanged`. `replaceSourceSnapshot` may change a GitHub/GitLab stable ID only when the provider ID is unchanged and the repository locator confirms the same host/issue redirect rules; migrate explicit duplicate cohorts and linked review repository identities atomically. `updateManualSourceContent` must require `isEditable`, preserve identity/URL/capabilities, update Mission title, and append a `.sourceRefreshed` event with user-facing text `Source context updated.`

Update `MissionPersistence` with these exact facade signatures:

```swift
func activeMission(sourceIdentity: MissionSourceIdentity) throws -> MissionAggregate?
func replaceSourceSnapshot(
    missionID: MissionID,
    snapshot: MissionSourceSnapshot,
    event: MissionEvent
) throws -> [MissionID]
func updateSourceRefreshError(
    missionID: MissionID,
    refreshError: String,
    event: MissionEvent
) throws
func updateManualSourceContent(
    missionID: MissionID,
    title: String,
    body: String,
    event: MissionEvent
) throws
```

- [ ] **Step 4: Run all MissionStore tests**

Run the Task 3 command again.

Expected: PASS for v1-v5 migrations, manual round-trip, duplicate rules, refresh replacement, repository rename cohorts, manual edits, and rollback.

- [ ] **Step 5: Commit the persistence migration**

```bash
git add Alas/Sources/Missions/MissionModels.swift Alas/Sources/Missions/MissionStore.swift Alas/Sources/Missions/MissionPersistence.swift AlasTests/Missions/MissionStoreTests.swift AlasTests/Missions/MissionTestFixtures.swift
git commit -m "refactor(missions): persist provider-neutral sources"
```

---

### Task 4: Create Missions From Manual or Adapter-Backed Sources

**Files:**
- Modify: `Alas/Sources/Missions/NewMissionDialog.swift`
- Modify: `Alas/Sources/Missions/MissionCoordinator.swift`
- Modify: `Alas/Sources/Missions/AddMissionLegModel.swift`
- Modify: `Alas/Sources/Missions/AddMissionLegDialog.swift`
- Modify: `AlasTests/Missions/NewMissionDialogTests.swift`
- Modify: `AlasTests/Missions/MissionCoordinatorTests.swift`
- Modify: `AlasTests/Missions/AddMissionLegModelTests.swift`
- Modify: `AlasTests/Missions/AddMissionLegDialogTests.swift`

**Interfaces:**
- Consumes: `ResolvedMissionSource` from Task 2 and `MissionDraft.source` from Task 3.
- Produces: `NewMissionDialogModel.continueManually()`, editable `sourceTitle`/`sourceBody`, and explicit all-project selection for locator-less sources.
- Preserves: selected-project preference, branch/base draft ownership, duplicate choice, worktree checkpointing, and Add Repository flow.

- [ ] **Step 1: Write failing dialog-model tests for manual creation and provider fallback**

Add tests that drive the model rather than snapshotting SwiftUI internals:

```swift
@Test func arbitraryLinkRequiresTitleAndUsesExplicitSelectedRepository() async throws {
    let recorder = MissionDraftRecorder()
    let model = Self.model(
        resolution: MissionFixtures.manualResolution(selectedProjectID: "project-b"),
        recorder: recorder
    )
    model.reference = "https://jira.example.com/browse/ALAS-123"

    await model.resolve()
    #expect(model.phase == .confirmation)
    #expect(model.projectId == "project-b")
    #expect(model.validationMessage == "Enter a work-item title.")

    model.sourceTitle = "Fix login timeout"
    model.sourceBody = "Sessions expire during refresh."
    #expect(model.branch == "nacho/fix-login-timeout")
    #expect(await model.create(allowDuplicate: false) != nil)
    #expect(recorder.draft?.source.title == "Fix login timeout")
    #expect(recorder.draft?.projectId == "project-b")
}

@Test func providerFailureWaitsForExplicitManualContinuation() async {
    let fallback = MissionFixtures.githubManualFallback()
    let model = Self.model(resolutionFailure: fallback)

    await model.resolve()
    #expect(model.phase == .entry)
    #expect(model.pendingManualFallback != nil)
    #expect(model.errorMessage == "Authentication is required for github.com.")

    model.continueManually()
    #expect(model.phase == .confirmation)
    #expect(model.sourceTitle.isEmpty)
    #expect(model.projectId == "project-a")
}
```

Also test empty context is accepted, source title edits regenerate branch/prompt only until the user owns those fields, changing project preserves user-owned branch/base, and creating an allowed duplicate still requires a distinct branch.

- [ ] **Step 2: Run focused creation tests and verify they fail**

```bash
rtk xcodebuild -derivedDataPath /private/tmp/alas-mission-source-task4 -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -only-testing:AlasTests/NewMissionDialogTests -only-testing:AlasTests/MissionCoordinatorTests -only-testing:AlasTests/AddMissionLegModelTests -only-testing:AlasTests/AddMissionLegDialogTests test
```

Expected: FAIL because the dialog still requires `ResolvedMissionIssue` and has no manual fields/fallback action.

- [ ] **Step 3: Implement the work-item creation flow**

Rename the environment closure to:

```swift
let resolveSource: (String) async throws -> ResolvedMissionSource
```

Store `resolved: ResolvedMissionSource?`, `pendingManualFallback: ResolvedMissionSource?`, `sourceTitle`, and `sourceBody`. On an arbitrary source, seed `candidateProjectIds` from all configured projects and use `selectedProjectID` when present. On `MissionSourceResolutionFailure`, remain in entry and expose `Continue Manually`; that action adopts the fallback and advances to confirmation without another request.

Use these validation strings:

```swift
"Enter a work-item link."
"Enter a work-item title."
"Choose a primary repository."
"Resolve a work item before creating a Mission."
```

Update the entry copy to `Start from any work-item link.`, label to `Work item link`, and placeholder to `Work-item URL or #123`. In confirmation, show editable title/context fields only when `source.contentOrigin == .manual`; provider content remains read-only.

Change `MissionCoordinator`, retry prompt creation, and Add Repository prompt construction to consume `aggregate.source`. Do not change their checkpoint/idempotency behavior.

- [ ] **Step 4: Run focused creation tests**

Run the Task 4 command again.

Expected: PASS for manual creation, provider continuation, existing code-host confirmation, duplicate behavior, coordinator checkpoints, and additional-leg prompt delivery.

- [ ] **Step 5: Commit the creation flow**

```bash
git add Alas/Sources/Missions/NewMissionDialog.swift Alas/Sources/Missions/MissionCoordinator.swift Alas/Sources/Missions/AddMissionLegModel.swift Alas/Sources/Missions/AddMissionLegDialog.swift AlasTests/Missions/NewMissionDialogTests.swift AlasTests/Missions/MissionCoordinatorTests.swift AlasTests/Missions/AddMissionLegModelTests.swift AlasTests/Missions/AddMissionLegDialogTests.swift
git commit -m "feat(missions): create missions from work item links"
```

---

### Task 5: Decouple Source Refresh From Leg Review Discovery

**Files:**
- Modify: `Alas/Sources/Missions/MissionController.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `AlasTests/Missions/MissionIntegrationTests.swift`
- Modify: `AlasTests/Missions/MissionTabTests.swift`

**Interfaces:**
- Consumes: Task 3 source persistence and Task 2 source-provider registry.
- Produces: `MissionSourceRefresh`, `MissionSourceRefreshProposal`, `MissionSourceRefreshResult`, `MissionController.refreshSource(_:)`, `MissionController.confirmSourceRefresh(_:)`, and review discovery signatures without `MissionIssueIdentity`.
- Preserves: sticky readiness, linked-review replacement guards, branch-tip checks, refresh generations, and stale-snapshot behavior.

- [ ] **Step 1: Add failing source-independent review and refresh tests**

Add an integration test whose Mission source is manual and whose primary leg uses a GitHub remote:

```swift
@Test func manualSourceMissionLinksMergedGitHubReviewFromItsLeg() async throws {
    let fake = try await MissionIntegrationFake.running(
        source: MissionFixtures.manualSource(),
        reviewRepositoryMatches: { _, _, _, request in request.remote.repositorySlug == "acme/alas" },
        discoverReviewRequest: { _, branch, _, headSHA, _ in
            MissionFixtures.mergedReview(branch: branch, headSHA: headSHA)
        }
    )

    await fake.controller.discoverMergedReview(
        worktreeId: "worktree-1",
        baseRef: "origin/main",
        snapshot: MissionFixtures.reviewLoopSnapshot()
    )

    let aggregate = try #require(fake.controller.aggregate(id: .fixture))
    #expect(aggregate.primaryLeg?.reviewIdentity?.provider == .github)
    #expect(aggregate.mission.state == .readyToComplete)
}
```

Add refresh tests asserting manual/non-refreshable sources do nothing, refreshable sources call the matching adapter, failures preserve stored content and set `refreshError`, stale generations cannot overwrite a newer success, and the event text is `Source <displayReference> refreshed.` or `Source refreshed.`. For a refreshable source whose content origin is manual, assert `refreshSource` returns a confirmation proposal and leaves persistence unchanged until `confirmSourceRefresh` is called.

- [ ] **Step 2: Run focused integration tests and verify they fail**

```bash
rtk xcodebuild -derivedDataPath /private/tmp/alas-mission-source-task5 -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -only-testing:AlasTests/MissionIntegrationTests -only-testing:AlasTests/MissionTabTests test
```

Expected: FAIL because refresh and review-discovery closures still require `MissionIssueIdentity`.

- [ ] **Step 3: Implement source refresh and leg-only review matching**

Replace the refresh and discovery typealiases with:

```swift
typealias MissionSourceRefresh = @MainActor (
    _ source: MissionSourceSnapshot,
    _ projectId: String
) async throws -> MissionSourceSnapshot

typealias MissionReviewDiscovery = @MainActor (
    _ projectID: String,
    _ branch: String,
    _ baseRef: String,
    _ headSHA: String,
    _ headOwner: String?
) async -> ReviewRequest?

typealias MissionBranchOwner = @MainActor (
    _ projectID: String,
    _ branch: String,
    _ baseRef: String
) async -> String?

enum MissionSourceRefreshResult: Equatable, Sendable {
    case applied
    case confirmationRequired(MissionSourceRefreshProposal)
    case unavailable
    case failed(String)
}

struct MissionSourceRefreshProposal: Equatable, Sendable {
    let missionID: MissionID
    let expectedIdentity: MissionSourceIdentity
    let expectedCapturedAt: Date
    let snapshot: MissionSourceSnapshot
}
```

Rename `refreshIssue` to `refreshSource` throughout controller/AppState. Return `.unavailable` when `source.isRefreshable == false`. Route refresh through `MissionSourceProviderRegistry.provider(for: source.identity.providerID)`, preserve the complete old snapshot on failure, and use the Task 3 source persistence APIs. Provider-origin content is persisted immediately and returns `.applied`. Manually authored adapter content returns `.confirmationRequired(fetched)` without changing persistence.

Implement `confirmSourceRefresh(_ proposal: MissionSourceRefreshProposal)` with a compare-before-write guard: reload the aggregate, require its identity and `capturedAt` to match `proposal.expectedIdentity` and `proposal.expectedCapturedAt`, then call `replaceSourceSnapshot`. If a newer edit or refresh won the race, discard the proposal and expose `The Mission source changed before refresh confirmation.` rather than overwriting it.

Remove source identity from `reviewMatchesTarget`, `discoverMissionReview`, and branch-owner selection. Repository acceptance must come from `reviewRepositoryMatches(projectID, baseRef, baseRemoteName, request)`. Branch owner and review discovery select the effective code-host remote through the leg's persisted base remote, push remote, upstream remote, and configured Git remotes.

Keep provider-confirmed repository rename behavior by updating `source.repositoryLocator` and stable ID through source refresh; do not use it to match reviews for other legs.

- [ ] **Step 4: Run focused controller/integration tests**

Run the Task 5 command again.

Expected: PASS, including a manual-source GitHub-leg merged review and existing code-host rename/refresh generations.

- [ ] **Step 5: Commit source lifecycle decoupling**

```bash
git add Alas/Sources/Missions/MissionController.swift Alas/Sources/App/AppState.swift AlasTests/Missions/MissionIntegrationTests.swift AlasTests/Missions/MissionTabTests.swift
git commit -m "refactor(missions): decouple sources from reviews"
```

---

### Task 6: Present and Edit Manual Mission Source Context

**Files:**
- Create: `Alas/Sources/Missions/EditMissionSourceDialog.swift`
- Create: `AlasTests/Missions/EditMissionSourceDialogTests.swift`
- Modify: `Alas/Sources/Missions/MissionTabView.swift`
- Modify: `Alas/Sources/Missions/MissionSidebarSection.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `AlasTests/Missions/MissionPresentationTests.swift`
- Modify: `AlasTests/Missions/MissionSidebarTests.swift`
- Modify: `AlasTests/Missions/MissionTabTests.swift`

**Interfaces:**
- Consumes: source capabilities and `MissionPersistence.updateManualSourceContent`.
- Produces: `MissionController.updateManualSource(id:title:body:)`, `EditMissionSourceDialogModel`, and neutral presentation actions/copy.
- Preserves: Mission tab routing, worktree recovery, leg actions, review actions, activity ordering, and completion controls.

- [ ] **Step 1: Write failing presentation and editor-model tests**

Add these behavior assertions:

```swift
@Test func manualSourcePresentationUsesNeutralActions() {
    let aggregate = MissionFixtures.runningMission(source: MissionFixtures.manualSource())
    let presentation = MissionTabPresentation(aggregate: aggregate, worktree: nil)

    #expect(presentation.sourceProviderName == "jira.example.com")
    #expect(presentation.sourceReference == nil)
    #expect(presentation.sourceDestination == aggregate.source.canonicalURL)
    #expect(presentation.actions.openSource)
    #expect(presentation.actions.editSourceContext)
    #expect(!presentation.actions.refreshSource)
}

@Test func editorTrimsTitleButPreservesContextFormatting() async {
    let recorder = ManualSourceEditRecorder()
    let model = EditMissionSourceDialogModel(
        source: MissionFixtures.manualSource(),
        save: recorder.save
    )
    model.title = "  Updated title  "
    model.body = "First line\n\nSecond line"

    #expect(await model.submit())
    #expect(recorder.title == "Updated title")
    #expect(recorder.body == "First line\n\nSecond line")
}
```

Also test provider-origin content shows Refresh but not Edit, a manual-fallback GitHub source shows both, empty edited titles are rejected, URL is displayed read-only, and sidebar help text does not invent a repository or issue number.
Add a Mission-tab action test that receives `.confirmationRequired`, opens a confirmation sheet containing the fetched title/body, and calls `confirmSourceRefresh` only after the user confirms. Cancelling must leave the stored manual content unchanged.

- [ ] **Step 2: Run focused presentation tests and verify they fail**

```bash
rtk xcodebuild -derivedDataPath /private/tmp/alas-mission-source-task6 -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -only-testing:AlasTests/EditMissionSourceDialogTests -only-testing:AlasTests/MissionPresentationTests -only-testing:AlasTests/MissionSidebarTests -only-testing:AlasTests/MissionTabTests test
```

Expected: FAIL because presentation still exposes issue-specific fields/actions and the editor does not exist.

- [ ] **Step 3: Implement neutral presentation and editing**

Replace issue-specific presentation properties with:

```swift
let sourceProviderName: String
let sourceReference: String?
let sourceBody: String
let sourceCapturedAt: Date
let sourceDestination: URL

struct Actions: Equatable {
    let openAgent: Bool
    let openChanges: Bool
    let openSource: Bool
    let refreshSource: Bool
    let editSourceContext: Bool
    let retryWorktree: Bool
    let retryAgent: Bool
    let recoverWorktree: Bool
    let completeMission: Bool
}
```

Create `EditMissionSourceDialogModel` with `title`, `body`, `errorMessage`, `isSaving`, and `submit() async -> Bool`. It trims title outer whitespace, preserves body content, rejects an empty title with `Enter a work-item title.`, and calls the injected save closure exactly once while saving.

Add `MissionController.updateManualSource(id:title:body:)`, persist an event via Task 3, publish the updated aggregate, and surface errors through `loadError`. Wire the Mission tab buttons as `Open source`, `Refresh source`, and `Edit source context`; show `Stored source snapshot may be stale:` for refresh errors. When refresh returns `.confirmationRequired`, present a sheet titled `Replace manual source context?` with the fetched provider snapshot, `Cancel`, and `Replace` actions. `Replace` calls `confirmSourceRefresh`; `Cancel` dismisses without persistence. Use the same neutral fields in sidebar rows and accessibility help.

- [ ] **Step 4: Regenerate and run focused UI-model tests**

```bash
rtk xcodegen
rtk xcodebuild -derivedDataPath /private/tmp/alas-mission-source-task6 -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -only-testing:AlasTests/EditMissionSourceDialogTests -only-testing:AlasTests/MissionPresentationTests -only-testing:AlasTests/MissionSidebarTests -only-testing:AlasTests/MissionTabTests test
```

Expected: PASS for manual/provider/manual-fallback capabilities and preserved Mission/leg actions.

- [ ] **Step 5: Commit presentation and editing**

```bash
git add project.yml Alas.xcodeproj Alas/Sources/Missions/EditMissionSourceDialog.swift Alas/Sources/Missions/MissionTabView.swift Alas/Sources/Missions/MissionSidebarSection.swift Alas/Sources/App/AppState.swift AlasTests/Missions/EditMissionSourceDialogTests.swift AlasTests/Missions/MissionPresentationTests.swift AlasTests/Missions/MissionSidebarTests.swift AlasTests/Missions/MissionTabTests.swift
git commit -m "feat(missions): edit manual source context"
```

---

### Task 7: Remove Issue Compatibility Shims and Verify End to End

**Files:**
- Modify: `Alas/Sources/Missions/MissionModels.swift`
- Delete: `Alas/Sources/Missions/MissionIssueResolver.swift` if no non-test caller remains
- Modify: every remaining file reported by the issue-specific Mission symbol scan
- Modify: every remaining test fixture/assertion reported by the same scan
- Modify: `Alas.xcodeproj/project.pbxproj` through XcodeGen

**Interfaces:**
- Consumes: the final source APIs from Tasks 1-6.
- Produces: no `MissionIssueIdentity`, `MissionIssueSnapshot`, `MissionIssueResolver`, `aggregate.issue`, `draft.issue`, `refreshIssue`, or issue-specific Mission UI symbols.
- Preserves: `CodeHostIssueProviding` only as the internal GitHub/GitLab CLI metadata implementation behind source adapters.

- [ ] **Step 1: Add the final end-to-end regression**

In `MissionIntegrationTests`, exercise the complete manual path with a real temporary Mission store and fake worktree/ACP environment:

```swift
@Test func arbitraryLinkCreatesEditableMissionAndTracksLegReview() async throws {
    let fake = try await MissionIntegrationFake.manualSource(
        url: "https://linear.app/acme/issue/ALAS-123/fix-login-timeout",
        title: "Fix login timeout",
        body: "Sessions expire during refresh."
    )

    let missionID = try await fake.createMission()
    await fake.controller.updateManualSource(
        id: missionID,
        title: "Fix login timeout safely",
        body: "Preserve refresh tokens."
    )
    await fake.observeMergedReview()

    let aggregate = try #require(fake.controller.aggregate(id: missionID))
    #expect(aggregate.source.title == "Fix login timeout safely")
    #expect(aggregate.source.canonicalURL.absoluteString == "https://linear.app/acme/issue/ALAS-123/fix-login-timeout")
    #expect(aggregate.legs.count == 1)
    #expect(aggregate.primaryLeg?.reviewIdentity?.provider == .github)
    #expect(aggregate.mission.state == .readyToComplete)
}
```

- [ ] **Step 2: Run the end-to-end test before cleanup**

```bash
rtk xcodebuild -derivedDataPath /private/tmp/alas-mission-source-task7 -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -only-testing:AlasTests/MissionIntegrationTests test
```

Expected: PASS. If it fails, fix the owning task's behavior before removing compatibility shims.

- [ ] **Step 3: Remove transitional issue symbols and migrate every caller**

Run this inventory:

```bash
rg -n 'MissionIssue|ResolvedMissionIssue|MissionIssueResolver|aggregate\.issue|draft\.issue|refreshIssue|Open Issue|Issue context|Stored issue' Alas/Sources AlasTests
```

Remove Task 1 compatibility conversions/accessors after migrating all Mission-domain callers to `source`. Delete the old resolver once only the internal `CodeHostIssueProviding` bridge remains. Keep `CodeHostIssueProviding` and provider CLI tests because GitHub/GitLab source adapters still depend on them. Repeat the inventory until it returns no Mission-domain or UI matches; matches inside the internal code-host adapter/provider implementation are allowed only when they describe actual GitHub/GitLab issues.

Run `rtk xcodegen` after deletion and confirm `Alas.xcodeproj` contains the new source/provider/editor files and no deleted resolver reference.

- [ ] **Step 4: Run formatting, focused Mission tests, full build, and full tests**

```bash
rtk swiftformat --lint Alas/Sources/Missions AlasTests/Missions
git diff --check
rtk xcodegen
rtk xcodebuild -derivedDataPath /private/tmp/alas-mission-source-final-build -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -quiet build
rtk xcodebuild -derivedDataPath /private/tmp/alas-mission-source-final-test -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' test
```

Expected: SwiftFormat lint and diff check exit 0, build exits 0, and the full test action reaches `** TEST SUCCEEDED **`. A run that stalls or exits before `xctest` is incomplete and must not be reported as passing.

- [ ] **Step 5: Commit cleanup and verified integration**

```bash
git add project.yml Alas.xcodeproj Alas/Sources AlasTests
git commit -m "test(missions): verify provider-neutral source workflow"
```

- [ ] **Step 6: Inspect the final branch history and diff**

```bash
git status --short --branch
git log --oneline --decorate -8
git diff HEAD~7 --stat
git diff HEAD~7 --check
```

Expected: clean worktree, seven implementation commits after the design/plan commits, only Mission/source integration and generated project membership changes, and no whitespace errors.
