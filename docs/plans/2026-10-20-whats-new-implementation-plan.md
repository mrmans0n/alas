# What's New Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After updating to a stable release that has a curated entry, show a corner card with one headline feature (plus up to two "also" items), with entries authored at release time and bundled into the app.

**Architecture:** Entry model, bundle catalog loading/validation, and the show/no-show decision are UI-free and live in `Packages/AlasCore/Sources/AlasCore/Updates/`. The app owns a thin `WhatsNewController` (seen-version persistence, presentation state) and a SwiftUI corner card overlaid on the root view. Entries live in `Alas/Resources/WhatsNew/` (folder reference, like `VisualAid`); a core test validates every committed entry, and the release workflow runs that test before publishing.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit, Swift Testing, XcodeGen, GitHub Actions.

**Spec:** `docs/plans/2026-10-20-whats-new-design.md`

## Global Constraints

- Core code must not import SwiftUI/AppKit; anything the app uses from it is `public`.
- Stable track only shows the card automatically; nightly neither reads nor writes the seen-version key.
- `also` holds at most two items; entry `version` must equal the filename stem.
- `action` must be one of the app's fixed identifiers; no arbitrary URLs/commands.
- Card: bottom-right, non-modal, no backdrop, never takes keyboard focus, never times out.
- Header reads `New in <major>.<minor>` of the **entry's** version; Release notes opens `https://github.com/mrmans0n/alas/releases/tag/v<entry version>`.
- Primary button label defaults to `Try it` when `actionLabel` is absent.
- English UI strings. Tests use Swift Testing; follow AGENTS.md testing policy (no view tests).
- After editing `project.yml`, run `xcodegen` and commit `Alas.xcodeproj` too.

## Review Focus

1. **Downgrade then re-upgrade** (0.22 → 0.21 → 0.22): the 0.22 card must not reappear; the stored seen version never decreases. → Task 2 test.
2. **Entry newer than the running build** (a `0.23.0.json` committed before the version bump): never shown by 0.22.x, never offered by Help → What's New. → Task 2 tests.
3. **Media path escaping the WhatsNew folder** (`../x.gif`, absolute path): rejected as invalid, not loaded. → Task 1 test.
4. **A broken entry at runtime** (should be impossible after the release check, but): the catalog skips it and keeps the valid ones; the app never crashes. → Task 1 test.
5. **Quit while the card is open**: the card comes back next launch because the seen version only advances on dismiss/action. → Task 2 test (policy) + Task 4 controller wiring.

---

### Task 1: Entry model, actions, and catalog loading

**Files:**
- Create: `Packages/AlasCore/Sources/AlasCore/Updates/WhatsNew.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/WhatsNewTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum WhatsNewAction: String, Codable, CaseIterable, Sendable { case openPluginSettings }
  public struct WhatsNewHeadline: Codable, Equatable, Sendable {
      public let title: String; public let body: String
      public let media: String?; public let action: WhatsNewAction?; public let actionLabel: String?
  }
  public struct WhatsNewAlso: Codable, Equatable, Sendable { public let title: String }
  public struct WhatsNewEntry: Codable, Equatable, Sendable {
      public let version: SemanticVersion        // decoded from the "version" string
      public let headline: WhatsNewHeadline
      public let also: [WhatsNewAlso]            // missing key → []
      public var headerTitle: String { get }     // "New in 0.22"
      public var releaseNotesURL: URL { get }    // .../releases/tag/v0.22.0
  }
  public struct WhatsNewProblem: Equatable, Sendable { public let file: String; public let message: String }
  public struct WhatsNewCatalog: Sendable {
      public let directory: URL
      public let entries: [WhatsNewEntry]        // valid only, sorted ascending by version
      public let problems: [WhatsNewProblem]
      public static func load(directory: URL, fileManager: FileManager = .default) -> WhatsNewCatalog
      public func mediaURL(for entry: WhatsNewEntry) -> URL?
  }
  ```
  `SemanticVersion` needs `Codable` (single-value string via `init?(parsing:)`); add the conformance in this file as an extension if it lacks one.

- [ ] **Step 1: Write the failing tests** in `WhatsNewTests.swift`, building a temp directory per test (`FileManager.default.temporaryDirectory` + UUID) with JSON files and empty media files:

  - `loadsAValidEntryWithOptionalFieldsMissing` — file `0.22.0.json` with only `version` and `headline.title/body`; expect one entry, `also == []`, `headline.action == nil`, `problems.isEmpty`.
  - `headerAndReleaseNotesUseTheEntryVersion` — entry `0.22.1`: `headerTitle == "New in 0.22"`, `releaseNotesURL.absoluteString == "https://github.com/mrmans0n/alas/releases/tag/v0.22.1"`.
  - `@Test(arguments:) rejectsInvalidEntries` — each case is one file, expect `entries.isEmpty` and one problem naming the file:
    - `version` `"0.22.1"` in `0.22.0.json` (filename mismatch)
    - `"media": "media/missing.gif"` (no such file)
    - `"media": "../escape.gif"` and `"media": "/tmp/x.gif"` (outside the directory)
    - `"action": "launchMissiles"` (unknown action)
    - three `also` items
    - malformed JSON
  - `keepsValidEntriesWhenAnotherIsBroken` — `0.21.0.json` valid, `0.22.0.json` malformed: `entries.map(\.version) == [0.21.0]`, `problems.count == 1`.
  - `ignoresNonJSONFilesAndMediaFolder` — a `README.md` and `media/` dir alongside one valid entry: one entry, no problems.

