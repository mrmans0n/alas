---
task_id: 987
title: Update loading spinner UI
date: 2026-05-28
project: alas
phase: backlog
prior_art:
  - Alas/Sources/ACP/UI/ACPConnectingPlaceholder.swift (lines 86-97, canonical Spinner)
  - Alas/Sources/ACP/UI/ACPToolCallCard.swift (lines 154-165)
  - Alas/Sources/ACP/UI/ACPPlanCard.swift (lines 111-122)
---

## TL;DR

Straightforward UI consistency task. Three ACP files already define a private
`Spinner` struct (75%-arc Circle with linear rotation). That same spinner needs
to replace every `ProgressView()` used as a loading indicator across the app.
The main work is extracting a single shared `Spinner` view and swapping ~17
call sites. No architectural changes, no new dependencies.

## Scope confirmation

### In scope (v1)

- Extract a **shared `Spinner` view** from the three identical private structs
  in the ACP layer, parameterized by size (frame), line width, and animation
  duration so each call site can match its current visual weight.
- Replace every `ProgressView()` **spinner** usage in first-party Alas code
  (see call-site inventory below) with the shared `Spinner`.
- Preserve existing frame sizes, accessibility modifiers, and layout at each
  call site — the only visible change should be the spinner style itself.

### Out of scope (v1)

