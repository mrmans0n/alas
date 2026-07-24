# New Worktree Two-State GG Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the new-worktree dialog's inherited GG policy choice with icon-led explicit On and Off choices initialized from the selected repository's effective policy.

**Architecture:** Keep `GGWorktreeMode.inherit` for existing persistence and sidebar behavior, but resolve it to `.on` or `.off` at the dialog boundary. Extract the established custom three-line GG glyph into a reusable SwiftUI component with a slashed variant, then render that component through the dialog's shared segment renderer.

**Tech Stack:** Swift 5.9+, SwiftUI for macOS, Swift Testing, XcodeGen, `xcodebuild`

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Use Swift Testing (`import Testing`), not XCTest.
- Do not change project-level GG policy, existing-worktree inheritance, GG availability, branch naming, stack-base pinning, or remote-project behavior.
- Do not introduce a third visible or hidden creation state: every dialog creation passes explicit `.on` or `.off`.
- Preserve the existing custom GG glyph geometry instead of replacing it with `line.3.horizontal`.
- Prefix shell commands with `rtk`.
- If `project.yml` changes, run `rtk xcodegen` and commit both `project.yml` and `Alas.xcodeproj`; this implementation should not require a `project.yml` change because source folders are discovered recursively.

---

## File Map

- Create `Alas/Sources/Integrations/GG/GGStackIcon.swift`: shared three-line GG glyph, normal/slashed variants, and deterministic slash overlay.
- Modify `Alas/Sources/Sidebar/WorktreeRowView.swift`: replace the private shape with the shared normal glyph and delete the duplicate private shape.
- Modify `Alas/Sources/Dialogs/NewWorktreeDialog.swift`: resolve initial explicit GG mode, expose only On/Off segments, attach GG icon variants, and render system or GG icons through one segment helper.
- Modify `AlasTests/NewWorktreeDialogTests.swift`: cover policy resolution, repository-reset semantics, explicit segment definitions, and icon variants.
- Use existing `AlasTests/WorktreeRowHeightTests.swift` unchanged as the sidebar-layout regression after extracting the icon.

---

### Task 1: Resolve Repository Policy Into An Explicit Dialog Mode

**Files:**
- Modify: `AlasTests/NewWorktreeDialogTests.swift:340-375`
- Modify: `Alas/Sources/Dialogs/NewWorktreeDialog.swift:18-25`
- Modify: `Alas/Sources/Dialogs/NewWorktreeDialog.swift:125-160`
- Modify: `Alas/Sources/Dialogs/NewWorktreeDialog.swift:414-435`
- Modify: `Alas/Sources/Dialogs/NewWorktreeDialog.swift:482-505`

**Interfaces:**
- Consumes: `GGWorktreeContextResolver.isPolicyEnabled(projectMode:worktreeOverride:isMainWorktree:repoHasGGConfig:)`.
- Produces: `NewWorktreeDialog.initialGGMode(projectMode:repoHasGGConfig:) -> GGWorktreeMode`.
- Produces: `NewWorktreeDialog.ggModeAfterRepositoryChange(projectMode:repoHasGGConfig:) -> GGWorktreeMode`.
- Produces: a dialog invariant that `ggMode` is `.on` or `.off` before creation.

- [ ] **Step 1: Replace the inherited-mode tests with failing explicit-default tests**

In `AlasTests/NewWorktreeDialogTests.swift`, replace
`repositoryChangeResetsGGModeToInherit` and update the segment-order test:

```swift
@Test(arguments: [
    (GGProjectMode.off, false, GGWorktreeMode.off),
    (GGProjectMode.off, true, GGWorktreeMode.off),
    (GGProjectMode.on, false, GGWorktreeMode.on),
    (GGProjectMode.on, true, GGWorktreeMode.on),
    (GGProjectMode.auto, false, GGWorktreeMode.off),
    (GGProjectMode.auto, true, GGWorktreeMode.on),
])
func initialGGModeResolvesRepositoryPolicy(
    projectMode: GGProjectMode,
    repoHasGGConfig: Bool,
    expected: GGWorktreeMode
) {
    #expect(NewWorktreeDialog.initialGGMode(
        projectMode: projectMode,
        repoHasGGConfig: repoHasGGConfig
    ) == expected)
}

@Test func repositoryChangeReplacesExplicitChoiceWithNewRepositoryDefault() {
    #expect(NewWorktreeDialog.ggModeAfterRepositoryChange(
        projectMode: .off,
        repoHasGGConfig: true
    ) == .off)
    #expect(NewWorktreeDialog.ggModeAfterRepositoryChange(
        projectMode: .auto,
        repoHasGGConfig: true
    ) == .on)
}

@Test func ggModeSegmentsMatchDialogOrder() {
    #expect(NewWorktreeDialog.ggModeSegments.map(\.mode) == [.on, .off])
    #expect(NewWorktreeDialog.ggModeSegments.map(\.label) == ["On", "Off"])
}
```

Keep `explicitGGDescriptionsExplainCreation`. Remove
`inheritedGGDescriptionReportsEffectiveMode`, because the dialog can no longer
select `.inherit`.

- [ ] **Step 2: Run the focused tests and verify the new API expectations fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/NewWorktreeDialogTests test
```

Expected: FAIL to compile because `initialGGMode(projectMode:repoHasGGConfig:)`
does not exist and `ggModeAfterRepositoryChange` has the old signature.

- [ ] **Step 3: Add the explicit policy resolver**

In `NewWorktreeDialog.swift`, replace the old repository-change helper with:

```swift
nonisolated static func initialGGMode(
    projectMode: GGProjectMode,
    repoHasGGConfig: Bool
) -> GGWorktreeMode {
    GGWorktreeContextResolver.isPolicyEnabled(
        projectMode: projectMode,
        worktreeOverride: .inherit,
        isMainWorktree: false,
        repoHasGGConfig: repoHasGGConfig
    ) ? .on : .off
}

nonisolated static func ggModeAfterRepositoryChange(
    projectMode: GGProjectMode,
    repoHasGGConfig: Bool
) -> GGWorktreeMode {
    initialGGMode(
        projectMode: projectMode,
        repoHasGGConfig: repoHasGGConfig
    )
}
```

Add a repository-scoped state seeder near `applyLaunchDefaults`:

```swift
private func applyGGModeDefault(for selectedProjectId: String) {
    guard let project = state.projects.first(where: { $0.id == selectedProjectId }) else {
        ggMode = .off
        return
    }
    ggMode = Self.initialGGMode(
        projectMode: project.ggMode,
        repoHasGGConfig: GGStackGate.repoHasGGConfig(repoPath: project.path)
    )
}
```

Change the initial state declaration to:

```swift
@State private var ggMode: GGWorktreeMode = .off
```

- [ ] **Step 4: Seed the explicit mode on appearance and repository changes**

In `.onAppear`, call the seeder after `projectId` is resolved and before the
initial base is derived:

```swift
applyGGModeDefault(for: projectId)
if base.isEmpty {
    base = Self.initialBase(
        configuredDefault: state.config.worktrees.baseBranch,
        stackPinnedBase: stackPinnedBase
    )
}
```

In `.onChange(of: projectId)`, replace the inherited reset with:

```swift
applyGGModeDefault(for: projectId)
applyLaunchDefaults(for: projectId)
```

Keep this before assigning `base`, so `stackPinnedBase` reflects the newly
resolved repository default.

- [ ] **Step 5: Expose only On and Off segments**

Change the segment model temporarily to:

```swift
nonisolated static let ggModeSegments: [(mode: GGWorktreeMode, label: String)] = [
    (.on, "On"),
    (.off, "Off"),
]
```

Keep the existing segment rendering text-only for this task. Task 2 adds the
shared icon model without mixing visual extraction into policy behavior.

- [ ] **Step 6: Run the focused tests and verify explicit defaults pass**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/NewWorktreeDialogTests test
```

Expected: PASS for `NewWorktreeDialogTests`, including all six policy cases and
the two-segment order.

- [ ] **Step 7: Commit the two-state behavior**