- [ ] **Step 2: Run to verify failure**

  Run: `swift test --package-path Packages/AlasCore --filter WhatsNewTests`
  Expected: compile failure (`WhatsNewCatalog` not found).

- [ ] **Step 3: Implement `WhatsNew.swift`**

  Load every top-level `*.json` in `directory`; decode with `JSONDecoder`; then validate (stem == `version.description`, `also.count <= 2`, media resolved via `directory.appendingPathComponent(media).standardizedFileURL` must stay under `directory.standardizedFileURL.path` and exist). Decoding errors (including unknown action) become a `WhatsNewProblem`. Missing directory → empty catalog, no problems.

- [ ] **Step 4: Run to verify pass**

  Run: `swift test --package-path Packages/AlasCore --filter WhatsNewTests`
  Expected: all `WhatsNewTests` pass.

- [ ] **Step 5: Commit**

  ```bash
  git add Packages/AlasCore/Sources/AlasCore/Updates/WhatsNew.swift Packages/AlasCore/Tests/AlasCoreTests/WhatsNewTests.swift
  git commit -m "feat(updates): load and validate bundled what's new entries"
  ```

### Task 2: Show/no-show policy

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasCore/Updates/WhatsNew.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/WhatsNewTests.swift` (extend)

**Interfaces:**
- Consumes: `WhatsNewEntry`, `SemanticVersion`, `ReleaseTrack`.
- Produces:
  ```swift
  public enum WhatsNewPolicy {
      public struct LaunchDecision: Equatable, Sendable {
          public let entry: WhatsNewEntry?            // card to show now
          public let seenVersionToStore: SemanticVersion?  // write immediately; nil = leave untouched
      }
      public static func onLaunch(track: ReleaseTrack, current: SemanticVersion,
                                  lastSeen: SemanticVersion?, isExistingInstall: Bool,
                                  entries: [WhatsNewEntry]) -> LaunchDecision
      /// Value to store when the card is dismissed or acted on.
      public static func seenVersionAfterDismiss(current: SemanticVersion,
                                                 lastSeen: SemanticVersion?) -> SemanticVersion
      /// Entry for Help → What's New: newest with version <= current.
      public static func latestEntry(current: SemanticVersion, entries: [WhatsNewEntry]) -> WhatsNewEntry?
  }
  ```

  Rules (from spec):
  - nightly → `(nil, nil)`.
  - `lastSeen == nil && !isExistingInstall` (fresh) → `(nil, current)`.
  - `lastSeen == nil && isExistingInstall` → entry with version == current if any; store `current` only when there is none.
  - `lastSeen < current` → newest entry with `lastSeen < version <= current`; store `current` only when there is none.
  - `lastSeen >= current` (same or downgrade) → `(nil, nil)` (never lower the stored value).
  - `seenVersionAfterDismiss` → `max(current, lastSeen ?? current)`.

- [ ] **Step 1: Write the failing tests** (entries fixture: `0.21.0`, `0.22.0`, `0.23.0`; build `WhatsNewEntry` values directly):

  `@Test(arguments:) launchDecision(track, current, lastSeen, existing, expectedEntry, expectedStore)`:

  | case | track | current | lastSeen | existing | entry | store |
  |---|---|---|---|---|---|---|
  | fresh install | stable | 0.22.0 | nil | false | nil | 0.22.0 |
  | existing user, first release with feature | stable | 0.22.0 | nil | true | 0.22.0 | nil |
  | existing user, no entry for current | stable | 0.22.1 | nil | true | nil | 0.22.1 |
  | update with entry | stable | 0.22.0 | 0.21.0 | – | 0.22.0 | nil |
  | multi-version jump fills from skipped | stable | 0.22.1 | 0.21.5 | – | 0.22.0 | nil |
  | update without entry in range | stable | 0.21.3 | 0.21.0 | – | nil | 0.21.3 |
  | entry newer than build ignored | stable | 0.22.5 | 0.22.0 | – | nil | 0.22.5 |
  | same version (quit with card answered) | stable | 0.22.0 | 0.22.0 | – | nil | nil |
  | downgrade | stable | 0.21.0 | 0.22.0 | – | nil | nil |
  | nightly | nightly | 0.22.0 | 0.21.0 | – | nil | nil |

  (Card left unanswered across a quit is covered by "update with entry": lastSeen is still 0.21.0 next launch.)

  - `dismissNeverLowersTheSeenVersion` — `seenVersionAfterDismiss(current: 0.21.0, lastSeen: 0.22.0) == 0.22.0`; `(0.22.0, 0.21.0) == 0.22.0`; `(0.22.0, nil) == 0.22.0`.
  - `helpMenuSkipsEntriesNewerThanTheBuild` — `latestEntry(current: 0.22.4, …)?.version == 0.22.0`; `latestEntry(current: 0.20.0, …) == nil`.

- [ ] **Step 2: Run to verify failure** — `swift test --package-path Packages/AlasCore --filter WhatsNewTests`; expect compile failure on `WhatsNewPolicy`.
- [ ] **Step 3: Implement `WhatsNewPolicy`** per the rules above.
- [ ] **Step 4: Run to verify pass** — same command, all pass.
- [ ] **Step 5: Commit** — `git commit -m "feat(updates): decide when to show the what's new card"`

### Task 3: Bundle the entries folder and gate releases on it

**Files:**
- Create: `Alas/Resources/WhatsNew/README.md` (one paragraph: what this folder is; points to `RELEASING.md`). Keeps the folder in git and in the bundle before the first entry exists.
- Modify: `project.yml` (Alas target `sources`, next to `Alas/Resources/VisualAid`):
  ```yaml
      - path: Alas/Resources/WhatsNew
        buildPhase: resources
        type: folder
  ```
- Regenerate: `Alas.xcodeproj` via `xcodegen`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/WhatsNewTests.swift` (extend)
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `WhatsNewCatalog.load(directory:)`.
- Produces: bundle folder `WhatsNew` at `Bundle.main.url(forResource: "WhatsNew", withExtension: nil)`; CI job `whats-new-check`.