- **ThirdParty/ghostty/** — `UpdatePopoverView.swift` has two `ProgressView()`
  spinners (lines 103, 239) but this is vendored code; changing it creates
  merge-conflict risk on upstream syncs.
- **Determinate progress bars** — `UpdatePopoverView.swift` lines 233, 267 use
  `ProgressView(value:)` which are progress bars, not spinners.
- **Color / animation design changes** — we replicate the existing Figma
  spinner as-is (accent color, 75% arc, linear rotation). Any design tweaks
  are a separate task.

## Architectural alignment

### The target spinner

All three ACP files define an identical pattern:

```swift
// ACPConnectingPlaceholder.swift:86-97 (canonical)
private struct Spinner: View {
    @State private var angle: Double = 0
    @Environment(\.theme) private var theme
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(theme.color("accent"), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(angle))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: angle)
            .onAppear { angle = 360 }
    }
}
```

Variations across the three files: `lineWidth` (2 vs 1.5) and `duration`
(0.8 vs 0.7). The shared view should accept these as parameters with sensible
defaults.

### Suggested shared view location

`Alas/Sources/UI/Spinner.swift`. The repo's shared SwiftUI atoms currently
live under `Alas/Sources/UI` (`AlasButton`, `AlasToggle`, `AlasField`, etc.),
so the spinner should follow that convention.

### ProgressView() call-site inventory (17 spinner usages)

| # | File | Line | Context | Frame / Size |
|---|------|------|---------|--------------|
| 1 | `Center/Commit/CommitTabView.swift` | 37 | Loading commit details | maxWidth/maxHeight: .infinity |
| 2 | `Center/Commit/CommitEditorTabView.swift` | 62 | Loading commit editor | maxWidth/maxHeight: .infinity |
| 3 | `Center/Commit/CommitDiffView.swift` | 69 | Loading image diff | default |
| 4 | `Center/Commit/CommitDiffView.swift` | 140 | Loading text diff | .padding() |
| 5 | `Center/DiffTabView.swift` | 39 | Loading image diff | default |
| 6 | `Center/DiffTabView.swift` | 94 | Loading text diff | .padding() |
| 7 | `Center/MergeConflictToolbar.swift` | 54 | Agent resolving conflicts | .controlSize(.small) |
| 8 | `Center/MergeConflictTabView.swift` | 141 | Loading conflicted file | maxWidth/maxHeight: .infinity |
| 9 | `Center/ImageDiff/ImageDiffDifferenceView.swift` | 24 | Computing image diff | default |
| 10 | `Dialogs/BranchPicker.swift` | 23 | Loading branches | scaled + sized |
| 11 | `Right/Commit/AiSplitButton.swift` | 30 | AI commit generation | scaleEffect(0.5), 12×12 |
| 12 | `Right/FilesTabView.swift` | 78 | Loading directory children | default |
| 13 | `Right/ConflictsSection.swift` | 101 | Bulk conflict resolution | default |
| 14 | `Right/CommitsSectionView.swift` | 154 | Loading older commits | .controlSize(.mini) |
| 15 | `ACP/UI/ACPSetupNudgeBanner.swift` | 27 | Installing ACP adapter | .controlSize(.small), scaleEffect(0.7) |
| 16 | `Code/Editor/BlockedNudgeBanner.swift` | 50 | Gatekeeper remediation running | .controlSize(.small) |
| 17 | `Code/Editor/EditorLSPStatusBadge.swift` | 79 | LSP server loading | .controlSize(.mini), 9×9 |

Plus 3 existing private `Spinner` structs to consolidate into the shared one.

## Acceptance criteria

1. A single shared `Spinner` view exists with configurable `lineWidth`,
   `duration`, and frame size (with defaults matching the ACP originals).
2. All 17 `ProgressView()` spinner call sites in first-party code use the
   shared `Spinner` instead.
3. The three private `Spinner` structs in ACP are deleted, replaced by the
   shared view.
4. No `ProgressView()` spinner remains in first-party code (determinate
   progress bars in ThirdParty are excluded).
5. Visual appearance at each call site matches the Figma spinner (75% arc,
   accent color, linear rotation, rounded line caps).
6. Build succeeds with zero warnings on the existing Xcode scheme.
7. No regressions in existing functionality — spinners appear in the same
   contexts and same sizes as before.

## Open questions

1. **Where should the shared Spinner live?**
   Resolved recommendation: `Alas/Sources/UI/Spinner.swift`, matching the
   existing shared UI atom convention.

2. **Should the spinner color be parameterizable?**
   Recommendation: No for v1 — all current usages use `theme.color("accent")`.
   A color parameter can be added later if needed.

3. **Should full-screen spinners (items 1, 2, 8) get a different treatment?**
   Recommendation: No — just swap the inner `ProgressView()` for `Spinner()`
   inside the existing `.frame(maxWidth: .infinity, maxHeight: .infinity)`
   wrapper, picking a reasonable size (e.g. 20×20).

## Implementation order

1. **Create shared `Spinner` view** — `Alas/Sources/UI/Spinner.swift`.
   Accept `lineWidth: CGFloat = 2`, `duration: Double = 0.8`
   as init parameters. Frame is applied at the call site, not inside the view.
2. **Update ACP files** — Replace the three private `Spinner` structs with
   imports of the shared one. Verify existing frame/lineWidth/duration values
   are preserved.
3. **Update call sites in batch** — Replace `ProgressView()` with `Spinner()`
   at each of the 17 locations, adjusting `lineWidth`/`duration` and frame
   to match the visual weight of the original `ProgressView` at that size.
4. **Grep for remaining `ProgressView()`** — Confirm no spinner usages remain
   (only ThirdParty determinate bars should be left).
5. **Build and smoke-test** — Verify Xcode build, spot-check a few spinner
   locations visually.

## Risks / things to watch

- **Frame sizing**: `ProgressView()` with `.controlSize(.mini)` or
  `.scaleEffect()` has implicit sizing. The custom `Spinner` needs explicit
  `.frame()` at each site — get the pixel sizes right or things will look off.
- **Full-screen spinner sizing**: Items 1, 2, 8 wrap `ProgressView()` in
  `maxWidth/maxHeight: .infinity` — the Spinner needs an explicit size inside
  that frame or it will stretch to fill the entire area.
- **Animation lifecycle**: The custom Spinner triggers its animation via
  `.onAppear { angle = 360 }`. If any call site conditionally shows/hides the
  spinner without fully removing it from the view hierarchy, the animation
  might not restart. Test toggle scenarios.

## Definition of done (handoff sign-off)

- Grooming doc reviewed and accepted
- No open questions blocking implementation
- Call-site inventory verified against current `main` (line numbers may shift)
- Ready for design phase (implementer can work from this doc alone)