```bash
rtk git add Alas/Sources/Dialogs/NewWorktreeDialog.swift AlasTests/NewWorktreeDialogTests.swift
rtk git commit -m "feat(gg): make new worktree mode explicit"
```

---

### Task 2: Share The GG Stack Glyph And Add The Slashed Variant

**Files:**
- Create: `Alas/Sources/Integrations/GG/GGStackIcon.swift`
- Modify: `Alas/Sources/Sidebar/WorktreeRowView.swift:145-180`
- Modify: `Alas/Sources/Sidebar/WorktreeRowView.swift:276-300`
- Modify: `Alas/Sources/Dialogs/NewWorktreeDialog.swift:482-505`
- Modify: `Alas/Sources/Dialogs/NewWorktreeDialog.swift:590-640`
- Modify: `AlasTests/NewWorktreeDialogTests.swift:365-380`
- Verify unchanged: `AlasTests/WorktreeRowHeightTests.swift`

**Interfaces:**
- Produces: `enum GGStackIconVariant: Equatable { case stack, disabled }`.
- Produces: `struct GGStackIcon: View` initialized with
  `init(variant: GGStackIconVariant = .stack, size: CGFloat, color: Color)`.
- Produces: `enum NewWorktreeSegmentIcon: Equatable` with `.system(String)` and
  `.gg(GGStackIconVariant)`.
- Produces: `struct NewWorktreeGGModeSegment: Equatable` with `mode`, `label`,
  and `icon`.

- [ ] **Step 1: Extend the segment test to require GG icon variants**

Replace the Task 1 segment test with:

```swift
@Test func ggModeSegmentsMatchDialogOrderAndIcons() {
    #expect(NewWorktreeDialog.ggModeSegments == [
        NewWorktreeGGModeSegment(mode: .on, label: "On", icon: .stack),
        NewWorktreeGGModeSegment(mode: .off, label: "Off", icon: .disabled),
    ])
}
```

- [ ] **Step 2: Run the focused test and verify the missing types fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/NewWorktreeDialogTests test
```

Expected: FAIL to compile because `NewWorktreeGGModeSegment` and
`GGStackIconVariant` do not exist.

- [ ] **Step 3: Create the shared GG icon**

Create `Alas/Sources/Integrations/GG/GGStackIcon.swift`:

```swift
import SwiftUI

enum GGStackIconVariant: Equatable {
    case stack
    case disabled
}

struct GGStackIcon: View {
    let variant: GGStackIconVariant
    let size: CGFloat
    let color: Color

    init(
        variant: GGStackIconVariant = .stack,
        size: CGFloat,
        color: Color
    ) {
        self.variant = variant
        self.size = size
        self.color = color
    }

    var body: some View {
        ZStack {
            GGStackShape()
                .fill(color)
            if variant == .disabled {
                Capsule()
                    .fill(color)
                    .frame(width: 1, height: size + 2)
                    .rotationEffect(.degrees(-45))
            }
        }
        .frame(width: size, height: size)
    }
}

private struct GGStackShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let strokeHeight = min(rect.height / 9, 1)
        let strokeWidth = min(rect.width, 7)
        let x = rect.midX - strokeWidth / 2
        let yPositions = [
            rect.minY + 1,
            rect.midY - strokeHeight / 2,
            rect.maxY - strokeHeight - 1,
        ]

        for y in yPositions {
            path.addRoundedRect(
                in: CGRect(x: x, y: y, width: strokeWidth, height: strokeHeight),
                cornerSize: CGSize(width: strokeHeight / 2, height: strokeHeight / 2)
            )
        }
        return path
    }
}
```

- [ ] **Step 4: Replace both sidebar glyph call sites**

In `WorktreeRowView.swift`, replace each:

```swift
GGSidebarStackShape()
    .fill(theme.color(...))
    .frame(width: 9, height: 9)
```

with the corresponding shared view:

```swift
GGStackIcon(
    size: 9,
    color: theme.color("fg-faint")
)
```

and:

```swift
GGStackIcon(
    size: 9,
    color: theme.color("accent")
)
```

Preserve the existing `.accessibilityHidden`, `.help`, and
`.accessibilityLabel` modifiers at each call site. Delete the private
`GGSidebarStackShape` definition from the bottom of the file.

- [ ] **Step 5: Add typed dialog icon models**

Above `NewWorktreeDialog`, add:

```swift
enum NewWorktreeSegmentIcon: Equatable {
    case system(String)
    case gg(GGStackIconVariant)
}