- [ ] **Step 1: Write the repository test** `committedEntriesAreValid`: resolve `Alas/Resources/WhatsNew` from `#filePath` (`../../../../Alas/Resources/WhatsNew` relative to the test file), `#require` the directory exists, load the catalog, `#expect(catalog.problems.isEmpty, "\(catalog.problems)")`. This runs in normal CI on every PR and push.
- [ ] **Step 2: Run** — `swift test --package-path Packages/AlasCore --filter WhatsNewTests`; fails until the folder exists, then passes after Step 3.
- [ ] **Step 3: Add the folder and `project.yml` entry, run `xcodegen`.**
- [ ] **Step 4: Add a `whats-new-check` job to `release.yml`** on `macos-26`, checking out the same ref as `publish`, running `swift test --package-path Packages/AlasCore --filter WhatsNewTests`. Add it to `publish`'s `needs` so it runs in parallel with `macos-app` and blocks publishing. Keep `timeout-minutes: 30`.
- [ ] **Step 5: Verify** — `swift test --package-path Packages/AlasCore --filter WhatsNewTests` passes; `xcodebuild … -quiet build` succeeds; `ls "$(…)/Alas.app/Contents/Resources/WhatsNew/README.md"` exists in the built product.
- [ ] **Step 6: Commit**
  ```bash
  git add Alas/Resources/WhatsNew project.yml Alas.xcodeproj .github/workflows/release.yml Packages/AlasCore/Tests/AlasCoreTests/WhatsNewTests.swift
  git commit -m "build: bundle what's new entries and validate them before release"
  ```

### Task 4: Controller, corner card, and Help menu

**Files:**
- Create: `Alas/Sources/Updates/WhatsNewController.swift`
- Create: `Alas/Sources/Updates/WhatsNewCard.swift`
- Modify: `Alas/Sources/App/AppState.swift` (next to `lazy var updates`, ~line 1012)
- Modify: `Alas/Sources/App/RootView.swift` (new `RootWhatsNewPresentation` modifier beside `RootUpdatePresentationHandlers`, ~line 915, applied in the same chain)
- Modify: `Alas/Sources/App/AlasApp.swift` (Help menu)

**Interfaces:**
- Consumes: `WhatsNewCatalog`, `WhatsNewPolicy`, `BuildIdentity.current()`, `AlasProfile.userDefaults`.
- Produces:
  ```swift
  @MainActor @Observable final class WhatsNewController {
      var presented: WhatsNewEntry?
      let catalog: WhatsNewCatalog
      init(identity: BuildIdentity = .current(), catalog: WhatsNewCatalog = .bundled(),
           defaults: UserDefaults = AlasProfile.userDefaults)
      func evaluateOnLaunch()          // applies WhatsNewPolicy.onLaunch; sets presented / writes store
      func showLatest()                // Help menu; presents latestEntry, no store change
      var hasLatest: Bool { get }
      func dismiss()                   // presented = nil; on stable, store seenVersionAfterDismiss
  }
  extension WhatsNewCatalog { static func bundled() -> WhatsNewCatalog }  // app-side, Bundle.main
  ```
  Seen key: `io.nlopez.alas.whatsNew.lastSeenVersion` (string). Existing-install signal: `defaults.object(forKey: "io.nlopez.alas.updates.lastCheckedAt") != nil`. Log `catalog.problems` once via the app's existing logging; never crash.

