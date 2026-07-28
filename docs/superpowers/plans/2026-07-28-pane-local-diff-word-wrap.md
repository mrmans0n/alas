# Pane-Local Diff Word Wrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every diff pane that exposes the word-wrap toggle start unwrapped and keep its word-wrap choice local to that pane's lifetime.

**Architecture:** Each pane root owns `@State private var wrapLines = false` and supplies `$wrapLines` to `DiffPreferenceBindings`. The binding helper continues to persist layout mode, but forwards word wrap and whitespace to pane-local storage; the obsolete `AppConfig.Changes.diffWrapLines` field is removed so old saved values have no effect.

**Tech Stack:** Swift 5.9+, SwiftUI for macOS, Swift Testing, Xcode/XcodeGen

## Global Constraints

- Every diff pane that exposes the word-wrap toggle starts with word wrapping off.
- Enabling word wrap affects only that pane for its current lifetime and does not affect existing or future panes.
- Do not alter the word-wrap toggle appearance, diff layout defaults, whitespace behavior, or rendering implementation.
- Keep code, comments, logs, and UI strings in English.
- Tests use Swift Testing (`import Testing`), not XCTest.
- Prefix project shell commands with `rtk`.

---

### Task 1: Make Word Wrap a Pane-Local Binding

**Files:**
- Modify: `Alas/Sources/Center/Diff/DiffPreferenceBindings.swift`
- Modify: `Alas/Sources/Center/DiffTabView.swift`
- Modify: `Alas/Sources/Center/Commit/CommitTabView.swift`
- Modify: `Alas/Sources/Center/Commit/CommitEditorTabView.swift`
- Modify: `Alas/Sources/Center/Commit/DraftCommitTabView.swift`
- Modify: `Alas/Sources/Center/Review/ReviewTabView.swift`
- Modify: `Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift`
- Modify: `Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift`
- Test: `AlasTests/DiffPaneViewTests.swift`

**Interfaces:**
- Consumes: `Binding<Bool>` supplied by each pane root.
- Produces: `DiffPreferenceBindings.init(appState:wrapLines:showWhitespace:)`, whose `wrapLines` and `showWhitespace` properties forward local bindings while `layoutMode` remains backed by `AppConfig`.

- [ ] **Step 1: Replace the existing persistence test with a failing pane-isolation test**

Rename `diffPreferenceBindingsPersistLayoutAndWrapButKeepWhitespaceLocal` to `diffPreferenceBindingsPersistLayoutButKeepWrapAndWhitespacePaneLocal`. Use two independent local word-wrap values and construct the bindings with the not-yet-implemented `wrapLines:` argument:

```swift
@Test func diffPreferenceBindingsPersistLayoutButKeepWrapAndWhitespacePaneLocal() {
    let appState = AppState(store: MemoryStore())
    appState.config.changes.diffLayoutMode = .split
    appState.config.changes.diffWrapLines = false
    var firstWrapLines = false
    var secondWrapLines = false
    var firstWhitespace = false
    var secondWhitespace = false

    let first = DiffPreferenceBindings(
        appState: appState,
        wrapLines: Binding(get: { firstWrapLines }, set: { firstWrapLines = $0 }),
        showWhitespace: Binding(get: { firstWhitespace }, set: { firstWhitespace = $0 })
    )
    first.layoutMode.wrappedValue = .stacked
    first.wrapLines.wrappedValue = true
    first.showWhitespace.wrappedValue = true
    let second = DiffPreferenceBindings(
        appState: appState,
        wrapLines: Binding(get: { secondWrapLines }, set: { secondWrapLines = $0 }),
        showWhitespace: Binding(get: { secondWhitespace }, set: { secondWhitespace = $0 })
    )

    #expect(appState.config.changes.diffLayoutMode == .stacked)
    #expect(appState.config.changes.diffWrapLines == false)
    #expect(first.wrapLines.wrappedValue == true)
    #expect(second.wrapLines.wrappedValue == false)
    #expect(first.showWhitespace.wrappedValue == true)
    #expect(second.showWhitespace.wrappedValue == false)
}
```

This test catches the production bug where toggling word wrap mutates the shared configuration and changes later panes.

- [ ] **Step 2: Run the focused test to verify RED**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneViewTests/diffPreferenceBindingsPersistLayoutButKeepWrapAndWhitespacePaneLocal test
```

Expected: compilation fails because `DiffPreferenceBindings` has no `wrapLines:` initializer argument.

- [ ] **Step 3: Change `DiffPreferenceBindings` to forward pane-local word wrap**

Add local storage and remove the config-backed word-wrap getter/setter:

```swift
struct DiffPreferenceBindings {
    let appState: AppState
    private let wrapLinesStorage: Binding<Bool>
    private let showWhitespaceStorage: Binding<Bool>

