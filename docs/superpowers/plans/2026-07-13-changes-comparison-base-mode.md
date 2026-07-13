# Changes tab comparison-base mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Changes tab's on/off "track upstream" checkbox with a three-way mode — **Auto** (compare against `origin/<base>`, rebase-stable, new default) · **Branch upstream** (compare against the branch's own `@{u}`) · **Manual** (compare against a per-worktree-selected base) — surfaced as a segmented control in Settings.

**Architecture:** Introduce a `GitService.BaseResolution` enum that makes the three base-ref resolution strategies first-class (`upstreamThenBase`, `baseOriginFirst`, `baseLocalFirst`), replacing the old `ignoreUpstream: Bool` parameter on `commitsAhead`. Replace the persisted `changes.trackUpstreamForCommits: Bool` with a `changes.comparisonMode: ChangesComparisonMode` enum (migrating legacy configs: `true → .branchUpstream`, `false`/absent → `.auto`). A pure mapping (`BaseResolution.forCommits` / `.forReviewLoopBase`) turns `(mode, userOverrodeBaseBranch)` into a resolution at every call site.

**Tech Stack:** Swift 5.9+, SwiftUI (macOS), Swift Testing (`import Testing`), git via `Process.git`.

## Global Constraints

- All code, comments, logs, and UI strings in English.
- Tests use the Swift Testing framework (`import Testing`), not XCTest.
- No agent attributions anywhere (no `Co-Authored-By`, no "Generated with", no 🤖) in commits, PRs, code, or docs.
- Do not edit `Info.plist` directly; pinned keys live in `project.yml`. (Not expected to change here.)
- No new files are added to the Xcode target without regenerating via `xcodegen` (Task 3 adds one file — regenerate + commit `project.yml`/`Alas.xcodeproj` if the new file is not picked up by the existing glob).
- Build/test commands:
  - `xcodegen`
  - `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`
  - `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test`
- Each task must leave the project **building and all tests green** before its commit.

## File map

- `Alas/Sources/Git/GitService.swift` — `BaseResolution` enum + `commitsAhead` signature/logic (Task 1).
- `AlasTests/CommitsAheadTests.swift` — update 3 existing `ignoreUpstream:` call sites; add Auto-mode tests (Task 1).
- `Alas/Sources/Persistence/AppConfig.swift` — `ChangesComparisonMode` enum, `comparisonMode` property, migration decoder; legacy bool removal (Tasks 2 & 5).
- `AlasTests/AppConfigChangesTests.swift` — migration tests (Task 2).
- `Alas/Sources/Right/BaseResolutionMapping.swift` — **new**: pure `(mode, override) → BaseResolution` mapping (Task 3).
- `AlasTests/BaseResolutionMappingTests.swift` — **new**: mapping unit tests (Task 3).
- `Alas/Sources/Right/RightPaneState.swift` — resolution derivation + mirror property (Tasks 1 & 3).
- `Alas/Sources/Right/RightPaneStore.swift` — `state(for:)` signature + sync (Task 3).
- `Alas/Sources/Right/RightPaneView.swift`, `Alas/Sources/Center/CenterPaneView.swift` — `.task(id:)` keys + `state(for:)` calls (Task 3).
- `Alas/Sources/App/AppState.swift` — two `state(for:)` calls + direct `commitsAhead` (Tasks 1 & 3).
- `Alas/Sources/Center/Commit/CommitEditorTabView.swift` — resolution derivation (Tasks 1 & 3).
- `Alas/Sources/Settings/ChangesPane.swift` — segmented control UI (Task 4).

---

### Task 1: `BaseResolution` enum in GitService (behavior-preserving refactor + new `.baseOriginFirst`)

Replace the `ignoreUpstream: Bool` parameter on `commitsAhead` with an explicit
`BaseResolution` enum. `.upstreamThenBase` and `.baseLocalFirst` reproduce
today's `ignoreUpstream: false` / `true` behavior exactly; `.baseOriginFirst` is
new (skip upstream, prefer `origin/<base>` over local `<base>`). All existing
runtime call sites keep their current behavior by deriving the enum from the
still-present `trackUpstreamForCommits` bool.

**Files:**
- Modify: `Alas/Sources/Git/GitService.swift` (enum near `commitsAhead`; signature/body at ~1191–1259)
- Modify: `Alas/Sources/Right/RightPaneState.swift:553–568`
- Modify: `Alas/Sources/App/AppState.swift:4405–4409`
- Modify: `Alas/Sources/Center/Commit/CommitEditorTabView.swift:375,390`
- Test: `AlasTests/CommitsAheadTests.swift`