- [ ] **Step 1: Implement `WhatsNewController`** and `AppState.whatsNew` (`@ObservationIgnored lazy var whatsNew = WhatsNewController()`).
- [ ] **Step 2: Implement `WhatsNewCard(entry:mediaURL:onAction:onReleaseNotes:onDismiss:)`** matching the spec layout: header `entry.headerTitle` with ✕; media only when `mediaURL != nil` (animated via an `NSViewRepresentable` wrapping `NSImageView` with `animates = true`, `imageScaling = .scaleProportionallyUpOrDown`); title; body; `Also: a · b` line only when `also` is non-empty; primary button (`actionLabel ?? "Try it"`) only when `action != nil`; `Release notes` link button. Fixed width ~320pt, themed via `\.theme`. No `.focusable`, no default-button keyboard shortcut.
- [ ] **Step 3: Wire `RootWhatsNewPresentation`**: `.overlay(alignment: .bottomTrailing)` with ~16pt padding, shown when `state.whatsNew.presented != nil && state.updates.presentedUpdate == nil && !state.presentUpdateProgress`; `.task { state.whatsNew.evaluateOnLaunch() }`. Action dispatch:
  - `.openPluginSettings` → `NotificationCenter.default.post(name: .alasOpenSettings, object: SettingsSection.plugins)`
  - Release notes → `NSWorkspace.shared.open(entry.releaseNotesURL)`
  - All three call `state.whatsNew.dismiss()`.
- [ ] **Step 4: Help menu** in `AlasApp.swift`: `CommandGroup(before: .help) { Button("What's New…") { state.whatsNew.showLatest() }.disabled(!state.whatsNew.hasLatest) }`.
- [ ] **Step 5: Build** — `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build`; expect success.
- [ ] **Step 6: Hands-on check (do not commit the fixture)**: add a temporary `Alas/Resources/WhatsNew/0.21.9.json` (current version) with a headline using `openPluginSettings`, one `also`, and a small GIF; build; `open` the built app (do not quit the user's running Alas); use Help → What's New… and confirm: card bottom-right, typing in a terminal still works while it is visible, Try it opens Settings → Plugins and closes the card, ✕ closes it. Remove the fixture afterwards.
- [ ] **Step 7: Commit**
  ```bash
  git add Alas/Sources/Updates/WhatsNewController.swift Alas/Sources/Updates/WhatsNewCard.swift Alas/Sources/App/AppState.swift Alas/Sources/App/RootView.swift Alas/Sources/App/AlasApp.swift
  git commit -m "feat(updates): show a what's new card after updating"
  ```

### Task 5: Release docs and the Hermes skill step

**Files:**
- Modify: `RELEASING.md`
- Add: `docs/plans/2026-10-20-whats-new-design.md`, `docs/plans/2026-10-20-whats-new-implementation-plan.md`

- [ ] **Step 1: Update `RELEASING.md`**
  - Insert a new step 4 between "Promote the curated notes" and "Bump the version": pick highlights from the new section's `✨ Features` (one headline, 0–2 also, or none); write `Alas/Resources/WhatsNew/<version>.json` with short marketing copy; put media in `Alas/Resources/WhatsNew/media/<version>-<slug>.gif` (keep under ~2 MB); add the file(s) to the release commit's `git add`. "None" = no file. Renumber later steps.
  - Add a "What's new entries" section: the JSON format from the spec (with field meanings and which are optional), the valid `action` identifiers (`openPluginSettings` — opens Settings → Plugins), the note that adding an action is an app change shipped with the feature, how to preview locally (Help → What's New… on a build whose version >= the entry), and that `whats-new-check` blocks publishing on an invalid entry.
- [ ] **Step 2: Commit**
  ```bash
  git add RELEASING.md docs/plans/2026-10-20-whats-new-design.md docs/plans/2026-10-20-whats-new-implementation-plan.md
  git commit -m "docs: describe curating what's new entries at release time"
  ```
- [ ] **Step 3: Draft the Hermes skill step** as plain text in the final hand-off message (not committed): after promoting the changelog, show the `✨ Features` bullets numbered, ask the maintainer for a headline number, up to two also numbers, or "none"; draft the JSON per `RELEASING.md`; ask for media path and action (from the documented list) or skip; show the file for approval; include it in the release commit.