    init(
        appState: AppState,
        wrapLines: Binding<Bool>,
        showWhitespace: Binding<Bool>
    ) {
        self.appState = appState
        self.wrapLinesStorage = wrapLines
        self.showWhitespaceStorage = showWhitespace
    }

    // layoutMode remains unchanged.

    var wrapLines: Binding<Bool> {
        wrapLinesStorage
    }

    var showWhitespace: Binding<Bool> {
        showWhitespaceStorage
    }
}
```

- [ ] **Step 4: Give every currently persisted pane root local word-wrap state**

Add this next to each root's existing local `showWhitespace` state:

```swift
@State private var wrapLines = false
@State private var showWhitespace = false
```

Apply it to:

- `DiffTabView`
- `CommitTabView`
- `CommitEditorTabView`
- `DraftCommitTabView`
- `ReviewTabView`
- `ReviewChangesTabView`
- `DraftReviewRequestTabView`

Update each root's helper construction to:

```swift
private var diffPreferences: DiffPreferenceBindings {
    DiffPreferenceBindings(
        appState: appState,
        wrapLines: $wrapLines,
        showWhitespace: $showWhitespace
    )
}
```

`StashDiffTabView` and `GGSplitCommitTabView` already declare `@State private var wrapLines = false`; leave them unchanged.

- [ ] **Step 5: Keep review-session wrap state local even when `AppState` is available**

`ReviewSessionTabView` already owns `localWrapLines = false`. Supply it to both helper constructions:

```swift
private var layoutModeBinding: Binding<DiffLayoutMode> {
    guard let appState else { return $localLayoutMode }
    return DiffPreferenceBindings(
        appState: appState,
        wrapLines: $localWrapLines,
        showWhitespace: $localShowWhitespace
    ).layoutMode
}

private var wrapLinesBinding: Binding<Bool> {
    guard let appState else { return $localWrapLines }
    return DiffPreferenceBindings(
        appState: appState,
        wrapLines: $localWrapLines,
        showWhitespace: $localShowWhitespace
    ).wrapLines
}
```

This preserves the existing no-`AppState` fallback while preventing an available `AppState` from changing wrap ownership.

- [ ] **Step 6: Run the focused test to verify GREEN**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneViewTests/diffPreferenceBindingsPersistLayoutButKeepWrapAndWhitespacePaneLocal test
```

Expected: the focused test passes, proving the first pane toggles locally while the second remains off and the config remains unchanged.

- [ ] **Step 7: Run the mutation check**

Temporarily reason through these regressions; the test must fail for each:

- `DiffPreferenceBindings.wrapLines` reads/writes `appState.config.changes.diffWrapLines`.
- Both test panes receive the same local `Binding`.
- Toggling layout no longer updates `appState.config.changes.diffLayoutMode`.

Do not add source-text assertions. The existing behavior test covers these mutations.

- [ ] **Step 8: Commit the pane-local binding change**

```bash
rtk git add Alas/Sources/Center/Diff/DiffPreferenceBindings.swift \
  Alas/Sources/Center/DiffTabView.swift \
  Alas/Sources/Center/Commit/CommitTabView.swift \
  Alas/Sources/Center/Commit/CommitEditorTabView.swift \
  Alas/Sources/Center/Commit/DraftCommitTabView.swift \
  Alas/Sources/Center/Review/ReviewTabView.swift \
  Alas/Sources/Center/ReviewChanges/ReviewChangesTabView.swift \
  Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift \
  Alas/Sources/Center/ReviewWorkspace/ReviewSessionTabView.swift \
  AlasTests/DiffPaneViewTests.swift
rtk git commit -m "fix(diff): keep word wrap pane-local"
```

---

### Task 2: Retire the Persisted Word-Wrap Configuration

**Files:**
- Modify: `Alas/Sources/Persistence/AppConfig.swift`
- Test: `AlasTests/AppConfigChangesTests.swift`

**Interfaces:**
- Consumes: Legacy JSON may contain `"diffWrapLines": true`.
- Produces: `AppConfig` ignores that legacy key and no longer encodes it; `diffLayoutMode` and `diffShowWhitespace` retain their existing schema behavior.

- [ ] **Step 1: Write a failing legacy-key retirement test**