struct NewWorktreeGGModeSegment: Equatable {
    let mode: GGWorktreeMode
    let label: String
    let icon: GGStackIconVariant
}
```

Replace `ggModeSegments` with:

```swift
nonisolated static let ggModeSegments: [NewWorktreeGGModeSegment] = [
    .init(mode: .on, label: "On", icon: .stack),
    .init(mode: .off, label: "Off", icon: .disabled),
]
```

At the GG segment call site, pass:

```swift
icon: .gg(segmentItem.icon),
```

For launch segments, wrap the existing symbol names:

```swift
icon: .system("circle.slash")
icon: .system("terminal")
icon: .system("sparkle")
```

- [ ] **Step 6: Render either system or GG segment icons**

Change the segment helper parameter from `String?` to:

```swift
icon: NewWorktreeSegmentIcon?,
```

Inside the button label, replace the current optional `Icon` block with:

```swift
if let icon {
    let iconColor = isSelected ? theme.color("fg") : theme.color("fg-muted")
    switch icon {
    case .system(let name):
        Icon(name: name, size: 11, color: iconColor)
    case .gg(let variant):
        GGStackIcon(variant: variant, size: 11, color: iconColor)
            .accessibilityHidden(true)
    }
}
```

The adjacent text remains the accessibility name for each segment, matching
the launch-surface pattern.

- [ ] **Step 7: Run focused dialog and sidebar regressions**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/NewWorktreeDialogTests \
  -only-testing:AlasTests/WorktreeRowHeightTests test
```

Expected: PASS. `NewWorktreeDialogTests` confirms the On/Off icon model;
`WorktreeRowHeightTests` confirms the extracted sidebar glyph preserves row
height, tooltip terminology, and accessibility-label terminology.

- [ ] **Step 8: Build the app for visual/compile validation**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0 with no compiler errors. Open the dialog and confirm the
normal and slashed glyphs remain legible at the 11-point segment size.

- [ ] **Step 9: Commit the shared icon**

```bash
rtk git add Alas/Sources/Integrations/GG/GGStackIcon.swift \
  Alas/Sources/Sidebar/WorktreeRowView.swift \
  Alas/Sources/Dialogs/NewWorktreeDialog.swift \
  AlasTests/NewWorktreeDialogTests.swift
rtk git commit -m "feat(gg): add mode icons to worktree creation"
```

---

### Task 3: Required Full Verification

**Files:**
- Verify: `project.yml`
- Verify: `Alas.xcodeproj`
- Verify: all files changed by Tasks 1 and 2

**Interfaces:**
- Consumes: the explicit dialog-mode resolver and shared GG icon from Tasks 1
  and 2.
- Produces: evidence that generated project state, the app build, and the full
  test suite are green.

- [ ] **Step 1: Regenerate the Xcode project**

Run:

```bash
rtk xcodegen
```

Expected: successful generation. Then run:

```bash
rtk git status --short
```

Expected: no `project.yml` or `Alas.xcodeproj` diff. If generation changes
`Alas.xcodeproj`, inspect and include only the expected source-discovery change.

- [ ] **Step 2: Run the required quiet macOS build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0.

- [ ] **Step 3: Run the required full test suite**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: `** TEST SUCCEEDED **` with no failures.

- [ ] **Step 4: Inspect final scope**

Run:

```bash
rtk git status --short
rtk git diff HEAD~2 --stat
rtk git diff HEAD~2 --check
```

Expected: only the planned GG icon/dialog/test files are changed by the two
implementation commits, and `git diff --check` reports no whitespace errors.

- [ ] **Step 5: Commit generated state only if regeneration changed it**

If and only if Step 1 produced an expected generated-project diff:

```bash
rtk git add Alas.xcodeproj
rtk git commit -m "chore: regenerate Xcode project"
```

Otherwise, do not create an empty verification commit.