**Interfaces:**
- Produces:
  - `enum GitService.BaseResolution { case upstreamThenBase, baseOriginFirst, baseLocalFirst }`
  - `func commitsAhead(at: URL, baseBranch: String? = nil, resolution: BaseResolution = .upstreamThenBase) async throws -> (commits: [CommitInfo], comparisonRef: String?)`

- [ ] **Step 1: Update the 3 existing `ignoreUpstream: true` call sites in the test to the new enum, and add the two Auto-mode tests (failing — enum/param don't exist yet).**

In `AlasTests/CommitsAheadTests.swift`, change the three existing calls:
- Line ~183: `ignoreUpstream: true` → `resolution: .baseLocalFirst`
- Line ~201: `ignoreUpstream: true` → `resolution: .baseLocalFirst`
- Line ~213: `ignoreUpstream: true` → `resolution: .baseLocalFirst`

Then add these tests to the `CommitsAheadTests` suite:

```swift
@Test func baseOriginFirstPrefersOriginOverLocalBase() async throws {
    let (worktree, _) = try await makeRepoWithUpstream()
    defer { try? FileManager.default.removeItem(at: worktree.deletingLastPathComponent()) }
    _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: worktree)
    _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "feat: feature work"], cwd: worktree)

    let svc = GitService()
    // Local `main` and `origin/main` both exist; Auto prefers origin.
    let (_, comparisonRef) = try await svc.commitsAhead(
        at: worktree, baseBranch: "main", resolution: .baseOriginFirst
    )
    #expect(comparisonRef == "origin/main")
}

@Test func baseOriginFirstComparesAgainstOriginBaseNotBranchUpstream() async throws {
    let (worktree, _) = try await makeRepoWithUpstream()
    defer { try? FileManager.default.removeItem(at: worktree.deletingLastPathComponent()) }
    _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: worktree)
    _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "feat: work"], cwd: worktree)
    _ = try await Process.git(["push", "-q", "-u", "origin", "feature"], cwd: worktree)

    let svc = GitService()
    // Upstream mode compares vs origin/feature -> nothing ahead.
    let (up, upRef) = try await svc.commitsAhead(
        at: worktree, baseBranch: "main", resolution: .upstreamThenBase
    )
    #expect(upRef == "origin/feature")
    #expect(up.isEmpty)
    // Auto compares vs origin/main -> lists the branch's own work.
    let (auto, autoRef) = try await svc.commitsAhead(
        at: worktree, baseBranch: "main", resolution: .baseOriginFirst
    )
    #expect(autoRef == "origin/main")
    #expect(auto.count == 1)
    #expect(auto[0].subject == "work")
}
```

- [ ] **Step 2: Run the new tests to confirm they fail to compile / fail.**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/CommitsAheadTests 2>&1 | tail -30`
Expected: compile failure — `commitsAhead` has no `resolution:` parameter / `BaseResolution` undefined.

- [ ] **Step 3: Add the `BaseResolution` enum and rewrite `commitsAhead` to switch on it.**

In `Alas/Sources/Git/GitService.swift`, add the enum just above `commitsAhead` (inside `GitService`):

```swift
/// How `commitsAhead` chooses the ref it compares `HEAD` against.
/// - `upstreamThenBase`: use the branch's own upstream `@{u}` when it
///   resolves, otherwise the base branch (origin-qualified, then local).
/// - `baseOriginFirst`: never use `@{u}`; prefer `origin/<base>`, then local
///   `<base>`. Rebase-stable ("Auto").
/// - `baseLocalFirst`: never use `@{u}`; prefer local `<base>`, then
///   `origin/<base>` ("Manual").
enum BaseResolution {
    case upstreamThenBase
    case baseOriginFirst
    case baseLocalFirst
}
```

Change the signature (line ~1191):

```swift
func commitsAhead(
    at worktree: URL,
    baseBranch: String? = nil,
    resolution: BaseResolution = .upstreamThenBase
) async throws -> (commits: [CommitInfo], comparisonRef: String?) {
```

Replace Step 1's guard `if !ignoreUpstream {` (line ~1196) with:

```swift
        var upstreamName: String? = nil
        if resolution == .upstreamThenBase {
```

Replace the entire Step 2 base-resolution block (the `var baseName: String? = nil` block, lines ~1213–1254) with:

```swift
        // Step 2: If no upstream ref was chosen, resolve the base branch.
        // Slash-named bases are ambiguous, so always resolve local first for
        // them; simple names follow the requested preference.
        func refExists(_ ref: String) async -> Bool {
            let r = try? await Process.git(["show-ref", "--verify", "--quiet", ref], cwd: worktree)
            return r?.exitCode == 0
        }
        var baseName: String? = nil
        if upstreamName == nil, let base = baseBranch, !base.isEmpty {
            if base.contains("/") {
                if await refExists("refs/heads/\(base)") {
                    baseName = base
                } else if await refExists("refs/remotes/\(base)") {
                    baseName = base
                }
            }
            if baseName == nil {
                let localExists = await refExists("refs/heads/\(base)")
                let originExists = await refExists("refs/remotes/origin/\(base)")
                switch resolution {
                case .baseLocalFirst:
                    if localExists { baseName = base }
                    else if originExists { baseName = "origin/\(base)" }
                case .baseOriginFirst, .upstreamThenBase:
                    if originExists { baseName = "origin/\(base)" }
                    else if localExists { baseName = base }
                }
            }
        }
```

(Note: `.baseOriginFirst` and `.upstreamThenBase` share identical *base* ordering — origin then local. They differ only in whether Step 1 consulted `@{u}`. This matches today's behavior for `.upstreamThenBase`.)

- [ ] **Step 4: Update the four runtime call sites to derive the enum from the existing bool (behavior-preserving).**

`Alas/Sources/Right/RightPaneState.swift` — replace lines ~553 and the two `commitsAhead` calls (~559–568):

```swift
            let ignoreUpstream = userOverrodeBaseBranch || !trackUpstreamForCommits
            let commitsResolution: GitService.BaseResolution = ignoreUpstream ? .baseLocalFirst : .upstreamThenBase
            async let s = git.status(worktreePath: worktree.path)
            async let statusRaw = Process.git(
                ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
                cwd: worktree.path
            )
            async let c = git.commitsAhead(
                at: worktree.path,
                baseBranch: baseBranch,
                resolution: commitsResolution
            )
            async let reviewLoopBase = git.commitsAhead(
                at: worktree.path,
                baseBranch: baseBranch,
                resolution: .baseLocalFirst
            )
```

`Alas/Sources/App/AppState.swift` — replace line ~4408:

```swift
            async let commits = git.commitsAhead(
                at: worktree.path,
                baseBranch: config.worktrees.baseBranch,
                resolution: config.changes.trackUpstreamForCommits ? .upstreamThenBase : .baseLocalFirst
            )
```

`Alas/Sources/Center/Commit/CommitEditorTabView.swift` — replace line ~375 and the call at ~390:

```swift
        let commitsResolution: GitService.BaseResolution =
            appState.config.changes.trackUpstreamForCommits ? .upstreamThenBase : .baseLocalFirst
```

and at the call site (~390) replace `ignoreUpstream: ignoreUpstream` with `resolution: commitsResolution`.

- [ ] **Step 5: Build and run the full test suite.**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: build succeeds; all tests pass (existing `CommitsAheadTests` still green with `.baseLocalFirst`; the two new Auto tests pass).

- [ ] **Step 6: Commit.**

```bash
git add Alas/Sources/Git/GitService.swift Alas/Sources/Right/RightPaneState.swift Alas/Sources/App/AppState.swift Alas/Sources/Center/Commit/CommitEditorTabView.swift AlasTests/CommitsAheadTests.swift
git commit -m "refactor(git): replace commitsAhead ignoreUpstream flag with BaseResolution enum"
```

---

### Task 2: `ChangesComparisonMode` config enum + migration (coexisting with the legacy bool)

Add the persisted mode enum and its migration alongside the existing
`trackUpstreamForCommits` bool. Nothing reads the new field at runtime yet; this
task is purely the config surface + migration so it can be tested in isolation.

**Files:**
- Modify: `Alas/Sources/Persistence/AppConfig.swift` (Changes struct ~294–321; defaults ~427–437; decoder ~652–688)
- Test: `AlasTests/AppConfigChangesTests.swift`

**Interfaces:**
- Produces:
  - `enum AppConfig.ChangesComparisonMode: String, Codable { case auto, branchUpstream, manual }`
  - `AppConfig.Changes.comparisonMode: ChangesComparisonMode` (default `.auto`)

- [ ] **Step 1: Write failing migration tests.**

Add to `AlasTests/AppConfigChangesTests.swift` (a helper plus four tests). The helper round-trips `AppConfig.defaults` through JSON, mutating only the `changes` object, so the full-config decode path (which requires e.g. `harness`) stays valid:

```swift
    private func decodeChanges(mutating: ([String: Any]) -> [String: Any]) throws -> AppConfig.Changes {
        let data = try JSONEncoder().encode(AppConfig.defaults)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj["changes"] = mutating(obj["changes"] as! [String: Any])
        let mutated = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(AppConfig.self, from: mutated).changes
    }

    @Test func migratesLegacyTrackUpstreamTrueToBranchUpstream() throws {
        let changes = try decodeChanges { var c = $0; c.removeValue(forKey: "comparisonMode"); c["trackUpstreamForCommits"] = true; return c }
        #expect(changes.comparisonMode == .branchUpstream)
    }

    @Test func migratesLegacyTrackUpstreamFalseToAuto() throws {
        let changes = try decodeChanges { var c = $0; c.removeValue(forKey: "comparisonMode"); c["trackUpstreamForCommits"] = false; return c }
        #expect(changes.comparisonMode == .auto)
    }

    @Test func defaultsToAutoWhenNeitherKeyPresent() throws {
        let changes = try decodeChanges { var c = $0; c.removeValue(forKey: "comparisonMode"); c.removeValue(forKey: "trackUpstreamForCommits"); return c }
        #expect(changes.comparisonMode == .auto)
    }

    @Test func explicitComparisonModeWinsOverLegacyBool() throws {
        let changes = try decodeChanges { var c = $0; c["comparisonMode"] = "manual"; c["trackUpstreamForCommits"] = true; return c }
        #expect(changes.comparisonMode == .manual)
    }
```

- [ ] **Step 2: Run the tests to confirm they fail.**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppConfigChangesTests 2>&1 | tail -30`
Expected: compile failure — `comparisonMode` / `ChangesComparisonMode` undefined.

- [ ] **Step 3: Add the enum + property + CodingKey.**

In `Alas/Sources/Persistence/AppConfig.swift`, inside `struct Changes` add the enum and property (keep `trackUpstreamForCommits` for now):

```swift
        /// How the Commits section chooses its comparison base.
        /// - `auto` (default): compare against `origin/<base>` (falls back to
        ///   local `<base>`); stable across rebases.
        /// - `branchUpstream`: compare against the branch's own `@{u}`.
        /// - `manual`: compare against the per-worktree selected base branch.
        enum ChangesComparisonMode: String, Codable {
            case auto
            case branchUpstream
            case manual
        }
        var comparisonMode: ChangesComparisonMode
```

Add `comparisonMode` to the `CodingKeys` enum (line ~317–320):

```swift
        enum CodingKeys: String, CodingKey {
            case aiToolId, prompt, reviewRequestPrompt, mergeBulkResolvePrompt,
                 mergeSingleResolvePrompt, trackUpstreamForCommits, comparisonMode,
                 diffLayoutMode, diffWrapLines, diffShowWhitespace
        }
```

- [ ] **Step 4: Set the default and both decoder branches, with migration.**

In the defaults factory (`Changes(` at ~427), add after `trackUpstreamForCommits: false,`:

```swift
            comparisonMode: .auto,
```

In the decoder's `if let changesContainer` branch, after the `trackUpstream` line (~661) add:

```swift
            let comparisonMode: Changes.ChangesComparisonMode = {
                if let explicit = try? changesContainer.decode(Changes.ChangesComparisonMode.self, forKey: .comparisonMode) {
                    return explicit
                }
                return trackUpstream ? .branchUpstream : .auto
            }()
```

and pass `comparisonMode: comparisonMode,` into the `Changes(` initializer (after `trackUpstreamForCommits: trackUpstream,`).

In the `else` branch (~677 `Changes(`), add `comparisonMode: .auto,` after `trackUpstreamForCommits: false,`.

- [ ] **Step 5: Build and run the tests.**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppConfigChangesTests 2>&1 | tail -20`
Expected: build succeeds; all four migration tests pass.

- [ ] **Step 6: Commit.**

```bash
git add Alas/Sources/Persistence/AppConfig.swift AlasTests/AppConfigChangesTests.swift
git commit -m "feat(config): add changes.comparisonMode with legacy trackUpstream migration"
```

---

### Task 3: Route runtime readers through `comparisonMode`

Introduce the pure `(mode, override) → BaseResolution` mapping and switch every
runtime reader from the bool to `comparisonMode`. This is where Auto's
`.baseOriginFirst` and the per-worktree-override → Manual rule take effect at
runtime. Also switch the review-loop base to mirror the mode's base flavor
(`.baseOriginFirst` except Manual/override → `.baseLocalFirst`).

**Files:**
- Create: `Alas/Sources/Right/BaseResolutionMapping.swift`
- Test: `AlasTests/BaseResolutionMappingTests.swift`
- Modify: `Alas/Sources/Right/RightPaneState.swift` (mirror prop ~175; derivation ~553–568)
- Modify: `Alas/Sources/Right/RightPaneStore.swift` (~64, 69, 121, 137; and the mirror sync)
- Modify: `Alas/Sources/Right/RightPaneView.swift:188–196`
- Modify: `Alas/Sources/Center/CenterPaneView.swift:306,314`
- Modify: `Alas/Sources/App/AppState.swift:3208–3212, 3572–3576, 4405–4409`
- Modify: `Alas/Sources/Center/Commit/CommitEditorTabView.swift:375`

**Interfaces:**
- Consumes: `GitService.BaseResolution` (Task 1), `AppConfig.Changes.ChangesComparisonMode` (Task 2).
- Produces:
  - `GitService.BaseResolution.forCommits(mode:userOverrodeBaseBranch:) -> BaseResolution`
  - `GitService.BaseResolution.forReviewLoopBase(mode:userOverrodeBaseBranch:) -> BaseResolution`
  - `RightPaneStore.state(for:baseBranch:comparisonMode:)` (renamed param)
  - `RightPaneState.comparisonMode: AppConfig.Changes.ChangesComparisonMode`

- [ ] **Step 1: Write failing mapping tests.**

Create `AlasTests/BaseResolutionMappingTests.swift`:

```swift
import Testing
@testable import Alas

struct BaseResolutionMappingTests {
    typealias Mode = AppConfig.Changes.ChangesComparisonMode

    @Test func autoMapsToOriginFirst() {
        #expect(GitService.BaseResolution.forCommits(mode: .auto, userOverrodeBaseBranch: false) == .baseOriginFirst)
    }
    @Test func branchUpstreamMapsToUpstreamThenBase() {
        #expect(GitService.BaseResolution.forCommits(mode: .branchUpstream, userOverrodeBaseBranch: false) == .upstreamThenBase)
    }
    @Test func manualMapsToLocalFirst() {
        #expect(GitService.BaseResolution.forCommits(mode: .manual, userOverrodeBaseBranch: false) == .baseLocalFirst)
    }
    @Test func perWorktreeOverrideForcesLocalFirstRegardlessOfMode() {
        #expect(GitService.BaseResolution.forCommits(mode: .auto, userOverrodeBaseBranch: true) == .baseLocalFirst)
        #expect(GitService.BaseResolution.forCommits(mode: .branchUpstream, userOverrodeBaseBranch: true) == .baseLocalFirst)
    }
    @Test func reviewLoopBaseIsOriginFirstExceptManualAndOverride() {
        #expect(GitService.BaseResolution.forReviewLoopBase(mode: .auto, userOverrodeBaseBranch: false) == .baseOriginFirst)
        #expect(GitService.BaseResolution.forReviewLoopBase(mode: .branchUpstream, userOverrodeBaseBranch: false) == .baseOriginFirst)
        #expect(GitService.BaseResolution.forReviewLoopBase(mode: .manual, userOverrodeBaseBranch: false) == .baseLocalFirst)
        #expect(GitService.BaseResolution.forReviewLoopBase(mode: .auto, userOverrodeBaseBranch: true) == .baseLocalFirst)
    }
}
```

For these to compile, `GitService.BaseResolution` must be `Equatable`. Add `: Equatable` to the enum in `GitService.swift` if not already (it is a payload-free enum, so `enum BaseResolution: Equatable`).

- [ ] **Step 2: Run to confirm failure.**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/BaseResolutionMappingTests 2>&1 | tail -30`
Expected: compile failure — `forCommits` / `forReviewLoopBase` undefined.

- [ ] **Step 3: Create the mapping.**

Create `Alas/Sources/Right/BaseResolutionMapping.swift`:

```swift
import Foundation

extension GitService.BaseResolution {
    /// The resolution for the Commits section, given the global mode and
    /// whether this worktree has a manual per-worktree base override.
    static func forCommits(
        mode: AppConfig.Changes.ChangesComparisonMode,
        userOverrodeBaseBranch: Bool
    ) -> GitService.BaseResolution {
        if userOverrodeBaseBranch { return .baseLocalFirst }
        switch mode {
        case .auto: return .baseOriginFirst
        case .branchUpstream: return .upstreamThenBase
        case .manual: return .baseLocalFirst
        }
    }

    /// The resolution for the review-loop base. It never uses the branch's own
    /// upstream — it wants a stable remote base — so every non-Manual mode maps
    /// to origin-first.
    static func forReviewLoopBase(
        mode: AppConfig.Changes.ChangesComparisonMode,
        userOverrodeBaseBranch: Bool
    ) -> GitService.BaseResolution {
        if userOverrodeBaseBranch { return .baseLocalFirst }
        return mode == .manual ? .baseLocalFirst : .baseOriginFirst
    }
}
```

If the build does not pick this file up automatically, run `xcodegen` and commit the regenerated `Alas.xcodeproj` alongside this task.

- [ ] **Step 4: Add the `comparisonMode` mirror to `RightPaneState` and use the mapping.**

In `Alas/Sources/Right/RightPaneState.swift`, replace the `trackUpstreamForCommits` mirror property (~170–175) with:

```swift
    /// Mirrors `AppConfig.changes.comparisonMode`. Synced by `RightPaneStore`
    /// on every `state(for:)` call. Combined with `userOverrodeBaseBranch`, it
    /// selects the `BaseResolution` `refresh()` passes to `commitsAhead`.
    var comparisonMode: AppConfig.Changes.ChangesComparisonMode = .auto
```

Replace the derivation added in Task 1 (the `ignoreUpstream` / `commitsResolution` lines and the two `commitsAhead` calls, ~553–568) with:

```swift
            let commitsResolution = GitService.BaseResolution.forCommits(
                mode: comparisonMode, userOverrodeBaseBranch: userOverrodeBaseBranch
            )
            let reviewLoopResolution = GitService.BaseResolution.forReviewLoopBase(
                mode: comparisonMode, userOverrodeBaseBranch: userOverrodeBaseBranch
            )
            async let s = git.status(worktreePath: worktree.path)
            async let statusRaw = Process.git(
                ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
                cwd: worktree.path
            )
            async let c = git.commitsAhead(
                at: worktree.path,
                baseBranch: baseBranch,
                resolution: commitsResolution
            )
            async let reviewLoopBase = git.commitsAhead(
                at: worktree.path,
                baseBranch: baseBranch,
                resolution: reviewLoopResolution
            )
```

- [ ] **Step 5: Update `RightPaneStore.state(for:)`.**

In `Alas/Sources/Right/RightPaneStore.swift`:
- Line ~64 signature: `func state(for worktree: Worktree, baseBranch: String, comparisonMode: AppConfig.Changes.ChangesComparisonMode) -> RightPaneState {`
- Line ~69: `let trackUpstreamChanged = existing.comparisonMode != comparisonMode`
- Line ~121: `existing.comparisonMode = comparisonMode`
- Line ~137: `new.comparisonMode = comparisonMode`
- Rename the local `trackUpstreamChanged` usages consistently (keep the variable name or rename to `comparisonModeChanged`; if renamed, update its one `if` usage at ~120).

- [ ] **Step 6: Update the four `state(for:)` / `commitsAhead` call sites and CommitEditorTabView.**

`Alas/Sources/Right/RightPaneView.swift` — `.task(id:)` (~188) and call (~192–196):

```swift
        .task(id: "\(worktree.id)\u{0000}\(worktree.branch)\u{0000}\(state.config.worktrees.baseBranch)\u{0000}\(state.config.changes.comparisonMode.rawValue)") {
            if rps?.worktree.id != worktree.id {
                rps = nil
            }
            let activated = state.rightPaneStore.state(
                for: worktree,
                baseBranch: state.config.worktrees.baseBranch,
                comparisonMode: state.config.changes.comparisonMode
            )
            rps = activated
            await activated.refresh()
        }
```

`Alas/Sources/Center/CenterPaneView.swift` — key (~306) and call (~311–315):

```swift
    private var rightPaneActivationKey: String {
        "\(worktree.id)\u{0000}\(worktree.branch)\u{0000}\(state.config.worktrees.baseBranch)\u{0000}\(state.config.changes.comparisonMode.rawValue)"
    }
```
```swift
        state.rightPaneStore.state(
            for: worktree,
            baseBranch: state.config.worktrees.baseBranch,
            comparisonMode: state.config.changes.comparisonMode
        )
```

`Alas/Sources/App/AppState.swift` — the two store calls (~3208–3212 and ~3572–3576) replace `trackUpstreamForCommits: config.changes.trackUpstreamForCommits` with `comparisonMode: config.changes.comparisonMode`. Replace the direct `commitsAhead` (~4405–4409):

```swift
            async let commits = git.commitsAhead(
                at: worktree.path,
                baseBranch: config.worktrees.baseBranch,
                resolution: GitService.BaseResolution.forCommits(
                    mode: config.changes.comparisonMode, userOverrodeBaseBranch: false
                )
            )
```

`Alas/Sources/Center/Commit/CommitEditorTabView.swift` — replace the `commitsResolution` line from Task 1 (~375):

```swift
        let commitsResolution = GitService.BaseResolution.forCommits(
            mode: appState.config.changes.comparisonMode, userOverrodeBaseBranch: false
        )
```

- [ ] **Step 7: Build and run the full suite.**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: build succeeds; all tests pass, including `BaseResolutionMappingTests`. (`ChangesPane` still binds the legacy bool and still compiles — it is switched in Task 4.)

- [ ] **Step 8: Commit.**

```bash
git add Alas/Sources/Right/BaseResolutionMapping.swift AlasTests/BaseResolutionMappingTests.swift Alas/Sources/Right/RightPaneState.swift Alas/Sources/Right/RightPaneStore.swift Alas/Sources/Right/RightPaneView.swift Alas/Sources/Center/CenterPaneView.swift Alas/Sources/App/AppState.swift Alas/Sources/Center/Commit/CommitEditorTabView.swift Alas.xcodeproj project.yml
git commit -m "feat(changes): drive comparison base from comparisonMode at runtime"
```

(Include `Alas.xcodeproj`/`project.yml` in the commit only if `xcodegen` changed them.)

---

### Task 4: Segmented control in Settings

Replace the "Track upstream branch" toggle with a three-way segmented control
bound to `comparisonMode`, plus a per-selection description explaining what each
mode compares against.

**Files:**
- Modify: `Alas/Sources/Settings/ChangesPane.swift:16–23`

**Interfaces:**
- Consumes: `AppConfig.Changes.ChangesComparisonMode`, `state.bind(_:)`.

- [ ] **Step 1: Replace the toggle row with a segmented `Picker` + dynamic description.**

In `Alas/Sources/Settings/ChangesPane.swift`, replace the `SettingsGroup(title: "Commits section")` block (lines ~16–23) with:

```swift
                SettingsGroup(title: "Comparison base") {
                    SettingsRow(
                        name: "Compare commits against",
                        desc: comparisonModeDescription
                    ) {
                        Picker("", selection: state.bind(\.changes.comparisonMode)) {
                            Text("Auto").tag(AppConfig.Changes.ChangesComparisonMode.auto)
                            Text("Branch upstream").tag(AppConfig.Changes.ChangesComparisonMode.branchUpstream)
                            Text("Manual").tag(AppConfig.Changes.ChangesComparisonMode.manual)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
```

Add this computed property to `ChangesPane` (near `body`):

```swift
    private var comparisonModeDescription: String {
        switch state.config.changes.comparisonMode {
        case .auto:
            return "Compares against origin/<base> (falls back to your local base branch). Always shows this branch's own work and stays stable across rebases."
        case .branchUpstream:
            return "Compares against this branch's own remote tracking ref, so it only lists unpushed commits once you push."
        case .manual:
            return "Compares against the base branch you pick per worktree (via the base-branch selector), resolved locally first."
        }
    }
```

- [ ] **Step 2: Build.**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build 2>&1 | tail -20`
Expected: build succeeds.

- [ ] **Step 3: Verify the control end-to-end.**

Launch the app (see the `/run` skill or `xcodebuild ... -destination 'platform=macOS'` run), open Settings → Changes, confirm the segmented control shows Auto · Branch upstream · Manual, that the description updates per selection, and that switching it re-drives the Commits section comparison. Confirm the change persists across relaunch (config round-trip). Note the result of this manual check in the commit body or task notes.

- [ ] **Step 4: Commit.**

```bash
git add Alas/Sources/Settings/ChangesPane.swift
git commit -m "feat(settings): segmented comparison-base control for the Changes tab"
```

---

### Task 5: Remove the legacy `trackUpstreamForCommits` bool

Nothing reads the bool at runtime anymore. Remove it from the config surface,
keeping the decoder's ability to read the legacy key for migration via a local
legacy-key container (so `Changes`'s synthesized `Codable` stays valid without a
matching stored property).

**Files:**
- Modify: `Alas/Sources/Persistence/AppConfig.swift`

**Interfaces:**
- Removes: `AppConfig.Changes.trackUpstreamForCommits`.

- [ ] **Step 1: Confirm no runtime readers remain.**

Run: `grep -rn "trackUpstreamForCommits" Alas/Sources`
Expected: only occurrences inside `AppConfig.swift` (schema, CodingKeys, defaults, decoder). If any other file still references it, that file was missed in Task 3 — fix it before proceeding.

- [ ] **Step 2: Add a legacy-key container and drop the property/key.**

In `AppConfig.swift`:

1. Delete the `var trackUpstreamForCommits: Bool` property (~312) and its doc comment.
2. Remove `trackUpstreamForCommits` from `Changes.CodingKeys` (~318).
3. Add a private legacy key type (top-level within `AppConfig` or file scope):

```swift
private enum LegacyChangesKey: String, CodingKey {
    case trackUpstreamForCommits
}
```

4. In the decoder's `if let changesContainer` branch, replace the `trackUpstream` decode (~661) so it reads through a *separate* container keyed by the legacy key (the `changesContainer` no longer knows this key):

```swift
            let legacyTrackUpstream: Bool? = {
                guard let legacy = try? c.nestedContainer(keyedBy: LegacyChangesKey.self, forKey: .changes) else { return nil }
                return try? legacy.decode(Bool.self, forKey: .trackUpstreamForCommits)
            }()
            let comparisonMode: Changes.ChangesComparisonMode = {
                if let explicit = try? changesContainer.decode(Changes.ChangesComparisonMode.self, forKey: .comparisonMode) {
                    return explicit
                }
                return (legacyTrackUpstream == true) ? .branchUpstream : .auto
            }()
```

5. Remove `trackUpstreamForCommits: ...,` from all three `Changes(` initializers (defaults ~433, decoder `if` branch ~671, decoder `else` branch ~683).

- [ ] **Step 3: Build and run the full suite (migration tests must still pass).**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: build succeeds; `AppConfigChangesTests` (including the four migration tests) all pass — the legacy `true → .branchUpstream` / `false`/absent `→ .auto` behavior still works through the legacy-key container.

- [ ] **Step 4: Commit.**

```bash
git add Alas/Sources/Persistence/AppConfig.swift
git commit -m "chore(config): drop legacy trackUpstreamForCommits bool"
```

---

## Self-review notes

- **Spec coverage:** Auto/Upstream/Manual modes (Tasks 1+3), `origin/<base>`-first Auto resolution (Task 1 `.baseOriginFirst`), config enum + migration OFF→Auto / ON→Branch upstream (Tasks 2, 5), per-worktree override → Manual (`forCommits` override branch, Task 3), review-loop base mirrors mode (`forReviewLoopBase`, Task 3), segmented UI with per-mode description (Task 4), all ~15 call sites threaded (Tasks 1, 3), test coverage for migration + resolution + mapping (Tasks 1–3). No non-goals implemented (no override persistence, no diff two/three-dot change).
- **Type consistency:** `BaseResolution` (cases `upstreamThenBase`/`baseOriginFirst`/`baseLocalFirst`, `Equatable`) is defined in Task 1 and consumed unchanged in Task 3; `ChangesComparisonMode` (cases `auto`/`branchUpstream`/`manual`) defined in Task 2, consumed in Tasks 3–5; `state(for:baseBranch:comparisonMode:)` renamed once (Task 3) and all four callers updated in the same task.
- **Green between tasks:** the legacy bool intentionally coexists with `comparisonMode` from Task 2 until Task 5 so every intermediate task builds and tests clean; `ChangesPane` keeps binding the bool until Task 4, and the bool is only removed once nothing reads it (Task 5 Step 1 guards this).
