# Needs attention feature flag implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide Needs Attention until a user enables its debug feature flag, without stopping event collection.

**Architecture:** Persist `needsAttentionEnabled` in `AppConfig`, expose a Debug toggle, and project the flag in `SidebarView`. Sidebar presentation receives real attention state only when enabled; the attention store and producers remain unchanged.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Testing, XcodeGen.

---

### Task 1: Persist the feature flag

**Files:**
- Modify: `Alas/Sources/Persistence/AppConfig.swift`
- Test: `AlasTests/AppConfigTests.swift`

- [ ] **Step 1: Write failing tests for the default and legacy decode behavior**

```swift
#expect(AppConfig.defaults.needsAttentionEnabled == false)
// Remove "needsAttentionEnabled" from an encoded config, decode it, then:
#expect(decoded.needsAttentionEnabled == false)
```

- [ ] **Step 2: Run the focused tests and verify they fail because the property is absent**

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppConfigTests`

- [ ] **Step 3: Add `needsAttentionEnabled` to `AppConfig`**

Add the Boolean with a `false` property default, initialize it as `false` in `AppConfig.defaults`, include its coding key, and decode absent keys as `false`.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AppConfigTests`

### Task 2: Gate sidebar presentation and add the Debug control

**Files:**
- Modify: `Alas/Sources/Settings/AdvancedPane.swift`
- Modify: `Alas/Sources/Sidebar/SidebarView.swift`
- Modify: `Alas/Sources/Sidebar/SidebarHeaderView.swift`
- Test: `AlasTests/Attention/AttentionInboxViewTests.swift`

- [ ] **Step 1: Write a failing test for sidebar presentation**

Extract a small, pure `SidebarAttentionPresentation` value from `SidebarView`. It receives the enabled flag and aggregation, and exposes whether to show the inbox plus the global and per-project counts. Assert disabled presentation hides the inbox and returns zero counts. Assert enabled presentation preserves the aggregation values.

- [ ] **Step 2: Run the focused attention tests and verify the new test fails**

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AttentionInboxViewTests`

- [ ] **Step 3: Implement the smallest presentation gate**

Add the `Needs attention` Settings > Debug > Experimental toggle using `state.config.needsAttentionEnabled` and `state.saveConfig()`. Add `showsAttentionInbox` to `SidebarHeaderView` and use it to omit the toolbar button from both header variants. In `SidebarView`, use `SidebarAttentionPresentation` for the header and project counts. When disabling, set `state.isAttentionInboxOpen` to `false`, covered by the focused test.

- [ ] **Step 4: Run focused attention tests and verify they pass**

Run: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/AttentionInboxViewTests`

### Task 3: Regenerate, verify, review, and publish

**Files:**
- Modify: `Alas.xcodeproj/project.pbxproj` only if `xcodegen` changes it

- [ ] **Step 1: Regenerate the Xcode project**

Run: `rtk xcodegen`

- [ ] **Step 2: Run required verification**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
rtk git diff --check
```

- [ ] **Step 3: Commit and request review**

Commit the implementation and tests, push the branch, open a pull request, then address every actionable review finding and failing CI check.