Replace the wrap-specific assertions in `defaultsHaveDiffDisplayPreferences`, `decodesLegacyChangesWithoutDiffDisplayPreferences`, and `roundTripsDiffDisplayPreferences`. Add this behavior test:

```swift
@Test func ignoresAndDropsLegacyDiffWrapLines() throws {
    let json = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfig.defaults))
            as? [String: Any]
    )
    var legacy = json
    var changes = try #require(legacy["changes"] as? [String: Any])
    changes["diffWrapLines"] = true
    legacy["changes"] = changes

    let legacyData = try JSONSerialization.data(withJSONObject: legacy)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: legacyData)
    let encodedData = try JSONEncoder().encode(decoded)
    let encoded = try #require(
        JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
    )
    let encodedChanges = try #require(encoded["changes"] as? [String: Any])

    #expect(encodedChanges["diffWrapLines"] == nil)
}
```

This test catches a schema regression where an obsolete saved `true` value remains part of runtime configuration or is written back to disk.

- [ ] **Step 2: Run the focused configuration test to verify RED**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/AppConfigChangesTests/ignoresAndDropsLegacyDiffWrapLines test
```

Expected: FAIL because the current encoder still emits `diffWrapLines`.

- [ ] **Step 3: Remove `diffWrapLines` from the configuration model**

In `AppConfig.Changes`:

- remove `var diffWrapLines: Bool`;
- remove `diffWrapLines` from `Changes.CodingKeys`;
- remove `diffWrapLines: false` from both default `Changes` constructions;
- remove the decoder's `let diffWrapLines = ...` fallback;
- remove `diffWrapLines: diffWrapLines` from the decoded `Changes` construction.

Do not add a custom legacy property. Swift `Decodable` ignores unknown JSON keys, so old files continue to decode and the next save naturally drops the retired key.

- [ ] **Step 4: Update existing configuration expectations**

Keep assertions proving:

```swift
#expect(AppConfig.defaults.changes.diffLayoutMode == .split)
#expect(AppConfig.defaults.changes.diffShowWhitespace == false)
```

Keep the legacy-without-display-preferences test asserting the same two defaults. Keep the round-trip test covering `.stacked` layout and `diffShowWhitespace = true`, but remove all reads and writes of `diffWrapLines`.

- [ ] **Step 5: Run configuration tests to verify GREEN**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/AppConfigChangesTests test
```

Expected: all `AppConfigChangesTests` pass, including decoding a legacy `diffWrapLines` key and omitting it when re-encoding.

- [ ] **Step 6: Confirm no production references remain**

Run:

```bash
rtk rg -n "diffWrapLines" Alas/Sources AlasTests
```

Expected: only the legacy JSON key inside `ignoresAndDropsLegacyDiffWrapLines` remains.

- [ ] **Step 7: Commit the configuration cleanup**

```bash
rtk git add Alas/Sources/Persistence/AppConfig.swift AlasTests/AppConfigChangesTests.swift
rtk git commit -m "refactor(diff): retire persisted word wrap setting"
```

---

### Task 3: Verify All Diff Surfaces

**Files:**
- Verify only; no planned source changes.

**Interfaces:**
- Consumes: pane-local word-wrap bindings and the retired config schema from Tasks 1-2.
- Produces: formatting, focused regression coverage, and a successful macOS build.

- [ ] **Step 1: Regenerate the project**

Run:

```bash
rtk xcodegen
```

Expected: project generation succeeds. Commit generated changes only if `xcodegen` legitimately changes `Alas.xcodeproj`.

- [ ] **Step 2: Run SwiftFormat lint**

Run:

```bash
rtk swiftformat Alas AlasTests --lint --reporter github-actions-log
```

Expected: exit code 0 with no formatting violations.

- [ ] **Step 3: Run focused diff and configuration suites serially**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/DiffPaneViewTests test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/AppConfigChangesTests test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewSessionTabViewTests test
```

Expected: all three suites finish with `TEST SUCCEEDED`.

- [ ] **Step 4: Build the macOS app**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit code 0.

- [ ] **Step 5: Inspect the final diff and worktree**

Run:

```bash
rtk git diff --check
rtk git status --short
rtk git diff main...HEAD --stat
```

Expected: no whitespace errors, no unintended generated or user files, and changes limited to the approved spec, plan, diff preference wiring, configuration cleanup, and tests.

- [ ] **Step 6: Commit any legitimate generated-project change**

Only if `xcodegen` changed `Alas.xcodeproj`:

```bash
rtk git add Alas.xcodeproj
rtk git commit -m "chore: regenerate Xcode project"
```

If there is no generated change, do not create an empty commit.
